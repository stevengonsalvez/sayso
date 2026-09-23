package ai.sayso.dictation.settings

import android.content.Context
import android.content.SharedPreferences
import ai.sayso.dictation.core.LexiconRule
import ai.sayso.dictation.core.SettingsStore
import ai.sayso.dictation.models.LocalModelCatalog
import ai.sayso.dictation.polish.Lexicon
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray

/** Typed view over the app's SharedPreferences file. */
class Settings(private val prefs: SharedPreferences) : SettingsStore {

    override var sttModelId: String
        get() = prefs.getString(KEY_STT_MODEL_ID, null)?.takeIf { it.isNotBlank() } ?: DEFAULT_STT_MODEL_ID
        set(value) = putString(KEY_STT_MODEL_ID, value)

    override var language: String?
        get() = optionalString(KEY_LANGUAGE)
        set(value) = putString(KEY_LANGUAGE, value)

    override var hints: List<String>
        get() = decodeStrings(prefs.getString(KEY_HINTS, null))
        set(value) = putString(KEY_HINTS, encodeStrings(value))

    override var polishEnabled: Boolean
        get() = prefs.getBoolean(KEY_POLISH_ENABLED, false)
        set(value) = prefs.edit().putBoolean(KEY_POLISH_ENABLED, value).apply()

    override var polishModelId: String
        get() = prefs.getString(KEY_POLISH_MODEL_ID, null)?.takeIf { it.isNotBlank() } ?: DEFAULT_POLISH_MODEL_ID
        set(value) = putString(KEY_POLISH_MODEL_ID, value)

    override var customPrompt: String?
        get() = optionalString(KEY_CUSTOM_PROMPT)
        set(value) = putString(KEY_CUSTOM_PROMPT, value)

    override var outputLanguage: String?
        get() = optionalString(KEY_OUTPUT_LANGUAGE)
        set(value) = putString(KEY_OUTPUT_LANGUAGE, value)

    override var lexicon: List<LexiconRule>
        get() = Lexicon.decode(prefs.getString(KEY_LEXICON, null).orEmpty())
        set(value) = putString(KEY_LEXICON, Lexicon.encode(value))

    override var pronunciations: List<ai.sayso.dictation.core.PronunciationEntry>
        get() {
            val raw = prefs.getString(KEY_PRONUNCIATIONS, null)
            if (raw.isNullOrBlank()) {
                val legacy = lexicon
                if (legacy.isNotEmpty()) {
                    return legacy.map {
                        ai.sayso.dictation.core.PronunciationEntry(
                            word = it.canonical,
                            pronunciation = it.aliases.firstOrNull().orEmpty(),
                            replacement = it.aliases.drop(1).firstOrNull(),
                            category = ai.sayso.dictation.core.PronunciationCategory.TECHNICAL,
                        )
                    }
                }
                return ai.sayso.dictation.polish.PronunciationDefaults.entries
            }
            return Lexicon.decodePronunciations(raw)
        }
        set(value) {
            putString(KEY_PRONUNCIATIONS, Lexicon.encodePronunciations(value))
            lexicon = value.map { it.toLexiconRule() }
        }

    override var maxRecordingSeconds: Int
        // Clamped on read so a value left by an older build cannot ask for a clip the app
        // will not hold in memory.
        get() = prefs.getInt(KEY_MAX_RECORDING_SECONDS, DEFAULT_MAX_RECORDING_SECONDS)
            .coerceIn(MIN_RECORDING_SECONDS, MAX_RECORDING_SECONDS)
        set(value) = prefs.edit().putInt(KEY_MAX_RECORDING_SECONDS, value).apply()

    override var soundsEnabled: Boolean
        get() = prefs.getBoolean(KEY_SOUNDS_ENABLED, true)
        set(value) = prefs.edit().putBoolean(KEY_SOUNDS_ENABLED, value).apply()

    override var historyEnabled: Boolean
        get() = prefs.getBoolean(KEY_HISTORY_ENABLED, true)
        set(value) = prefs.edit().putBoolean(KEY_HISTORY_ENABLED, value).apply()

