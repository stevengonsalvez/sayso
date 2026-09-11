package com.shotclubhouse.sayso.service

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import com.shotclubhouse.sayso.core.AudioClip
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

/** Why a recording produced nothing; the service turns these into user-facing text. */
enum class CaptureError { PERMISSION, UNAVAILABLE }

/** Outcome of one recording. [clip] is empty whenever [error] is set. */
class Capture(val clip: AudioClip, val error: CaptureError? = null)

/**
 * One push-to-talk recording: 16 kHz mono 16-bit PCM, bounded by [maxSeconds].
 *
 * A capture instance records once. Call [record] from a coroutine and [stop] from
 * anywhere to end it; [record] returns as soon as the reader loop notices.
 */
class AudioCapture(private val maxSeconds: Int) {

    @Volatile private var recording = true

    /** Ends the recording. Safe to call before [record] starts or after it returns. */
    fun stop() {
        recording = false
    }

    /**
     * Records until [stop] is called or [maxSeconds] elapses, in which case
     * [onAutoStop] fires on the recording thread just before returning.
     */
    suspend fun record(onAutoStop: () -> Unit = {}): Capture = withContext(Dispatchers.IO) {
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL, ENCODING)
        val bufferBytes = maxOf(minBuffer, SAMPLE_RATE * BYTES_PER_SAMPLE / 10)

        val recorder = try {
            AudioRecord(MediaRecorder.AudioSource.MIC, SAMPLE_RATE, CHANNEL, ENCODING, bufferBytes)
        } catch (e: SecurityException) {
            Log.d(TAG, "Microphone permission denied", e)
            return@withContext Capture(EMPTY, CaptureError.PERMISSION)
        } catch (e: IllegalArgumentException) {
            Log.d(TAG, "Unsupported recorder configuration", e)
            return@withContext Capture(EMPTY, CaptureError.UNAVAILABLE)
        }

        try {
            if (recorder.state != AudioRecord.STATE_INITIALIZED) {
                Log.d(TAG, "Recorder did not initialise")
                return@withContext Capture(EMPTY, CaptureError.UNAVAILABLE)
            }
            recorder.startRecording()
            if (recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                Log.d(TAG, "Recorder did not start")
                return@withContext Capture(EMPTY, CaptureError.UNAVAILABLE)
            }
            Capture(read(recorder, bufferBytes, onAutoStop))
        } catch (e: SecurityException) {
            Log.d(TAG, "Microphone permission denied while starting", e)
            Capture(EMPTY, CaptureError.PERMISSION)
        } catch (e: IllegalStateException) {
            Log.d(TAG, "Recorder unavailable", e)
            Capture(EMPTY, CaptureError.UNAVAILABLE)
        } finally {
            runCatching { recorder.stop() }
            recorder.release()
        }
    }

    private fun read(recorder: AudioRecord, bufferBytes: Int, onAutoStop: () -> Unit): AudioClip {
        // ponytail: 300 s at 32 kB/s is ~9.6 MB in memory, which a modern phone carries fine.
        // Stream to a file instead if the cap ever grows past a few minutes.
        val maxBytes = maxSeconds * SAMPLE_RATE * BYTES_PER_SAMPLE
        val collected = ByteArrayOutputStream(minOf(maxBytes, INITIAL_BUFFER_BYTES))
        val buffer = ByteArray(bufferBytes)
        var autoStopped = false

        while (recording) {
            val read = recorder.read(buffer, 0, buffer.size)
            if (read <= 0) {
                if (read < 0) Log.d(TAG, "Recorder read failed with $read")
                break
            }
            val room = maxBytes - collected.size()
            collected.write(buffer, 0, minOf(read, room))
            if (collected.size() >= maxBytes) {
                autoStopped = true
                recording = false
            }
        }

        if (autoStopped) onAutoStop()
        return AudioClip(collected.toByteArray(), SAMPLE_RATE)
    }

    private companion object {
        const val TAG = "SaysoCapture"
        const val SAMPLE_RATE = AudioClip.DEFAULT_SAMPLE_RATE
        const val CHANNEL = AudioFormat.CHANNEL_IN_MONO
        const val ENCODING = AudioFormat.ENCODING_PCM_16BIT
        const val BYTES_PER_SAMPLE = 2

        /** 10 s of audio, so ordinary clips never reallocate. */
        const val INITIAL_BUFFER_BYTES = SAMPLE_RATE * BYTES_PER_SAMPLE * 10

        val EMPTY = AudioClip(ByteArray(0), SAMPLE_RATE)
    }
}
