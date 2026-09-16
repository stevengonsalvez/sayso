package ai.sayso.dictation.service

import ai.sayso.dictation.core.OutputMethod
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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

    @Test
    fun `text that was inserted does not trigger the clipboard fallback`() {
        var copied = false

        val method = deliveryOutcome(inserted = true) {
            copied = true
            true
        }

        assertEquals(OutputMethod.INSERTED, method)
        assertFalse("the fallback copy must not run once the text was inserted", copied)
    }

    @Test
    fun `setting the text keeps the transcript off the clipboard`() {
        assertFalse(needsClipboardBeforeAction(hasCustomPaste = false, isEditable = true))
    }

    @Test
    fun `a paste needs the transcript on the clipboard first`() {
        assertTrue(needsClipboardBeforeAction(hasCustomPaste = false, isEditable = false))
        assertTrue(needsClipboardBeforeAction(hasCustomPaste = true, isEditable = false))
    }

    @Test
    fun `a terminal pastes even when its node says it is editable`() {
        assertTrue(needsClipboardBeforeAction(hasCustomPaste = true, isEditable = true))
    }

    @Test
    fun `text that could not be inserted falls back to the clipboard`() {
        assertEquals(OutputMethod.CLIPBOARD, deliveryOutcome(inserted = false) { true })
    }

    @Test
    fun `a refused clipboard write is reported as no delivery`() {
        assertEquals(OutputMethod.NONE, deliveryOutcome(inserted = false) { false })
    }

    @Test
    fun `only a terminal has its paste action matched by label`() {
        assertTrue(matchesPasteByLabel("com.termux.view.TerminalView"))
        assertTrue(matchesPasteByLabel("dev.example.TerminalViewLite"))

        assertFalse(matchesPasteByLabel("android.widget.TextView"))
        assertFalse(matchesPasteByLabel("android.webkit.WebView"))
        assertFalse(matchesPasteByLabel(null))
    }

    @Test
    fun `resolveExistingText drops hint when isShowingHintText is true`() {
        assertEquals("", resolveExistingText("Message", isShowingHintText = true))
        assertEquals("", resolveExistingText("Type something", isShowingHintText = true))
    }

    @Test
    fun `resolveExistingText drops text matching hintText`() {
        assertEquals("", resolveExistingText("Message", hintText = "Message"))
        assertEquals("", resolveExistingText("Search here", hintText = "Search here"))
    }

    @Test
    fun `resolveExistingText drops common placeholder patterns`() {
        assertEquals("", resolveExistingText("Message"))
        assertEquals("", resolveExistingText("message"))
        assertEquals("", resolveExistingText("Type a message..."))
        assertEquals("", resolveExistingText("Send a message"))
        assertEquals("", resolveExistingText("Search"))
        assertEquals("", resolveExistingText("Type something"))
    }

    @Test
    fun `resolveExistingText keeps genuine typed text`() {
        assertEquals("Hello world", resolveExistingText("Hello world"))
        assertEquals("Important message for Stevie", resolveExistingText("Important message for Stevie"))
    }

    @Test
    fun `resolveExistingText handles empty and null`() {
        assertEquals("", resolveExistingText(null))
        assertEquals("", resolveExistingText(""))
        assertEquals("", resolveExistingText("   "))
    }
}
