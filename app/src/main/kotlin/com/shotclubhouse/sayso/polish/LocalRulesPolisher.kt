package com.shotclubhouse.sayso.polish

import com.shotclubhouse.sayso.core.PolishModel
import com.shotclubhouse.sayso.core.PolishProvider
import com.shotclubhouse.sayso.core.PolishResult

/** Offline cleanup: a handful of regex rules, no network, no key. */
object LocalRulesPolisher : PolishProvider {
    override val id = "rules"
    override val displayName = "Built-in rules"
    override val needsApiKey = false
    override val apiKeyUrl: String? = null
    override val supportsCustomPrompt = false
    override val models = listOf(PolishModel("rules/basic", "Basic cleanup"))

    /**
     * The [PolishProvider] contract hands over the JSON envelope built by
     * [CleanupPolicy.userMessage], so unwrap it before cleaning. An envelope this cleaner
     * cannot read is an error, never something to emit as the user's text.
     */
    override suspend fun polish(
        systemPrompt: String,
        userMessage: String,
        modelName: String,
        apiKey: String?,
    ): PolishResult {
        val transcript = CleanupPolicy.extractTranscript(userMessage)
            ?: return PolishResult.Failure("Malformed cleanup payload")
        return PolishResult.Success(clean(transcript))
    }

    /** Trims transcription markers and normalises spacing, casing and the final full stop. */
    fun clean(text: String): String {
        var cleaned = MARKER.replace(text, " ")
        cleaned = SPACE_BEFORE_PUNCTUATION.replace(cleaned, "$1")
        cleaned = WHITESPACE_RUN.replace(cleaned, " ").trim()
        if (cleaned.isEmpty()) return ""

        if (firstWordIsPlain(cleaned)) cleaned = cleaned.replaceFirstChar { it.uppercaseChar() }
        if (needsTerminalPunctuation(cleaned)) cleaned += "."
        return cleaned
    }

    /** Leaves "iPhone" alone: a first word that already carries a capital keeps its own casing. */
    private fun firstWordIsPlain(text: String): Boolean =
        text.substringBefore(' ').drop(1).none { it.isUpperCase() }

    private fun needsTerminalPunctuation(text: String): Boolean =
        text.last().isLetterOrDigit() && text.split(' ').count { it.isNotBlank() } >= MIN_WORDS_FOR_PERIOD

    private const val MIN_WORDS_FOR_PERIOD = 3

    // Only the known marker vocabulary. A wildcard bracket rule would eat real dictation
    // such as "list[0]", which the technical cleanup preset promises to preserve.
    private val MARKER = Regex(
        "[\\[(](?:blank[ _-]?audio|inaudible|unintelligible|silence|music|noise|laughter|applause)[\\])]",
        RegexOption.IGNORE_CASE,
    )
    private val SPACE_BEFORE_PUNCTUATION = Regex("\\s+([,.;:!?])")
    private val WHITESPACE_RUN = Regex("\\s+")
}
