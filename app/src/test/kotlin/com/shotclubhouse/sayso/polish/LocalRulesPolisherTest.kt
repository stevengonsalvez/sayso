package com.shotclubhouse.sayso.polish

import com.shotclubhouse.sayso.core.PolishResult
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalRulesPolisherTest {

    @Test
    fun `declares itself as a keyless fixed prompt provider`() {
        assertEquals("rules", LocalRulesPolisher.id)
        assertEquals("Built-in rules", LocalRulesPolisher.displayName)
        assertFalse(LocalRulesPolisher.needsApiKey)
        assertFalse(LocalRulesPolisher.supportsCustomPrompt)
        assertNull(LocalRulesPolisher.apiKeyUrl)
        assertEquals(listOf("rules/basic"), LocalRulesPolisher.models.map { it.id })
    }

    @Test
    fun `strips transcription markers`() {
        assertEquals(
            "Hello there friend.",
            LocalRulesPolisher.clean("[BLANK_AUDIO] hello there [blank_audio] friend (inaudible)"),
        )
    }

    @Test
    fun `collapses whitespace and fixes spacing before punctuation`() {
        assertEquals(
            "This is a test, really.",
            LocalRulesPolisher.clean("this   is \n a test , really ."),
        )
    }

    @Test
    fun `adds a full stop only for sentences of at least three words`() {
        assertEquals("Yes", LocalRulesPolisher.clean("yes"))
        assertEquals("Yes please", LocalRulesPolisher.clean("yes please"))
        assertEquals("Yes please do.", LocalRulesPolisher.clean("yes please do"))
        assertEquals("Yes please do?", LocalRulesPolisher.clean("yes please do?"))
        assertEquals("Hello there world.", LocalRulesPolisher.clean("hello there world."))
    }

    @Test
    fun `leaves bracketed code alone`() {
        assertEquals("The value at list[0] equals five.", LocalRulesPolisher.clean("the value at list[0] equals five"))
        assertEquals(
            "Run npm install [see the readme]",
            LocalRulesPolisher.clean("run npm install [see the readme]"),
        )
    }

    @Test
    fun `keeps a word that shapes its own casing`() {
        assertEquals("iPhone battery life.", LocalRulesPolisher.clean("iPhone battery life"))
        assertEquals("Hello there world.", LocalRulesPolisher.clean("hello there world"))
    }

    @Test
    fun `an unreadable envelope is an error rather than echoed instructions`() = runTest {
        val result = LocalRulesPolisher.polish("SYSTEM", "not an envelope", "basic", null)

        assertTrue(result is PolishResult.Failure)
        assertEquals("Malformed cleanup payload", (result as PolishResult.Failure).message)
    }

    @Test
    fun `handles empty and marker only input`() {
        assertEquals("", LocalRulesPolisher.clean(""))
        assertEquals("", LocalRulesPolisher.clean("   "))
        assertEquals("", LocalRulesPolisher.clean("[BLANK_AUDIO]"))
        assertEquals("", LocalRulesPolisher.clean("(inaudible)"))
    }

    @Test
    fun `polish unwraps the json payload before cleaning`() = runTest {
        val transcript = "[blank_audio] this   is a \"quoted\" test ."

        val result = LocalRulesPolisher.polish(
            systemPrompt = CleanupPolicy.systemPrompt(outputLanguage = null, lexicon = emptyList()),
            userMessage = CleanupPolicy.userMessage(transcript),
            modelName = "basic",
            apiKey = null,
        )

        assertTrue(result is PolishResult.Success)
        assertEquals("This is a \"quoted\" test.", (result as PolishResult.Success).text)
    }

    @Test
    fun `transforms spoken code symbols`() {
        assertEquals("If a != b.", LocalRulesPolisher.clean("if a not equal b"))
        assertEquals("When x == y.", LocalRulesPolisher.clean("when x double equals y"))
        assertEquals("Map item -> result.", LocalRulesPolisher.clean("map item arrow result"))
        assertEquals("Fn = () => true.", LocalRulesPolisher.clean("fn = () fat arrow true"))
    }
}
