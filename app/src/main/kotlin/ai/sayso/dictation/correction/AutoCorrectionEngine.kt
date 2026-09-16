package ai.sayso.dictation.correction

import android.content.Context
import android.content.SharedPreferences
import ai.sayso.dictation.core.PronunciationCategory
import ai.sayso.dictation.core.PronunciationEntry
import ai.sayso.dictation.core.SettingsStore
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.util.UUID

enum class ChangeType { REPLACEMENT, SPLIT, MERGE }

data class WordChange(
    val type: ChangeType,
    val original: String,
    val corrected: String,
) {
    val isLikelyCorrection: Boolean
        get() {
            if (original.length < 2 || corrected.length < 2) return false
            if (original.equals(corrected, ignoreCase = false)) return false

            val origLower = original.lowercase()
            val corrLower = corrected.lowercase()

            return when (type) {
                ChangeType.REPLACEMENT -> {
                    stringSimilarity(origLower, corrLower) > 0.3 || origLower == corrLower
                }
                ChangeType.SPLIT -> {
                    val first = corrected.split(" ").firstOrNull().orEmpty().lowercase()
                    first.length >= 2 && origLower.startsWith(first.take(2))
                }
                ChangeType.MERGE -> {
                    val parts = original.split(" ")
                    parts.all { it.isNotBlank() && corrLower.contains(it.lowercase()) }
                }
            }
        }

    private fun stringSimilarity(s1: String, s2: String): Double {
        if (s1.isEmpty() || s2.isEmpty()) return 0.0
        val maxLen = maxOf(s1.length, s2.length)
        var matches = 0
        val minLen = minOf(s1.length, s2.length)
        for (i in 0 until minLen) {
            if (s1[i] == s2[i]) matches++
        }
        if (s1.contains(s2) || s2.contains(s1)) return 0.7
        return matches.toDouble() / maxLen
    }
}

object WordDiffer {
    private val TOKEN_REGEX = Regex("[\\p{L}\\p{N}]+(?:'[\\p{L}\\p{N}]+)*")

    fun findChanges(original: String, edited: String): List<WordChange> {
        val origTokens = TOKEN_REGEX.findAll(original).map { it.value }.toList()
        val editTokens = TOKEN_REGEX.findAll(edited).map { it.value }.toList()

        if (origTokens.isEmpty() || editTokens.isEmpty()) return emptyList()

        val changes = mutableListOf<WordChange>()

        if (origTokens.size == editTokens.size) {
            for (i in origTokens.indices) {
                if (!origTokens[i].equals(editTokens[i], ignoreCase = false)) {
                    val change = WordChange(ChangeType.REPLACEMENT, origTokens[i], editTokens[i])
                    if (change.isLikelyCorrection) changes += change
                }
            }
        } else if (origTokens.size < editTokens.size) {
            var i = 0
            var j = 0
            while (i < origTokens.size && j < editTokens.size) {
                if (origTokens[i] == editTokens[j]) {
                    i++; j++
                } else if (j + 1 < editTokens.size) {
                    val splitCandidate = "${editTokens[j]} ${editTokens[j + 1]}"
                    val change = WordChange(ChangeType.SPLIT, origTokens[i], splitCandidate)
                    if (change.isLikelyCorrection) {
                        changes += change
                        i++
                        j += 2
                    } else {
                        i++; j++
                    }
                } else {
                    i++; j++
                }
            }
        } else {
            var i = 0
            var j = 0
            while (i < origTokens.size && j < editTokens.size) {
                if (origTokens[i] == editTokens[j]) {
                    i++; j++
                } else if (i + 1 < origTokens.size) {
                    val mergeCandidate = "${origTokens[i]} ${origTokens[i + 1]}"
                    val change = WordChange(ChangeType.MERGE, mergeCandidate, editTokens[j])
                    if (change.isLikelyCorrection) {
                        changes += change
                        i += 2
                        j++
                    } else {
                        i++; j++
                    }
                } else {
                    i++; j++
                }
            }
        }

        return changes
    }
}

/** Represents an observed post-injection manual correction. */
data class AutoCorrectionCandidate(
    val id: String = UUID.randomUUID().toString(),
    val original: String,
    val corrected: String,
    val seenCount: Int = 1,
    val firstSeenAt: Long = System.currentTimeMillis(),
    val lastSeenAt: Long = System.currentTimeMillis(),
    val dismissed: Boolean = false,
) {
    val matchKey: String get() = "${original.lowercase()}->${corrected.lowercase()}"
}

/**
 * Platform engine that records edits to dictated text, detects recurring fixes,
 * and suggests or auto-promotes candidates to PronunciationEntry rules.
 */
