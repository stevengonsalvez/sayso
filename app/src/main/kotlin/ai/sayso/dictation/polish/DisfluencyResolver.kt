package ai.sayso.dictation.polish

/**
 * Recognised standalone voice editing commands that act directly
 * on the active input field rather than injecting text.
 */
enum class StandaloneCommand {
    NONE,
    UNDO,
    CLEAR,
}

/**
 * Resolves spoken speech disfluencies (hesitation fillers, stutter repetitions,
 * and intra-utterance self-corrections) and applies voice editing directives
 * (line breaks, bullets, and explicit spoken punctuation).
 */
object DisfluencyResolver {

    private val FILLER_START = Regex("(?i)^\\s*(?:um|uh|er|ah|umm|uhh)\\b[,;]?\\s*")
    private val FILLER_END = Regex("(?i)[,;]?\\s*\\b(?:um|uh|er|ah|umm|uhh)\\b\\s*$")
    private val FILLER_WITH_COMMAS = Regex("(?i),\\s*(?:um|uh|er|ah|umm|uhh)\\b\\s*,?")
    private val FILLER_WORD = Regex("(?i)\\b(?:um|uh|er|ah|umm|uhh)\\b[,;]?")

    private val STUTTER_WORDS = Regex(
        "(?i)\\b(the|we|i|it|is|and|of|to|a|an|in|on|with|for|at|my|your|our|their|his|her|he|she|they|you)\\s+(?:,\\s*)?\\1\\b",
    )
    private val COMMA_REPEAT = Regex("(?i)\\b([a-zA-Z]+),\\s*\\1\\b")

    private val EXPLICIT_CORRECTION_MARKER = Regex(
        "(?i)(?:,\\s*)?\\b(?:scratch\\s+that|delete\\s+that|no\\s+wait|wait\\s+no|or\\s+rather)\\b[,;]?\\s*",
    )
    private val CONVERSATIONAL_CORRECTION_MARKER = Regex(
        "(?i),\\s*(?:actually|in\\s+fact|i\\s+mean|sorry)\\b[,;]?\\s*",
    )

    private val CARRIER_PHRASE = Regex(
        "(?i)^(?:make\\s+that|let's\\s+make\\s+that|change\\s+that\\s+to|i\\s+meant|i\\s+mean)\\s+",
    )

    private val DAYS_OF_WEEK = setOf(
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    )
    private val MONTHS = setOf(
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    )
    private val NUMBER_TOKEN = Regex(
        "(?i)^(?:\\d+|zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|first|second|third|fourth|fifth)$",
    )

    private val SPOKEN_PUNCTUATION = listOf(
        Regex("(?i)\\bquestion\\s+mark\\b") to "?",
        Regex("(?i)\\bexclamation\\s+(?:mark|point)\\b") to "!",
        Regex("(?i)\\bfull\\s+stop\\b") to ".",
        Regex("(?i)\\bperiod\\b(?!\\s+(?:of|in|between|from)\\b)") to ".",
        Regex("(?i)\\bcomma\\b(?!\\s+(?:separated|splice|delimited)\\b)") to ",",
        Regex("(?i)\\bcolon\\b(?!\\s+(?:cancer|surgery|screening|cleanse)\\b)") to ":",
        Regex("(?i)\\bsemicolon\\b") to ";",
        Regex("(?i)\\bellipsis\\b|\\bdot\\s+dot\\s+dot\\b") to "...",
        Regex("(?i)\\bopen\\s+quotes?\\s*") to "\"",
        Regex("(?i)\\s*\\bclose\\s+quotes?\\b") to "\"",
        Regex("(?i)\\bopen\\s+paren(?:thesis)?\\s*") to "(",
        Regex("(?i)\\s*\\bclose\\s+paren(?:thesis)?\\b") to ")",
    )

    private val NEW_PARAGRAPH_REGEX = Regex("(?i)\\bnew\\s+paragraph\\b")
    private val NEW_LINE_REGEX = Regex("(?i)\\b(?:new\\s+line|newline)\\b")
    private val BULLET_LINE_START = Regex("(?im)^\\s*(?:bullet\\s+point|bullet|dash)\\s+")
    private val BULLET_MID_SENTENCE = Regex("(?i)(?<=[.?!;:])\\s+(?:bullet\\s+point|bullet|dash)\\s+")

    private val SPACING_BEFORE_PUNCT = Regex("\\s+([,.:;?]|!(?!=)|\\))")
    private val SPACING_AFTER_OPEN_PAREN = Regex("(\\()\\s+")
    private val PUNCT_CAPITALIZE = Regex("([.?!]\\s+)([a-z])")

