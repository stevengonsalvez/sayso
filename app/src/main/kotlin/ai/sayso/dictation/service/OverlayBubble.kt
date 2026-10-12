package ai.sayso.dictation.service

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.TextView
import ai.sayso.dictation.R
import ai.sayso.dictation.core.SettingsStore
import kotlin.math.hypot
import kotlin.math.roundToInt

/** What the bubble is showing. */
enum class BubbleState { Idle, Recording, Busy }

/**
 * Returns the left edge the bubble settles on: whichever screen side its centre
 * is nearer, inset by [margin].
 */
fun snapToEdge(x: Int, width: Int, screenWidth: Int, margin: Int): Int {
    val centre = x + width / 2
    return if (centre * 2 < screenWidth) margin else screenWidth - width - margin
}

/** Keeps a window of [size] fully on a [extent] long axis, inset by [margin]. */
fun clampToScreen(value: Int, size: Int, extent: Int, margin: Int): Int {
    val highest = extent - size - margin
    if (highest < margin) return margin
    return value.coerceIn(margin, highest)
}

/**
 * Calculates the X position of the companion discard button relative to the bubble.
 * When the bubble is on the right half of the screen, the discard button is placed
 * to the left of the bubble. When on the left half, it is placed to the right.
 */
fun calculateDiscardPositionX(
    bubbleX: Int,
    bubbleWidth: Int,
    discardWidth: Int,
    screenWidth: Int,
    companionMargin: Int,
    edgeMargin: Int,
): Int {
    val onRightHalf = bubbleX + bubbleWidth / 2 > screenWidth / 2
    return if (onRightHalf) {
        (bubbleX - discardWidth - companionMargin).coerceAtLeast(edgeMargin)
    } else {
        (bubbleX + bubbleWidth + companionMargin).coerceAtMost(screenWidth - discardWidth - edgeMargin)
    }
}

/**
 * Returns true if the user's touch movement constitutes a slide-to-cancel gesture.
 * When docked on the right side, sliding left past [threshold] cancels.
 * When docked on the left side, sliding right past [threshold] cancels.
 */
fun isSlideToCancelGesture(
    dx: Float,
    onRightHalf: Boolean,
    threshold: Float,
): Boolean {
    return if (onRightHalf) dx <= -threshold else dx >= threshold
}

/**
 * The floating microphone button, drawn by the accessibility service through
 * [WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY] so that no
 * SYSTEM_ALERT_WINDOW permission is needed.
 *
 * Supports both:
 * 1. Push-and-hold (press to talk, release to transcribe)
 * 2. Tap-to-toggle (tap once to record hands-free, tap again to finish)
 *
 * Dragging moves the window live; a release that travelled less than 10 dp counts
 * as a tap/hold release, anything further snaps to the nearest side and is remembered.
 *
 * Every method must be called on the main thread.
 */
