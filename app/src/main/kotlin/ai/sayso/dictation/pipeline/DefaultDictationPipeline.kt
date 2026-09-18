package ai.sayso.dictation.pipeline

import ai.sayso.dictation.core.AudioClip
import ai.sayso.dictation.core.DictationPipeline
import ai.sayso.dictation.core.HistoryEntry
import ai.sayso.dictation.core.HistoryRepository
import ai.sayso.dictation.core.OutputMethod
import ai.sayso.dictation.core.PipelineResult
import ai.sayso.dictation.core.PolishModel
import ai.sayso.dictation.core.PolishProvider
import ai.sayso.dictation.core.PolishResult
import ai.sayso.dictation.core.SecretStore
import ai.sayso.dictation.core.SettingsStore
import ai.sayso.dictation.core.SttModel
import ai.sayso.dictation.core.TranscriptionProvider
import ai.sayso.dictation.core.TranscriptionRequest
import ai.sayso.dictation.core.TranscriptionResult
import ai.sayso.dictation.polish.CleanupPolicy
import ai.sayso.dictation.polish.Lexicon
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException

/** Lookup of speech-to-text models, plus the on-device model to fall back to. */
interface SttCatalog {
    fun find(modelId: String): Pair<TranscriptionProvider, SttModel>?

    /** Id of an installed local model, or null when none is available. */
    val localFallbackModelId: String?
}

/** Lookup of cleanup models. */
interface PolishCatalog {
    fun find(modelId: String): Pair<PolishProvider, PolishModel>?
}

/**
 * Clip in, text out: transcribe, apply the personal lexicon, optionally clean up with an
 * LLM, then record the result in history. Provider failures become entries with an
 * `error`, never exceptions.
 */
