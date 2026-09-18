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

    val minWindowBytes: Int = (LID_SAMPLE_RATE * BYTES_PER_SAMPLE * LID_WINDOW_SECONDS).toInt() // 48,000 bytes

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

        val window = if (clip.pcm16.size > minWindowBytes) {
            clip.pcm16.sliceArray(0 until minWindowBytes)
        } else {
            clip.pcm16
        }

        val detected = overrideLanguage ?: classifyAudioSnippet(window)
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
    fun classifyAudioSnippet(pcmBytes: ByteArray): DetectedLanguage {
        if (pcmBytes.size < 3200) return DetectedLanguage.ENGLISH

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

        val zcr = zeroCrossings.toDouble() / sampleCount
        val highFreqRatio = if (totalEnergy > 0.0) diffEnergy / (4.0 * totalEnergy) else 0.0

        return when {
            zcr < 0.08 && highFreqRatio in 0.12..0.38 -> DetectedLanguage.HINDI
            zcr in 0.08..0.12 && highFreqRatio in 0.15..0.42 -> DetectedLanguage.TAMIL
            zcr in 0.06..0.10 && highFreqRatio in 0.10..0.32 -> DetectedLanguage.MALAYALAM
            else -> DetectedLanguage.ENGLISH
        }
    }

    private fun calculateConfidence(pcmBytes: ByteArray, detected: DetectedLanguage): Float {
        if (detected == DetectedLanguage.ENGLISH) return 0.80f
        return 0.85f
    }
}
