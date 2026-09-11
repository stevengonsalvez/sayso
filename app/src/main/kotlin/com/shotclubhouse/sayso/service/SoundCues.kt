package com.shotclubhouse.sayso.service

import android.media.AudioManager
import android.media.ToneGenerator
import android.util.Log
import com.shotclubhouse.sayso.core.SettingsStore

/**
 * Short tones marking the edges of a dictation, so the bubble does not have to be
 * watched. Silent when the user has turned sounds off.
 */
class SoundCues(private val settings: SettingsStore) {

    private var generator: ToneGenerator? = null

    fun start() = play(ToneGenerator.TONE_PROP_BEEP)

    fun stop() = play(ToneGenerator.TONE_PROP_ACK)

    fun error() = play(ToneGenerator.TONE_PROP_NACK)

    fun release() {
        generator?.release()
        generator = null
    }

    private fun play(tone: Int) {
        if (!settings.soundsEnabled) return
        val active = generator ?: runCatching { ToneGenerator(STREAM, VOLUME) }
            .onFailure { Log.d(TAG, "Tone generator unavailable", it) }
            .getOrNull()
            ?.also { generator = it }
            ?: return
        runCatching { active.startTone(tone) }
    }

    private companion object {
        const val TAG = "SaysoSounds"
        const val STREAM = AudioManager.STREAM_NOTIFICATION
        const val VOLUME = 60
    }
}
