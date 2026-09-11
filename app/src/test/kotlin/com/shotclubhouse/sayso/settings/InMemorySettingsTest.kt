package com.shotclubhouse.sayso.settings

import com.shotclubhouse.sayso.core.LexiconRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InMemorySettingsTest {

    @Test
    fun `defaults match the documented shipping defaults`() {
        val settings = InMemorySettings()

        assertEquals(
            "local/sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8",
            settings.sttModelId,
        )
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
    fun `keys are distinct so nothing overwrites a sibling setting`() {
        val keys = listOf(
            Settings.KEY_STT_MODEL_ID,
            Settings.KEY_LANGUAGE,
            Settings.KEY_HINTS,
            Settings.KEY_POLISH_ENABLED,
            Settings.KEY_POLISH_MODEL_ID,
            Settings.KEY_CUSTOM_PROMPT,
            Settings.KEY_OUTPUT_LANGUAGE,
            Settings.KEY_LEXICON,
            Settings.KEY_MAX_RECORDING_SECONDS,
            Settings.KEY_SOUNDS_ENABLED,
            Settings.KEY_HISTORY_ENABLED,
            Settings.KEY_BUBBLE_X,
            Settings.KEY_BUBBLE_Y,
        )

        assertEquals(keys.size, keys.toSet().size)
        assertEquals("sayso", Settings.PREFS_NAME)
        assertEquals("sayso_secrets", KeystoreSecretStore.PREFS_NAME)
        assertEquals("sayso.secrets", KeystoreSecretStore.KEY_ALIAS)
    }

    @Test
    fun `the in memory secret store behaves like the real one`() {
        val secrets = InMemorySecretStore(mapOf("openai" to "sk-a"))

        assertEquals("sk-a", secrets.get("openai"))
        assertNull(secrets.get("groq"))

        secrets.set("groq", "gsk-b")
        assertEquals("gsk-b", secrets.get("groq"))

        secrets.remove("groq")
        assertNull(secrets.get("groq"))
    }
}
