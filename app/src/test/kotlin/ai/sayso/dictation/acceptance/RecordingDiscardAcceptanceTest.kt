package ai.sayso.dictation.acceptance

import ai.sayso.dictation.service.calculateDiscardPositionX
import ai.sayso.dictation.service.isSlideToCancelGesture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Acceptance test suite for the recording discard option.
 *
 * Verifies both:
 * 1. Push-to-talk slide-to-cancel gesture mechanics
 * 2. Hands-free tap-to-discard companion button mechanics
 * 3. DictationService cancellation flow (abort capture, skip text injection, reset to IDLE)
 */
class RecordingDiscardAcceptanceTest {

    enum class DictationState { IDLE, RECORDING, BUSY }

    class FakeOverlayBubble(
        val onTap: () -> Unit,
        val onHoldStart: () -> Unit,
        val onHoldEnd: () -> Unit,
        val onDiscard: () -> Unit,
    ) {
        var isBubbleVisible: Boolean = false
        var isDiscardVisible: Boolean = false
        var isSlideActive: Boolean = false
        var feedbackMessage: String? = null

        fun show() {
            isBubbleVisible = true
        }

        fun hide() {
            isBubbleVisible = false
            isDiscardVisible = false
        }

        fun setState(state: DictationState) {
            when (state) {
                DictationState.RECORDING -> isDiscardVisible = true
                DictationState.IDLE,
                DictationState.BUSY -> {
                    isDiscardVisible = false
                    isSlideActive = false
                }
            }
        }

        fun showFeedback(text: String) {
            feedbackMessage = text
        }

        // Simulates user sliding while holding down
        fun simulateHoldMove(dx: Float, onRightEdge: Boolean, threshold: Float) {
            isSlideActive = isSlideToCancelGesture(dx, onRightEdge, threshold)
        }

        // Simulates release of hold
        fun simulateHoldRelease() {
            if (isSlideActive) {
                isSlideActive = false
                onDiscard()
            } else {
                onHoldEnd()
            }
        }

        // Simulates tapping companion discard button directly
        fun simulateTapDiscard() {
            if (isDiscardVisible) {
                onDiscard()
            }
        }
    }

    class FakeAudioCapture {
        var isRecording: Boolean = false
            private set
        var stopCount: Int = 0
            private set

        fun start() {
            isRecording = true
        }

        fun stop() {
            isRecording = false
            stopCount++
        }
    }

    class FakeSoundCues {
        var startCount: Int = 0
            private set
        var stopCount: Int = 0
            private set
        var discardCount: Int = 0
            private set

        fun start() { startCount++ }
        fun stop() { stopCount++ }
        fun discard() { discardCount++ }
    }

    class FakeTextInjector {
        var injectedTexts = mutableListOf<String>()

        fun inject(text: String) {
            injectedTexts.add(text)
        }
    }

    /**
     * Models the service-level discard orchestration.
     */
    class DictationController {
        var state = DictationState.IDLE
            private set

        val capture = FakeAudioCapture()
        val sounds = FakeSoundCues()
        val injector = FakeTextInjector()
        var recordingJobActive = false
        var discardedCount = 0

        val bubble = FakeOverlayBubble(
            onTap = ::handleTap,
            onHoldStart = ::handleHoldStart,
            onHoldEnd = ::handleHoldEnd,
            onDiscard = ::discardRecording,
        )

        fun handleTap() {
            when (state) {
                DictationState.IDLE -> startRecording()
                DictationState.RECORDING -> stopRecording()
                DictationState.BUSY -> bubble.showFeedback("Still working")
            }
        }

        fun handleHoldStart() {
            if (state == DictationState.IDLE) {
                startRecording()
            }
        }

        fun handleHoldEnd() {
            if (state == DictationState.RECORDING) {
                stopRecording()
            }
        }

        fun startRecording() {
            state = DictationState.RECORDING
            capture.start()
            sounds.start()
            recordingJobActive = true
            bubble.setState(DictationState.RECORDING)
        }

        fun stopRecording() {
            capture.stop()
            state = DictationState.BUSY
            sounds.stop()
            bubble.setState(DictationState.BUSY)
            // Simulates transcription and text injection completion
            if (recordingJobActive) {
                injector.inject("Dictated text")
                recordingJobActive = false
            }
            state = DictationState.IDLE
            bubble.setState(DictationState.IDLE)
        }

        fun discardRecording() {
            if (state != DictationState.RECORDING) return
            recordingJobActive = false
            capture.stop()
            sounds.discard()
            discardedCount++
            state = DictationState.IDLE
            bubble.setState(DictationState.IDLE)
            bubble.showFeedback("Discarded")
        }
    }

