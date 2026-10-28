package ai.sayso.dictation.polish

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DisfluencyResolverTest {

    @Test
    fun `strips leading, trailing, and embedded hesitation fillers`() {
        assertEquals("Let's meet tomorrow", DisfluencyResolver.stripFillers("Um, let's meet tomorrow"))
        assertEquals("Let's meet tomorrow", DisfluencyResolver.stripFillers("Let's, uh, meet tomorrow"))
        assertEquals("I think this works", DisfluencyResolver.stripFillers("I think, er, this works"))
        assertEquals("Hello there", DisfluencyResolver.stripFillers("Hello there, ah"))
        assertEquals("Ready to start", DisfluencyResolver.stripFillers("Um, uh, ready to start"))
    }

    @Test
    fun `preserves words containing filler substrings`() {
        assertEquals("Bring an umbrella", DisfluencyResolver.stripFillers("Bring an umbrella"))
        assertEquals("Plan ahead for tomorrow", DisfluencyResolver.stripFillers("Plan ahead for tomorrow"))
        assertEquals("An aha moment", DisfluencyResolver.stripFillers("An aha moment"))
    }

    @Test
    fun `removes repeated stutter words`() {
        assertEquals("The meeting", DisfluencyResolver.removeStutters("The the meeting"))
        assertEquals("we can do it", DisfluencyResolver.removeStutters("we we can do it"))
        assertEquals("in the room", DisfluencyResolver.removeStutters("in, in the room"))
        assertEquals("the book", DisfluencyResolver.removeStutters("the the the book"))
        assertEquals("Wait", DisfluencyResolver.removeStutters("Wait, wait"))
    }

    @Test
    fun `resolves day and month self-corrections`() {
        assertEquals(
            "meet on Saturday",
            DisfluencyResolver.resolveSelfCorrections("meet on Friday, actually Saturday"),
        )
        assertEquals(
            "meet on Saturday",
            DisfluencyResolver.resolveSelfCorrections("meet on Friday, actually make that Saturday"),
        )
        assertEquals(
            "launch in June",
            DisfluencyResolver.resolveSelfCorrections("launch in May, actually June"),
        )
    }

    @Test
    fun `resolves number self-corrections`() {
        assertEquals(
            "we need three apples",
            DisfluencyResolver.resolveSelfCorrections("we need two, actually three apples"),
        )
        assertEquals(
            "at 3 PM",
            DisfluencyResolver.resolveSelfCorrections("at 2 PM, actually 3 PM"),
        )
        assertEquals(
            "order 4 tickets",
            DisfluencyResolver.resolveSelfCorrections("order 3, no wait, 4 tickets"),
        )
    }

    @Test
    fun `resolves explicit scratch that and delete that self-corrections`() {
        assertEquals(
            "call Alice",
            DisfluencyResolver.resolveSelfCorrections("call Bob, scratch that, call Alice"),
        )
        assertEquals(
            "send email to Alice",
            DisfluencyResolver.resolveSelfCorrections("send email to Bob scratch that Alice"),
        )
        assertEquals(
            "delete this row",
            DisfluencyResolver.resolveSelfCorrections("update this row, delete that, delete this row"),
        )
    }

    @Test
    fun `trailing scratch that cancels the preceding utterance`() {
        assertEquals(
            "",
            DisfluencyResolver.resolveSelfCorrections("Let's go home, scratch that"),
        )
        assertEquals(
            "",
            DisfluencyResolver.resolveSelfCorrections("never mind delete that"),
        )
    }

    @Test
    fun `preserves conversational adverbs at start or inside sentences`() {
        assertEquals(
            "Actually, I think this works",
            DisfluencyResolver.resolveSelfCorrections("Actually, I think this works"),
        )
        assertEquals(
            "I actually like that idea",
            DisfluencyResolver.resolveSelfCorrections("I actually like that idea"),
        )
    }

    @Test
    fun `preserves ordinary conversational clauses after commas`() {
        assertEquals(
            "I agree, actually I think it's good",
            DisfluencyResolver.resolveSelfCorrections("I agree, actually I think it's good"),
        )
        assertEquals(
            "I am late, sorry",
            DisfluencyResolver.resolveSelfCorrections("I am late, sorry"),
        )
        assertEquals(
            "I am late, sorry for the delay",
            DisfluencyResolver.resolveSelfCorrections("I am late, sorry for the delay"),
        )
    }

    @Test
    fun `preserves literal punctuation names in dictation`() {
        assertEquals("I missed my period today.", LocalRulesPolisher.clean("I missed my period today"))
        assertEquals("The colon is healthy.", LocalRulesPolisher.clean("the colon is healthy"))
        assertEquals("Use an oxford comma here.", LocalRulesPolisher.clean("use an oxford comma here"))
        assertEquals("A grace period of thirty days.", LocalRulesPolisher.clean("a grace period of thirty days"))
        assertEquals("Note: this is important.", LocalRulesPolisher.clean("note colon this is important"))
    }

    @Test
    fun `detects cancelled utterances`() {
        assertTrue(DisfluencyResolver.isCancelled("never mind scratch that"))
        assertTrue(DisfluencyResolver.isCancelled("send email to Bob, delete that"))
        org.junit.Assert.assertFalse(DisfluencyResolver.isCancelled("send email to Bob"))
    }

    @Test
    fun `transforms spoken punctuation directives`() {
        assertEquals("How are you?", DisfluencyResolver.resolve("how are you question mark").trim())
        assertEquals("Watch out!", DisfluencyResolver.resolve("watch out exclamation point").trim())
        assertEquals("Item one: item two", DisfluencyResolver.resolve("item one colon item two").trim())
        assertEquals("Hello, world.", DisfluencyResolver.resolve("hello comma world full stop").trim())
        assertEquals("Wait...", DisfluencyResolver.resolve("wait dot dot dot").trim())
        assertEquals("She said \"hello\"", DisfluencyResolver.resolve("she said open quote hello close quote").trim())
    }

    @Test
    fun `transforms formatting directives into newlines and bullets`() {
        val multiline = DisfluencyResolver.resolve("first line new line second line")
        assertTrue(multiline.contains("First line\nSecond line"))

        val paragraphs = DisfluencyResolver.resolve("first paragraph new paragraph second paragraph")
        assertTrue(paragraphs.contains("First paragraph\n\nSecond paragraph"))

        val bullets = DisfluencyResolver.resolve("bullet point apples new line bullet point oranges")
        assertTrue(bullets.contains("- Apples\n- Oranges"))
    }

    @Test
    fun `parses standalone voice commands`() {
        assertEquals(StandaloneCommand.UNDO, DisfluencyResolver.parseStandaloneCommand("scratch that"))
        assertEquals(StandaloneCommand.UNDO, DisfluencyResolver.parseStandaloneCommand("Scratch that."))
        assertEquals(StandaloneCommand.UNDO, DisfluencyResolver.parseStandaloneCommand("delete that"))
        assertEquals(StandaloneCommand.UNDO, DisfluencyResolver.parseStandaloneCommand("undo"))
        assertEquals(StandaloneCommand.UNDO, DisfluencyResolver.parseStandaloneCommand("please scratch that"))
        assertEquals(StandaloneCommand.UNDO, DisfluencyResolver.parseStandaloneCommand("undo please"))

        assertEquals(StandaloneCommand.CLEAR, DisfluencyResolver.parseStandaloneCommand("clear text"))
        assertEquals(StandaloneCommand.CLEAR, DisfluencyResolver.parseStandaloneCommand("clear all"))
        assertEquals(StandaloneCommand.CLEAR, DisfluencyResolver.parseStandaloneCommand("delete all"))

        assertEquals(StandaloneCommand.NONE, DisfluencyResolver.parseStandaloneCommand("hello world"))
        assertEquals(StandaloneCommand.NONE, DisfluencyResolver.parseStandaloneCommand("scratch that I made a mistake"))
    }
}
