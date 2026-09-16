package ai.sayso.dictation.core

/**
 * The one place a saved API key is vetted before it becomes a request header.
 *
 * OkHttp refuses a header value holding anything outside printable ASCII and, for every
 * header it does not class as sensitive, quotes the offending value back in the exception
 * message. That message reaches the feedback pill and the history file, so a key carrying a
 * stray character is caught here rather than on the wire. A key pasted out of a web console
 * picking up a non-breaking space is the realistic case.
 */
object ApiKeys {

    fun isSendable(apiKey: String): Boolean = apiKey.all { it.code in PRINTABLE_ASCII }

    fun missing(displayName: String): String = "$displayName API key is missing"

    /** Deliberately carries no part of the key: this text is shown and stored. */
    const val UNSUPPORTED = "API key contains unsupported characters"

    private val PRINTABLE_ASCII = 0x20..0x7e
}
