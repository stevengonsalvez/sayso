package com.shotclubhouse.sayso.service

import org.junit.Assert.assertEquals
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
}
