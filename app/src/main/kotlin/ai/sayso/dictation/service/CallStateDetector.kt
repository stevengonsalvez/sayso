package ai.sayso.dictation.service

import android.content.Context
import android.media.AudioManager
import android.os.Build

/**
 * Detects whether an active telephony or VoIP call (e.g. WhatsApp, Phone, Meet, Telegram)
 * is in progress on the device.
 *
 * Uses [AudioManager.getMode] which requires zero special permissions, ensuring full
 * privacy and compliance while accurately detecting cellular calls (MODE_IN_CALL, MODE_RINGTONE)
 * and VoIP or communication apps (MODE_IN_COMMUNICATION, MODE_CALL_SCREENING).
 */
object CallStateDetector {

    /**
     * Returns true if any cellular phone call or VoIP audio/video call (WhatsApp, Meet, etc.)
     * is currently active, ringing, or screening.
     */
    fun isCallActive(context: Context): Boolean {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return false
        return isCallMode(audioManager.mode)
    }

    /**
     * Evaluates an [AudioManager] mode value to determine if a call is active.
     */
    fun isCallMode(mode: Int): Boolean {
        return when (mode) {
            AudioManager.MODE_IN_CALL,
            AudioManager.MODE_IN_COMMUNICATION,
            AudioManager.MODE_RINGTONE -> true
            else -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && mode == AudioManager.MODE_CALL_SCREENING) {
                    true
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && mode == AudioManager.MODE_CALL_REDIRECT) {
                    true
                } else {
                    false
                }
            }
        }
    }
}
