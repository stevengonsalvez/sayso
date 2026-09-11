package com.shotclubhouse.sayso.polish

import com.shotclubhouse.sayso.core.LexiconRule
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Personal vocabulary: rewrites aliases to their canonical spelling, and persists the rules. */
object Lexicon {

    /**
     * Replaces every alias with its canonical form, case-insensitively and on word
     * boundaries only, so "cat" inside "catalogue" is left alone.
     *
     * One pass over the text with a single alternation, longest alias first. Applying the
     * rules one after another instead would let a canonical form produced by one rule be
     * rewritten again by the next.
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
        // Lookarounds rather than \b so an alias such as "c++" or ".NET" still anchors, and
        // (?iu) so case folding covers non-ASCII letters.
        val pattern = Regex(
            "(?iu)$LEFT_EDGE(?:" + aliases.joinToString("|") { Regex.escape(it) } + ")$RIGHT_EDGE",
        )
        return pattern.replace(text) { match ->
            canonicalByAlias[match.value.lowercase()] ?: match.value
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
