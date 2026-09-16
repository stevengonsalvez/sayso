package ai.sayso.dictation.settings

import ai.sayso.dictation.core.LexiconRule
import ai.sayso.dictation.models.LocalModelCatalog
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Exercises the real SharedPreferences-backed [Settings] against an in-memory store. */
class SettingsTest {

    private val prefs = FakeSharedPreferences()
    private val settings = Settings(prefs)

    @Test
    fun `the default transcription model is the recommended on-device one`() {
        assertEquals("local/${LocalModelCatalog.default.dirName}", Settings.DEFAULT_STT_MODEL_ID)
    }

    @Test
    fun `an empty store yields the shipping defaults`() {
        assertEquals("local/sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8", settings.sttModelId)
        assertNull(settings.language)
        assertEquals(emptyList<String>(), settings.hints)
        assertFalse(settings.polishEnabled)
        assertEquals("rules/basic", settings.polishModelId)
        assertNull(settings.customPrompt)
        assertNull(settings.outputLanguage)
        assertEquals(emptyList<LexiconRule>(), settings.lexicon)
        assertEquals(300, settings.maxRecordingSeconds)
        assertTrue(settings.soundsEnabled)
        assertTrue(settings.historyEnabled)
        assertEquals(-1, settings.bubbleX)
        assertEquals(-1, settings.bubbleY)
    }

    @Test
    fun `every setting round trips`() {
        settings.sttModelId = "openai/gpt-4o-mini-transcribe"
        settings.language = "en"
        settings.hints = listOf("Sayso", "sherpa-onnx", "a \"quoted\" phrase")
        settings.polishEnabled = true
        settings.polishModelId = "openrouter/anthropic/claude-haiku-4.5"
        settings.customPrompt = "Only fix typos."
        settings.outputLanguage = "British English"
        settings.lexicon = listOf(LexiconRule("Kubernetes", listOf("kubernetes", "koobernetes")))
        settings.maxRecordingSeconds = 120
        settings.soundsEnabled = false
        settings.historyEnabled = false
        settings.bubbleX = 42
        settings.bubbleY = 1337

        val reloaded = Settings(prefs)
        assertEquals("openai/gpt-4o-mini-transcribe", reloaded.sttModelId)
        assertEquals("en", reloaded.language)
        assertEquals(listOf("Sayso", "sherpa-onnx", "a \"quoted\" phrase"), reloaded.hints)
        assertTrue(reloaded.polishEnabled)
        assertEquals("openrouter/anthropic/claude-haiku-4.5", reloaded.polishModelId)
        assertEquals("Only fix typos.", reloaded.customPrompt)
        assertEquals("British English", reloaded.outputLanguage)
        assertEquals(listOf(LexiconRule("Kubernetes", listOf("kubernetes", "koobernetes"))), reloaded.lexicon)
        assertEquals(120, reloaded.maxRecordingSeconds)
        assertFalse(reloaded.soundsEnabled)
        assertFalse(reloaded.historyEnabled)
        assertEquals(42, reloaded.bubbleX)
        assertEquals(1337, reloaded.bubbleY)
    }

    @Test
    fun `clearing an optional string removes the key rather than storing a blank`() {
        settings.language = "en"
        settings.customPrompt = "something"

        settings.language = null
        settings.customPrompt = "   "

        assertNull(settings.language)
        assertNull(settings.customPrompt)
        assertFalse(prefs.snapshot.containsKey(Settings.KEY_LANGUAGE))
        assertFalse(prefs.snapshot.containsKey(Settings.KEY_CUSTOM_PROMPT))
    }

    @Test
    fun `blank and corrupt stored values fall back to the defaults`() {
        val corrupt = Settings(
            FakeSharedPreferences(
                mutableMapOf(
                    Settings.KEY_STT_MODEL_ID to "",
                    Settings.KEY_POLISH_MODEL_ID to "  ",
                    Settings.KEY_HINTS to "not json",
                    Settings.KEY_LEXICON to "{}",
                ),
            ),
        )

        assertEquals(Settings.DEFAULT_STT_MODEL_ID, corrupt.sttModelId)
        assertEquals(Settings.DEFAULT_POLISH_MODEL_ID, corrupt.polishModelId)
        assertEquals(emptyList<String>(), corrupt.hints)
        assertEquals(emptyList<LexiconRule>(), corrupt.lexicon)
    }

    @Test
    fun `blank hints are dropped on write`() {
        settings.hints = listOf("keep", "  ", "")

        assertEquals(listOf("keep"), Settings(prefs).hints)
    }

    @Test
    fun `a recording length left by an older build is clamped to what the app will hold`() {
        settings.maxRecordingSeconds = 600
        assertEquals(300, Settings(prefs).maxRecordingSeconds)

        settings.maxRecordingSeconds = 5
        assertEquals(30, Settings(prefs).maxRecordingSeconds)

        settings.maxRecordingSeconds = 120
        assertEquals(120, Settings(prefs).maxRecordingSeconds)
    }
}
