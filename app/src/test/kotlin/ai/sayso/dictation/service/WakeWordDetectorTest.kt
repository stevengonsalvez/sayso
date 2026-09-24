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

    @Test
    fun `wake word sensitivity defaults to medium`() {
        val settings = InMemorySettings()
        assertEquals(SettingsStore.WAKE_SENSITIVITY_DEFAULT, settings.wakeWordSensitivity)
        settings.wakeWordSensitivity = SettingsStore.WAKE_SENSITIVITY_HIGH
        assertEquals(SettingsStore.WAKE_SENSITIVITY_HIGH, settings.wakeWordSensitivity)
        settings.wakeWordSensitivity = SettingsStore.WAKE_SENSITIVITY_LOW
        assertEquals(SettingsStore.WAKE_SENSITIVITY_LOW, settings.wakeWordSensitivity)
    }

    @Test
    fun `sensitivityParams returns tuned values for high medium and low`() {
        val (highScore, highThreshold, highPaths) = WakeWordDetector.sensitivityParams(SettingsStore.WAKE_SENSITIVITY_HIGH)
        assertEquals(3.0f, highScore, 0.001f)
        assertEquals(0.08f, highThreshold, 0.001f)
        assertEquals(16, highPaths)

        val (medScore, medThreshold, medPaths) = WakeWordDetector.sensitivityParams(SettingsStore.WAKE_SENSITIVITY_DEFAULT)
        assertEquals(2.8f, medScore, 0.001f)
        assertEquals(0.10f, medThreshold, 0.001f)
        assertEquals(12, medPaths)

        val (lowScore, lowThreshold, lowPaths) = WakeWordDetector.sensitivityParams(SettingsStore.WAKE_SENSITIVITY_LOW)
        assertEquals(2.2f, lowScore, 0.001f)
        assertEquals(0.16f, lowThreshold, 0.001f)
        assertEquals(8, lowPaths)
    }

    @Test
    fun `matchesWakePhrase matches phonetic keyword variants`() {
        assertTrue(WakeWordDetector.matchesWakePhrase("@hey_sayso_v1", SettingsStore.WAKE_PHRASE_BOTH))
        assertTrue(WakeWordDetector.matchesWakePhrase("hey say so", SettingsStore.WAKE_PHRASE_BOTH))
        assertTrue(WakeWordDetector.matchesWakePhrase("say so", SettingsStore.WAKE_PHRASE_BOTH))
        assertTrue(WakeWordDetector.matchesWakePhrase("hey say so", SettingsStore.WAKE_PHRASE_HEY))
        assertFalse(WakeWordDetector.matchesWakePhrase("say so", SettingsStore.WAKE_PHRASE_HEY))
    }
}