class DefaultDictationPipeline(
    private val settings: SettingsStore,
    private val secrets: SecretStore,
    private val stt: SttCatalog,
    private val polish: PolishCatalog,
    private val history: HistoryRepository? = null,
) : DictationPipeline {

    // The pipeline owns its dispatcher. Every step blocks (sockets, on-device inference, the
    // history file), so callers on the main thread, the service and the history screen, hand
    // the whole run over rather than each wrapping it themselves.
    override suspend fun run(clip: AudioClip): PipelineResult = run(clip, targetPackage = null)

    override suspend fun run(clip: AudioClip, targetPackage: String?): PipelineResult = withContext(Dispatchers.IO) {
        process(clip, previous = null, targetPackage = targetPackage)
    }

    override suspend fun reprocess(entry: HistoryEntry): PipelineResult? = withContext(Dispatchers.IO) {
        val repository = history ?: return@withContext null
        val path = entry.audioPath ?: return@withContext null
        val clip = ignoringFailure { repository.loadAudio(path) } ?: return@withContext null
        process(clip, previous = entry, targetPackage = null)
    }

    private suspend fun process(clip: AudioClip, previous: HistoryEntry?, targetPackage: String? = null): PipelineResult {
        if (clip.isEmpty) return finish(clip, previous, error = "No audio captured")

        val model = resolveStt(clip)
            ?: return finish(clip, previous, error = "No transcription model is set up")

        val notice = model.notice

        val dictationHints = (settings.hints + settings.pronunciations.filter { !it.isRegex && it.word.length in 2..40 }.map { it.word })
            .distinct()
            .take(100)

        val transcription = try {
            model.provider.transcribe(
                TranscriptionRequest(
                    clip = clip,
                    modelName = model.model.modelName,
                    language = settings.language,
                    hints = dictationHints,
                ),
                model.apiKey,
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            TranscriptionResult.Failure(e.message ?: "Transcription failed")
        }

        if (transcription is TranscriptionResult.Failure) {
            return finish(clip, previous, transcription.message, model.model.id, notice = notice)
        }

        val transcript = (transcription as TranscriptionResult.Success).text.trim()
        if (transcript.isBlank()) {
            return finish(clip, previous, "No speech detected", model.model.id, notice = notice)
        }

        val raw = Lexicon.applyPronunciations(transcript, settings.pronunciations)
        val cleanup = if (settings.polishEnabled) applyPolish(raw, targetPackage) else Cleanup.SKIPPED

        return finish(
            clip = clip,
            previous = previous,
            error = cleanup.error,
            sttModelId = model.model.id,
            rawText = raw,
            polishedText = cleanup.text,
            polishModelId = cleanup.modelId,
            notice = listOfNotNull(notice, cleanup.notice).joinToString(". ").ifEmpty { null },
        )
    }

    private class Resolved(
        val provider: TranscriptionProvider,
        val model: SttModel,
        val apiKey: String?,
        /** Set when this is not the model the user chose. */
        val notice: String? = null,
    )

    /**
     * Uses the configured model when possible. An unknown id, or a cloud provider with no
     * saved key, falls back to the installed local model; a missing key is the case the user
     * can act on, so that one carries a notice.
     */
    private fun resolveStt(clip: AudioClip? = null): Resolved? {
        val targetModelId = if (settings.autoLanguageRoutingEnabled && clip != null && !clip.isEmpty) {
            val installedIds = ai.sayso.dictation.models.LocalModelCatalog.all
                .map { "local/${it.dirName}" }
                .filter { stt.find(it) != null }
                .toSet()
            val decision = ai.sayso.dictation.models.EarlyLidRouter.route(clip, installedIds, settings.sttModelId)
            decision.recommendedModelId
        } else {
            settings.sttModelId
        }

        var keyless: TranscriptionProvider? = null
        val configured = stt.find(targetModelId)
        if (configured != null) {
            val (provider, model) = configured
            val routingNotice = if (targetModelId != settings.sttModelId) "Auto-routed to ${model.displayName}" else null
            if (!provider.needsApiKey) return Resolved(provider, model, null, routingNotice)
            key(provider.id)?.let { return Resolved(provider, model, it, routingNotice) }
            keyless = provider
        }
        val fallbackId = stt.localFallbackModelId ?: return null
        val (provider, model) = stt.find(fallbackId) ?: return null
        if (provider.needsApiKey && key(provider.id) == null) return null
        val notice = keyless?.let { "No API key for ${it.displayName}, used ${model.displayName}" }
        return Resolved(provider, model, key(provider.id), notice)
    }

    private class Cleanup(
        val text: String?,
        val modelId: String?,
        val error: String?,
        /** Why cleanup did not run, when the user asked for it and it was skipped anyway. */
        val notice: String? = null,
    ) {
        companion object {
            val SKIPPED = Cleanup(null, null, null)

            fun skipped(why: String) = Cleanup(null, null, null, "Cleanup skipped: $why")
        }
    }

    /**
     * Cleanup is optional, so a missing key or a model that is no longer offered keeps the raw
     * transcript rather than failing the dictation. It is not silent though: without a word the
     * user just sees cleanup quietly stop working.
     */
    private suspend fun applyPolish(raw: String, targetPackage: String? = null): Cleanup {
        val (provider, model) = polish.find(settings.polishModelId)
            ?: return Cleanup.skipped("unknown cleanup model")
        val apiKey = if (provider.needsApiKey) {
            key(provider.id) ?: return Cleanup.skipped("no API key for ${provider.displayName}")
        } else {
            null
        }

        val base = settings.customPrompt
            ?.takeIf { it.isNotBlank() && provider.supportsCustomPrompt }
            ?: CleanupPolicy.BASE_PROMPT

        val appContext = if (settings.appContextAwarenessEnabled) {
            CleanupPolicy.AppContextCategory.fromPackage(targetPackage)
        } else {
            null
        }

        val result = try {
            provider.polish(
                systemPrompt = CleanupPolicy.systemPrompt(
                    base = base,
                    outputLanguage = settings.outputLanguage,
                    lexicon = settings.lexicon,
                    appContext = appContext,
                    enableSmartDictation = settings.smartDictationModesEnabled,
                    transliterateIndicToLatin = settings.transliterateIndicToLatin,
                ),
                userMessage = CleanupPolicy.userMessage(raw),
                modelName = model.modelName,
                apiKey = apiKey,
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            PolishResult.Failure(e.message ?: "Cleanup failed")
        }

        return when (result) {
            is PolishResult.Success -> Cleanup(result.text.takeIf { it.isNotBlank() }, model.id, null)
            is PolishResult.Failure -> Cleanup(null, model.id, result.message)
        }
    }

    private fun key(providerId: String): String? = secrets.get(providerId)?.takeIf { it.isNotBlank() }

    private suspend fun finish(
        clip: AudioClip,
        previous: HistoryEntry?,
        error: String?,
        sttModelId: String = previous?.sttModelId ?: settings.sttModelId,
        // A failed re-run must not replace what is already stored with an empty transcript.
        rawText: String = previous?.rawText ?: "",
        polishedText: String? = previous?.polishedText,
        polishModelId: String? = previous?.polishModelId,
        notice: String? = null,
    ): PipelineResult {
        var entry = HistoryEntry(
            id = previous?.id ?: UUID.randomUUID().toString(),
            createdAt = previous?.createdAt ?: System.currentTimeMillis(),
            durationMs = clip.durationMs,
            rawText = rawText,
            polishedText = polishedText,
            sttModelId = sttModelId,
            polishModelId = polishModelId,
            outputMethod = previous?.outputMethod ?: OutputMethod.NONE,
            error = error,
            audioPath = previous?.audioPath,
        )

        val repository = history
        if (repository != null) {
            if (previous != null) {
                ignoringFailure { repository.update(entry) }
            } else if (settings.historyEnabled) {
                val path = ignoringFailure { repository.saveAudio(entry.id, clip) }
                entry = entry.copy(audioPath = path)
                ignoringFailure { repository.add(entry) }
            }
        }

        return PipelineResult(text = entry.finalText, entry = entry, error = error, notice = notice)
    }

    /** History is a convenience, not the dictation itself: a storage failure must not sink a run. */
    private suspend fun <T> ignoringFailure(block: suspend () -> T): T? = try {
        block()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        null
    }
}
