package ai.sayso.dictation.voicenotes

import ai.sayso.dictation.core.Wav
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

class DiskAudioRecorderTest {

    private lateinit var tempDir: File

    @Before
    fun setUp() {
        tempDir = Files.createTempDirectory("disk-recorder-test").toFile()
    }

    @After
    fun tearDown() {
        tempDir.deleteRecursively()
    }

    class FakeSampleSource(
        private val totalPackets: Int = 10,
        private val packetSize: Int = 3200,
    ) : AudioSampleSource {
        var packetsRead = 0
        var isStarted = false
        var isReleased = false

        override val isAvailable: Boolean = true

        override fun start() {
            isStarted = true
        }

        override fun read(buffer: ByteArray, offset: Int, size: Int): Int {
            if (packetsRead >= totalPackets) {
                return 0
            }
            val toWrite = minOf(size, packetSize)
            // Generate non-zero 16-bit PCM waveform (sine or ramp)
            for (i in 0 until toWrite step 2) {
                val sample = ((packetsRead * 1000 + i) % 10000).toShort()
                buffer[offset + i] = (sample.toInt() and 0xFF).toByte()
                buffer[offset + i + 1] = ((sample.toInt() shr 8) and 0xFF).toByte()
            }
            packetsRead++
            return toWrite
        }

        override fun stop() {}

        override fun release() {
            isReleased = true
        }
    }

    @Test
    fun record_streamsToFile_andFinalizesWavHeader() = runBlocking {
        val targetFile = File(tempDir, "output.wav")
        val fakeSource = FakeSampleSource(totalPackets = 5, packetSize = 3200) // 16000 bytes = 0.5s audio
        val amplitudes = mutableListOf<Float>()

        val recorder = DiskAudioRecorder(
            outputFile = targetFile,
            sampleSource = fakeSource,
            onAmplitude = { amplitudes.add(it) },
        )

        val result = recorder.record()

        assertTrue(fakeSource.isStarted)
        assertTrue(fakeSource.isReleased)
        assertEquals(targetFile.absolutePath, result.file.absolutePath)
        assertEquals(16000L, result.byteCount)
        assertEquals(500L, result.durationMs) // 16000 bytes / (16000 * 2) = 0.5s = 500ms

        // Verify valid WAV decoding
        val fileBytes = targetFile.readBytes()
        assertEquals(44 + 16000, fileBytes.size)

        val decoded = Wav.decode(fileBytes)
        assertNotNull(decoded)
        assertEquals(16000, decoded!!.sampleRate)
        assertEquals(16000, decoded.pcm16.size)
        assertEquals(500L, decoded.durationMs)

        // Verify amplitudes were emitted
        assertTrue(amplitudes.isNotEmpty())
        assertTrue(amplitudes.all { it in 0f..1f })
    }

    @Test
    fun pauseAndResume_controlsStreamFlow() = runBlocking {
        val targetFile = File(tempDir, "paused.wav")
        var readsPerformed = 0
        val controllableSource = object : AudioSampleSource {
            override val isAvailable: Boolean = true
            override fun start() {}
            override fun stop() {}
            override fun release() {}
            override fun read(buffer: ByteArray, offset: Int, size: Int): Int {
                readsPerformed++
                if (readsPerformed > 6) return 0
                buffer.fill(42)
                return minOf(size, 1600)
            }
        }

        val recorder = DiskAudioRecorder(
            outputFile = targetFile,
            sampleSource = controllableSource,
        )

        val job = launch(Dispatchers.IO) {
            recorder.record()
        }

        recorder.pause()
        assertTrue(recorder.paused)
        recorder.resume()
        assertTrue(!recorder.paused)
        recorder.stop()
        job.join()

        assertTrue(targetFile.exists())
    }

    @Test
    fun computeNormalizedRms_returnsZeroForEmptyOrSilence() {
        val empty = ByteArray(0)
        assertEquals(0f, DiskAudioRecorder.computeNormalizedRms(empty, 0), 0.001f)

        val silent = ByteArray(100)
        assertEquals(0f, DiskAudioRecorder.computeNormalizedRms(silent, 100), 0.001f)
    }

    @Test
    fun finalizeWavHeader_patchesFileAccurately() {
        val testFile = File(tempDir, "header_test.wav")
        // Write 44 byte header + 1000 bytes data
        val dummyData = ByteArray(1044)
        testFile.writeBytes(dummyData)

        DiskAudioRecorder.finalizeWavHeader(testFile, 1000L)

        val bytes = testFile.readBytes()
        // Check RIFF size at offset 4: 1000 + 36 = 1036 = 0x0000040C
        val riffSize = (bytes[4].toInt() and 0xFF) or
            ((bytes[5].toInt() and 0xFF) shl 8) or
            ((bytes[6].toInt() and 0xFF) shl 16) or
            ((bytes[7].toInt() and 0xFF) shl 24)
        assertEquals(1036, riffSize)

        // Check data size at offset 40: 1000 = 0x000003E8
        val dataSize = (bytes[40].toInt() and 0xFF) or
            ((bytes[41].toInt() and 0xFF) shl 8) or
            ((bytes[42].toInt() and 0xFF) shl 16) or
            ((bytes[43].toInt() and 0xFF) shl 24)
        assertEquals(1000, dataSize)
    }

    @Test
    fun stopBeforeRecord_terminatesWithoutStarting() = runBlocking {
        val targetFile = File(tempDir, "early_stop.wav")
        val fakeSource = FakeSampleSource(totalPackets = 5, packetSize = 3200)

        val recorder = DiskAudioRecorder(
            outputFile = targetFile,
            sampleSource = fakeSource,
        )

        // Stop invoked before record() starts
        recorder.stop()
        val result = recorder.record()

        assertTrue(!fakeSource.isStarted)
        assertEquals(0L, result.byteCount)
        assertEquals(0L, result.durationMs)
        assertTrue(targetFile.exists())
        assertEquals(44L, targetFile.length())
    }

    @Test
    fun pause_drainsAudioFromSampleSource_withoutWritingToDisk() = runBlocking {
        val targetFile = File(tempDir, "drained.wav")
        var readsPerformed = 0
        val drainingSource = object : AudioSampleSource {
            override val isAvailable: Boolean = true
            override fun start() {}
            override fun stop() {}
            override fun release() {}
            override fun read(buffer: ByteArray, offset: Int, size: Int): Int {
                readsPerformed++
                buffer.fill(1)
                return minOf(size, 1600)
            }
        }

        val recorder = DiskAudioRecorder(
            outputFile = targetFile,
            sampleSource = drainingSource,
        )

        val job = launch(Dispatchers.IO) {
            recorder.record()
        }

        recorder.pause()
        var attempts = 0
        while (readsPerformed < 3 && attempts < 20) {
            kotlinx.coroutines.delay(20)
            attempts++
        }
        val drainedCount = readsPerformed
        assertTrue(drainedCount >= 2)

        recorder.stop()
        job.join()

        val fileBytes = targetFile.readBytes()
        val pcmByteCount = fileBytes.size - 44
        assertTrue(pcmByteCount < readsPerformed * 1600)
    }
}
