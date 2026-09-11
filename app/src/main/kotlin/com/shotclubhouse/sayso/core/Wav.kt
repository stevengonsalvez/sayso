package com.shotclubhouse.sayso.core

/**
 * Minimal RIFF/WAVE support for the one format the app records in: 16-bit
 * little-endian PCM, mono.
 */
object Wav {
    private const val HEADER_BYTES = 44
    private const val BITS_PER_SAMPLE = 16
    private const val CHANNELS = 1
    private const val PCM_FORMAT = 1

    fun encode(clip: AudioClip): ByteArray {
        val out = ByteArray(HEADER_BYTES + clip.pcm16.size)
        val byteRate = clip.sampleRate * CHANNELS * BITS_PER_SAMPLE / 8
        ascii(out, 0, "RIFF")
        int32(out, 4, 36 + clip.pcm16.size)
        ascii(out, 8, "WAVE")
        ascii(out, 12, "fmt ")
        int32(out, 16, 16)
        int16(out, 20, PCM_FORMAT)
        int16(out, 22, CHANNELS)
        int32(out, 24, clip.sampleRate)
        int32(out, 28, byteRate)
        int16(out, 32, CHANNELS * BITS_PER_SAMPLE / 8)
        int16(out, 34, BITS_PER_SAMPLE)
        ascii(out, 36, "data")
        int32(out, 40, clip.pcm16.size)
        clip.pcm16.copyInto(out, HEADER_BYTES)
        return out
    }

    /**
     * Walks the chunk list rather than assuming a 44-byte header, so files that
     * carry LIST/fact chunks before the samples still decode.
     */
    fun decode(bytes: ByteArray): AudioClip? {
        if (bytes.size < 12 || readAscii(bytes, 0) != "RIFF" || readAscii(bytes, 8) != "WAVE") return null
        var sampleRate = AudioClip.DEFAULT_SAMPLE_RATE
        var offset = 12
        while (offset + 8 <= bytes.size) {
            val id = readAscii(bytes, offset)
            val size = readInt32(bytes, offset + 4)
            if (size < 0) return null
            val body = offset + 8
            when (id) {
                "fmt " -> if (body + 8 <= bytes.size) sampleRate = readInt32(bytes, body + 4)
                "data" -> {
                    val end = minOf(body + size, bytes.size)
                    if (end <= body) return null
                    return AudioClip(bytes.copyOfRange(body, end), sampleRate)
                }
            }
            // Chunk bodies are padded to an even length. A size large enough to overflow the
            // offset would otherwise walk backwards through the file for ever.
            val next = body + size + (size and 1)
            if (next <= offset) return null
            offset = next
        }
        return null
    }

    private fun ascii(out: ByteArray, at: Int, value: String) {
        for (i in value.indices) out[at + i] = value[i].code.toByte()
    }

    private fun int32(out: ByteArray, at: Int, value: Int) {
        for (i in 0 until 4) out[at + i] = (value ushr (8 * i)).toByte()
    }

    private fun int16(out: ByteArray, at: Int, value: Int) {
        for (i in 0 until 2) out[at + i] = (value ushr (8 * i)).toByte()
    }

    private fun readAscii(bytes: ByteArray, at: Int): String =
        String(bytes, at, 4, Charsets.US_ASCII)

    private fun readInt32(bytes: ByteArray, at: Int): Int {
        var value = 0
        for (i in 0 until 4) value = value or ((bytes[at + i].toInt() and 0xFF) shl (8 * i))
        return value
    }
}
