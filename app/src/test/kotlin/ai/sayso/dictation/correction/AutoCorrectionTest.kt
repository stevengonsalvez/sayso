package ai.sayso.dictation.correction

import ai.sayso.dictation.settings.InMemorySettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoCorrectionTest {

    @Test
    fun wordDiffer_detectsSimpleReplacement() {
        val original = "Deploying with kubctl to production"
        val edited = "Deploying with kubectl to production"

        val changes = WordDiffer.findChanges(original, edited)

        assertEquals(1, changes.size)
        assertEquals(ChangeType.REPLACEMENT, changes[0].type)
        assertEquals("kubctl", changes[0].original)
        assertEquals("kubectl", changes[0].corrected)
        assertTrue(changes[0].isLikelyCorrection)
    }

    @Test
    fun wordDiffer_detectsSplitWord() {
        val original = "We are gonna deploy now"
        val edited = "We are going to deploy now"

        val changes = WordDiffer.findChanges(original, edited)

        assertEquals(1, changes.size)
        assertEquals(ChangeType.SPLIT, changes[0].type)
        assertEquals("gonna", changes[0].original)
        assertEquals("going to", changes[0].corrected)
        assertTrue(changes[0].isLikelyCorrection)
    }

    @Test
    fun wordDiffer_detectsMergedWord() {
        val original = "We can not deploy now"
        val edited = "We cannot deploy now"

        val changes = WordDiffer.findChanges(original, edited)

        assertEquals(1, changes.size)
        assertEquals(ChangeType.MERGE, changes[0].type)
        assertEquals("can not", changes[0].original)
        assertEquals("cannot", changes[0].corrected)
        assertTrue(changes[0].isLikelyCorrection)
    }

    @Test
    fun wordDiffer_ignoresCompleteRewrite() {
        val original = "hello world"
        val edited = "completely different sentence entirely"

        val changes = WordDiffer.findChanges(original, edited)

        assertTrue(changes.none { it.isLikelyCorrection })
    }
}
