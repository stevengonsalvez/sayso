package ai.sayso.dictation.voicenotes

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import kotlin.math.sqrt

/**
 * Result of a completed disk recording session.
 */
data class DiskRecordResult(
    val file: File,
    val durationMs: Long,
    val byteCount: Long,
)

/**
 * Abstraction over audio input source to permit unit testing on JVM without hardware microphone.
 */
interface AudioSampleSource {
    fun start()
    fun read(buffer: ByteArray, offset: Int, size: Int): Int
    fun stop()
    fun release()
    val isAvailable: Boolean
}

class SystemAudioRecordSource(
    private val sampleRate: Int = DiskAudioRecorder.SAMPLE_RATE,
    private val channelConfig: Int = DiskAudioRecorder.CHANNEL_CONFIG,
    private val audioFormat: Int = DiskAudioRecorder.AUDIO_FORMAT,
) : AudioSampleSource {
    private var recorder: AudioRecord? = null

    override val isAvailable: Boolean
        get() = try {
            val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
            minBuf > 0
        } catch (_: Throwable) {
            false
        }

    override fun start() {
        val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        val bufferBytes = maxOf(minBuf, sampleRate * DiskAudioRecorder.BYTES_PER_SAMPLE / 10)
        val rec = AudioRecord(MediaRecorder.AudioSource.MIC, sampleRate, channelConfig, audioFormat, bufferBytes)
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            throw IllegalStateException("AudioRecord failed to initialize")
        }
        rec.startRecording()
        recorder = rec
    }

    override fun read(buffer: ByteArray, offset: Int, size: Int): Int {
        val rec = recorder ?: return -1
        return rec.read(buffer, offset, size)
    }

    override fun stop() {
        runCatching { recorder?.stop() }
    }

    override fun release() {
        runCatching {
            recorder?.stop()
            recorder?.release()
        }
        recorder = null
    }
}

/**
 * Direct-to-disk streaming audio recorder for continuous long-form recordings.
 *
 * Streams 16 kHz mono 16-bit PCM WAV directly to disk with constant memory (<1 MB).
 * Supports pause, resume, real-time amplitude metering, and header finalization.
 * Never terminates automatically on silence.
 */
