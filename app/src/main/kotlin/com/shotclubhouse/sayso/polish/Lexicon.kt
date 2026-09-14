package com.shotclubhouse.sayso.polish

import com.shotclubhouse.sayso.core.LexiconRule
import com.shotclubhouse.sayso.core.PronunciationCategory
import com.shotclubhouse.sayso.core.PronunciationEntry
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Personal vocabulary: rewrites aliases to their canonical spelling, and persists the rules. */
object Lexicon {

    /**
     * Replaces every alias with its canonical form, case-insensitively and on word
     * boundaries only, so "cat" inside "catalogue" is left alone.
     */
    fun apply(text: String, rules: List<LexiconRule>): String {
        if (text.isEmpty() || rules.isEmpty()) return text

        val canonicalByAlias = HashMap<String, String>()
        val aliases = mutableListOf<String>()
        rules.forEach { rule ->
            rule.aliases.filter { it.isNotBlank() }.forEach { alias ->
                if (canonicalByAlias.put(alias.lowercase(), rule.canonical) == null) aliases += alias
            }
        }
        if (aliases.isEmpty()) return text

        aliases.sortByDescending { it.length }
        val pattern = Regex(
            "(?iu)$LEFT_EDGE(?:" + aliases.joinToString("|") { Regex.escape(it) } + ")$RIGHT_EDGE",
        )
        return pattern.replace(text) { match ->
            canonicalByAlias[match.value.lowercase()] ?: match.value
        }
    }

    /**
     * Applies the pronunciation dictionary to raw transcript text:
     * 1. Evaluates regex replacement entries.
     * 2. Evaluates word-boundary aliases and phonetics to canonical forms.
     */
    fun applyPronunciations(text: String, entries: List<PronunciationEntry>): String {
        if (text.isEmpty() || entries.isEmpty()) return text

        var current = text

        // 1. Process regex entries
        val (regexEntries, simpleEntries) = entries.partition { it.isRegex }
        for (entry in regexEntries) {
            val patternStr = entry.word.trim()
            if (patternStr.isEmpty()) continue
            val options = if (entry.caseSensitive) emptySet() else setOf(RegexOption.IGNORE_CASE)
            val regex = runCatching { Regex(patternStr, options) }.getOrNull() ?: continue
            val replacement = entry.replacement?.ifBlank { null } ?: entry.pronunciation.ifBlank { null } ?: entry.word
            current = regex.replace(current, replacement)
        }

        if (simpleEntries.isEmpty() || current.isEmpty()) return current

        // 2. Process simple whole-word entries
        val canonicalByAlias = HashMap<String, String>()
        val aliases = mutableListOf<String>()

        simpleEntries.forEach { entry ->
            val canonical = entry.word.trim()
            if (canonical.isNotEmpty()) {
                val targets = mutableListOf<String>()
                if (entry.pronunciation.isNotBlank()) targets += entry.pronunciation.trim()
                if (!entry.replacement.isNullOrBlank()) targets += entry.replacement.trim()
                // If not case-sensitive and word has uppercase, allow case-folding match
                if (!entry.caseSensitive && canonical.any { it.isUpperCase() }) {
                    targets += canonical
                }

                targets.forEach { target ->
                    val key = if (entry.caseSensitive) target else target.lowercase()
                    if (canonicalByAlias.put(key, canonical) == null) {
                        aliases += target
                    }
                }
            }
        }

        if (aliases.isEmpty()) return current

        aliases.sortByDescending { it.length }
        val pattern = Regex(
            "(?iu)$LEFT_EDGE(?:" + aliases.joinToString("|") { Regex.escape(it) } + ")$RIGHT_EDGE",
        )
        return pattern.replace(current) { match ->
            val matched = match.value
            canonicalByAlias[matched] ?: canonicalByAlias[matched.lowercase()] ?: matched
        }
    }

    fun encode(rules: List<LexiconRule>): String = buildJsonArray {
        rules.forEach { rule ->
            add(
                buildJsonObject {
                    put("canonical", rule.canonical)
                    put("aliases", buildJsonArray { rule.aliases.forEach { add(it) } })
                },
            )
        }
    }.toString()

    fun encodePronunciations(entries: List<PronunciationEntry>): String = buildJsonArray {
        entries.forEach { entry ->
            add(
                buildJsonObject {
                    put("id", entry.id)
                    put("word", entry.word)
                    put("pronunciation", entry.pronunciation)
                    entry.replacement?.let { put("replacement", it) }
                    put("category", entry.category.displayName)
                    put("isRegex", entry.isRegex)
                    put("caseSensitive", entry.caseSensitive)
                },
            )
        }
    }.toString()

    fun decodePronunciations(json: String): List<PronunciationEntry> {
        if (json.isBlank()) return emptyList()
        val array = runCatching { Json.parseToJsonElement(json) as? JsonArray }.getOrNull() ?: return emptyList()
        return array.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            // Check if it's a PronunciationEntry
            val word = (obj["word"] as? JsonPrimitive)?.contentOrNullIfJsonNull()
            if (word != null) {
                val id = (obj["id"] as? JsonPrimitive)?.contentOrNullIfJsonNull() ?: java.util.UUID.randomUUID().toString()
                val pronunciation = (obj["pronunciation"] as? JsonPrimitive)?.contentOrNullIfJsonNull().orEmpty()
                val replacement = (obj["replacement"] as? JsonPrimitive)?.contentOrNullIfJsonNull()
                val categoryName = (obj["category"] as? JsonPrimitive)?.contentOrNullIfJsonNull()
                val isRegex = (obj["isRegex"] as? JsonPrimitive)?.booleanOrNull ?: false
                val caseSensitive = (obj["caseSensitive"] as? JsonPrimitive)?.booleanOrNull ?: false
                PronunciationEntry(
                    id = id,
                    word = word,
                    pronunciation = pronunciation,
                    replacement = replacement,
                    category = PronunciationCategory.fromString(categoryName),
                    isRegex = isRegex,
                    caseSensitive = caseSensitive,
                )
            } else {
                // Fallback for legacy LexiconRule format: canonical & aliases
                val canonical = (obj["canonical"] as? JsonPrimitive)?.contentOrNullIfJsonNull() ?: return@mapNotNull null
                val aliases = (obj["aliases"] as? JsonArray)
                    ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNullIfJsonNull() }
                    .orEmpty()
                PronunciationEntry(
                    word = canonical,
                    pronunciation = aliases.firstOrNull().orEmpty(),
                    replacement = aliases.drop(1).firstOrNull(),
                    category = PronunciationCategory.TECHNICAL,
                )
            }
        }
    }

    /** Tolerant of anything that is not a well-formed rule array: returns what it can parse. */
    fun decode(json: String): List<LexiconRule> {
        if (json.isBlank()) return emptyList()
        val array = runCatching { Json.parseToJsonElement(json) as? JsonArray }.getOrNull() ?: return emptyList()
        return array.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val canonical = (obj["canonical"] as? JsonPrimitive)?.contentOrNullIfJsonNull() ?: return@mapNotNull null
            val aliases = (obj["aliases"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNullIfJsonNull() }
                .orEmpty()
            LexiconRule(canonical, aliases)
        }
    }

    private fun JsonPrimitive.contentOrNullIfJsonNull(): String? = if (isString) content else null

    private const val LEFT_EDGE = "(?<![\\p{L}\\p{N}_])"
    private const val RIGHT_EDGE = "(?![\\p{L}\\p{N}_])"
}
