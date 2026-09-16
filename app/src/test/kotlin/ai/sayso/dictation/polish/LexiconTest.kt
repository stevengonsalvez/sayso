package ai.sayso.dictation.polish

import ai.sayso.dictation.core.LexiconRule
import org.junit.Assert.assertEquals
import org.junit.Test

class LexiconTest {

    @Test
    fun `replaces aliases regardless of case`() {
        val rules = listOf(LexiconRule("Kubernetes", listOf("kubernetes", "koobernetes")))

        assertEquals(
            "We deployed Kubernetes and Kubernetes again",
            Lexicon.apply("We deployed KOOBERNETES and Kubernetes again", rules),
        )
    }

    @Test
    fun `only replaces whole words`() {
        val rules = listOf(LexiconRule("Cat", listOf("cat")))

        assertEquals("Cat in the catalogue, concat", Lexicon.apply("cat in the catalogue, concat", rules))
    }

    @Test
    fun `longest alias wins over a shorter one it contains`() {
        val rules = listOf(
            LexiconRule("Sayso", listOf("say")),
            LexiconRule("Say So Labs", listOf("say so")),
        )

        assertEquals("Say So Labs shipped", Lexicon.apply("say so shipped", rules))
    }

    @Test
    fun `a canonical form produced by one rule is not rewritten by another`() {
        val rules = listOf(
            LexiconRule("Sayso", listOf("say so")),
            LexiconRule("Speaking", listOf("sayso")),
        )

        assertEquals("Sayso ships", Lexicon.apply("say so ships", rules))
    }

    @Test
    fun `skips blank aliases and leaves text untouched when there are no rules`() {
        assertEquals("unchanged", Lexicon.apply("unchanged", listOf(LexiconRule("X", listOf("", "   ")))))
        assertEquals("unchanged", Lexicon.apply("unchanged", emptyList()))
        assertEquals("", Lexicon.apply("", listOf(LexiconRule("X", listOf("y")))))
    }

    @Test
    fun `canonical text with regex characters is inserted literally`() {
        val rules = listOf(LexiconRule("C++ $1", listOf("see plus plus")))

        assertEquals("I use C++ $1 daily", Lexicon.apply("I use see plus plus daily", rules))
    }

    @Test
    fun `an alias made of punctuation still anchors`() {
        val rules = listOf(LexiconRule("C++", listOf("see plus plus")), LexiconRule("dotnet", listOf(".NET")))

        assertEquals("I use C++ and dotnet", Lexicon.apply("I use see plus plus and .NET", rules))
    }

    @Test
    fun `case folding covers non ascii letters`() {
        val rules = listOf(LexiconRule("Muller", listOf("müller")))

        assertEquals("Muller spoke", Lexicon.apply("MÜLLER spoke", rules))
    }

    @Test
    fun `encode and decode round trip`() {
        val rules = listOf(
            LexiconRule("Kubernetes", listOf("kubernetes", "koobernetes")),
            LexiconRule("Sayso", emptyList()),
        )

        assertEquals(rules, Lexicon.decode(Lexicon.encode(rules)))
        assertEquals(emptyList<LexiconRule>(), Lexicon.decode(""))
        assertEquals(emptyList<LexiconRule>(), Lexicon.decode("not json"))
        assertEquals(emptyList<LexiconRule>(), Lexicon.decode("""[{"nope":1}]"""))
    }
}
