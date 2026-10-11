package ai.sayso.dictation.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import ai.sayso.dictation.AppGraph
import ai.sayso.dictation.R
import ai.sayso.dictation.ui.MainActivity
import ai.sayso.dictation.voicenotes.DiskAudioRecorder
import ai.sayso.dictation.voicenotes.VoiceNote
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/**
 * Live state of long-form audio recording and chunked background transcription.
 */
data class LongRecordingState(
    val isRecording: Boolean = false,
    val isPaused: Boolean = false,
    val durationMs: Long = 0L,
    val amplitude: Float = 0f,
    val activeNoteId: String? = null,
    val activeAudioFile: File? = null,
    val isTranscribing: Boolean = false,
    val transcriptionProgress: Float = 0f,
    val transcribingNoteId: String? = null,
)

/**
 * Foreground Service for continuous long-form audio recording.
 *
 * Runs with FOREGROUND_SERVICE_MICROPHONE. Provides a persistent notification with
 * live duration, pause/resume and stop controls. Does not terminate on silence.
 */
class LongRecordingService : Service() {

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var recordJob: Job? = null
    private var activeRecorder: DiskAudioRecorder? = null
    private var activeNote: VoiceNote? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START
        when (action) {
            ACTION_START -> handleStart()
            ACTION_PAUSE -> handlePause()
            ACTION_RESUME -> handleResume()
            ACTION_STOP -> handleStop()
            ACTION_CANCEL -> handleCancel()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        activeRecorder?.stop()
        serviceScope.cancel()
        _state.update {
            it.copy(
                isRecording = false,
                isPaused = false,
                activeNoteId = null,
                activeAudioFile = null,
            )
        }
    }

    private fun handleStart() {
        if (_state.value.isRecording) {
            Log.d(TAG, "Recording already in progress")
            return
        }

        // Start foreground notification immediately before background dispatch
        startForegroundWithNotification(0L, isPaused = false)

        _state.update {
            it.copy(
                isRecording = true,
                isPaused = false,
                durationMs = 0L,
                amplitude = 0f,
            )
        }

        serviceScope.launch(Dispatchers.IO) {
            try {
                val noteId = UUID.randomUUID().toString()
                val audioFile = AppGraph.voiceNotes.getAudioFile(noteId)
                val dateFormat = SimpleDateFormat("MMM d, h:mm a", Locale.getDefault())
                val initialTitle = "Voice Note " + dateFormat.format(Date())

                val note = VoiceNote(
                    id = noteId,
                    title = initialTitle,
                    createdAt = System.currentTimeMillis(),
                    durationMs = 0L,
                    audioPath = audioFile.absolutePath,
                )
                AppGraph.voiceNotes.add(note)
                activeNote = note

                _state.update {
                    it.copy(
                        activeNoteId = noteId,
                        activeAudioFile = audioFile,
                    )
                }

                val recorder = DiskAudioRecorder(
                    outputFile = audioFile,
                    onAmplitude = { amp ->
                        _state.update { it.copy(amplitude = amp) }
                    },
                    onDurationTick = { durationMs ->
                        _state.update { it.copy(durationMs = durationMs) }
                        updateNotification(durationMs, _state.value.isPaused)
                    },
                )
                activeRecorder = recorder

                val result = recorder.record()

                // Finalize note duration
                val updatedNote = note.copy(durationMs = result.durationMs)
                AppGraph.voiceNotes.update(updatedNote)
                activeNote = updatedNote

                _state.update {
                    it.copy(
                        isRecording = false,
                        isPaused = false,
                        durationMs = result.durationMs,
                        amplitude = 0f,
                        activeNoteId = null,
                        activeAudioFile = null,
                    )
                }

                // Stop foreground recording and initiate transcription in background
                stopForeground(STOP_FOREGROUND_REMOVE)
                triggerChunkedTranscription(updatedNote)

            } catch (t: Throwable) {
                Log.e(TAG, "Error in long recording session", t)
                _state.update {
                    it.copy(
                        isRecording = false,
                        isPaused = false,
                        activeNoteId = null,
                        activeAudioFile = null,
                    )
                }
                stopSelf()
            }
        }
    }

    private fun handlePause() {
        activeRecorder?.pause()
        _state.update { it.copy(isPaused = true) }
        updateNotification(_state.value.durationMs, isPaused = true)
    }

    private fun handleResume() {
        activeRecorder?.resume()
        _state.update { it.copy(isPaused = false) }
        updateNotification(_state.value.durationMs, isPaused = false)
    }

    private fun handleStop() {
        activeRecorder?.stop()
    }

