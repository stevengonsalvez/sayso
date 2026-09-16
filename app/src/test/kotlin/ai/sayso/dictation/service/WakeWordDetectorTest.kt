package ai.sayso.dictation.service

import ai.sayso.dictation.settings.InMemorySettings
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WakeWordDetectorTest {

    @Test
    fun `wake word setting defaults to false`() {
        val settings = InMemorySettings()
        assertFalse(settings.wakeWordEnabled)
    }

    @Test
    fun `wake word setting can be enabled and disabled`() {
        val settings = InMemorySettings()
        settings.wakeWordEnabled = true
        assertTrue(settings.wakeWordEnabled)
        settings.wakeWordEnabled = false
        assertFalse(settings.wakeWordEnabled)
    }
}