    /**
     * Applies full disfluency resolution and voice directive processing.
     */
    fun resolve(text: String): String {
        if (text.isBlank()) return text

        var processed = stripFillers(text)
        processed = removeStutters(processed)
        processed = resolveSelfCorrections(processed)
        processed = applySpokenPunctuation(processed)
        processed = applyFormattingDirectives(processed)

        return formatLines(processed)
    }

    /**
     * Strips speech hesitation fillers ("um", "uh", "er", "ah", "umm", "uhh").
     */
    fun stripFillers(text: String): String {
        if (text.isBlank()) return text
        val wasCapitalized = text.firstOrNull { it.isLetter() }?.isUpperCase() == true
        var res = text
        res = FILLER_START.replace(res, "")
        res = FILLER_END.replace(res, "")
        res = FILLER_WITH_COMMAS.replace(res, " ")
        res = FILLER_WORD.replace(res, "")
        res = res.replace(Regex("\\s+"), " ")
            .replace(Regex("\\s+,\\s*"), ", ")
            .replace(Regex(",\\s*,"), ",")
            .trim()
            .trimStart(',', ';', ' ')
            .trimEnd(',', ';', ' ')

        if (wasCapitalized && res.isNotEmpty()) {
            if (firstWordIsPlain(res)) {
                res = res.replaceFirstChar { it.uppercaseChar() }
            }
        }
        return res
    }

    /**
     * Removes immediate duplicate words (stutter repetitions) like "the the" -> "the".
     */
    fun removeStutters(text: String): String {
        if (text.isBlank()) return text
        var res = text
        var previous = ""
        var count = 0
        while (res != previous && count < 5) {
            previous = res
            count++
            res = STUTTER_WORDS.replace(res) { match -> match.groupValues[1] }
            res = COMMA_REPEAT.replace(res) { match -> match.groupValues[1] }
        }
        return res
    }

    /**
     * Resolves intra-utterance self-corrections such as:
     * - "meet on Friday, actually Saturday" -> "meet on Saturday"
     * - "call Bob, scratch that, call Alice" -> "call Alice"
     * - "send email to Bob scratch that Alice" -> "send email to Alice"
     * - "two, actually three apples" -> "three apples"
     */
    fun resolveSelfCorrections(text: String): String {
        if (text.isBlank()) return text
        var res = text
        var count = 0
        while (count < 5) {
            val updated = resolveSingleCorrection(res)
            if (updated == res) break
            res = updated
            count++
        }
        return res
    }

    private fun resolveSingleCorrection(text: String): String {
        val explicitMatch = EXPLICIT_CORRECTION_MARKER.find(text)
        val convMatch = CONVERSATIONAL_CORRECTION_MARKER.find(text)

        val match = when {
            explicitMatch != null && convMatch != null -> {
                if (explicitMatch.range.first <= convMatch.range.first) explicitMatch else convMatch
            }
            explicitMatch != null -> explicitMatch
            convMatch != null -> convMatch
            else -> return text
        }

        val prefix = text.substring(0, match.range.first).trimEnd().trimEnd(',', ';').trimEnd()
        val rawSuffix = text.substring(match.range.last + 1).trimStart().trimStart(',', ';').trimStart()

        // Marker at the very start is conversational (e.g. "Actually, I think...")
        if (prefix.isBlank()) return text

        val matchedMarker = match.value.lowercase()
        val isExplicitScratch = matchedMarker.contains("scratch that") || matchedMarker.contains("delete that")

        // Utterance ending with "scratch that" cancels the preceding phrase
        if (rawSuffix.isBlank()) {
            return if (isExplicitScratch) "" else prefix
        }

        val cleanSuffix = CARRIER_PHRASE.replace(rawSuffix, "").trimStart(',', ';').trimStart()
        val suffixWords = cleanSuffix.split(Regex("\\s+")).filter { it.isNotBlank() }
        val prefixWords = prefix.split(Regex("\\s+")).filter { it.isNotBlank() }

        if (suffixWords.isEmpty() || prefixWords.isEmpty()) return cleanSuffix

        // Case 1: Overlapping prefix match ("call Bob" -> "call Alice")
        val overlapWordIndex = findOverlapIndex(prefixWords, suffixWords)
        if (overlapWordIndex >= 0) {
            val keptPrefix = prefixWords.take(overlapWordIndex).joinToString(" ").trimEnd(',', ';')
            return if (keptPrefix.isEmpty()) cleanSuffix else "$keptPrefix $cleanSuffix"
        }

        // Case 2: Matching grammatical categories (days, months, numbers)
        val lastPrefixWord = prefixWords.last().lowercase().trimEnd('.', ',', '!', '?')
        val firstSuffixWord = suffixWords.first().lowercase().trimEnd('.', ',', '!', '?')

        val isCategoryMatch = (DAYS_OF_WEEK.contains(lastPrefixWord) && DAYS_OF_WEEK.contains(firstSuffixWord)) ||
            (MONTHS.contains(lastPrefixWord) && MONTHS.contains(firstSuffixWord)) ||
            (NUMBER_TOKEN.matches(lastPrefixWord) && NUMBER_TOKEN.matches(firstSuffixWord))

        if (isCategoryMatch) {
            val keptPrefix = prefixWords.dropLast(1).joinToString(" ").trimEnd(',', ';')
            return if (keptPrefix.isEmpty()) cleanSuffix else "$keptPrefix $cleanSuffix"
        }

        // Case 3: Explicit "scratch that" or "delete that" with full clause
        if (isExplicitScratch && suffixWords.size >= 2) {
            return cleanSuffix
        }

        // Case 4: Single token replacement ("Bob" -> "Alice")
        if (suffixWords.size == 1) {
            val keptPrefix = prefixWords.dropLast(1).joinToString(" ").trimEnd(',', ';')
            return if (keptPrefix.isEmpty()) cleanSuffix else "$keptPrefix $cleanSuffix"
        }

        // Case 5: Short replacement (2-3 words) replaces equal number of words from prefix
        if (suffixWords.size <= 3 && prefixWords.size >= suffixWords.size) {
            val keptPrefix = prefixWords.dropLast(suffixWords.size).joinToString(" ").trimEnd(',', ';')
            return if (keptPrefix.isEmpty()) cleanSuffix else "$keptPrefix $cleanSuffix"
        }

        // Default fallback: replace last word and append suffix
        val keptPrefix = prefixWords.dropLast(1).joinToString(" ").trimEnd(',', ';')
        return if (keptPrefix.isEmpty()) cleanSuffix else "$keptPrefix $cleanSuffix"
    }

