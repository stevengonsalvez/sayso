package ai.sayso.dictation.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WavTest {

    private val pcm = ByteArray(800) { (it * 7 % 256 - 128).toByte() }

    @Test
    fun `encode writes a 44 byte header in front of the samples`() {
        val wav = Wav.encode(AudioClip(pcm, 16_000))

        assertEquals(44 + pcm.size, wav.size)
        assertEquals("RIFF", String(wav, 0, 4))
        assertEquals("WAVE", String(wav, 8, 4))
        assertEquals("fmt ", String(wav, 12, 4))
        assertEquals("data", String(wav, 36, 4))
        // Sample rate is little-endian 16000 = 0x3E80.
        assertEquals(0x80.toByte(), wav[24])
        assertEquals(0x3E.toByte(), wav[25])
        assertEquals(1, wav[22].toInt())
        assertEquals(16, wav[34].toInt())
        assertArrayEquals(pcm, wav.copyOfRange(44, wav.size))
    }

    @Test
    fun `round trip preserves samples and sample rate`() {
        val decoded = Wav.decode(Wav.encode(AudioClip(pcm, 22_050)))

        assertEquals(22_050, decoded!!.sampleRate)
        assertArrayEquals(pcm, decoded.pcm16)
    }

    @Test
    fun `decode skips chunks that sit between fmt and data`() {
        val plain = Wav.encode(AudioClip(pcm, 16_000))
        val list = "LIST".toByteArray() + byteArrayOf(4, 0, 0, 0) + "INFO".toByteArray()
        val withExtra = plain.copyOfRange(0, 36) + list + plain.copyOfRange(36, plain.size)

        val decoded = Wav.decode(withExtra)

        assertEquals(16_000, decoded!!.sampleRate)
        assertArrayEquals(pcm, decoded.pcm16)
    }

    @Test
    fun `decode returns null for input that is not a wav`() {
        assertNull(Wav.decode(ByteArray(0)))
        assertNull(Wav.decode("not audio at all, really".toByteArray()))
        assertNull(Wav.decode(Wav.encode(AudioClip(pcm)).copyOfRange(0, 30)))
    }

    @Test
    fun `float samples are normalised to plus or minus one`() {
        // -32768, 0, 32767 little-endian.
        val clip = AudioClip(byteArrayOf(0, -128, 0, 0, -1, 127))

        val samples = clip.toFloatSamples()

        assertEquals(3, samples.size)
        assertEquals(-1f, samples[0], 1e-6f)
        assertEquals(0f, samples[1], 1e-6f)
        assertEquals(1f, samples[2], 1e-4f)
    }

    @Test
    fun `decode rejects a header that declares an impossible sample rate`() {
        val wav = Wav.encode(AudioClip(pcm, 16_000))
        // Sample rate lives at offset 24 of the fmt chunk this encoder writes.
        for (i in 0 until 4) wav[24 + i] = 0

        assertNull(Wav.decode(wav))
    }

    @Test
    fun `a clip with a nonsense sample rate reports a duration rather than dividing by zero`() {
        assertEquals(pcm.size * 1000L / 2, AudioClip(pcm, 0).durationMs)
        assertEquals(pcm.size * 1000L / 2, AudioClip(pcm, -44_100).durationMs)
    }
}
