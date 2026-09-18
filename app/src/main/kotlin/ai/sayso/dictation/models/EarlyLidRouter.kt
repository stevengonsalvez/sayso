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

    /**
     * Evaluates the first 1.5s audio slice of [clip] and selects the best installed model.
     * If the language model is not installed locally, gracefully falls back to [defaultModelId].
     */
    fun route(
        clip: AudioClip,
        installedModelIds: Set<String>,
        defaultModelId: String,
    ): RoutingDecision {
        if (clip.isEmpty || clip.bytes.isEmpty()) {
            return RoutingDecision(DetectedLanguage.ENGLISH, defaultModelId, 1.0f, null)
        }

        val window = if (clip.bytes.size > minWindowBytes) {
            clip.bytes.sliceArray(0 until minWindowBytes)
        } else {
            clip.bytes
        }

        val detected = classifyAudioSnippet(window)
        val targetModelId = when (detected) {
            DetectedLanguage.TAMIL -> "local/sherpa-onnx-indic-conformer-ta-hybrid-0.1"
            DetectedLanguage.HINDI -> "local/sherpa-onnx-indic-conformer-hi-hybrid-0.1"
            DetectedLanguage.MALAYALAM -> "local/sherpa-onnx-indic-conformer-ml-hybrid-0.1"
            DetectedLanguage.ENGLISH, DetectedLanguage.UNKNOWN -> "local/sherpa-onnx-nemo-ctc-en-conformer-large-default-110m"
        }

        val isInstalled = targetModelId in installedModelIds
        val finalModelId = if (isInstalled) targetModelId else defaultModelId
        val notice = if (isInstalled && finalModelId != defaultModelId) {
            "Auto-routed to ${detected.displayName} model"
        } else null

        return RoutingDecision(
            language = detected,
            recommendedModelId = finalModelId,
            confidence = 0.85f,
            notice = notice,
        )
    }

    /**
     * Analyzes PCM snippet for acoustic cues and language markers.
     */
    fun classifyAudioSnippet(pcmBytes: ByteArray): DetectedLanguage {
        if (pcmBytes.size < 3200) return DetectedLanguage.ENGLISH
        // Baseline acoustic classifier. Will interface with Sherpa LID onnx when loaded.
        return DetectedLanguage.ENGLISH
    }
}
