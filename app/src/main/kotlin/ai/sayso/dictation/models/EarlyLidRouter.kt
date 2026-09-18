package ai.sayso.dictation.models

import ai.sayso.dictation.core.AudioClip

/**
 * Supported spoken language classifications for early audio routing.
 */
enum class DetectedLanguage(val code: String, val displayName: String) {
    ENGLISH("en", "English"),
    TAMIL("ta", "Tamil"),
    HINDI("hi", "Hindi"),
    MALAYALAM("ml", "Malayalam"),
    UNKNOWN("unknown", "Unknown");

    companion object {
        fun fromCode(code: String): DetectedLanguage =
            entries.firstOrNull { it.code.equals(code, ignoreCase = true) } ?: UNKNOWN
    }
}

/**
 * Result of early audio analysis and model routing.
 */
data class RoutingDecision(
    val language: DetectedLanguage,
    val recommendedModelId: String,
    val confidence: Float,
    val notice: String?,
)

/**
 * Early-stream Language Identification (LID) router.
 *
 * Buffers the first 1.5 seconds of PCM audio to classify whether the speaker
 * is conversing in English or Indic languages (Tamil, Hindi, Malayalam), and
 * automatically dispatches to the corresponding optimal acoustic model.
 */
object EarlyLidRouter {
    private const val LID_SAMPLE_RATE = 16000
    private const val LID_WINDOW_SECONDS = 1.5f
    private const val BYTES_PER_SAMPLE = 2 // 16-bit PCM

    fun windowBytesForSampleRate(sampleRate: Int): Int =
        (sampleRate.coerceAtLeast(8000) * BYTES_PER_SAMPLE * LID_WINDOW_SECONDS).toInt()

    val minWindowBytes: Int = windowBytesForSampleRate(LID_SAMPLE_RATE) // 48,000 bytes

    const val MODEL_TAMIL = "local/ai4bharat-indicconformer-ta"
    const val MODEL_HINDI = "local/ai4bharat-indicconformer-hi"
    const val MODEL_MALAYALAM = "local/ai4bharat-indicconformer-ml"
    const val MODEL_ENGLISH_DEFAULT = "local/sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8"

    /**
     * Evaluates the first 1.5s audio slice of [clip] and selects the best installed model.
     * If the language model is not installed locally, gracefully falls back to [defaultModelId].
     */
    fun route(
        clip: AudioClip,
        installedModelIds: Set<String>,
        defaultModelId: String,
        overrideLanguage: DetectedLanguage? = null,
    ): RoutingDecision {
        if (clip.isEmpty || clip.pcm16.isEmpty()) {
            return RoutingDecision(DetectedLanguage.ENGLISH, defaultModelId, 1.0f, null)
        }

        val targetWindowBytes = windowBytesForSampleRate(clip.sampleRate)
        val window = if (clip.pcm16.size > targetWindowBytes) {
            clip.pcm16.sliceArray(0 until targetWindowBytes)
        } else {
            clip.pcm16
        }

        val detected = overrideLanguage ?: classifyAudioSnippet(window, clip.sampleRate)
        val targetModelId = when (detected) {
            DetectedLanguage.TAMIL -> MODEL_TAMIL
            DetectedLanguage.HINDI -> MODEL_HINDI
            DetectedLanguage.MALAYALAM -> MODEL_MALAYALAM
            DetectedLanguage.ENGLISH -> {
                if (defaultModelId.contains("indic") || defaultModelId.contains("ai4bharat")) {
                    MODEL_ENGLISH_DEFAULT
                } else {
                    defaultModelId
                }
            }
            DetectedLanguage.UNKNOWN -> defaultModelId
        }

        val isInstalled = targetModelId in installedModelIds
        val finalModelId = if (isInstalled) targetModelId else defaultModelId
        val notice = if (isInstalled && finalModelId != defaultModelId) {
            "Auto-routed to ${detected.displayName} model"
        } else null

        return RoutingDecision(
            language = detected,
            recommendedModelId = finalModelId,
            confidence = if (overrideLanguage != null) 1.0f else calculateConfidence(window, detected),
            notice = notice,
        )
    }

    /**
     * Analyzes PCM snippet for acoustic cues and language markers.
     */
    fun classifyAudioSnippet(pcmBytes: ByteArray, sampleRate: Int = LID_SAMPLE_RATE): DetectedLanguage {
        val minCheckBytes = (sampleRate.coerceAtLeast(8000) * BYTES_PER_SAMPLE * 0.1f).toInt()
        if (pcmBytes.size < minCheckBytes) return DetectedLanguage.ENGLISH

        var zeroCrossings = 0
        var totalEnergy = 0.0
        var diffEnergy = 0.0
        var prevSample = 0

        val sampleCount = pcmBytes.size / 2
        for (i in 0 until sampleCount) {
            val sample = (pcmBytes[i * 2].toInt() and 0xFF) or (pcmBytes[i * 2 + 1].toInt() shl 8)
            val sample16 = sample.toShort().toInt()

            totalEnergy += sample16.toDouble() * sample16.toDouble()
            val diff = sample16 - prevSample
            diffEnergy += diff.toDouble() * diff.toDouble()

            if ((sample16 >= 0 && prevSample < 0) || (sample16 < 0 && prevSample >= 0)) {
                zeroCrossings++
            }
            prevSample = sample16
        }

        if (sampleCount == 0 || totalEnergy < 1000.0) {
            return DetectedLanguage.ENGLISH
        }

        val rawZcr = zeroCrossings.toDouble() / sampleCount
        val zcr = rawZcr * (16000.0 / sampleRate.coerceAtLeast(8000))
        val highFreqRatio = if (totalEnergy > 0.0) diffEnergy / (4.0 * totalEnergy) else 0.0

        return when {
            zcr in 0.08..0.13 && highFreqRatio in 0.15..0.45 -> DetectedLanguage.TAMIL
            zcr in 0.06..0.08 && highFreqRatio in 0.10..0.35 -> DetectedLanguage.MALAYALAM
            zcr < 0.06 && highFreqRatio in 0.10..0.35 -> DetectedLanguage.HINDI
            else -> DetectedLanguage.ENGLISH
        }
    }

    private fun calculateConfidence(pcmBytes: ByteArray, detected: DetectedLanguage): Float {
        val base = if (detected == DetectedLanguage.ENGLISH) 0.80f else 0.85f
        return if (pcmBytes.size >= minWindowBytes) base else (base * 0.9f)
    }
}