    private fun handleCancel() {
        activeRecorder?.stop()
        val currentNote = activeNote
        if (currentNote != null) {
            serviceScope.launch(Dispatchers.IO) {
                AppGraph.voiceNotes.delete(currentNote.id)
            }
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun triggerChunkedTranscription(note: VoiceNote) {
        serviceScope.launch(Dispatchers.IO) {
            val audioFile = File(note.audioPath)
            if (!audioFile.exists()) {
                stopSelf()
                return@launch
            }

            val installedModels = AppGraph.local.models
            val modelId = installedModels.firstOrNull()?.id
            val modelName = modelId?.substringAfter('/')

            if (modelName.isNullOrBlank()) {
                Log.i(TAG, "No local model installed for automatic background transcription")
                stopSelf()
                return@launch
            }

            _state.update {
                it.copy(
                    isTranscribing = true,
                    transcriptionProgress = 0f,
                    transcribingNoteId = note.id,
                )
            }

            try {
                val transcriber = AppGraph.local.asChunkTranscriber(
                    modelName = modelName,
                    language = AppGraph.settings.language,
                )

                val chunkerResult = AppGraph.chunker.transcribeFile(
                    wavFile = audioFile,
                    transcriber = transcriber,
                    onProgress = { progress, _, _, segments ->
                        _state.update {
                            it.copy(transcriptionProgress = progress)
                        }
                        serviceScope.launch(Dispatchers.IO) {
                            val inProgressNote = note.copy(
                                fullText = segments.joinToString(" ") { it.text },
                                segments = segments,
                                transcriptionProgress = progress,
                                modelUsed = modelId,
                            )
                            AppGraph.voiceNotes.update(inProgressNote)
                        }
                    },
                )

                val finishedNote = note.copy(
                    fullText = chunkerResult.fullText,
                    segments = chunkerResult.segments,
                    isTranscribed = true,
                    transcriptionProgress = 1.0f,
                    modelUsed = modelId,
                )
                AppGraph.voiceNotes.update(finishedNote)
            } catch (t: Throwable) {
                Log.e(TAG, "Chunked transcription failed", t)
            } finally {
                _state.update {
                    it.copy(
                        isTranscribing = false,
                        transcriptionProgress = 1.0f,
                        transcribingNoteId = null,
                    )
                }
                stopSelf()
            }
        }
    }

    private fun startForegroundWithNotification(durationMs: Long, isPaused: Boolean) {
        val notification = buildNotification(durationMs, isPaused)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification(durationMs: Long, isPaused: Boolean) {
        val notification = buildNotification(durationMs, isPaused)
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIFICATION_ID, notification)
    }

    private fun buildNotification(durationMs: Long, isPaused: Boolean): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_OPEN_VOICE_NOTES, true)
            putExtra(EXTRA_NOTE_ID, _state.value.activeNoteId)
        }
        val contentPendingIntent = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val pauseResumeAction = if (isPaused) {
            val resumeIntent = Intent(this, LongRecordingService::class.java).apply {
                action = ACTION_RESUME
            }
            val resumePendingIntent = PendingIntent.getService(
                this,
                1,
                resumeIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            NotificationCompat.Action.Builder(
                android.R.drawable.ic_media_play,
                "Resume",
                resumePendingIntent,
            ).build()
        } else {
            val pauseIntent = Intent(this, LongRecordingService::class.java).apply {
                action = ACTION_PAUSE
            }
            val pausePendingIntent = PendingIntent.getService(
                this,
                2,
                pauseIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            NotificationCompat.Action.Builder(
                android.R.drawable.ic_media_pause,
                "Pause",
                pausePendingIntent,
            ).build()
        }

        val stopIntent = Intent(this, LongRecordingService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            3,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopAction = NotificationCompat.Action.Builder(
            android.R.drawable.ic_delete,
            "Stop",
            stopPendingIntent,
        ).build()

        val timeFormatted = formatDuration(durationMs)
        val statusText = if (isPaused) "Paused ($timeFormatted)" else "Recording ($timeFormatted)"

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Sayso Voice Note")
            .setContentText(statusText)
            .setSmallIcon(R.drawable.ic_bubble_idle)
            .setOngoing(true)
            .setContentIntent(contentPendingIntent)
            .addAction(pauseResumeAction)
            .addAction(stopAction)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    private fun ensureNotificationChannel() {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Voice Notes Recording",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shows ongoing status and controls for voice notes recordings"
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }
    }

    companion object {
        const val TAG = "LongRecordingService"
        const val CHANNEL_ID = "sayso_long_recording"
        const val NOTIFICATION_ID = 4001

        const val ACTION_START = "ai.sayso.dictation.action.START_LONG_RECORDING"
        const val ACTION_PAUSE = "ai.sayso.dictation.action.PAUSE_LONG_RECORDING"
        const val ACTION_RESUME = "ai.sayso.dictation.action.RESUME_LONG_RECORDING"
        const val ACTION_STOP = "ai.sayso.dictation.action.STOP_LONG_RECORDING"
        const val ACTION_CANCEL = "ai.sayso.dictation.action.CANCEL_LONG_RECORDING"

        const val EXTRA_OPEN_VOICE_NOTES = "extra_open_voice_notes"
        const val EXTRA_NOTE_ID = "extra_note_id"

        private val _state = MutableStateFlow(LongRecordingState())
        val state: StateFlow<LongRecordingState> = _state.asStateFlow()

        fun start(context: Context) {
            val intent = Intent(context, LongRecordingService::class.java).apply {
                action = ACTION_START
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun pause(context: Context) {
            val intent = Intent(context, LongRecordingService::class.java).apply {
                action = ACTION_PAUSE
            }
            context.startService(intent)
        }

        fun resume(context: Context) {
            val intent = Intent(context, LongRecordingService::class.java).apply {
                action = ACTION_RESUME
            }
            context.startService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, LongRecordingService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }

        fun cancel(context: Context) {
            val intent = Intent(context, LongRecordingService::class.java).apply {
                action = ACTION_CANCEL
            }
            context.startService(intent)
        }

        fun formatDuration(durationMs: Long): String {
            val totalSeconds = durationMs / 1000
            val seconds = totalSeconds % 60
            val minutes = (totalSeconds / 60) % 60
            val hours = totalSeconds / 3600
            return if (hours > 0) {
                String.format(Locale.US, "%02d:%02d:%02d", hours, minutes, seconds)
            } else {
                String.format(Locale.US, "%02d:%02d", minutes, seconds)
            }
        }
    }
}
