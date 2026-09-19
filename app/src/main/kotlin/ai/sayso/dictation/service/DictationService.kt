package ai.sayso.dictation.service

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import ai.sayso.dictation.AppGraph
import ai.sayso.dictation.R
import ai.sayso.dictation.core.AudioClip
import ai.sayso.dictation.core.OutputMethod
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.coroutines.cancellation.CancellationException

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
    private var lastInjectedText: String? = null
    private var lastInjectedTime: Long = 0L

    /**
     * Called again every time the system rebinds the service, so whatever the previous
     * connection left running is torn down before a fresh set is built.
     */
    override fun onServiceConnected() {
        AppGraph.init(this)
        capture?.stop()
        capture = null
        // A dictation still in flight belongs to the previous connection: it would finish
        // against components that are about to be replaced, so it is cancelled outright.
        scope.coroutineContext.cancelChildren()
        sounds?.release()
        bubble?.hide()

        val info = serviceInfo ?: AccessibilityServiceInfo()
        info.eventTypes = AccessibilityEvent.TYPE_VIEW_FOCUSED or
            AccessibilityEvent.TYPE_VIEW_CLICKED or
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
            AccessibilityEvent.TYPE_WINDOWS_CHANGED
        info.feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
        info.flags = info.flags or
            AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
            AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
        serviceInfo = info

        injector = TextInjector(this)
        sounds = SoundCues(AppGraph.settings)
        bubble = OverlayBubble(
            context = this,
            settings = AppGraph.settings,
            onTap = ::onTap,
            onHoldStart = ::onHoldStart,
            onHoldEnd = ::onHoldEnd,
        )
        instance = this
        enter(State.IDLE)
        updateBubbleVisibility()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val settings = AppGraph.settings
        if (settings.bubbleAlwaysVisible || state != State.IDLE) {
            bubble?.show()
            return
        }

        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_FOCUSED,
            AccessibilityEvent.TYPE_VIEW_CLICKED -> {
                val source = event.source
                if (source != null && isEditableTarget(source)) {
                    bubble?.show()
                } else {
                    checkActiveWindowFocus()
                }
            }
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOWS_CHANGED -> {
                checkActiveWindowFocus()
            }
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED -> {
                val injected = lastInjectedText
                if (injected != null && System.currentTimeMillis() - lastInjectedTime < 45_000L) {
                    val current = event.text.joinToString("")
                    if (current.isNotBlank() && current != injected) {
                        AppGraph.corrections.recordEdit(injected, current)
                    }
                }
            }
        }
    }

    fun updateBubbleVisibility() {
        if (AppGraph.settings.bubbleAlwaysVisible || state != State.IDLE) {
            bubble?.show()
        } else {
            checkActiveWindowFocus()
        }
    }

    private fun isEditableTarget(node: AccessibilityNodeInfo): Boolean {
        if (node.isEditable) return true
        val className = node.className?.toString().orEmpty()
        if (className.contains("EditText", ignoreCase = true)) return true
        if (className.contains("TerminalView", ignoreCase = true)) return true
        return false
    }

    private fun checkActiveWindowFocus() {
        if (AppGraph.settings.bubbleAlwaysVisible || state != State.IDLE) {
            bubble?.show()
            return
        }

        // If soft keyboard (IME window) is currently open, user is in an input field
        val isKeyboardOpen = windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
        if (isKeyboardOpen) {
            bubble?.show()
            return
        }

        val root = rootInActiveWindow
        val focusedInput = root?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (focusedInput != null && isEditableTarget(focusedInput)) {
            bubble?.show()
            return
        }

        val hasEditableFocus = windows.filter { it.isActive || it.isFocused }.any { window ->
            val wRoot = window.root ?: return@any false
            val inputFocus = wRoot.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            inputFocus != null && isEditableTarget(inputFocus)
        }

        if (hasEditableFocus) {
            bubble?.show()
        } else {
            bubble?.hide()
        }
    }

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        instance = null
        capture?.stop()
        capture = null
        bubble?.hide()
        bubble = null
        sounds?.release()
        ai.sayso.dictation.models.EarlyLidRouter.releaseLid()
        scope.cancel()
        super.onDestroy()
    }

    /**
     * Drops the loaded on-device recogniser so the next dictation reloads it. Called
     * by the settings screen after the selected local model changes.
     */
    fun reloadLocalModel() {
        scope.launch {
            ignoringFailure { withContext(Dispatchers.IO) { AppGraph.local.unload() } }
        }
    }

    /**
     * Runs work whose failure must not sink the dictation, such as writing history. A
     * cancellation is not a failure: it still has to travel, or a rebind leaves the run
     * half alive.
     */
    private suspend fun ignoringFailure(block: suspend () -> Unit) {
        try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Deliberately silent: the message could quote the dictated text.
        }
    }

    private fun onTap() {
        when (state) {
            State.IDLE -> startRecording()
            State.RECORDING -> stopRecording()
            State.BUSY -> feedback(getString(R.string.feedback_busy))
        }
    }

    private fun onHoldStart() {
        if (state == State.IDLE) {
            startRecording()
        }
    }

    private fun onHoldEnd() {
        if (state == State.RECORDING) {
            stopRecording()
        }
    }

    fun startRecordingFromWakeWord() {
        if (state != State.IDLE) return
        bubble?.show()
        startRecording()
    }

    private fun startRecording() {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            fail(getString(R.string.feedback_grant_microphone))
            return
        }

        val settings = AppGraph.settings
        val recorder = AudioCapture(
            maxSeconds = settings.maxRecordingSeconds,
            autoStopSilence = settings.autoStopSilenceEnabled,
            silenceTimeoutMs = (settings.silenceTimeoutSeconds * 1000).toLong(),
        )
        capture = recorder
        enter(State.RECORDING)
        sounds?.start()

        scope.launch {
            val result = recorder.record(onAutoStop = { reason -> scope.launch { onAutoStop(reason) } })
            handle(result)
        }
    }

    private fun stopRecording() {
        capture?.stop()
        enterBusy()
    }

    private fun onAutoStop(reason: AutoStopReason) {
        if (state != State.RECORDING) return
        enterBusy()
        if (reason == AutoStopReason.MAX_DURATION) {
            feedback(getString(R.string.feedback_max_length))
        }
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
            // A cancelled run belongs to a connection that has already been torn down and
            // reset; resetting again here would undo whatever the fresh one set up.
            if (currentCoroutineContext().isActive) {
                capture = null
                enter(State.IDLE)
                updateBubbleVisibility()
            }
        }
    }

    private fun getTargetPackageName(): String? {
        val focused = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (focused?.packageName != null) return focused.packageName.toString()
        val rootPkg = rootInActiveWindow?.packageName
        if (rootPkg != null) return rootPkg.toString()
        for (w in windows) {
            val p = w.root?.packageName ?: continue
            return p.toString()
        }
        return null
    }

    private suspend fun dictate(clip: AudioClip) {
        // The pipeline moves itself off the main thread.
        val targetPackage = getTargetPackageName()
        val result = AppGraph.pipeline.run(clip, targetPackage)
        if (result.text.isBlank()) {
            fail(result.error ?: getString(R.string.feedback_no_speech))
            return
        }

        val method = injector?.inject(result.text) ?: OutputMethod.NONE
        if (method == OutputMethod.INSERTED) {
            lastInjectedText = result.text
            lastInjectedTime = System.currentTimeMillis()
        }
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
                ignoringFailure { AppGraph.history.update(result.entry.copy(outputMethod = method)) }
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

        fun isBusyOrRecording(): Boolean {
            val s = instance?.state
            return s == State.RECORDING || s == State.BUSY
        }

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