class DiskAudioRecorder(
    private val outputFile: File,
    private val sampleSource: AudioSampleSource = SystemAudioRecordSource(),
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val onAmplitude: ((Float) -> Unit)? = null,
    private val onDurationTick: ((Long) -> Unit)? = null,
) {

    @Volatile private var isRecording = false
    @Volatile private var isPaused = false
    @Volatile private var stopRequested = false

    val recording: Boolean get() = isRecording
    val paused: Boolean get() = isPaused

    fun pause() {
        isPaused = true
    }

    fun resume() {
        isPaused = false
    }

    fun stop() {
        stopRequested = true
        isRecording = false
    }

    suspend fun record(): DiskRecordResult = withContext(Dispatchers.IO) {
        outputFile.parentFile?.mkdirs()
        if (outputFile.exists()) {
            outputFile.delete()
        }

        val fos = FileOutputStream(outputFile)
        var totalBytesWritten = 0L
        var accumulatedDurationMs = 0L
        var lastTickMs = clock()

        try {
            // Write 44-byte placeholder WAV header
            writePlaceholderWavHeader(fos)

            if (!stopRequested) {
                sampleSource.start()
                if (!stopRequested) {
                    isRecording = true
                }
            }

            val bufferSize = 3200 // 100ms at 16kHz 16-bit mono
            val buffer = ByteArray(bufferSize)

            while (isRecording) {
                if (isPaused) {
                    onAmplitude?.invoke(0f)
                    val read = sampleSource.read(buffer, 0, buffer.size)
                    if (read < 0) {
                        Log.w(TAG, "AudioRecord read returned negative code while paused: $read")
                        break
                    }
                    if (read == 0) {
                        Thread.sleep(20)
                    }
                    lastTickMs = clock()
                    continue
                }

                val read = sampleSource.read(buffer, 0, buffer.size)
                if (read <= 0) {
                    if (read < 0) {
                        Log.w(TAG, "AudioRecord read returned negative code: $read")
                    }
                    break
                }
                fos.write(buffer, 0, read)
                totalBytesWritten += read

                val now = clock()
                val delta = now - lastTickMs
                if (delta > 0) {
                    accumulatedDurationMs += delta
                    lastTickMs = now
                    onDurationTick?.invoke(accumulatedDurationMs)
                }

                // Compute RMS amplitude normalized between 0.0f and 1.0f
                val amp = computeNormalizedRms(buffer, read)
                onAmplitude?.invoke(amp)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            Log.e(TAG, "DiskAudioRecorder error while recording", t)
            throw t
        } finally {
            isRecording = false
            sampleSource.release()
            runCatching { fos.flush() }
            runCatching { fos.close() }

            // Seek back and patch header with exact file sizes
            finalizeWavHeader(outputFile, totalBytesWritten)
        }

        // Calculate final duration from total PCM sample bytes
        val finalDurationMs = totalBytesWritten * 1000L / (SAMPLE_RATE * BYTES_PER_SAMPLE)
        DiskRecordResult(
            file = outputFile,
            durationMs = finalDurationMs,
            byteCount = totalBytesWritten,
        )
    }

    companion object {
        const val TAG = "DiskAudioRecorder"
        const val SAMPLE_RATE = 16_000
        const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
        const val BYTES_PER_SAMPLE = 2
        const val HEADER_SIZE = 44

        fun computeNormalizedRms(buffer: ByteArray, length: Int): Float {
            var sumSquares = 0.0
            var sampleCount = 0
            var i = 0
            while (i + 1 < length) {
                val sample = ((buffer[i + 1].toInt() shl 8) or (buffer[i].toInt() and 0xFF)).toShort()
                sumSquares += sample.toDouble() * sample.toDouble()
                sampleCount++
                i += 2
            }
            if (sampleCount == 0) return 0f
            val rms = sqrt(sumSquares / sampleCount)
            // 32767 is max amplitude for 16-bit PCM; normalize with dynamic scaling
            return (rms / 32767.0).toFloat().coerceIn(0f, 1f)
        }

        private fun writePlaceholderWavHeader(fos: FileOutputStream) {
            val header = ByteArray(HEADER_SIZE)
            val byteRate = SAMPLE_RATE * 1 * BYTES_PER_SAMPLE

            // RIFF chunk descriptor
            ascii(header, 0, "RIFF")
            int32(header, 4, 36) // Placeholder: 36 + 0
            ascii(header, 8, "WAVE")

            // fmt sub-chunk
            ascii(header, 12, "fmt ")
            int32(header, 16, 16) // Subchunk1Size for PCM
            int16(header, 20, 1)  // AudioFormat 1 = PCM
            int16(header, 22, 1)  // Channels = 1 (Mono)
            int32(header, 24, SAMPLE_RATE)
            int32(header, 28, byteRate)
            int16(header, 32, BYTES_PER_SAMPLE) // BlockAlign
            int16(header, 34, 16) // BitsPerSample

            // data sub-chunk
            ascii(header, 36, "data")
            int32(header, 40, 0) // Placeholder data size

            fos.write(header)
        }

        fun finalizeWavHeader(file: File, pcmBytes: Long = -1L) {
            if (!file.exists() || file.length() < HEADER_SIZE) return
            val actualPcmBytes = if (pcmBytes >= 0) pcmBytes else file.length() - HEADER_SIZE
            val riffSize = actualPcmBytes + 36

            RandomAccessFile(file, "rw").use { raf ->
                // Seek to offset 4: RIFF chunk size
                raf.seek(4)
                raf.write((riffSize and 0xFF).toInt())
                raf.write(((riffSize shr 8) and 0xFF).toInt())
                raf.write(((riffSize shr 16) and 0xFF).toInt())
                raf.write(((riffSize shr 24) and 0xFF).toInt())

                // Seek to offset 40: data chunk size
                raf.seek(40)
                raf.write((actualPcmBytes and 0xFF).toInt())
                raf.write(((actualPcmBytes shr 8) and 0xFF).toInt())
                raf.write(((actualPcmBytes shr 16) and 0xFF).toInt())
                raf.write(((actualPcmBytes shr 24) and 0xFF).toInt())
            }
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
    }
}