    override var bubbleX: Int
        get() = prefs.getInt(KEY_BUBBLE_X, DEFAULT_BUBBLE_POSITION)
        set(value) = prefs.edit().putInt(KEY_BUBBLE_X, value).apply()

    override var bubbleY: Int
        get() = prefs.getInt(KEY_BUBBLE_Y, DEFAULT_BUBBLE_POSITION)
        set(value) = prefs.edit().putInt(KEY_BUBBLE_Y, value).apply()

    override var bubbleAlwaysVisible: Boolean
        get() = prefs.getBoolean(KEY_BUBBLE_ALWAYS_VISIBLE, false)
        set(value) = prefs.edit().putBoolean(KEY_BUBBLE_ALWAYS_VISIBLE, value).apply()

    override var wakeWordEnabled: Boolean
        get() = prefs.getBoolean(KEY_WAKE_WORD_ENABLED, false)
        set(value) = prefs.edit().putBoolean(KEY_WAKE_WORD_ENABLED, value).apply()

    override var wakeWordPhrase: String
        get() = prefs.getString(KEY_WAKE_WORD_PHRASE, SettingsStore.WAKE_PHRASE_BOTH) ?: SettingsStore.WAKE_PHRASE_BOTH
        set(value) = putString(KEY_WAKE_WORD_PHRASE, value)

    override var appContextAwarenessEnabled: Boolean
        get() = prefs.getBoolean(KEY_APP_CONTEXT_AWARENESS, true)
        set(value) = prefs.edit().putBoolean(KEY_APP_CONTEXT_AWARENESS, value).apply()

    override var smartDictationModesEnabled: Boolean
        get() = prefs.getBoolean(KEY_SMART_DICTATION_MODES, true)
        set(value) = prefs.edit().putBoolean(KEY_SMART_DICTATION_MODES, value).apply()

    override var hasCompletedOnboarding: Boolean
        get() = prefs.getBoolean(KEY_HAS_COMPLETED_ONBOARDING, false)
        set(value) = prefs.edit().putBoolean(KEY_HAS_COMPLETED_ONBOARDING, value).apply()

    override var autoStopSilenceEnabled: Boolean
        get() = prefs.getBoolean(KEY_AUTO_STOP_SILENCE, true)
        set(value) = prefs.edit().putBoolean(KEY_AUTO_STOP_SILENCE, value).apply()

    override var silenceTimeoutSeconds: Float
        get() = prefs.getFloat(KEY_SILENCE_TIMEOUT_SECONDS, 1.8f)
        set(value) = prefs.edit().putFloat(KEY_SILENCE_TIMEOUT_SECONDS, value).apply()

    override var transliterateIndicToLatin: Boolean
        get() = prefs.getBoolean(KEY_TRANSLITERATE_INDIC_TO_LATIN, false)
        set(value) = prefs.edit().putBoolean(KEY_TRANSLITERATE_INDIC_TO_LATIN, value).apply()

    override var autoLanguageRoutingEnabled: Boolean
        get() = prefs.getBoolean(KEY_AUTO_LANGUAGE_ROUTING, false)
        set(value) = prefs.edit().putBoolean(KEY_AUTO_LANGUAGE_ROUTING, value).apply()

    private fun optionalString(key: String): String? =
        prefs.getString(key, null)?.takeIf { it.isNotBlank() }

    private fun putString(key: String, value: String?) {
        val editor = prefs.edit()
        if (value.isNullOrBlank()) editor.remove(key) else editor.putString(key, value)
        editor.apply()
    }

    private fun encodeStrings(values: List<String>): String =
        buildJsonArray { values.filter { it.isNotBlank() }.forEach { add(it) } }.toString()

    private fun decodeStrings(raw: String?): List<String> {
        if (raw.isNullOrBlank()) return emptyList()
        val array = runCatching { Json.parseToJsonElement(raw) as? JsonArray }.getOrNull() ?: return emptyList()
        return array.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
    }

