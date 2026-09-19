package ai.sayso.dictation.polish

import ai.sayso.dictation.core.PolishModel
import ai.sayso.dictation.core.PolishProvider
import ai.sayso.dictation.core.PolishResult

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
        val baseCleaned = if (systemPrompt.contains("Transliteration directive") && IndicTransliterator.hasIndicCharacters(transcript)) {
            IndicTransliterator.transliterate(transcript)
        } else {
            transcript
        }
        return PolishResult.Success(clean(baseCleaned))
    }

    /** Trims transcription markers and normalises spacing, casing and the final full stop. */
    fun clean(text: String): String {
        var cleaned = MARKER.replace(text, " ")
        cleaned = applyCodeSymbols(cleaned)

        val isCommand = COMMAND_PREFIX_REGEX.containsMatchIn(cleaned)
        if (isCommand) {
            cleaned = COMMAND_PREFIX_REGEX.replace(cleaned, "").trim()
            return cleaned
        }

        cleaned = SPACE_BEFORE_PUNCTUATION.replace(cleaned, "$1")
        cleaned = BRACKET_SPACING_OPEN.replace(cleaned, "$1")
        cleaned = BRACKET_SPACING_CLOSE.replace(cleaned, "$1")
        cleaned = WHITESPACE_RUN.replace(cleaned, " ").trim()
        if (cleaned.isEmpty()) return ""

        cleaned = applyActionItems(cleaned)
        cleaned = applyBulletSummary(cleaned)

        cleaned = when {
            cleaned.startsWith("- [ ] ") -> "- [ ] " + cleaned.removePrefix("- [ ] ").replaceFirstChar { it.uppercaseChar() }
            cleaned.startsWith("- ") -> "- " + cleaned.removePrefix("- ").replaceFirstChar { it.uppercaseChar() }
            firstWordIsPlain(cleaned) -> cleaned.replaceFirstChar { it.uppercaseChar() }
            else -> cleaned
        }

        if (needsTerminalPunctuation(cleaned)) cleaned += "."
        return cleaned
    }

    private fun applyActionItems(text: String): String {
        return ACTION_ITEM_REGEX.replace(text, "- [ ] ")
    }

    private fun applyBulletSummary(text: String): String {
        return BULLET_PREFIX_REGEX.replace(text, "- ")
    }

    private fun applyCodeSymbols(text: String): String {
        var result = text
        for ((pattern, replacement) in CODE_SYMBOLS) {
            result = pattern.replace(result, replacement)
        }
        return result
    }

    /** Leaves "iPhone" alone: a first word that already carries a capital keeps its own casing. */
    private fun firstWordIsPlain(text: String): Boolean =
        text.substringBefore(' ').drop(1).none { it.isUpperCase() }

    private fun needsTerminalPunctuation(text: String): Boolean =
        !text.startsWith("- [ ]") &&
            !text.startsWith("- ") &&
            text.last().isLetterOrDigit() &&
            text.split(' ').count { it.isNotBlank() } >= MIN_WORDS_FOR_PERIOD

    private const val MIN_WORDS_FOR_PERIOD = 3

    // Known marker vocabulary. A wildcard bracket rule would eat real dictation
    // such as "list[0]", which the technical cleanup preset promises to preserve.
    private val MARKER = Regex(
        "[\\[(](?:blank[ _-]?audio|inaudible|unintelligible|silence|music|noise|laughter|applause|whispering|crying|sigh|groan)[\\])]",
        RegexOption.IGNORE_CASE,
    )
    private val SPACE_BEFORE_PUNCTUATION = Regex("\\s+([,.;:?]|!(?!=))")
    private val BRACKET_SPACING_OPEN = Regex("([(\\[{])\\s+")
    private val BRACKET_SPACING_CLOSE = Regex("\\s+([)\\]}])")
    private val WHITESPACE_RUN = Regex("\\s+")
    private val ACTION_ITEM_REGEX = Regex("(?im)^\\s*(?:todo|task|action item)\\s*:\\s*")
    private val BULLET_PREFIX_REGEX = Regex("(?im)^\\s*(?:bullet|in bullets|summary|summarize)\\s*:\\s*")
    private val COMMAND_PREFIX_REGEX = Regex("(?i)^\\s*(?:run\\s+command|command|shell)\\s*:\\s*")

    private val CODE_SYMBOLS = listOf(
        Regex("(?i)\\bnot\\s+equal(?:s)?(?:\\s+to)?\\b") to "!=",
        Regex("(?i)\\bequals?\\s+equals?\\b|\\bdouble\\s+equals?\\b") to "==",
        Regex("(?i)\\bgreater\\s+than\\s+or\\s+equal(?:s)?(?:\\s+to)?\\b") to ">=",
        Regex("(?i)\\bless\\s+than\\s+or\\s+equal(?:s)?(?:\\s+to)?\\b") to "<=",
        Regex("(?i)\\bfat\\s+arrow\\b") to "=>",
        Regex("(?i)\\b(?:right\\s+)?arrow\\b") to "->",
        Regex("(?i)\\bhash\\s+tag\\b") to "#",
        Regex("(?i)\\bat\\s+sign\\b") to "@",
    )
}
