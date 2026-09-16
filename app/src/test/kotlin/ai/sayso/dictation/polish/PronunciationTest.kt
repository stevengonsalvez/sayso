package ai.sayso.dictation.polish

import ai.sayso.dictation.core.PronunciationCategory
import ai.sayso.dictation.core.PronunciationEntry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PronunciationTest {

    @Test
    fun defaultEntries_containExpectedDevKeywords() {
        val entries = PronunciationDefaults.entries
        val words = entries.map { it.word }

        assertTrue(words.contains("API"))
        assertTrue(words.contains("SQL"))
        assertTrue(words.contains("kubectl"))
        assertTrue(words.contains("nginx"))
        assertTrue(words.contains("!="))
        assertTrue(words.contains("=="))
        assertTrue(words.contains("->"))
        assertTrue(words.contains("GitHub"))
    }

    @Test
    fun applyPronunciations_replacesTechnicalAndDevTerms() {
        val entries = listOf(
            PronunciationEntry(word = "SQL", pronunciation = "sequel", category = PronunciationCategory.TECHNICAL),
            PronunciationEntry(word = "kubectl", pronunciation = "cube-control", replacement = "cube control", category = PronunciationCategory.TECHNICAL),
            PronunciationEntry(word = "nginx", pronunciation = "engine-x", replacement = "engine X", category = PronunciationCategory.TECHNICAL),
            PronunciationEntry(word = "API", pronunciation = "A P I", category = PronunciationCategory.TECHNICAL),
        )

        val input = "We run sequel and deploy with cube-control or cube control to engine-x for the A P I"
        val expected = "We run SQL and deploy with kubectl or kubectl to nginx for the API"

        assertEquals(expected, Lexicon.applyPronunciations(input, entries))
    }

    @Test
    fun applyPronunciations_caseFoldsKeywordsWhenNotCaseSensitive() {
        val entries = listOf(
            PronunciationEntry(word = "JSON", pronunciation = "jay-son", caseSensitive = false),
            PronunciationEntry(word = "YAML", pronunciation = "yam-el", caseSensitive = false),
        )

        val input = "Parsing json and yaml config files"
        val expected = "Parsing JSON and YAML config files"

        assertEquals(expected, Lexicon.applyPronunciations(input, entries))
    }

    @Test
    fun applyPronunciations_evaluatesRegexRules() {
        val entries = listOf(
            PronunciationEntry(
                word = "\\b([a-zA-Z]+)-v(\\d+)\\b",
                pronunciation = "$1 version $2",
                replacement = "$1 v$2",
                isRegex = true,
            ),
        )

        val input = "Checking sayso-v1 and test-v2"
        val expected = "Checking sayso v1 and test v2"

        assertEquals(expected, Lexicon.applyPronunciations(input, entries))
    }

    @Test
    fun encodeAndDecodePronunciations_roundTrip() {
        val entries = listOf(
            PronunciationEntry(
                word = "kubectl",
                pronunciation = "cube-control",
                replacement = "cube control",
                category = PronunciationCategory.TECHNICAL,
                isRegex = false,
                caseSensitive = false,
            ),
            PronunciationEntry(
                word = "!=",
                pronunciation = "not equal",
                category = PronunciationCategory.SYMBOLS,
            ),
        )

        val json = Lexicon.encodePronunciations(entries)
        val decoded = Lexicon.decodePronunciations(json)

        assertEquals(entries.size, decoded.size)
        assertEquals(entries[0].word, decoded[0].word)
        assertEquals(entries[0].pronunciation, decoded[0].pronunciation)
        assertEquals(entries[0].replacement, decoded[0].replacement)
        assertEquals(entries[0].category, decoded[0].category)
        assertEquals(entries[1].word, decoded[1].word)
        assertEquals(entries[1].category, decoded[1].category)
    }

    @Test
    fun decodePronunciations_migratesLegacyLexiconRules() {
        val legacyJson = """[{"canonical":"Kubernetes","aliases":["koobernetes","k8s"]}]"""
        val decoded = Lexicon.decodePronunciations(legacyJson)

        assertEquals(1, decoded.size)
        assertEquals("Kubernetes", decoded[0].word)
        assertEquals("koobernetes", decoded[0].pronunciation)
        assertEquals("k8s", decoded[0].replacement)
    }
}