    companion object {
        /** SharedPreferences file name. */
        const val PREFS_NAME = "sayso"

        /** "<provider>/<model>" id of the speech-to-text model. */
        const val KEY_STT_MODEL_ID = "stt_model_id"

        /** ISO-639-1 spoken language, or absent for provider auto-detect. */
        const val KEY_LANGUAGE = "language"

        /** JSON array of recognition bias phrases. */
        const val KEY_HINTS = "hints"

        /** Whether transcripts are passed through a cleanup model. */
        const val KEY_POLISH_ENABLED = "polish_enabled"

        /** "<provider>/<model>" id of the cleanup model. */
        const val KEY_POLISH_MODEL_ID = "polish_model_id"

        /** User-edited system prompt replacing the built-in cleanup prompt. */
        const val KEY_CUSTOM_PROMPT = "custom_prompt"

        /** Language whose spelling conventions the cleanup output should follow. */
        const val KEY_OUTPUT_LANGUAGE = "output_language"

        /** JSON array of lexicon rules, see [Lexicon.encode]. */
        const val KEY_LEXICON = "lexicon"

        /** JSON array of pronunciation entries, see [Lexicon.encodePronunciations]. */
        const val KEY_PRONUNCIATIONS = "pronunciation_dictionary"

        /** Hard cap on a single recording. */
        const val KEY_MAX_RECORDING_SECONDS = "max_recording_seconds"

        /** Whether start/stop tones are played. */
        const val KEY_SOUNDS_ENABLED = "sounds_enabled"

        /** Whether transcripts and audio are kept on device. */
        const val KEY_HISTORY_ENABLED = "history_enabled"

        /** Last bubble position in pixels; [DEFAULT_BUBBLE_POSITION] means "not placed yet". */
        const val KEY_BUBBLE_X = "bubble_x"
        const val KEY_BUBBLE_Y = "bubble_y"

        /** Whether the bubble is shown everywhere or only when an editable text field is focused. */
        const val KEY_BUBBLE_ALWAYS_VISIBLE = "bubble_always_visible"

        /** Whether continuous on-device wake-word detection is running. */
        const val KEY_WAKE_WORD_ENABLED = "wake_word_enabled"

        /** Which wake phrase triggers detection: "both", "hey_sayso", or "sayso". */
        const val KEY_WAKE_WORD_PHRASE = "wake_word_phrase"

        /** Whether the active target application context alters dictation style. */
        const val KEY_APP_CONTEXT_AWARENESS = "app_context_awareness_enabled"

        /** Whether smart dictation formatting (checklists, summaries) is active. */
        const val KEY_SMART_DICTATION_MODES = "smart_dictation_modes_enabled"

        /** Whether the user has completed or dismissed first-run onboarding. */
        const val KEY_HAS_COMPLETED_ONBOARDING = "has_completed_onboarding"

        /** Whether hands-free recording automatically ends after sustained silence. */
        const val KEY_AUTO_STOP_SILENCE = "auto_stop_silence"

        /** Sustained silence duration in seconds before auto-stopping recording. */
        const val KEY_SILENCE_TIMEOUT_SECONDS = "silence_timeout_seconds"

        /** Whether Indic transcripts (ta, hi, ml) are phonetically transliterated into Latin script. */
        const val KEY_TRANSLITERATE_INDIC_TO_LATIN = "transliterate_indic_to_latin"

        /** Whether early audio (first 1.5s) is classified to automatically route English vs Indic models. */
        const val KEY_AUTO_LANGUAGE_ROUTING = "auto_language_routing"

        /** Derived from the catalog so retiring the recommended model cannot leave this stale. */
        val DEFAULT_STT_MODEL_ID = "local/${LocalModelCatalog.default.dirName}"

        const val DEFAULT_POLISH_MODEL_ID = "rules/basic"
        const val MIN_RECORDING_SECONDS = 30
        const val MAX_RECORDING_SECONDS = 300

        /** New installs record for as long as the app allows. */
        const val DEFAULT_MAX_RECORDING_SECONDS = MAX_RECORDING_SECONDS
        const val DEFAULT_BUBBLE_POSITION = -1

        fun open(context: Context): Settings =
            Settings(context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE))
    }
}
