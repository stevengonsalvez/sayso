package com.shotclubhouse.sayso.pipeline

import com.shotclubhouse.sayso.core.AudioClip
import com.shotclubhouse.sayso.core.DictationPipeline
import com.shotclubhouse.sayso.core.HistoryEntry
import com.shotclubhouse.sayso.core.HistoryRepository
import com.shotclubhouse.sayso.core.OutputMethod
import com.shotclubhouse.sayso.core.PipelineResult
import com.shotclubhouse.sayso.core.PolishModel
import com.shotclubhouse.sayso.core.PolishProvider
import com.shotclubhouse.sayso.core.PolishResult
import com.shotclubhouse.sayso.core.SecretStore
import com.shotclubhouse.sayso.core.SettingsStore
import com.shotclubhouse.sayso.core.SttModel
import com.shotclubhouse.sayso.core.TranscriptionProvider
import com.shotclubhouse.sayso.core.TranscriptionRequest
import com.shotclubhouse.sayso.core.TranscriptionResult
import com.shotclubhouse.sayso.polish.CleanupPolicy
import com.shotclubhouse.sayso.polish.Lexicon
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

    override suspend fun run(clip: AudioClip): PipelineResult = process(clip, previous = null)

    override suspend fun reprocess(entry: HistoryEntry): PipelineResult? {
        val repository = history ?: return null
        val path = entry.audioPath ?: return null
        val clip = ignoringFailure { repository.loadAudio(path) } ?: return null
        return process(clip, previous = entry)
    }

    private suspend fun process(clip: AudioClip, previous: HistoryEntry?): PipelineResult {
        if (clip.isEmpty) return finish(clip, previous, error = "No audio captured")

        val model = resolveStt()
            ?: return finish(clip, previous, error = "No transcription model is set up")

        val transcription = try {
            model.provider.transcribe(
                TranscriptionRequest(
                    clip = clip,
                    modelName = model.model.modelName,
                    language = settings.language,
                    hints = settings.hints,
                ),
                model.apiKey,
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            TranscriptionResult.Failure(e.message ?: "Transcription failed")
        }

        if (transcription is TranscriptionResult.Failure) {
            return finish(clip, previous, error = transcription.message, sttModelId = model.model.id)
        }

        val transcript = (transcription as TranscriptionResult.Success).text.trim()
        if (transcript.isBlank()) {
            return finish(clip, previous, error = "No speech detected", sttModelId = model.model.id)
        }

        val raw = Lexicon.apply(transcript, settings.lexicon)
        val cleanup = if (settings.polishEnabled) applyPolish(raw) else Cleanup.SKIPPED

        return finish(
            clip = clip,
            previous = previous,
            error = cleanup.error,
            sttModelId = model.model.id,
            rawText = raw,
            polishedText = cleanup.text,
            polishModelId = cleanup.modelId,
        )
    }

    private class Resolved(
        val provider: TranscriptionProvider,
        val model: SttModel,
        val apiKey: String?,
    )

    /**
     * Uses the configured model when possible. An unknown id, or a cloud provider with no
     * saved key, silently falls back to the installed local model.
     */
    private fun resolveStt(): Resolved? {
        val configured = stt.find(settings.sttModelId)
        if (configured != null) {
            val (provider, model) = configured
            if (!provider.needsApiKey) return Resolved(provider, model, null)
            key(provider.id)?.let { return Resolved(provider, model, it) }
        }
        val fallbackId = stt.localFallbackModelId ?: return null
        val (provider, model) = stt.find(fallbackId) ?: return null
        if (provider.needsApiKey && key(provider.id) == null) return null
        return Resolved(provider, model, key(provider.id))
    }

    private class Cleanup(val text: String?, val modelId: String?, val error: String?) {
        companion object {
            val SKIPPED = Cleanup(null, null, null)
        }
    }

    private suspend fun applyPolish(raw: String): Cleanup {
        val (provider, model) = polish.find(settings.polishModelId) ?: return Cleanup.SKIPPED
        val apiKey = if (provider.needsApiKey) key(provider.id) ?: return Cleanup.SKIPPED else null

        val base = settings.customPrompt
            ?.takeIf { it.isNotBlank() && provider.supportsCustomPrompt }
            ?: CleanupPolicy.BASE_PROMPT

        val result = try {
            provider.polish(
                systemPrompt = CleanupPolicy.systemPrompt(base, settings.outputLanguage, settings.lexicon),
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

        return PipelineResult(text = entry.finalText, entry = entry, error = error)
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
