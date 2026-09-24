package ai.sayso.dictation.service

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
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import android.widget.Toast
import androidx.core.app.NotificationCompat
import ai.sayso.dictation.R
import ai.sayso.dictation.ui.MainActivity
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

        if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            Log.e(TAG, "RECORD_AUDIO permission not granted; cannot start WakeWordService")
            stopSelf()
            return
        }

        createNotificationChannel()
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Throwable) {
            Log.e(TAG, "startForeground failed: ${e.message}", e)
            stopSelf()
            return
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

        scope.launch(Dispatchers.Default) {
            val settings = ai.sayso.dictation.AppGraph.settings
            val phrase = settings.wakeWordPhrase
            val sensitivity = settings.wakeWordSensitivity
            val d = WakeWordDetector(this@WakeWordService, phrase, sensitivity) { keyword ->
                Log.i(TAG, "Wake word trigger: $keyword")
                triggerWakeWordFeedback()
                scope.launch(Dispatchers.Main) {
                    val service = DictationService.instance
                    if (service != null) {
                        runCatching { audioRecord?.stop() }
                        service.startRecordingFromWakeWord()
                    } else {
                        Toast.makeText(
                            this@WakeWordService,
                            R.string.wake_word_accessibility_not_enabled,
                            Toast.LENGTH_LONG,
                        ).show()
                    }
                }
            }

            if (!d.start()) {
                Log.e(TAG, "Failed to start detector")
                stopSelf()
                return@launch
            }
            detector = d

            runAudioLoop()
        }
    }

    private fun triggerWakeWordFeedback() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vibratorManager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
                val vibrator = vibratorManager?.defaultVibrator
                vibrator?.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK))
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val vibrator = getSystemService(Vibrator::class.java)
                vibrator?.vibrate(VibrationEffect.createOneShot(150, VibrationEffect.DEFAULT_AMPLITUDE))
            } else {
                @Suppress("DEPRECATION")
                val vibrator = getSystemService(Vibrator::class.java)
                @Suppress("DEPRECATION")
                vibrator?.vibrate(150)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Failed to vibrate on wake word: ${e.message}")
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

        val sourcesToTry = intArrayOf(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            MediaRecorder.AudioSource.MIC,
        )

        var record: AudioRecord? = null
        for (source in sourcesToTry) {
            try {
                val candidate = AudioRecord(
                    source,
                    sampleRate,
                    channelConfig,
                    audioFormat,
                    bufferSize,
                )
                if (candidate.state == AudioRecord.STATE_INITIALIZED) {
                    record = candidate
                    Log.i(TAG, "Initialized AudioRecord with source $source")
                    break
                } else {
                    candidate.release()
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "Microphone permission missing", e)
                stopSelf()
                return
            } catch (t: Throwable) {
                Log.w(TAG, "AudioRecord init failed for source $source: ${t.message}")
            }
        }

        if (record == null || record.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "All AudioRecord candidates failed to initialize")
            record?.release()
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

        // 30ms chunks at 16kHz for fast acoustic feature calculation and low latency
        val chunkSize = 480
        val shortBuffer = ShortArray(chunkSize)
        val floatBuffer = FloatArray(chunkSize)

        val sensitivity = ai.sayso.dictation.AppGraph.settings.wakeWordSensitivity
        val gain = when (sensitivity) {
            ai.sayso.dictation.core.SettingsStore.WAKE_SENSITIVITY_HIGH -> 1.5f
            ai.sayso.dictation.core.SettingsStore.WAKE_SENSITIVITY_LOW -> 0.9f
            else -> 1.2f
        }

        while (scope.isActive && isListening) {
            // While DictationService is recording or busy, pause wake-word ingestion to avoid mic contention
            if (DictationService.isBusyOrRecording()) {
                if (record.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                    try { record.stop() } catch (_: Throwable) {}
                }
                delay(200)
                continue
            } else if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                try { record.startRecording() } catch (_: Throwable) {}
            }

            val read = record.read(shortBuffer, 0, shortBuffer.size)
            if (read > 0) {
                for (i in 0 until read) {
                    val sample = (shortBuffer[i] / 32768.0f) * gain
                    floatBuffer[i] = sample.coerceIn(-1.0f, 1.0f)
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

    fun updatePhrase(phrase: String) {
        detector?.wakeWordPhrase = phrase
        Log.i(TAG, "Updated wake word phrase in running detector: $phrase")
    }

    companion object {
        private const val TAG = "SaysoWakeWord"
        private const val CHANNEL_ID = "sayso_wake_word"
        private const val NOTIFICATION_ID = 2001
        const val ACTION_STOP = "ai.sayso.dictation.STOP_WAKE_WORD"

        @Volatile
        var instance: WakeWordService? = null
            private set

        fun updatePhrase(phrase: String) {
            instance?.updatePhrase(phrase)
        }

        fun start(context: Context) {
            if (context.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                Log.w(TAG, "Cannot start WakeWordService: RECORD_AUDIO permission missing")
                return
            }
            try {
                val intent = Intent(context, WakeWordService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Throwable) {
                Log.e(TAG, "Failed to start WakeWordService: ${e.message}", e)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, WakeWordService::class.java)
            context.stopService(intent)
        }

        fun restart(context: Context) {
            if (instance != null) {
                instance?.updatePhrase(ai.sayso.dictation.AppGraph.settings.wakeWordPhrase)
            } else {
                start(context)
            }
        }

        fun restartWithSettings(context: Context) {
            if (instance != null) {
                stop(context)
                start(context)
            }
        }
    }
}
