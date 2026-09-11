package com.shotclubhouse.sayso.service

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.TextView
import com.shotclubhouse.sayso.R
import com.shotclubhouse.sayso.core.SettingsStore
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
 * The floating microphone button, drawn by the accessibility service through
 * [WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY] so that no
 * SYSTEM_ALERT_WINDOW permission is needed.
 *
 * Dragging moves the window live; a release that travelled less than 10 dp counts
 * as a tap, anything further snaps to the nearest side and is remembered.
 *
 * Every method must be called on the main thread.
 */
class OverlayBubble(
    private val context: Context,
    private val settings: SettingsStore,
    private val onTap: () -> Unit,
) {
    private val windowManager = context.getSystemService(WindowManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val density = context.resources.displayMetrics.density

    private val sizePx = dp(56)
    private val marginPx = dp(8)
    private val tapSlopPx = dp(10)

    private val bubbleBackground = GradientDrawable().apply { shape = GradientDrawable.OVAL }

    private val icon = ImageView(context).apply {
        setImageResource(R.drawable.ic_bubble_idle)
        layoutParams = FrameLayout.LayoutParams(dp(26), dp(26), Gravity.CENTER)
    }

    private val spinner = ProgressBar(context).apply {
        isIndeterminate = true
        visibility = View.GONE
        layoutParams = FrameLayout.LayoutParams(dp(44), dp(44), Gravity.CENTER)
    }

    private val root = FrameLayout(context).apply {
        background = bubbleBackground
        contentDescription = context.getString(R.string.bubble_content_description)
        addView(spinner)
        addView(icon)
    }

    private val pill = TextView(context).apply {
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        maxLines = 2
        setPadding(dp(10), dp(6), dp(10), dp(6))
        background = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = dp(10).toFloat()
            setColor(COLOUR_IDLE.toInt())
        }
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

    private var pulse: ValueAnimator? = null
    private var shown = false
    private var pillShown = false

    init {
        bubbleBackground.setColor(COLOUR_IDLE.toInt())
        // Taps go through performClick so screen readers can activate the bubble too.
        root.setOnClickListener { onTap() }
        root.setOnTouchListener(DragListener())
    }

    fun show() {
        if (shown) return
        placeInitially()
        windowManager.addView(root, params)
        shown = true
    }

    fun hide() {
        handler.removeCallbacksAndMessages(null)
        pulse?.cancel()
        pulse = null
        hidePill()
        if (!shown) return
        runCatching { windowManager.removeView(root) }
        shown = false
    }

    fun setState(state: BubbleState) {
        bubbleBackground.setColor(
            when (state) {
                BubbleState.Idle -> COLOUR_IDLE
                BubbleState.Recording -> COLOUR_RECORDING
                BubbleState.Busy -> COLOUR_BUSY
            }.toInt(),
        )
        spinner.visibility = if (state == BubbleState.Busy) View.VISIBLE else View.GONE
        if (state == BubbleState.Recording) startPulse() else stopPulse()
    }

    /** Shows [text] beside the bubble for two seconds. */
    fun showFeedback(text: String) {
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
            windowManager.addView(pill, pillParams)
            pillShown = true
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
        pulse = ValueAnimator.ofFloat(1f, 0.4f).apply {
            duration = PULSE_MS
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
            addUpdateListener { icon.alpha = it.animatedValue as Float }
            start()
        }
    }

    private fun stopPulse() {
        pulse?.cancel()
        pulse = null
        icon.alpha = 1f
    }

    private fun screenBounds() = windowManager.currentWindowMetrics.bounds

    private fun dp(value: Int): Int = (value * density).roundToInt()

    /** Live drag, with a release that either taps or snaps to the nearest side. */
    private inner class DragListener : View.OnTouchListener {
        private var downX = 0f
        private var downY = 0f
        private var startX = 0
        private var startY = 0
        private var travelled = 0f

        override fun onTouch(view: View, event: MotionEvent): Boolean {
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    startX = params.x
                    startY = params.y
                    travelled = 0f
                }

                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downX
                    val dy = event.rawY - downY
                    travelled = maxOf(travelled, hypot(dx, dy))
                    val bounds = screenBounds()
                    params.x = clampToScreen((startX + dx).roundToInt(), sizePx, bounds.width(), 0)
                    params.y = clampToScreen((startY + dy).roundToInt(), sizePx, bounds.height(), 0)
                    if (shown) windowManager.updateViewLayout(root, params)
                }

                MotionEvent.ACTION_UP -> {
                    if (travelled < tapSlopPx) view.performClick() else settle()
                }

                MotionEvent.ACTION_CANCEL -> settle()

                else -> return false
            }
            return true
        }

        private fun settle() {
            val bounds = screenBounds()
            params.x = snapToEdge(params.x, sizePx, bounds.width(), marginPx)
            params.y = clampToScreen(params.y, sizePx, bounds.height(), marginPx)
            if (shown) windowManager.updateViewLayout(root, params)
            settings.bubbleX = params.x
            settings.bubbleY = params.y
        }
    }

    private companion object {
        const val COLOUR_IDLE = 0xDD1E2A44
        const val COLOUR_RECORDING = 0xDDE5484D
        const val COLOUR_BUSY = 0xDD6B6B6B
        const val PULSE_MS = 500L
        const val FEEDBACK_MS = 2_000L
    }
}
