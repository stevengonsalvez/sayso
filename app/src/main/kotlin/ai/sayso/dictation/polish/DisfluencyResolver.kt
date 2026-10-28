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

    private val PRONOUNS = setOf("i", "we", "you", "he", "she", "it", "they", "there")

    private val PERIOD_DIRECTIVE = Regex("(?i)\\b(?:period|full\\s+stop)\\b")
    private val PERIOD_NOUN_PREFIX = setOf(
        "the", "a", "an", "my", "his", "her", "their", "our", "this", "that",
        "grace", "time", "waiting", "long", "short", "menstrual", "first", "second", "third", "trial",
    )
    private val PERIOD_NOUN_SUFFIX = setOf(
        "of", "in", "between", "from", "for", "tutor", "panties", "piece", "costume",
    )

    private val COMMA_DIRECTIVE = Regex("(?i)\\bcomma\\b")
    private val COMMA_NOUN_PREFIX = setOf(
        "the", "a", "an", "oxford", "serial", "inverted", "trailing", "missing",
    )
    private val COMMA_NOUN_SUFFIX = setOf(
        "separated", "splice", "delimited", "delineated",
    )

    private val COLON_DIRECTIVE = Regex("(?i)\\bcolon\\b")
    private val COLON_NOUN_PREFIX = setOf(
        "the", "a", "an", "my", "his", "her", "their", "our", "healthy", "sigmoid", "spastic", "irritable",
    )
    private val COLON_NOUN_SUFFIX = setOf(
        "cancer", "surgery", "screening", "cleanse", "irrigation", "polyps", "disease", "wall", "tissue", "is", "was",
    )

    private val STATIC_SPOKEN_PUNCTUATION = listOf(
        Regex("(?i)\\bquestion\\s+mark\\b") to "?",
        Regex("(?i)\\bexclamation\\s+(?:mark|point)\\b") to "!",
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

    private val CANCELLED_END_REGEX = Regex("(?i)(?:,\\s*)?\\b(?:scratch\\s+that|delete\\s+that)\\s*[.!]?$")

    /**
     * Checks if the utterance ends with a cancellation command like "scratch that"
     * indicating the entire phrase should be discarded.
     */
    fun isCancelled(text: String): Boolean {
        if (text.isBlank()) return false
        val trimmed = text.trim()
        if (CANCELLED_END_REGEX.containsMatchIn(trimmed)) return true
        val resolved = resolve(trimmed)
        return resolved.isBlank()
    }

    /**
     * Applies full disfluency resolution and voice directive processing.
     */
    fun resolve(text: String): String {
        if (text.isBlank()) return text

        var processed = stripFillers(text)
        processed = removeStutters(processed)
        processed = resolveSelfCorrections(processed)
        if (processed.isBlank()) return ""
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
        val isConversational = matchedMarker.contains("actually") ||
            matchedMarker.contains("in fact") ||
            matchedMarker.contains("i mean") ||
            matchedMarker.contains("sorry")

        // Utterance ending with "scratch that" cancels the preceding phrase
        if (rawSuffix.isBlank()) {
            return if (isExplicitScratch) "" else text
        }

        val hasCarrierPhrase = CARRIER_PHRASE.containsMatchIn(rawSuffix)
        val cleanSuffix = CARRIER_PHRASE.replace(rawSuffix, "").trimStart(',', ';').trimStart()
        val suffixWords = cleanSuffix.split(Regex("\\s+")).filter { it.isNotBlank() }
        val prefixWords = prefix.split(Regex("\\s+")).filter { it.isNotBlank() }

        if (suffixWords.isEmpty() || prefixWords.isEmpty()) return cleanSuffix

        // Case 1: Overlapping prefix match ("call Bob" -> "call Alice")
        val overlapWordIndex = findOverlapIndex(prefixWords, suffixWords, isConversational)
        if (overlapWordIndex >= 0) {
            val keptPrefix = prefixWords.take(overlapWordIndex).joinToString(" ").trimEnd(',', ';')
            return if (keptPrefix.isEmpty()) cleanSuffix else "$keptPrefix $cleanSuffix"
        }

        // Case 2: Matching grammatical categories (days, months, numbers)
        var pCheck = prefixWords
        var sCheck = suffixWords
        var commonSuffixCount = 0
        while (pCheck.size > 1 && sCheck.size > 1 &&
            pCheck.last().equals(sCheck.last(), ignoreCase = true)
        ) {
            pCheck = pCheck.dropLast(1)
            sCheck = sCheck.dropLast(1)
            commonSuffixCount++
        }
        val lastPWord = pCheck.last().lowercase().trimEnd('.', ',', '!', '?')
        val firstSWord = sCheck.first().lowercase().trimEnd('.', ',', '!', '?')

        val isCategoryMatch = (DAYS_OF_WEEK.contains(lastPWord) && DAYS_OF_WEEK.contains(firstSWord)) ||
            (MONTHS.contains(lastPWord) && MONTHS.contains(firstSWord)) ||
            (NUMBER_TOKEN.matches(lastPWord) && NUMBER_TOKEN.matches(firstSWord))

        if (isCategoryMatch) {
            val dropCount = commonSuffixCount + 1
            val keptPrefix = prefixWords.dropLast(dropCount).joinToString(" ").trimEnd(',', ';')
            return if (keptPrefix.isEmpty()) cleanSuffix else "$keptPrefix $cleanSuffix"
        }

        // If conversational and no explicit evidence of replacement exists, preserve both clauses
        if (isConversational && !hasCarrierPhrase) {
            return text
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

        // Default fallback for explicit markers: replace last word and append suffix
        val keptPrefix = prefixWords.dropLast(1).joinToString(" ").trimEnd(',', ';')
        return if (keptPrefix.isEmpty()) cleanSuffix else "$keptPrefix $cleanSuffix"
    }

    private fun findOverlapIndex(prefixWords: List<String>, suffixWords: List<String>, isConversational: Boolean): Int {
        val firstSuffix = suffixWords.first().lowercase().trimEnd('.', ',', '!', '?')
        // Do not treat a single pronoun as conversational correction overlap (e.g. "I agree, actually I think...")
        if (isConversational && PRONOUNS.contains(firstSuffix)) {
            val secondSuffix = suffixWords.getOrNull(1)?.lowercase()?.trimEnd('.', ',', '!', '?')
            if (secondSuffix == null) return -1
            // Require at least 2 consecutive overlapping words if starting with pronoun
            for (i in 0 until prefixWords.size - 1) {
                val p1 = prefixWords[i].lowercase().trimEnd('.', ',', '!', '?')
                val p2 = prefixWords[i + 1].lowercase().trimEnd('.', ',', '!', '?')
                if (p1 == firstSuffix && p2 == secondSuffix) {
                    return i
                }
            }
            return -1
        }

        for (i in prefixWords.indices.reversed()) {
            val pWord = prefixWords[i].lowercase().trimEnd('.', ',', '!', '?')
            if (pWord == firstSuffix) {
                return i
            }
        }
        return -1
    }

    /**
     * Replaces spoken punctuation words with punctuation marks, disambiguating
     * literal nouns like "period", "colon", and "comma".
     */
    fun applySpokenPunctuation(text: String): String {
        var res = text
        for ((pattern, replacement) in STATIC_SPOKEN_PUNCTUATION) {
            res = pattern.replace(res, replacement)
        }

        // Disambiguate "period" / "full stop"
        res = PERIOD_DIRECTIVE.replace(res) { match ->
            val beforeWord = extractWordBefore(res, match.range.first)
            val afterWord = extractWordAfter(res, match.range.last)
            if (PERIOD_NOUN_PREFIX.contains(beforeWord) || PERIOD_NOUN_SUFFIX.contains(afterWord)) {
                match.value
            } else {
                "."
            }
        }

        // Disambiguate "colon"
        res = COLON_DIRECTIVE.replace(res) { match ->
            val beforeWord = extractWordBefore(res, match.range.first)
            val afterWord = extractWordAfter(res, match.range.last)
            if (COLON_NOUN_PREFIX.contains(beforeWord) || COLON_NOUN_SUFFIX.contains(afterWord)) {
                match.value
            } else {
                ":"
            }
        }

        // Disambiguate "comma"
        res = COMMA_DIRECTIVE.replace(res) { match ->
            val beforeWord = extractWordBefore(res, match.range.first)
            val afterWord = extractWordAfter(res, match.range.last)
            if (COMMA_NOUN_PREFIX.contains(beforeWord) || COMMA_NOUN_SUFFIX.contains(afterWord)) {
                match.value
            } else {
                ","
            }
        }

        res = SPACING_BEFORE_PUNCT.replace(res, "$1")
        res = SPACING_AFTER_OPEN_PAREN.replace(res, "$1")
        res = PUNCT_CAPITALIZE.replace(res) { match ->
            match.groupValues[1] + match.groupValues[2].uppercase()
        }
        return res
    }

    private fun extractWordBefore(text: String, startIndex: Int): String {
        if (startIndex <= 0) return ""
        val substring = text.substring(0, startIndex).trimEnd()
        return substring.split(Regex("\\s+")).lastOrNull()?.lowercase()?.trimEnd('.', ',', '!', '?', ';', ':').orEmpty()
    }

    private fun extractWordAfter(text: String, endIndex: Int): String {
        if (endIndex >= text.length - 1) return ""
        val substring = text.substring(endIndex + 1).trimStart()
        return substring.split(Regex("\\s+")).firstOrNull()?.lowercase()?.trimStart('.', ',', '!', '?', ';', ':').orEmpty()
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
