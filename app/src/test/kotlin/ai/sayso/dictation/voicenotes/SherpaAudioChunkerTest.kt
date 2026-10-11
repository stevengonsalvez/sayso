package ai.sayso.dictation.voicenotes

import ai.sayso.dictation.core.AudioClip
import ai.sayso.dictation.core.Wav
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

class SherpaAudioChunkerTest {

    private lateinit var tempDir: File

    @Before
    fun setUp() {
        tempDir = Files.createTempDirectory("chunker-test").toFile()
    }

    @After
    fun tearDown() {
        tempDir.deleteRecursively()
    }

    private fun createWavFile(seconds: Int, sampleRate: Int = 16_000): File {
        val pcmBytes = ByteArray(seconds * sampleRate * 2) { (it % 128).toByte() }
        val clip = AudioClip(pcmBytes, sampleRate)
        val wavBytes = Wav.encode(clip)
        val file = File(tempDir, "test_${seconds}s.wav")
        file.writeBytes(wavBytes)
        return file
    }

    @Test
    fun deduplicateOverlap_removesRepeatedWordsAtBoundary() {
        val prev = "Good morning everyone today we discuss"
        val curr = "today we discuss quarterly financial results"
        val deduplicated = SherpaAudioChunker.deduplicateOverlap(prev, curr)
        assertEquals("quarterly financial results", deduplicated)
    }

    @Test
    fun deduplicateOverlap_handlesPunctuationAndCaseInsensitive() {
        val prev = "We arrived in London."
        val curr = "London, was very busy that day."
        val deduplicated = SherpaAudioChunker.deduplicateOverlap(prev, curr)
        assertEquals("was very busy that day.", deduplicated)
    }

    @Test
    fun deduplicateOverlap_returnsOriginalWhenNoMatch() {
        val prev = "The project launched yesterday."
        val curr = "Tomorrow we start phase two."
        val deduplicated = SherpaAudioChunker.deduplicateOverlap(prev, curr)
        assertEquals("Tomorrow we start phase two.", deduplicated)
    }

    @Test
    fun deduplicateOverlap_handlesEmptyStrings() {
        assertEquals("Hello", SherpaAudioChunker.deduplicateOverlap("", "Hello"))
        assertEquals("", SherpaAudioChunker.deduplicateOverlap("Hello", ""))
    }

    @Test
    fun parseWavMetadata_extractsAccurateData() {
        val wavFile = createWavFile(seconds = 5) // 5 seconds = 160,000 bytes PCM
        val meta = SherpaAudioChunker.parseWavMetadata(wavFile)

        assertNotNull(meta)
        assertEquals(16_000, meta!!.sampleRate)
        assertEquals(1, meta.channels)
        assertEquals(16, meta.bitsPerSample)
        assertEquals(44L, meta.dataOffset)
        assertEquals(5 * 16_000 * 2L, meta.dataLength)
    }

    @Test
    fun transcribeFile_shortAudio_slicesIntoSingleChunk() = runTest {
        val wavFile = createWavFile(seconds = 10) // 10 seconds audio (< 30s chunk size)
        val chunker = SherpaAudioChunker(chunkDurationSec = 30, overlapSec = 2)

        var calls = 0
        val fakeTranscriber = ChunkTranscriber { _, sampleCount, _ ->
            calls++
            assertEquals(10 * 16_000, sampleCount)
            "Single chunk transcription."
        }

        val result = chunker.transcribeFile(wavFile, fakeTranscriber)

        assertEquals(1, calls)
        assertEquals(1, result.totalChunks)
        assertEquals(10_000L, result.totalDurationMs)
        assertEquals(1, result.segments.size)
        assertEquals(0L, result.segments[0].startMs)
        assertEquals(10_000L, result.segments[0].endMs)
        assertEquals("Single chunk transcription.", result.fullText)
    }

    @Test
    fun transcribeFile_longAudio_slicesWithOverlapAndAdjustsTimestamps() = runTest {
        // 65 seconds audio with 30s chunk duration and 2s overlap.
        // Step = 28s.
        // Chunk 0: 0s..30s (0..30000 ms)
        // Chunk 1: 28s..58s (28000..58000 ms)
        // Chunk 2: 56s..65s (56000..65000 ms)
        val wavFile = createWavFile(seconds = 65)
        val chunker = SherpaAudioChunker(chunkDurationSec = 30, overlapSec = 2)

        val chunkTexts = listOf(
            "Hello team today we talk about architecture",
            "about architecture and streaming audio performance",
            "audio performance on mobile devices without any lag",
        )

        var chunkCallIndex = 0
        val progressUpdates = mutableListOf<Float>()

        val fakeTranscriber = ChunkTranscriber { _, _, _ ->
            val text = chunkTexts.getOrElse(chunkCallIndex) { "chunk $chunkCallIndex" }
            chunkCallIndex++
            text
        }

        val result = chunker.transcribeFile(
            wavFile = wavFile,
            transcriber = fakeTranscriber,
            onProgress = { prog, current, total, _ ->
                progressUpdates.add(prog)
                assertEquals(3, total)
                assertTrue(current in 1..3)
            },
        )

        assertEquals(3, chunkCallIndex)
        assertEquals(3, result.totalChunks)
        assertEquals(65_000L, result.totalDurationMs)
        assertEquals(3, result.segments.size)

        // Check segment timestamps
        assertEquals(0L, result.segments[0].startMs)
        assertEquals(30_000L, result.segments[0].endMs)
        assertEquals("Hello team today we talk about architecture", result.segments[0].text)

        assertEquals(28_000L, result.segments[1].startMs)
        assertEquals(58_000L, result.segments[1].endMs)
        // Overlap "about architecture" deduplicated:
        assertEquals("and streaming audio performance", result.segments[1].text)

        assertEquals(56_000L, result.segments[2].startMs)
        assertEquals(65_000L, result.segments[2].endMs)
        // Overlap "audio performance" deduplicated:
        assertEquals("on mobile devices without any lag", result.segments[2].text)

        // Stitched full text
        val expectedFull = "Hello team today we talk about architecture and streaming audio performance on mobile devices without any lag"
        assertEquals(expectedFull, result.fullText)

        // Progress emitted to 1.0f
        assertEquals(1.0f, progressUpdates.last(), 0.001f)
    }

    @Test
    fun transcribeFile_missingFile_returnsEmptyResultSafely() = runTest {
        val chunker = SherpaAudioChunker()
        val missing = File(tempDir, "non_existent.wav")
        val result = chunker.transcribeFile(missing, transcriber = { _, _, _ -> "test" })

        assertEquals("", result.fullText)
        assertTrue(result.segments.isEmpty())
        assertEquals(0L, result.totalDurationMs)
    }
}
