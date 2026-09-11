package com.shotclubhouse.sayso.service

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import com.shotclubhouse.sayso.AppGraph
import com.shotclubhouse.sayso.R
import com.shotclubhouse.sayso.core.AudioClip
import com.shotclubhouse.sayso.core.OutputMethod
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The whole dictation loop, driven by the floating bubble.
 *
 * Tap to record, tap again to transcribe and insert. Everything runs on the service
 * scope, which dies with the service, so a dictation in flight cannot outlive it.
 */
class DictationService : AccessibilityService() {

    private enum class State { IDLE, RECORDING, BUSY }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private var bubble: OverlayBubble? = null
    private var injector: TextInjector? = null
    private var sounds: SoundCues? = null
    private var capture: AudioCapture? = null
    private var state = State.IDLE

    /**
     * Called again every time the system rebinds the service, so whatever the previous
     * connection left running is torn down before a fresh set is built.
     */
    override fun onServiceConnected() {
        AppGraph.init(this)
        capture?.stop()
        capture = null
        sounds?.release()
        bubble?.hide()

        injector = TextInjector(this)
        sounds = SoundCues(AppGraph.settings)
        bubble = OverlayBubble(this, AppGraph.settings, ::onTap).apply { show() }
        instance = this
        enter(State.IDLE)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        instance = null
        capture?.stop()
        capture = null
        bubble?.hide()
        bubble = null
        sounds?.release()
        scope.cancel()
        super.onDestroy()
    }

    /**
     * Drops the loaded on-device recogniser so the next dictation reloads it. Called
     * by the settings screen after the selected local model changes.
     */
    fun reloadLocalModel() {
        scope.launch {
            runCatching { withContext(Dispatchers.IO) { AppGraph.local.unload() } }
        }
    }

    private fun onTap() {
        when (state) {
            State.IDLE -> startRecording()
            State.RECORDING -> stopRecording()
            State.BUSY -> feedback(getString(R.string.feedback_busy))
        }
    }

    private fun startRecording() {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            fail(getString(R.string.feedback_grant_microphone))
            return
        }

        val recorder = AudioCapture(AppGraph.settings.maxRecordingSeconds)
        capture = recorder
        enter(State.RECORDING)
        sounds?.start()

        scope.launch {
            val result = recorder.record(onAutoStop = { scope.launch { onAutoStop() } })
            handle(result)
        }
    }

    private fun stopRecording() {
        capture?.stop()
        enterBusy()
    }

    private fun onAutoStop() {
        enterBusy()
        feedback(getString(R.string.feedback_max_length))
    }

    /** Idempotent so that a tap and a hit time limit can both trigger it. */
    private fun enterBusy() {
        if (state == State.BUSY) return
        enter(State.BUSY)
        sounds?.stop()
    }

    private suspend fun handle(result: Capture) {
        enterBusy()
        try {
            when {
                result.error == CaptureError.PERMISSION -> fail(getString(R.string.feedback_grant_microphone))
                result.error == CaptureError.UNAVAILABLE -> fail(getString(R.string.feedback_microphone_unavailable))
                result.clip.isEmpty -> fail(getString(R.string.feedback_no_audio))
                else -> dictate(result.clip)
            }
        } finally {
            capture = null
            enter(State.IDLE)
        }
    }

    private suspend fun dictate(clip: AudioClip) {
        // The pipeline moves itself off the main thread.
        val result = AppGraph.pipeline.run(clip)
        if (result.text.isBlank()) {
            fail(result.error ?: getString(R.string.feedback_no_speech))
            return
        }

        val method = injector?.inject(result.text) ?: OutputMethod.NONE
        if (method == OutputMethod.NONE) {
            fail(getString(R.string.feedback_not_delivered))
        } else {
            val delivered = getString(
                if (method == OutputMethod.INSERTED) R.string.feedback_inserted else R.string.feedback_clipboard,
            )
            val outcome =
                if (result.error == null) delivered
                else getString(R.string.feedback_with_warning, delivered, getString(R.string.feedback_cleanup_failed))
            feedback(
                result.notice?.let { getString(R.string.feedback_with_warning, outcome, it) } ?: outcome,
            )
        }

        if (AppGraph.settings.historyEnabled) {
            withContext(Dispatchers.IO) {
                runCatching { AppGraph.history.update(result.entry.copy(outputMethod = method)) }
            }
        }
    }

    private fun enter(next: State) {
        state = next
        bubble?.setState(
            when (next) {
                State.IDLE -> BubbleState.Idle
                State.RECORDING -> BubbleState.Recording
                State.BUSY -> BubbleState.Busy
            },
        )
    }

    private fun fail(message: String) {
        sounds?.error()
        feedback(message)
    }

    private fun feedback(message: String) {
        bubble?.showFeedback(message)
    }

    companion object {
        /** The running service, or null while it is switched off. */
        @Volatile
        var instance: DictationService? = null
            private set

        /** Whether the user has granted Sayso the accessibility permission. */
        fun isEnabled(context: Context): Boolean {
            val component = ComponentName(context, DictationService::class.java)
            val enabled = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            ).orEmpty()
            return enabled.split(':').any { ComponentName.unflattenFromString(it) == component }
        }
    }
}
