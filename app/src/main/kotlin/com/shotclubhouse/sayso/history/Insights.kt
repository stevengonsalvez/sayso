package com.shotclubhouse.sayso.history

import com.shotclubhouse.sayso.core.HistoryEntry

/** Speech insights aggregated across a set of history entries. */
data class InsightsSummary(
    val sessions: Int,
    val totalWords: Int,
    val totalDurationMs: Long,
    val averageWpm: Double,
    val fillerRatePer1k: Double,
    val topWords: List<Pair<String, Int>>,
    val longestSessionMs: Long,
)

private val WORD_REGEX = Regex("[A-Za-z]+(?:'[A-Za-z]+)*")

private val FILLERS = setOf("um", "uh", "uhm", "erm", "hmm", "mmm", "ah", "er")

private val STOPWORDS = setOf(
    "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with",
    "is", "are", "was", "were", "be", "it", "this", "that", "i", "you", "we", "they",
    "he", "she", "my", "your", "so", "do", "have", "not", "as", "if", "then", "just",
)

/** Computes [InsightsSummary] from what was actually said (raw, pre-polish text). */
object Insights {
    fun compute(entries: List<HistoryEntry>): InsightsSummary {
        if (entries.isEmpty()) return InsightsSummary(0, 0, 0L, 0.0, 0.0, emptyList(), 0L)

        val wordCounts = mutableMapOf<String, Int>()
        var totalWords = 0
        var fillerCount = 0
        val wpmSamples = mutableListOf<Double>()

        for (entry in entries) {
            val words = WORD_REGEX.findAll(entry.rawText.lowercase()).map { it.value }.toList()
            totalWords += words.size
            for (word in words) {
                if (word in FILLERS) fillerCount++
                if (word.length >= 3 && word !in STOPWORDS) {
                    wordCounts[word] = (wordCounts[word] ?: 0) + 1
                }
            }
            if (entry.durationMs >= 1000 && words.isNotEmpty()) {
                wpmSamples += words.size / (entry.durationMs / 60_000.0)
            }
        }

        val topWords = wordCounts.entries
            .sortedByDescending { it.value }
            .take(10)
            .map { it.key to it.value }

        return InsightsSummary(
            sessions = entries.size,
            totalWords = totalWords,
            totalDurationMs = entries.sumOf { it.durationMs },
            averageWpm = if (wpmSamples.isEmpty()) 0.0 else wpmSamples.average(),
            fillerRatePer1k = if (totalWords == 0) 0.0 else fillerCount * 1000.0 / totalWords,
            topWords = topWords,
            longestSessionMs = entries.maxOf { it.durationMs },
        )
    }
}