class OverlayBubble(
    private val context: Context,
    private val settings: SettingsStore,
    private val onTap: () -> Unit,
    private val onHoldStart: () -> Unit = {},
    private val onHoldEnd: () -> Unit = {},
    private val onDiscard: () -> Unit = {},
) {
    private val windowManager = context.getSystemService(WindowManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val density = context.resources.displayMetrics.density

    private val sizePx = dp(60)
    private val bubbleSizePx = dp(52)
    private val marginPx = dp(8)
    private val tapSlopPx = dp(10)

    private val glowBackground = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(GLOW_IDLE.toInt())
    }

    private val glowRing = View(context).apply {
        background = glowBackground
        layoutParams = FrameLayout.LayoutParams(sizePx, sizePx, Gravity.CENTER)
    }

    private val bubbleBackground = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(COLOUR_IDLE.toInt())
        setStroke(dp(2.5f), STROKE_IDLE.toInt())
    }

    private val icon = ImageView(context).apply {
        setImageResource(R.drawable.ic_bubble_idle)
        setColorFilter(Color.WHITE)
        layoutParams = FrameLayout.LayoutParams(dp(28), dp(28), Gravity.CENTER)
    }

    private val spinner = ProgressBar(context).apply {
        isIndeterminate = true
        visibility = View.GONE
        layoutParams = FrameLayout.LayoutParams(dp(36), dp(36), Gravity.CENTER)
    }

    private val innerBubble = FrameLayout(context).apply {
        background = bubbleBackground
        elevation = dp(6).toFloat()
        addView(spinner)
        addView(icon)
        layoutParams = FrameLayout.LayoutParams(bubbleSizePx, bubbleSizePx, Gravity.CENTER)
    }

    private val root = FrameLayout(context).apply {
        contentDescription = context.getString(R.string.bubble_content_description)
        addView(glowRing)
        addView(innerBubble)
    }

    private val pill = TextView(context).apply {
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        maxLines = 2
        setPadding(dp(10), dp(6), dp(10), dp(6))
        background = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = dp(10).toFloat()
            setColor(0xEE1E293B.toInt())
        }
    }

    private val discardWindowSizePx = dp(56)
    private val discardButtonSizePx = dp(48)
    private val discardMarginPx = dp(8)
    private val slideCancelThresholdPx = dp(45).toFloat()

    private val discardBackground = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(COLOUR_DISCARD.toInt())
        setStroke(dp(2f), STROKE_DISCARD.toInt())
    }

    private val discardIcon = ImageView(context).apply {
        setImageResource(R.drawable.ic_discard)
        setColorFilter(Color.WHITE)
        layoutParams = FrameLayout.LayoutParams(dp(24), dp(24), Gravity.CENTER)
    }

    private val innerDiscard = FrameLayout(context).apply {
        background = discardBackground
        elevation = dp(6).toFloat()
        addView(discardIcon)
        layoutParams = FrameLayout.LayoutParams(discardButtonSizePx, discardButtonSizePx, Gravity.CENTER)
    }

    private val discardView = FrameLayout(context).apply {
        contentDescription = context.getString(R.string.bubble_discard_content_description)
        addView(innerDiscard)
        setOnClickListener { onDiscard() }
    }

    private val params = WindowManager.LayoutParams(
        sizePx,
        sizePx,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
        PixelFormat.TRANSLUCENT,
    ).apply { gravity = Gravity.TOP or Gravity.START }

    private val pillParams = WindowManager.LayoutParams(
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
        PixelFormat.TRANSLUCENT,
    ).apply { gravity = Gravity.TOP or Gravity.START }

    private val discardParams = WindowManager.LayoutParams(
        discardWindowSizePx,
        discardWindowSizePx,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
        PixelFormat.TRANSLUCENT,
    ).apply { gravity = Gravity.TOP or Gravity.START }

    private var pulse: ValueAnimator? = null
    private var shown = false
    private var pillShown = false
    private var discardShown = false
    private var isSlideToCancelActive = false
    private var currentState = BubbleState.Idle

    init {
        setState(BubbleState.Idle)
        // Taps go through performClick so screen readers can activate the bubble too.
        root.setOnClickListener { onTap() }
        root.setOnTouchListener(DragListener())
    }

    fun show() {
        val keyguardManager = context.getSystemService(android.app.KeyguardManager::class.java)
        if (keyguardManager?.isKeyguardLocked == true) {
            hide()
            return
        }
        if (shown) return
        placeInitially()
        // The window manager refuses an overlay while the service is being torn down or the
        // display is going away. A refused add must not leave the bubble thinking it is up.
        runCatching { windowManager.addView(root, params) }
            .onSuccess {
                shown = true
                if (currentState == BubbleState.Recording) {
                    showDiscardView()
                }
            }
            .onFailure { Log.w(TAG, "The window manager refused the bubble overlay") }
    }

    fun hide() {
        handler.removeCallbacksAndMessages(null)
        pulse?.cancel()
        pulse = null
        hidePill()
        hideDiscardView()
        if (!shown) return
        runCatching { windowManager.removeView(root) }
        shown = false
    }

    fun setState(state: BubbleState) {
        currentState = state
        val (bgColour, strokeColour, glowColour) = when (state) {
            BubbleState.Idle -> Triple(COLOUR_IDLE, STROKE_IDLE, GLOW_IDLE)
            BubbleState.Recording -> Triple(COLOUR_RECORDING, STROKE_RECORDING, GLOW_RECORDING)
            BubbleState.Busy -> Triple(COLOUR_BUSY, STROKE_BUSY, GLOW_BUSY)
        }
        bubbleBackground.setColor(bgColour.toInt())
        bubbleBackground.setStroke(dp(2.5f), strokeColour.toInt())
        glowBackground.setColor(glowColour.toInt())

        spinner.visibility = if (state == BubbleState.Busy) View.VISIBLE else View.GONE
        icon.visibility = if (state == BubbleState.Busy) View.INVISIBLE else View.VISIBLE

        innerBubble.invalidate()
        glowRing.invalidate()
        root.invalidate()
        if (shown) {
            runCatching { windowManager.updateViewLayout(root, params) }
        }

        if (state == BubbleState.Recording) {
            startPulse()
            if (shown) showDiscardView()
        } else {
            stopPulse()
            hideDiscardView()
        }
    }

    /** Shows [text] beside the bubble for two seconds. */
    fun showFeedback(text: String) {
        val keyguardManager = context.getSystemService(android.app.KeyguardManager::class.java)
        if (keyguardManager?.isKeyguardLocked == true) return
        pill.text = text
        handler.removeCallbacksAndMessages(null)
        pill.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED)
        val width = pill.measuredWidth
        val screenWidth = screenBounds().width()
        val onRightHalf = params.x + sizePx / 2 > screenWidth / 2
        pillParams.x =
            if (onRightHalf) (params.x - width - marginPx).coerceAtLeast(marginPx)
            else (params.x + sizePx + marginPx).coerceAtMost(screenWidth - width - marginPx)
        pillParams.y = params.y + (sizePx - pill.measuredHeight) / 2

        if (pillShown) {
            windowManager.updateViewLayout(pill, pillParams)
        } else {
            // Logged without the exception: its message can quote the view, and the pill holds
            // the dictated text.
            runCatching { windowManager.addView(pill, pillParams) }
                .onSuccess { pillShown = true }
                .onFailure { Log.w(TAG, "The window manager refused the feedback pill") }
        }
        handler.postDelayed(::hidePill, FEEDBACK_MS)
    }

    private fun hidePill() {
        if (!pillShown) return
        runCatching { windowManager.removeView(pill) }
        pillShown = false
    }

    private fun placeInitially() {
        val bounds = screenBounds()
        val savedX = settings.bubbleX
        val savedY = settings.bubbleY
        val placed = savedX >= 0 && savedY >= 0
        params.x = if (placed) clampToScreen(savedX, sizePx, bounds.width(), marginPx)
        else bounds.width() - sizePx - marginPx
        params.y = if (placed) clampToScreen(savedY, sizePx, bounds.height(), marginPx)
        else (bounds.height() - sizePx) / 2
    }

    private fun startPulse() {
        if (pulse != null) return
        pulse = ValueAnimator.ofFloat(1.0f, 1.25f).apply {
            duration = PULSE_MS
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
            addUpdateListener { anim ->
                val scale = anim.animatedValue as Float
                glowRing.scaleX = scale
                glowRing.scaleY = scale
                glowRing.alpha = 1.6f - scale
                icon.alpha = 0.5f + (scale - 1.0f) * 2f
            }
            start()
        }
    }

    private fun stopPulse() {
        pulse?.cancel()
        pulse = null
        glowRing.scaleX = 1.05f
        glowRing.scaleY = 1.05f
        glowRing.alpha = 0.6f
        icon.alpha = 1f
    }

    private fun screenBounds() = windowManager.currentWindowMetrics.bounds

    private fun dp(value: Int): Int = (value * density).roundToInt()

    private fun dp(value: Float): Int = (value * density).roundToInt()

    private fun updateDiscardPosition() {
        val bounds = screenBounds()
        discardParams.x = calculateDiscardPositionX(
            bubbleX = params.x,
            bubbleWidth = sizePx,
            discardWidth = discardWindowSizePx,
            screenWidth = bounds.width(),
            companionMargin = discardMarginPx,
            edgeMargin = marginPx,
        )
        discardParams.y = params.y + (sizePx - discardWindowSizePx) / 2
    }

    private fun showDiscardView() {
        val keyguardManager = context.getSystemService(android.app.KeyguardManager::class.java)
        if (keyguardManager?.isKeyguardLocked == true) return
        if (discardShown) return
        updateDiscardPosition()
        runCatching { windowManager.addView(discardView, discardParams) }
            .onSuccess { discardShown = true }
            .onFailure { Log.w(TAG, "The window manager refused the discard overlay") }
    }

    private fun hideDiscardView() {
        if (!discardShown) return
        setSlideToCancelActive(false)
        runCatching { windowManager.removeView(discardView) }
        discardShown = false
    }

    private fun setSlideToCancelActive(active: Boolean) {
        if (isSlideToCancelActive == active) return
        isSlideToCancelActive = active
        if (active) {
            discardBackground.setColor(COLOUR_DISCARD_ACTIVE.toInt())
            discardBackground.setStroke(dp(2.5f), STROKE_DISCARD_ACTIVE.toInt())
            innerDiscard.scaleX = 1.15f
            innerDiscard.scaleY = 1.15f
        } else {
            discardBackground.setColor(COLOUR_DISCARD.toInt())
            discardBackground.setStroke(dp(2f), STROKE_DISCARD.toInt())
            innerDiscard.scaleX = 1.0f
            innerDiscard.scaleY = 1.0f
        }
        innerDiscard.invalidate()
    }

    /** Live drag, with a release that either taps, holds, or snaps to the nearest side. */
    private inner class DragListener : View.OnTouchListener {
        private var downX = 0f
        private var downY = 0f
        private var startX = 0
        private var startY = 0
        private var travelled = 0f
        private var isHolding = false
        private var isDrag = false

        private val holdRunnable = Runnable {
            if (travelled < tapSlopPx) {
                isHolding = true
                onHoldStart()
            }
        }

        override fun onTouch(view: View, event: MotionEvent): Boolean {
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    startX = params.x
                    startY = params.y
                    travelled = 0f
                    isHolding = false
                    isDrag = false
                    setSlideToCancelActive(false)
                    handler.postDelayed(holdRunnable, HOLD_THRESHOLD_MS)
                }

                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downX
                    val dy = event.rawY - downY
                    travelled = maxOf(travelled, hypot(dx, dy))
                    if (isHolding) {
                        val bounds = screenBounds()
                        val onRightHalf = params.x + sizePx / 2 > bounds.width() / 2
                        val slid = isSlideToCancelGesture(dx, onRightHalf, slideCancelThresholdPx)
                        setSlideToCancelActive(slid)
                    } else if (travelled >= tapSlopPx) {
                        handler.removeCallbacks(holdRunnable)
                        isDrag = true
                        val bounds = screenBounds()
                        params.x = clampToScreen((startX + dx).roundToInt(), sizePx, bounds.width(), 0)
                        params.y = clampToScreen((startY + dy).roundToInt(), sizePx, bounds.height(), 0)
                        if (shown) runCatching { windowManager.updateViewLayout(root, params) }
                        if (discardShown) {
                            updateDiscardPosition()
                            runCatching { windowManager.updateViewLayout(discardView, discardParams) }
                        }
                    }
                }

                MotionEvent.ACTION_UP -> {
                    handler.removeCallbacks(holdRunnable)
                    if (isHolding) {
                        val cancelled = isSlideToCancelActive
                        isHolding = false
                        setSlideToCancelActive(false)
                        if (cancelled) {
                            onDiscard()
                        } else {
                            onHoldEnd()
                        }
                    } else if (isDrag) {
                        settle()
                    } else if (travelled < tapSlopPx) {
                        view.performClick()
                    } else {
                        settle()
                    }
                }

                MotionEvent.ACTION_CANCEL -> {
                    handler.removeCallbacks(holdRunnable)
                    if (isHolding) {
                        val cancelled = isSlideToCancelActive
                        isHolding = false
                        setSlideToCancelActive(false)
                        if (cancelled) {
                            onDiscard()
                        } else {
                            onHoldEnd()
                        }
                    } else if (isDrag) {
                        settle()
                    }
                }

                else -> return false
            }
            return true
        }

        private fun settle() {
            val bounds = screenBounds()
            params.x = snapToEdge(params.x, sizePx, bounds.width(), marginPx)
            params.y = clampToScreen(params.y, sizePx, bounds.height(), marginPx)
            if (shown) runCatching { windowManager.updateViewLayout(root, params) }
            if (discardShown) {
                updateDiscardPosition()
                runCatching { windowManager.updateViewLayout(discardView, discardParams) }
            }
            settings.bubbleX = params.x
            settings.bubbleY = params.y
        }
    }

    private companion object {
        const val TAG = "SaysoBubble"
        const val COLOUR_IDLE = 0xFF00B0FFL
        const val STROKE_IDLE = 0xFFE0F7FAL
        const val GLOW_IDLE = 0x5500D4FFL

        const val COLOUR_RECORDING = 0xFFFF1744L
        const val STROKE_RECORDING = 0xFFFF80ABL
        const val GLOW_RECORDING = 0x77FF1744L

        const val COLOUR_BUSY = 0xFFFF9100L
        const val STROKE_BUSY = 0xFFFFF59DL
        const val GLOW_BUSY = 0x55FFB300L

        const val COLOUR_DISCARD = 0xFFDC2626L
        const val STROKE_DISCARD = 0xFFFECACAL
        const val COLOUR_DISCARD_ACTIVE = 0xFF991B1BL
        const val STROKE_DISCARD_ACTIVE = 0xFFFFFFFFL

        const val HOLD_THRESHOLD_MS = 280L
        const val PULSE_MS = 500L
        const val FEEDBACK_MS = 2_000L
    }
}