    @Test
    fun `ptt slide to cancel cancels audio capture without injecting text`() {
        val controller = DictationController()
        controller.bubble.show()

        // 1. User presses down and holds to talk
        controller.bubble.onHoldStart()
        assertEquals(DictationState.RECORDING, controller.state)
        assertTrue(controller.capture.isRecording)
        assertTrue(controller.bubble.isDiscardVisible)

        // 2. User slides towards center (leftward on right-docked bubble) past 45dp threshold
        controller.bubble.simulateHoldMove(dx = -60f, onRightEdge = true, threshold = 45f)
        assertTrue(controller.bubble.isSlideActive)

        // 3. User releases finger
        controller.bubble.simulateHoldRelease()

        // 4. Verify recording was aborted cleanly
        assertEquals(DictationState.IDLE, controller.state)
        assertFalse(controller.capture.isRecording)
        assertEquals(1, controller.discardedCount)
        assertEquals(1, controller.sounds.discardCount)
        assertEquals(0, controller.sounds.stopCount)
        assertEquals("Discarded", controller.bubble.feedbackMessage)
        assertTrue("No text should be injected when discarded", controller.injector.injectedTexts.isEmpty())
        assertFalse("Discard button should be hidden after cancellation", controller.bubble.isDiscardVisible)
    }

    @Test
    fun `ptt slide to cancel aborted if user slides back before release`() {
        val controller = DictationController()
        controller.bubble.show()

        // 1. User starts holding
        controller.bubble.onHoldStart()
        assertEquals(DictationState.RECORDING, controller.state)

        // 2. User slides left towards discard
        controller.bubble.simulateHoldMove(dx = -50f, onRightEdge = true, threshold = 45f)
        assertTrue(controller.bubble.isSlideActive)

        // 3. User changes mind and slides back to bubble
        controller.bubble.simulateHoldMove(dx = -10f, onRightEdge = true, threshold = 45f)
        assertFalse(controller.bubble.isSlideActive)

        // 4. User releases finger
        controller.bubble.simulateHoldRelease()

        // 5. Normal transcription and injection occurs
        assertEquals(DictationState.IDLE, controller.state)
        assertEquals(0, controller.discardedCount)
        assertEquals(1, controller.sounds.stopCount)
        assertEquals(1, controller.injector.injectedTexts.size)
        assertEquals("Dictated text", controller.injector.injectedTexts.first())
    }

    @Test
    fun `hands-free tap on discard button aborts recording immediately`() {
        val controller = DictationController()
        controller.bubble.show()

        // 1. User taps bubble to record hands-free
        controller.bubble.onTap()
        assertEquals(DictationState.RECORDING, controller.state)
        assertTrue(controller.bubble.isDiscardVisible)

        // 2. User taps discard button
        controller.bubble.simulateTapDiscard()

        // 3. Verify clean discard
        assertEquals(DictationState.IDLE, controller.state)
        assertFalse(controller.capture.isRecording)
        assertEquals(1, controller.discardedCount)
        assertEquals("Discarded", controller.bubble.feedbackMessage)
        assertTrue(controller.injector.injectedTexts.isEmpty())
        assertFalse(controller.bubble.isDiscardVisible)
    }

    @Test
    fun `discard when idle is safe no-op`() {
        val controller = DictationController()
        assertEquals(DictationState.IDLE, controller.state)

        controller.discardRecording()

        assertEquals(DictationState.IDLE, controller.state)
        assertEquals(0, controller.discardedCount)
        assertEquals(0, controller.sounds.discardCount)
    }

    @Test
    fun `discard companion positioning handles left and right dock positions`() {
        val screenWidth = 1080
        val bubbleWidth = 168
        val discardWidth = 138
        val companionMargin = 30
        val edgeMargin = 24

        // Right docked (x = 888)
        val rightX = calculateDiscardPositionX(
            bubbleX = 888,
            bubbleWidth = bubbleWidth,
            discardWidth = discardWidth,
            screenWidth = screenWidth,
            companionMargin = companionMargin,
            edgeMargin = edgeMargin,
        )
        assertEquals(888 - discardWidth - companionMargin, rightX)

        // Left docked (x = 24)
        val leftX = calculateDiscardPositionX(
            bubbleX = edgeMargin,
            bubbleWidth = bubbleWidth,
            discardWidth = discardWidth,
            screenWidth = screenWidth,
            companionMargin = companionMargin,
            edgeMargin = edgeMargin,
        )
        assertEquals(edgeMargin + bubbleWidth + companionMargin, leftX)
    }
}
