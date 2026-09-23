package ai.sayso.dictation.service

import ai.sayso.dictation.core.SettingsStore
import ai.sayso.dictation.settings.InMemorySettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WakeWordDetectorTest {

    @Test
    fun `wake word setting defaults to false`() {
        val settings = InMemorySettings()
        assertFalse(settings.wakeWordEnabled)
        assertEquals(SettingsStore.WAKE_PHRASE_BOTH, settings.wakeWordPhrase)
    }

    @Test
    fun `wake word setting can be enabled and disabled`() {
        val settings = InMemorySettings()
        settings.wakeWordEnabled = true
        assertTrue(settings.wakeWordEnabled)
        settings.wakeWordEnabled = false
        assertFalse(settings.wakeWordEnabled)
    }

    @Test
    fun `matchesWakePhrase matches both triggers when setting is both`() {
        assertTrue(WakeWordDetector.matchesWakePhrase("@hey_sayso", SettingsStore.WAKE_PHRASE_BOTH))
        assertTrue(WakeWordDetector.matchesWakePhrase("@sayso", SettingsStore.WAKE_PHRASE_BOTH))
        assertTrue(WakeWordDetector.matchesWakePhrase("hey sayso", SettingsStore.WAKE_PHRASE_BOTH))
        assertTrue(WakeWordDetector.matchesWakePhrase("sayso", SettingsStore.WAKE_PHRASE_BOTH))
    }

    @Test
    fun `matchesWakePhrase filters for hey_sayso strictly`() {
        assertTrue(WakeWordDetector.matchesWakePhrase("@hey_sayso", SettingsStore.WAKE_PHRASE_HEY))
        assertTrue(WakeWordDetector.matchesWakePhrase("hey sayso", SettingsStore.WAKE_PHRASE_HEY))
        assertFalse(WakeWordDetector.matchesWakePhrase("@sayso", SettingsStore.WAKE_PHRASE_HEY))
        assertFalse(WakeWordDetector.matchesWakePhrase("sayso", SettingsStore.WAKE_PHRASE_HEY))
    }

    @Test
    fun `matchesWakePhrase filters for sayso strictly without hey`() {
        assertTrue(WakeWordDetector.matchesWakePhrase("@sayso", SettingsStore.WAKE_PHRASE_SAYSO))
        assertTrue(WakeWordDetector.matchesWakePhrase("sayso", SettingsStore.WAKE_PHRASE_SAYSO))
        assertFalse(WakeWordDetector.matchesWakePhrase("@hey_sayso", SettingsStore.WAKE_PHRASE_SAYSO))
        assertFalse(WakeWordDetector.matchesWakePhrase("hey sayso", SettingsStore.WAKE_PHRASE_SAYSO))
    }
}
