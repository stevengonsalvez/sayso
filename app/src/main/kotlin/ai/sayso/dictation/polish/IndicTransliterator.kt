package ai.sayso.dictation.polish

/**
 * Lightweight deterministic transliterator for Indic scripts (Tamil, Devanagari, Malayalam)
 * to Tanglish, Hinglish, and Manglish using English letters.
 *
 * Provides immediate phonetic rendering when offline or operating in rules-only mode,
 * preserving natural spoken phonetics and English loan words.
 */
object IndicTransliterator {

    private val TAMIL_VOWELS = mapOf(
        0x0B85 to "a", 0x0B86 to "aa", 0x0B87 to "i", 0x0B88 to "ee",
        0x0B89 to "u", 0x0B8A to "oo", 0x0B8E to "e", 0x0B8F to "ae",
        0x0B90 to "ai", 0x0B92 to "o", 0x0B93 to "oa", 0x0B94 to "au",
        0x0B83 to "h",
    )

    private val TAMIL_CONSONANTS = mapOf(
        0x0B95 to "k", 0x0B99 to "ng", 0x0B9A to "ch", 0x0B9C to "j",
        0x0B9E to "ny", 0x0B9F to "t", 0x0BA3 to "n", 0x0BA4 to "th",
        0x0BA8 to "n", 0x0BA9 to "n", 0x0BAA to "p", 0x0BAE to "m",
        0x0BAF to "y", 0x0BB0 to "r", 0x0BB1 to "r", 0x0BB2 to "l",
        0x0BB3 to "l", 0x0BB4 to "zh", 0x0BB5 to "v", 0x0BB7 to "sh",
        0x0BB8 to "s", 0x0BB9 to "h",
    )

    private val TAMIL_MATRAS = mapOf(
        0x0BBE to "aa", 0x0BBF to "i", 0x0BC0 to "ee", 0x0BC1 to "u",
        0x0BC2 to "oo", 0x0BC6 to "e", 0x0BC7 to "ae", 0x0BC8 to "ai",
        0x0BCA to "o", 0x0BCB to "oa", 0x0BCC to "au",
    )

    private val DEVA_VOWELS = mapOf(
        0x0905 to "a", 0x0906 to "aa", 0x0907 to "i", 0x0908 to "ee",
        0x0909 to "u", 0x090A to "oo", 0x090F to "e", 0x0910 to "ai",
        0x0913 to "o", 0x0914 to "au", 0x0902 to "n", 0x0903 to "h",
    )

    private val DEVA_CONSONANTS = mapOf(
        0x0915 to "k", 0x0916 to "kh", 0x0917 to "g", 0x0918 to "gh", 0x0919 to "ng",
        0x091A to "ch", 0x091B to "chh", 0x091C to "j", 0x091D to "jh", 0x091E to "ny",
        0x091F to "t", 0x0920 to "th", 0x0921 to "d", 0x0922 to "dh", 0x0923 to "n",
        0x0924 to "t", 0x0925 to "th", 0x0926 to "d", 0x0927 to "dh", 0x0928 to "n",
        0x092A to "p", 0x092B to "ph", 0x092C to "b", 0x092D to "bh", 0x092E to "m",
        0x092F to "y", 0x0930 to "r", 0x0932 to "l", 0x0933 to "l", 0x0935 to "v",
        0x0936 to "sh", 0x0937 to "sh", 0x0938 to "s", 0x0939 to "h",
    )

    private val DEVA_MATRAS = mapOf(
        0x093E to "aa", 0x093F to "i", 0x0940 to "ee", 0x0941 to "u",
        0x0942 to "oo", 0x0947 to "e", 0x0948 to "ai", 0x094B to "o",
        0x094C to "au", 0x0902 to "n",
    )

    fun hasIndicCharacters(text: String): Boolean =
        text.any { c -> c in '\u0900'..'\u097F' || c in '\u0B80'..'\u0BFF' || c in '\u0D00'..'\u0D7F' }

    fun transliterate(text: String): String {
        if (!hasIndicCharacters(text)) return text

        val out = StringBuilder()
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            val charCount = Character.charCount(cp)

            when {
                // Tamil Virama (Pulli)
                cp == 0x0BCD -> Unit

                // Tamil Matra
                TAMIL_MATRAS.containsKey(cp) -> {
                    out.append(TAMIL_MATRAS[cp])
                }

                // Tamil Independent Vowel
                TAMIL_VOWELS.containsKey(cp) -> {
                    out.append(TAMIL_VOWELS[cp])
                }

                // Tamil Consonant
                TAMIL_CONSONANTS.containsKey(cp) -> {
                    val cons = TAMIL_CONSONANTS[cp] ?: ""
                    val nextCp = if (i + charCount < text.length) text.codePointAt(i + charCount) else null
                    when {
                        nextCp == 0x0BCD -> out.append(cons) // Virama cancels inherent 'a'
                        nextCp != null && TAMIL_MATRAS.containsKey(nextCp) -> out.append(cons)
                        else -> out.append(cons).append("a") // Inherent 'a'
                    }
                }

                // Devanagari Virama (Halant)
                cp == 0x094D -> Unit

                // Devanagari Matra
                DEVA_MATRAS.containsKey(cp) -> {
                    out.append(DEVA_MATRAS[cp])
                }

                // Devanagari Vowel
                DEVA_VOWELS.containsKey(cp) -> {
                    out.append(DEVA_VOWELS[cp])
                }

                // Devanagari Consonant
                DEVA_CONSONANTS.containsKey(cp) -> {
                    val cons = DEVA_CONSONANTS[cp] ?: ""
                    val nextCp = if (i + charCount < text.length) text.codePointAt(i + charCount) else null
                    when {
                        nextCp == 0x094D -> out.append(cons)
                        nextCp != null && DEVA_MATRAS.containsKey(nextCp) -> out.append(cons)
                        else -> out.append(cons).append("a")
                    }
                }

                else -> out.appendCodePoint(cp)
            }
            i += charCount
        }
        return out.toString()
    }
}
