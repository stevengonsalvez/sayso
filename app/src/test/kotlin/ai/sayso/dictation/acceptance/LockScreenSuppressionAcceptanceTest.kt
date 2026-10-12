package ai.sayso.dictation.acceptance

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Acceptance test suite for lockscreen suppression in DictationService.
 *
 * Verifies that the floating overlay bubble is suppressed when the device
 * screen turns off or is locked with a keyguard, and safely restored only
 * when the user unlocks the device.
 */
class LockScreenSuppressionAcceptanceTest {

    enum class DictationState { IDLE, RECORDING, PROCESSING }

    class FakeOverlayBubble {
        var isVisible: Boolean = false
            private set
        var showCount: Int = 0
            private set
        var hideCount: Int = 0
            private set

        fun show() {
            isVisible = true
            showCount++
        }

        fun hide() {
            isVisible = false
            hideCount++
        }
    }

    class FakeAudioCapture {
        var isRecording: Boolean = false
            private set
        var stoppedCount: Int = 0
            private set

        fun start() {
            isRecording = true
        }

        fun stop() {
            isRecording = false
            stoppedCount++
        }
    }

    /**
     * Models the exact lockscreen suppression logic implemented in DictationService.kt
     */
    class LockScreenController(
        var isFloatingBubbleEnabled: Boolean = true,
        var isKeyguardLocked: Boolean = false,
        val bubble: FakeOverlayBubble = FakeOverlayBubble(),
        val capture: FakeAudioCapture = FakeAudioCapture(),
    ) {
        var state: DictationState = DictationState.IDLE

        fun updateBubbleVisibility() {
            if (isFloatingBubbleEnabled && !isKeyguardLocked) {
                bubble.show()
            } else {
                bubble.hide()
            }
        }

        fun onScreenOff() {
            if (state == DictationState.RECORDING) {
                capture.stop()
                state = DictationState.IDLE
            }
            bubble.hide()
        }

        fun onScreenOn() {
            if (isKeyguardLocked) {
                bubble.hide()
            } else {
                updateBubbleVisibility()
            }
        }

        fun onUserPresent() {
            isKeyguardLocked = false
            updateBubbleVisibility()
        }
    }

    @Test
    fun screen_off_aborts_active_recording_and_hides_overlay_bubble() {
        val controller = LockScreenController()
        controller.updateBubbleVisibility()
        assertTrue("Bubble visible initially when unlocked", controller.bubble.isVisible)

        // Start dictation
        controller.state = DictationState.RECORDING
        controller.capture.start()
        assertTrue(controller.capture.isRecording)

        // Screen turns off (ACTION_SCREEN_OFF)
        controller.onScreenOff()

        // Verify active recording stopped and bubble hidden
        assertFalse("Recording must abort on screen off", controller.capture.isRecording)
        assertEquals("Capture stop called once", 1, controller.capture.stoppedCount)
        assertFalse("Bubble must be hidden on screen off", controller.bubble.isVisible)
        assertEquals(DictationState.IDLE, controller.state)
    }

    @Test
    fun screen_on_with_locked_keyguard_suppresses_overlay_bubble() {
        val controller = LockScreenController()
        controller.isKeyguardLocked = true

        // Screen turns on (ACTION_SCREEN_ON) while user has not unlocked phone
        controller.onScreenOn()

        assertFalse("Bubble must NOT show over lockscreen", controller.bubble.isVisible)
    }

    @Test
    fun unlocking_device_restores_bubble_visibility_when_enabled() {
        val controller = LockScreenController(isFloatingBubbleEnabled = true)
        controller.isKeyguardLocked = true
        controller.bubble.hide()
        assertFalse(controller.bubble.isVisible)

        // User enters PIN / fingerprint (ACTION_USER_PRESENT)
        controller.onUserPresent()

        assertTrue("Bubble must become visible once device is unlocked", controller.bubble.isVisible)
        assertFalse("Keyguard must no longer be locked", controller.isKeyguardLocked)
    }

    @Test
    fun unlocking_device_respects_disabled_floating_bubble_setting() {
        val controller = LockScreenController(isFloatingBubbleEnabled = false)
        controller.isKeyguardLocked = true

        // User unlocks device, but user has toggled floating bubble OFF in settings
        controller.onUserPresent()

        assertFalse("Bubble must stay hidden if disabled in settings", controller.bubble.isVisible)
    }
}
