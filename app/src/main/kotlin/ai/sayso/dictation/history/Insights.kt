package ai.sayso.dictation.history

import ai.sayso.dictation.core.HistoryEntry

/** Bucket for speaking pace distribution chart. */
data class PaceBucket(val label: String, val count: Int)

/** Filler word count breakdown. */
data class FillerCount(val word: String, val count: Int)

/** Frequently repeated phrase. */
data class TopPhrase(val phrase: String, val count: Int)

/** Speech insights aggregated across a set of history entries. */
data class InsightsSummary(
    val sessions: Int,
    val totalWords: Int,
    val totalDurationMs: Long,
    val averageWpm: Double,
    val fillerRatePer1k: Double,
    val topWords: List<Pair<String, Int>>,
    val longestSessionMs: Long,
    val medianWpm: Double = 0.0,
    val paceBuckets: List<PaceBucket> = emptyList(),
    val topFillers: List<FillerCount> = emptyList(),
    val uniqueWords: Int = 0,
    val richnessPercent: Double = 0.0,
    val topPhrases: List<TopPhrase> = emptyList(),
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
        if (entries.isEmpty()) {
            return InsightsSummary(
                sessions = 0,
                totalWords = 0,
                totalDurationMs = 0L,
                averageWpm = 0.0,
                fillerRatePer1k = 0.0,
                topWords = emptyList(),
                longestSessionMs = 0L,
                medianWpm = 0.0,
                paceBuckets = emptyList(),
                topFillers = emptyList(),
                uniqueWords = 0,
                richnessPercent = 0.0,
                topPhrases = emptyList(),
            )
        }

        val wordCounts = mutableMapOf<String, Int>()
        val fillerCounts = mutableMapOf<String, Int>()
        val allWords = mutableSetOf<String>()
        val phraseCounts = mutableMapOf<String, Int>()
        var totalWords = 0
        var fillerCount = 0
        val wpmSamples = mutableListOf<Double>()

        for (entry in entries) {
            val words = WORD_REGEX.findAll(entry.rawText.lowercase()).map { it.value }.toList()
            totalWords += words.size
            allWords.addAll(words)

            for (word in words) {
                if (word in FILLERS) {
                    fillerCount++
                    fillerCounts[word] = (fillerCounts[word] ?: 0) + 1
                }
                if (word.length >= 3 && word !in STOPWORDS) {
                    wordCounts[word] = (wordCounts[word] ?: 0) + 1
                }
            }

            // Extract bigrams and trigrams for top phrases
            if (words.size >= 2) {
                for (i in 0 until words.size - 1) {
                    val w1 = words[i]
                    val w2 = words[i + 1]
                    if (w1 !in FILLERS && w2 !in FILLERS && (w1 !in STOPWORDS || w2 !in STOPWORDS)) {
                        val bigram = "$w1 $w2"
                        phraseCounts[bigram] = (phraseCounts[bigram] ?: 0) + 1
                    }
                }
            }
            if (words.size >= 3) {
                for (i in 0 until words.size - 2) {
                    val w1 = words[i]
                    val w2 = words[i + 1]
                    val w3 = words[i + 2]
                    if (w1 !in FILLERS && w2 !in FILLERS && w3 !in FILLERS) {
                        val trigram = "$w1 $w2 $w3"
                        phraseCounts[trigram] = (phraseCounts[trigram] ?: 0) + 1
                    }
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

        val sortedWpm = wpmSamples.sorted()
        val medianWpm = when {
            sortedWpm.isEmpty() -> 0.0
            sortedWpm.size % 2 == 1 -> sortedWpm[sortedWpm.size / 2]
            else -> (sortedWpm[sortedWpm.size / 2 - 1] + sortedWpm[sortedWpm.size / 2]) / 2.0
        }

        val paceBuckets = listOf(
            PaceBucket("<100", sortedWpm.count { it < 100.0 }),
            PaceBucket("100-130", sortedWpm.count { it in 100.0..<130.0 }),
            PaceBucket("130-160", sortedWpm.count { it in 130.0..<160.0 }),
            PaceBucket("160-190", sortedWpm.count { it in 160.0..<190.0 }),
            PaceBucket(">190", sortedWpm.count { it >= 190.0 }),
        )

        val topFillers = fillerCounts.entries
            .sortedByDescending { it.value }
            .take(5)
            .map { FillerCount(it.key, it.value) }

        val topPhrases = phraseCounts.entries
            .filter { it.value >= 2 }
            .sortedByDescending { it.value }
            .take(6)
            .map { TopPhrase(it.key, it.value) }

        val richness = if (totalWords == 0) 0.0 else (allWords.size.toDouble() / totalWords) * 100.0

        return InsightsSummary(
            sessions = entries.size,
            totalWords = totalWords,
            totalDurationMs = entries.sumOf { it.durationMs },
            averageWpm = if (wpmSamples.isEmpty()) 0.0 else wpmSamples.average(),
            fillerRatePer1k = if (totalWords == 0) 0.0 else fillerCount * 1000.0 / totalWords,
            topWords = topWords,
            longestSessionMs = entries.maxOf { it.durationMs },
            medianWpm = medianWpm,
            paceBuckets = paceBuckets,
            topFillers = topFillers,
            uniqueWords = allWords.size,
            richnessPercent = richness,
            topPhrases = topPhrases,
        )
    }
}
