package com.shotclubhouse.sayso.polish

import com.shotclubhouse.sayso.core.PronunciationCategory
import com.shotclubhouse.sayso.core.PronunciationEntry

/**
 * Pre-populated default technical and developer pronunciation dictionary entries.
 * Directly ported from justspeaktoit defaults.
 */
object PronunciationDefaults {
    val entries: List<PronunciationEntry> = listOf(
        // Technical terms
        PronunciationEntry(word = "API", pronunciation = "A P I", replacement = "A P I", category = PronunciationCategory.TECHNICAL),
        PronunciationEntry(word = "SQL", pronunciation = "sequel", replacement = "sequel", category = PronunciationCategory.TECHNICAL),
        PronunciationEntry(word = "iOS", pronunciation = "eye OS", replacement = "eye OS", category = PronunciationCategory.TECHNICAL),
        PronunciationEntry(word = "macOS", pronunciation = "mac OS", replacement = "mac OS", category = PronunciationCategory.TECHNICAL),
        PronunciationEntry(word = "CLI", pronunciation = "C L I", replacement = "C L I", category = PronunciationCategory.TECHNICAL),
        PronunciationEntry(word = "GUI", pronunciation = "gooey", replacement = "gooey", category = PronunciationCategory.TECHNICAL),
        PronunciationEntry(word = "JSON", pronunciation = "jay-son", replacement = "jason", category = PronunciationCategory.TECHNICAL),
        PronunciationEntry(word = "YAML", pronunciation = "yam-el", replacement = "yamel", category = PronunciationCategory.TECHNICAL),
        PronunciationEntry(word = "nginx", pronunciation = "engine-x", replacement = "engine X", category = PronunciationCategory.TECHNICAL),
        PronunciationEntry(word = "kubectl", pronunciation = "cube-control", replacement = "cube control", category = PronunciationCategory.TECHNICAL),

        // Names in tech
        PronunciationEntry(word = "Kubernetes", pronunciation = "koo-ber-net-ees", replacement = "koo ber nettees", category = PronunciationCategory.NAMES),
        PronunciationEntry(word = "PostgreSQL", pronunciation = "post-gres-Q-L", replacement = "post gres Q L", category = PronunciationCategory.NAMES),
        PronunciationEntry(word = "MySQL", pronunciation = "my-S-Q-L", replacement = "my S Q L", category = PronunciationCategory.NAMES),
        PronunciationEntry(word = "Xcode", pronunciation = "ex-code", replacement = "ex code", category = PronunciationCategory.NAMES),

        // Acronyms
        PronunciationEntry(word = "URL", pronunciation = "U R L", replacement = "U R L", category = PronunciationCategory.ACRONYMS),
        PronunciationEntry(word = "HTTP", pronunciation = "H T T P", replacement = "H T T P", category = PronunciationCategory.ACRONYMS),
        PronunciationEntry(word = "HTTPS", pronunciation = "H T T P S", replacement = "H T T P S", category = PronunciationCategory.ACRONYMS),
        PronunciationEntry(word = "HTML", pronunciation = "H T M L", replacement = "H T M L", category = PronunciationCategory.ACRONYMS),
        PronunciationEntry(word = "CSS", pronunciation = "C S S", replacement = "C S S", category = PronunciationCategory.ACRONYMS),
        PronunciationEntry(word = "AWS", pronunciation = "A W S", replacement = "A W S", category = PronunciationCategory.ACRONYMS),
        PronunciationEntry(word = "GCP", pronunciation = "G C P", replacement = "G C P", category = PronunciationCategory.ACRONYMS),

        // Symbols
        PronunciationEntry(word = "@", pronunciation = "at sign", replacement = " at ", category = PronunciationCategory.SYMBOLS),
        PronunciationEntry(word = "#", pronunciation = "hashtag", replacement = " hashtag ", category = PronunciationCategory.SYMBOLS),
        PronunciationEntry(word = "&", pronunciation = "ampersand", replacement = " and ", category = PronunciationCategory.SYMBOLS),
        PronunciationEntry(word = "->", pronunciation = "arrow", replacement = " arrow ", category = PronunciationCategory.SYMBOLS),
        PronunciationEntry(word = "=>", pronunciation = "fat arrow", replacement = " fat arrow ", category = PronunciationCategory.SYMBOLS),
        PronunciationEntry(word = "!=", pronunciation = "not equal", replacement = " not equal ", category = PronunciationCategory.SYMBOLS),
        PronunciationEntry(word = "==", pronunciation = "double equals", replacement = " equals equals ", category = PronunciationCategory.SYMBOLS),

        // Brands
        PronunciationEntry(word = "GitHub", pronunciation = "git-hub", replacement = "git hub", category = PronunciationCategory.BRANDS),
        PronunciationEntry(word = "GitLab", pronunciation = "git-lab", replacement = "git lab", category = PronunciationCategory.BRANDS),
        PronunciationEntry(word = "OpenAI", pronunciation = "open A I", replacement = "open A I", category = PronunciationCategory.BRANDS),
    )
}