    private fun findOverlapIndex(prefixWords: List<String>, suffixWords: List<String>): Int {
        val firstSuffix = suffixWords.first().lowercase().trimEnd('.', ',', '!', '?')
        for (i in prefixWords.indices.reversed()) {
            val pWord = prefixWords[i].lowercase().trimEnd('.', ',', '!', '?')
            if (pWord == firstSuffix) {
                return i
            }
        }
        return -1
    }

    /**
     * Replaces spoken punctuation words with punctuation marks.
     */
    fun applySpokenPunctuation(text: String): String {
        var res = text
        for ((pattern, replacement) in SPOKEN_PUNCTUATION) {
            res = pattern.replace(res, replacement)
        }
        res = SPACING_BEFORE_PUNCT.replace(res, "$1")
        res = SPACING_AFTER_OPEN_PAREN.replace(res, "$1")
        res = PUNCT_CAPITALIZE.replace(res) { match ->
            match.groupValues[1] + match.groupValues[2].uppercase()
        }
        return res
    }

    /**
     * Converts voice formatting directives ("new line", "new paragraph", "bullet point")
     * into newlines and markdown bullet markers.
     */
    fun applyFormattingDirectives(text: String): String {
        var res = text
        res = NEW_PARAGRAPH_REGEX.replace(res, "\n\n")
        res = NEW_LINE_REGEX.replace(res, "\n")
        res = BULLET_LINE_START.replace(res, "- ")
        res = BULLET_MID_SENTENCE.replace(res, "\n- ")
        return res
    }

    private fun firstWordIsPlain(text: String): Boolean =
        text.substringBefore(' ').drop(1).none { it.isUpperCase() }

    /**
     * Capitalizes each line and ensures bullet markers are formatted properly.
     */
    private fun formatLines(text: String): String {
        return text.lines().joinToString("\n") { line ->
            val trimmed = line.trim()
            when {
                trimmed.startsWith("- [ ] ") -> "- [ ] " + trimmed.removePrefix("- [ ] ").replaceFirstChar { it.uppercaseChar() }
                trimmed.startsWith("- ") -> "- " + trimmed.removePrefix("- ").replaceFirstChar { it.uppercaseChar() }
                firstWordIsPlain(trimmed) -> trimmed.replaceFirstChar { it.uppercaseChar() }
                else -> trimmed
            }
        }
    }

    /**
     * Parses a standalone speech utterance to check if it matches an editing command.
     */
    fun parseStandaloneCommand(rawText: String): StandaloneCommand {
        val normalized = rawText.trim()
            .lowercase()
            .removePrefix("please ")
            .removeSuffix(" please")
            .removeSuffix(".")
            .removeSuffix("!")
            .trim()

        return when (normalized) {
            "scratch that", "scratch this", "delete that", "delete this", "undo", "revert" -> StandaloneCommand.UNDO
            "clear text", "clear all", "delete all", "clear field" -> StandaloneCommand.CLEAR
            else -> StandaloneCommand.NONE
        }
    }
}
