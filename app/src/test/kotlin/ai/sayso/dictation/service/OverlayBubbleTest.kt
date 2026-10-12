package ai.sayso.dictation.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OverlayBubbleTest {

    private val size = 168 // 56 dp at 3x
    private val margin = 24 // 8 dp at 3x
    private val screen = 1080

    @Test
    fun `snaps left when the centre is on the left half`() {
        assertEquals(margin, snapToEdge(x = 300, width = size, screenWidth = screen, margin = margin))
    }

    @Test
    fun `snaps right when the centre is on the right half`() {
        assertEquals(screen - size - margin, snapToEdge(x = 600, width = size, screenWidth = screen, margin = margin))
    }

    @Test
    fun `the midpoint snaps right`() {
        val centred = (screen - size) / 2
        assertEquals(screen - size - margin, snapToEdge(centred, size, screen, margin))
    }

    @Test
    fun `keeps a dragged bubble on screen`() {
        assertEquals(margin, clampToScreen(-500, size, screen, margin))
        assertEquals(screen - size - margin, clampToScreen(5000, size, screen, margin))
        assertEquals(400, clampToScreen(400, size, screen, margin))
    }

    @Test
    fun `falls back to the margin when the screen is smaller than the bubble`() {
        assertEquals(margin, clampToScreen(0, size, extent = 100, margin = margin))
    }

    @Test
    fun `places discard companion to the left when bubble is on the right half`() {
        val bubbleX = 888 // Right side: screen 1080, bubble size 168, margin 24 -> 1080 - 168 - 24 = 888
        val discardWidth = 138 // 46 dp at 3x
        val companionMargin = 30 // 10 dp at 3x
        val expected = bubbleX - discardWidth - companionMargin
        val actual = calculateDiscardPositionX(
            bubbleX = bubbleX,
            bubbleWidth = size,
            discardWidth = discardWidth,
            screenWidth = screen,
            companionMargin = companionMargin,
            edgeMargin = margin,
        )
        assertEquals(expected, actual)
    }

    @Test
    fun `places discard companion to the right when bubble is on the left half`() {
        val bubbleX = margin // Left side: 24
        val discardWidth = 138
        val companionMargin = 30
        val expected = bubbleX + size + companionMargin
        val actual = calculateDiscardPositionX(
            bubbleX = bubbleX,
            bubbleWidth = size,
            discardWidth = discardWidth,
            screenWidth = screen,
            companionMargin = companionMargin,
            edgeMargin = margin,
        )
        assertEquals(expected, actual)
    }

    @Test
    fun `clamps discard companion to edge margin if pushed beyond left screen border`() {
        val actual = calculateDiscardPositionX(
            bubbleX = 100,
            bubbleWidth = size,
            discardWidth = 138,
            screenWidth = 180, // Narrow screen where center puts it on right half
            companionMargin = 30,
            edgeMargin = margin,
        )
        assertEquals(margin, actual)
    }

    @Test
    fun `clamps discard companion to right edge margin if pushed beyond right screen border`() {
        val actual = calculateDiscardPositionX(
            bubbleX = margin,
            bubbleWidth = size,
            discardWidth = 138,
            screenWidth = 300, // Left half dock, placing discard to right exceeds screenWidth - discardWidth - margin
            companionMargin = 30,
            edgeMargin = margin,
        )
        assertEquals(300 - 138 - margin, actual)
    }

    @Test
    fun `slide to cancel triggers when sliding left from right half past threshold`() {
        val threshold = 135f // 45 dp at 3x
        assertTrue(isSlideToCancelGesture(dx = -150f, onRightHalf = true, threshold = threshold))
        assertTrue(isSlideToCancelGesture(dx = -135f, onRightHalf = true, threshold = threshold))
        assertFalse(isSlideToCancelGesture(dx = -100f, onRightHalf = true, threshold = threshold))
        assertFalse(isSlideToCancelGesture(dx = 50f, onRightHalf = true, threshold = threshold))
    }

    @Test
    fun `slide to cancel triggers when sliding right from left half past threshold`() {
        val threshold = 135f // 45 dp at 3x
        assertTrue(isSlideToCancelGesture(dx = 150f, onRightHalf = false, threshold = threshold))
        assertTrue(isSlideToCancelGesture(dx = 135f, onRightHalf = false, threshold = threshold))
        assertFalse(isSlideToCancelGesture(dx = 100f, onRightHalf = false, threshold = threshold))
        assertFalse(isSlideToCancelGesture(dx = -50f, onRightHalf = false, threshold = threshold))
    }
}