class AutoCorrectionEngine(
    private val prefs: SharedPreferences,
    private val settings: SettingsStore,
    private val promotionThreshold: Int = 2,
) {
    private val candidates = mutableListOf<AutoCorrectionCandidate>()

    init {
        loadCandidates()
    }

    @Synchronized
    fun getActiveSuggestions(): List<AutoCorrectionCandidate> {
        return candidates.filter { !it.dismissed && it.seenCount >= promotionThreshold }
    }

    @Synchronized
    fun recordEdit(original: String, edited: String) {
        if (original.isBlank() || edited.isBlank() || original == edited) return

        val changes = WordDiffer.findChanges(original, edited)
        if (changes.isEmpty()) return

        var mutated = false
        val now = System.currentTimeMillis()

        for (change in changes) {
            val key = "${change.original.lowercase()}->${change.corrected.lowercase()}"
            val existingIndex = candidates.indexOfFirst { it.matchKey == key }

            if (existingIndex >= 0) {
                val old = candidates[existingIndex]
                candidates[existingIndex] = old.copy(
                    seenCount = old.seenCount + 1,
                    lastSeenAt = now,
                )
                mutated = true
            } else {
                candidates.add(
                    AutoCorrectionCandidate(
                        original = change.original,
                        corrected = change.corrected,
                        seenCount = 1,
                        firstSeenAt = now,
                        lastSeenAt = now,
                    ),
                )
                mutated = true
            }
        }

        if (mutated) {
            saveCandidates()
        }
    }

    @Synchronized
    fun promoteCandidate(candidateId: String) {
        val candidate = candidates.firstOrNull { it.id == candidateId } ?: return
        candidates.removeAll { it.id == candidateId }
        saveCandidates()

        // Promote to PronunciationEntry in settings
        val current = settings.pronunciations.toMutableList()
        val entry = PronunciationEntry(
            word = candidate.corrected,
            pronunciation = candidate.original,
            replacement = candidate.original,
            category = PronunciationCategory.CUSTOM,
        )
        current.add(0, entry)
        settings.pronunciations = current
    }

    @Synchronized
    fun dismissCandidate(candidateId: String) {
        val index = candidates.indexOfFirst { it.id == candidateId }
        if (index >= 0) {
            candidates[index] = candidates[index].copy(dismissed = true)
            saveCandidates()
        }
    }

    private fun loadCandidates() {
        val raw = prefs.getString(KEY_CANDIDATES, null).orEmpty()
        if (raw.isBlank()) return
        val array = runCatching { Json.parseToJsonElement(raw) as? JsonArray }.getOrNull() ?: return
        candidates.clear()
        array.mapNotNullTo(candidates) { elem ->
            val obj = elem as? JsonObject ?: return@mapNotNullTo null
            val orig = (obj["original"] as? JsonPrimitive)?.content ?: return@mapNotNullTo null
            val corr = (obj["corrected"] as? JsonPrimitive)?.content ?: return@mapNotNullTo null
            val id = (obj["id"] as? JsonPrimitive)?.content ?: UUID.randomUUID().toString()
            val seen = (obj["seenCount"] as? JsonPrimitive)?.intOrNull ?: 1
            val first = (obj["firstSeenAt"] as? JsonPrimitive)?.longOrNull ?: 0L
            val last = (obj["lastSeenAt"] as? JsonPrimitive)?.longOrNull ?: 0L
            val dismissed = (obj["dismissed"] as? JsonPrimitive)?.booleanOrNull ?: false
            AutoCorrectionCandidate(id, orig, corr, seen, first, last, dismissed)
        }
    }

    private fun saveCandidates() {
        val json = buildJsonArray {
            candidates.forEach { c ->
                add(
                    buildJsonObject {
                        put("id", c.id)
                        put("original", c.original)
                        put("corrected", c.corrected)
                        put("seenCount", c.seenCount)
                        put("firstSeenAt", c.firstSeenAt)
                        put("lastSeenAt", c.lastSeenAt)
                        put("dismissed", c.dismissed)
                    },
                )
            }
        }.toString()
        prefs.edit().putString(KEY_CANDIDATES, json).apply()
    }

    companion object {
        private const val KEY_CANDIDATES = "auto_correction_candidates"

        fun open(context: Context, settings: SettingsStore): AutoCorrectionEngine {
            val prefs = context.applicationContext.getSharedPreferences("sayso_autocorrection", Context.MODE_PRIVATE)
            return AutoCorrectionEngine(prefs, settings)
        }
    }
}
