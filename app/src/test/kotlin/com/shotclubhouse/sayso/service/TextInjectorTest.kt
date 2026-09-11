package com.shotclubhouse.sayso.service

import org.junit.Assert.assertEquals
import org.junit.Test

class TextInjectorTest {

    @Test
    fun `inserts at the caret`() {
        assertEquals("Hello there world", spliceAtSelection("Hello world", "there", 6, 6))
    }

    @Test
    fun `replaces the selected range`() {
        assertEquals("Hello Sayso", spliceAtSelection("Hello world", "Sayso", 6, 11))
    }

    @Test
    fun `adds a space when the caret sits against a word`() {
        assertEquals("Hello there", spliceAtSelection("Hello", "there", 5, 5))
    }

    @Test
    fun `separates from the word that follows the caret`() {
        assertEquals("Hello there world", spliceAtSelection("Helloworld", "there", 5, 5))
    }

    @Test
    fun `keeps the existing space`() {
        assertEquals("Hello there", spliceAtSelection("Hello ", "there", 6, 6))
    }

    @Test
    fun `appends when there is no selection`() {
        assertEquals("Hello there", spliceAtSelection("Hello", "there", -1, -1))
    }

    @Test
    fun `does not lead with a space in an empty field`() {
        assertEquals("there", spliceAtSelection("", "there", 0, 0))
    }

    @Test
    fun `handles a backwards selection`() {
        assertEquals("Hello Sayso", spliceAtSelection("Hello world", "Sayso", 11, 6))
    }

    @Test
    fun `clamps a selection past the end of the text`() {
        assertEquals("Hello there", spliceAtSelection("Hello", "there", 40, 40))
    }
}
