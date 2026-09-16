package ai.sayso.dictation.history

import ai.sayso.dictation.core.HistoryEntry
import ai.sayso.dictation.core.OutputMethod
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InsightsTest {

    private fun entry(rawText: String, durationMs: Long) = HistoryEntry(
        id = rawText.hashCode().toString(),
        createdAt = 0,
        durationMs = durationMs,
        rawText = rawText,
        polishedText = null,
        sttModelId = "local/tiny",
        polishModelId = null,
        outputMethod = OutputMethod.INSERTED,
        error = null,
        audioPath = null,
    )

    @Test
    fun compute_onEmptyList_returnsZeroedSummary() {
        val summary = Insights.compute(emptyList())

        assertEquals(0, summary.sessions)
        assertEquals(0, summary.totalWords)
        assertEquals(0L, summary.totalDurationMs)
        assertEquals(0.0, summary.averageWpm, 0.0)
        assertEquals(0.0, summary.fillerRatePer1k, 0.0)
        assertEquals(emptyList<Pair<String, Int>>(), summary.topWords)
        assertEquals(0L, summary.longestSessionMs)
    }

    @Test
    fun compute_wpmFillerRateAndTopWords() {
        val entries = listOf(
            // 10 words, 1 filler ("um"); 12s -> 50 wpm
            entry("um the quick brown fox jumps over the lazy dog", durationMs = 12_000),
            // 6 words, 1 filler ("uh"); 3s -> 120 wpm
            entry("uh brown brown fox fox fox", durationMs = 3_000),
            // 4 words; duration below the 1s floor, excluded from the wpm average
            entry("too short to count", durationMs = 500),
        )

        val summary = Insights.compute(entries)

        assertEquals(3, summary.sessions)
        assertEquals(20, summary.totalWords)
        assertEquals(15_500L, summary.totalDurationMs)
        assertEquals(12_000L, summary.longestSessionMs)
        // average of 50 and 120 (third entry excluded: durationMs < 1000)
        assertEquals(85.0, summary.averageWpm, 0.001)
        // 2 fillers ("um", "uh") out of 20 words -> 100 per 1k
        assertEquals(100.0, summary.fillerRatePer1k, 0.001)

        val topWords = summary.topWords.toMap()
        assertEquals(10, summary.topWords.size)
        assertEquals("fox" to 4, summary.topWords[0])
        assertEquals("brown" to 3, summary.topWords[1])
        assertEquals(1, topWords["quick"])
        assertEquals(1, topWords["dog"])
        assertEquals(1, topWords["short"])
        assertEquals(1, topWords["count"])
        // stopwords, fillers and sub-3-letter words never make the cut
        assertFalse(topWords.containsKey("the"))
        assertFalse(topWords.containsKey("to"))
        assertFalse(topWords.containsKey("um"))
        assertFalse(topWords.containsKey("uh"))

        // Rich insights
        assertEquals(85.0, summary.medianWpm, 0.001)
        assertEquals(5, summary.paceBuckets.size)
        assertEquals(1, summary.paceBuckets.first { it.label == "<100" }.count) // 50 wpm
        assertEquals(1, summary.paceBuckets.first { it.label == "100-130" }.count) // 120 wpm
        assertEquals(2, summary.topFillers.size)
        assertTrue(summary.topFillers.any { it.word == "um" && it.count == 1 })
        assertTrue(summary.topFillers.any { it.word == "uh" && it.count == 1 })
        assertTrue(summary.uniqueWords > 0)
        assertTrue(summary.richnessPercent > 0.0)
    }

    @Test
    fun compute_apostropheKeptInsideWord() {
        val summary = Insights.compute(listOf(entry("don't stop believing", durationMs = 2_000)))

        assertEquals(3, summary.totalWords)
        assertEquals(1, summary.topWords.toMap()["don't"])
    }
}
