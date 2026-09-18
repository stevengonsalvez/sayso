package ai.sayso.dictation.core

/**
 * Shared contracts for the dictation pipeline. Every module codes against these
 * types so that providers, the pipeline, the service and the UI can be built
 * independently.
 */

/** A recorded clip: 16-bit little-endian PCM, mono. */
class AudioClip(val pcm16: ByteArray, val sampleRate: Int = DEFAULT_SAMPLE_RATE) {
    // A clip decoded from a malformed header could otherwise divide by zero here, which
    // would take down a dictation on the way to reporting the real problem.
    val durationMs: Long get() = pcm16.size * 1000L / (sampleRate.coerceAtLeast(1) * 2)
    val isEmpty: Boolean get() = pcm16.isEmpty()

    companion object {
        const val DEFAULT_SAMPLE_RATE = 16_000
    }
}

/** Identifies a speech-to-text model. `id` is "<providerId>/<modelName>". */
data class SttModel(val id: String, val displayName: String, val note: String = "") {
    val providerId: String get() = id.substringBefore('/')
    val modelName: String get() = id.substringAfter('/')
}

data class TranscriptionRequest(
    val clip: AudioClip,
    val modelName: String,
    /** ISO-639-1 code such as "en"; null means provider auto-detect. */
    val language: String? = null,
    /** Words or phrases to bias recognition towards (names, jargon). */
    val hints: List<String> = emptyList(),
)

sealed class TranscriptionResult {
    data class Success(val text: String) : TranscriptionResult()
    data class Failure(val message: String) : TranscriptionResult()
}

interface TranscriptionProvider {
    val id: String
    val displayName: String
    val needsApiKey: Boolean
    /** Where the user can obtain a key; null for local providers. */
    val apiKeyUrl: String?
    val models: List<SttModel>
    suspend fun transcribe(request: TranscriptionRequest, apiKey: String?): TranscriptionResult
}

/** Identifies a text-cleanup model. `id` is "<providerId>/<modelName>". */
data class PolishModel(val id: String, val displayName: String) {
    val providerId: String get() = id.substringBefore('/')
    val modelName: String get() = id.substringAfter('/')
}

sealed class PolishResult {
    data class Success(val text: String) : PolishResult()
    data class Failure(val message: String) : PolishResult()
}

interface PolishProvider {
    val id: String
    val displayName: String
    val needsApiKey: Boolean
    val apiKeyUrl: String?
    val models: List<PolishModel>
    /** Whether a caller-supplied system prompt is honoured (false for rule-based cleaners). */
    val supportsCustomPrompt: Boolean
    suspend fun polish(systemPrompt: String, userMessage: String, modelName: String, apiKey: String?): PolishResult
}

/** A personal-vocabulary rule: any alias is rewritten to the canonical spelling. */
data class LexiconRule(val canonical: String, val aliases: List<String>)

/** Categories for pronunciation entries, matching developer workflows. */
enum class PronunciationCategory(val displayName: String) {
    TECHNICAL("Technical"),
    NAMES("Names"),
    ACRONYMS("Acronyms"),
    SYMBOLS("Symbols"),
    BRANDS("Brands"),
    MEDICAL("Medical"),
    CUSTOM("Custom");

    companion object {
        fun fromString(value: String?): PronunciationCategory =
            entries.firstOrNull {
                it.name.equals(value, ignoreCase = true) || it.displayName.equals(value, ignoreCase = true)
            } ?: CUSTOM
    }
}

/**
 * Custom pronunciation and technical dictionary entry.
 * Supports phonetic mapping, text replacement, regex, and category filtering.
 */
data class PronunciationEntry(
    val id: String = java.util.UUID.randomUUID().toString(),
    val word: String,
    val pronunciation: String,
    val replacement: String? = null,
    val category: PronunciationCategory = PronunciationCategory.TECHNICAL,
    val isRegex: Boolean = false,
    val caseSensitive: Boolean = false,
) {
    fun toLexiconRule(): LexiconRule {
        val aliases = mutableListOf<String>()
        val p = pronunciation.trim()
        val r = replacement?.trim()
        val w = word.trim()
        if (p.isNotBlank() && !p.equals(w, ignoreCase = true)) {
            aliases += p
        }
        if (!r.isNullOrBlank() && !r.equals(w, ignoreCase = true) && !aliases.contains(r)) {
            aliases += r
        }
        return LexiconRule(canonical = w, aliases = aliases)
    }
}

/** Secret storage keyed by provider id. */
interface SecretStore {
    fun get(providerId: String): String?
    fun set(providerId: String, value: String)
    fun remove(providerId: String)
}

enum class OutputMethod { INSERTED, CLIPBOARD, NONE }

/** Read/write app settings. Implemented over SharedPreferences; fakeable in tests. */
interface SettingsStore {
    var sttModelId: String
    var language: String?
    var hints: List<String>
    var polishEnabled: Boolean
    var polishModelId: String
    var customPrompt: String?
    var outputLanguage: String?
    var lexicon: List<LexiconRule>
    var pronunciations: List<PronunciationEntry>
        get() = lexicon.map {
            PronunciationEntry(
                word = it.canonical,
                pronunciation = it.aliases.firstOrNull().orEmpty(),
                replacement = it.aliases.drop(1).firstOrNull(),
            )
        }
        set(value) {
            lexicon = value.map { it.toLexiconRule() }
        }
    var maxRecordingSeconds: Int
    var soundsEnabled: Boolean
    var historyEnabled: Boolean
    var bubbleX: Int
    var bubbleY: Int
    var bubbleAlwaysVisible: Boolean
    var wakeWordEnabled: Boolean
    var appContextAwarenessEnabled: Boolean get() = true; set(_) {}
    var smartDictationModesEnabled: Boolean get() = true; set(_) {}
    var hasCompletedOnboarding: Boolean get() = false; set(_) {}
    var autoStopSilenceEnabled: Boolean get() = true; set(_) {}
    var silenceTimeoutSeconds: Float get() = 1.8f; set(_) {}
}

data class HistoryEntry(
    val id: String,
    val createdAt: Long,
    val durationMs: Long,
    val rawText: String,
    val polishedText: String?,
    val sttModelId: String,
    val polishModelId: String?,
    val outputMethod: OutputMethod,
    val error: String?,
    /** Absolute path of the saved WAV, if kept. */
    val audioPath: String?,
) {
    val finalText: String get() = polishedText?.takeIf { it.isNotBlank() } ?: rawText
}

interface HistoryRepository {
    suspend fun add(entry: HistoryEntry)
    suspend fun update(entry: HistoryEntry)
    suspend fun all(): List<HistoryEntry>
    suspend fun delete(id: String)
    suspend fun clear()
    /** Persist a clip for later reprocessing; returns absolute path. */
    suspend fun saveAudio(id: String, clip: AudioClip): String
    suspend fun loadAudio(path: String): AudioClip?
}

data class PipelineResult(
    val text: String,
    val entry: HistoryEntry,
    val error: String?,
    /** Something the run did differently that the user should know about, such as a fallback. */
    val notice: String? = null,
)

interface DictationPipeline {
    /** Transcribe, apply lexicon, polish. Never throws; errors land in [PipelineResult.error]. */
    suspend fun run(clip: AudioClip): PipelineResult = run(clip, targetPackage = null)
    suspend fun run(clip: AudioClip, targetPackage: String?): PipelineResult
    /** Re-run [run] on the saved audio of an entry with current settings; returns the updated entry. */
    suspend fun reprocess(entry: HistoryEntry): PipelineResult?
}
