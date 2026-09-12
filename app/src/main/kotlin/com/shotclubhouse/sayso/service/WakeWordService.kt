package com.shotclubhouse.sayso.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import com.shotclubhouse.sayso.R
import com.shotclubhouse.sayso.ui.MainActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Foreground service that runs continuous on-device wake-word detection.
 *
 * Captures 16 kHz audio in background and feeds it to [WakeWordDetector].
 * When "Hey Sayso" or "Sayso" is heard, triggers [DictationService] to start recording.
 */
class WakeWordService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var detector: WakeWordDetector? = null
    private var audioRecord: AudioRecord? = null
    private var isListening = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        startListening()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        instance = null
        stopListening()
        scope.cancel()
        super.onDestroy()
    }

    private fun startListening() {
        if (isListening) return
        isListening = true

        detector = WakeWordDetector(this) { keyword ->
            Log.i(TAG, "Wake word trigger: $keyword")
            scope.launch(Dispatchers.Main) {
                DictationService.instance?.startRecordingFromWakeWord()
            }
        }

        if (detector?.start() != true) {
            Log.e(TAG, "Failed to start detector")
            stopSelf()
            return
        }

        scope.launch(Dispatchers.IO) {
            runAudioLoop()
        }
    }

    private fun stopListening() {
        isListening = false
        runCatching {
            audioRecord?.stop()
            audioRecord?.release()
        }
        audioRecord = null
        detector?.release()
        detector = null
    }

    private suspend fun runAudioLoop() {
        val sampleRate = WakeWordDetector.SAMPLE_RATE
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val audioFormat = AudioFormat.ENCODING_PCM_16BIT
        val minBufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        val bufferSize = maxOf(minBufferSize, sampleRate * 2)

        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRate,
                channelConfig,
                audioFormat,
                bufferSize,
            )
        } catch (e: SecurityException) {
            Log.e(TAG, "Microphone permission missing", e)
            stopSelf()
            return
        }

        if (record.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord failed to initialize")
            record.release()
            stopSelf()
            return
        }

        audioRecord = record
        try {
            record.startRecording()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start recording", e)
            record.release()
            stopSelf()
            return
        }

        val shortBuffer = ShortArray(1600) // 100ms chunks at 16kHz
        val floatBuffer = FloatArray(1600)

        while (scope.isActive && isListening) {
            // While DictationService is recording or busy, pause wake-word ingestion to avoid mic contention
            if (DictationService.isBusyOrRecording()) {
                delay(200)
                continue
            }

            val read = record.read(shortBuffer, 0, shortBuffer.size)
            if (read > 0) {
                for (i in 0 until read) {
                    floatBuffer[i] = shortBuffer[i] / 32768.0f
                }
                val chunk = if (read == floatBuffer.size) floatBuffer else floatBuffer.copyOf(read)
                detector?.acceptWaveform(chunk)
            }
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.wake_word_notification_channel),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = getString(R.string.wake_word_notification_text)
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.wake_word_notification_title))
            .setContentText(getString(R.string.wake_word_notification_text))
            .setSmallIcon(R.drawable.ic_bubble_idle)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    companion object {
        private const val TAG = "SaysoWakeWord"
        private const val CHANNEL_ID = "sayso_wake_word"
        private const val NOTIFICATION_ID = 2001
        const val ACTION_STOP = "com.shotclubhouse.sayso.STOP_WAKE_WORD"

        @Volatile
        var instance: WakeWordService? = null
            private set

        fun start(context: Context) {
            val intent = Intent(context, WakeWordService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, WakeWordService::class.java)
            context.stopService(intent)
        }
    }
}
