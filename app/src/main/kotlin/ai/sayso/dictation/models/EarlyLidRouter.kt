package ai.sayso.dictation.models

import ai.sayso.dictation.core.AudioClip
import ai.sayso.dictation.core.toFloatSamples
import com.k2fsa.sherpa.onnx.OfflineStream
import com.k2fsa.sherpa.onnx.SpokenLanguageIdentification
import com.k2fsa.sherpa.onnx.SpokenLanguageIdentificationConfig
import com.k2fsa.sherpa.onnx.SpokenLanguageIdentificationWhisperConfig
import java.io.File

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
        fun fromCode(code: String): DetectedLanguage = when (code.lowercase().trim()) {
            "ta", "tamil" -> TAMIL
            "hi", "hindi" -> HINDI
            "ml", "malayalam" -> MALAYALAM
            "en", "english" -> ENGLISH
            else -> entries.firstOrNull { it.code.equals(code, ignoreCase = true) } ?: UNKNOWN
        }
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
 * Employs neural on-device spoken language identification (via Sherpa-ONNX / Whisper)
 * or acoustic voice classification to automatically dispatch incoming audio between
 * English (Parakeet) and Indic models (AI4Bharat Tamil, Hindi, Malayalam).
 */
object EarlyLidRouter {
    private const val LID_SAMPLE_RATE = 16000
    private const val LID_WINDOW_SECONDS = 1.5f
    private const val BYTES_PER_SAMPLE = 2 // 16-bit PCM

    private val lidLock = Any()
    @Volatile
    private var cachedLid: SpokenLanguageIdentification? = null
    @Volatile
    private var cachedLidDir: String? = null

    fun windowBytesForSampleRate(sampleRate: Int): Int =
        (sampleRate.coerceAtLeast(8000) * BYTES_PER_SAMPLE * LID_WINDOW_SECONDS).toInt()

    val minWindowBytes: Int = windowBytesForSampleRate(LID_SAMPLE_RATE) // 48,000 bytes

    const val MODEL_TAMIL = "local/ai4bharat-indicconformer-ta"
    const val MODEL_HINDI = "local/ai4bharat-indicconformer-hi"
    const val MODEL_MALAYALAM = "local/ai4bharat-indicconformer-ml"
    const val MODEL_ENGLISH_DEFAULT = "local/sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8"

    /**
     * Evaluates audio [clip] and selects the best installed model.
     * Uses neural SpokenLanguageIdentification if [modelsDir] contains Whisper,
     * otherwise falls back to acoustic classification.
     */
    fun route(
        clip: AudioClip,
        installedModelIds: Set<String>,
        defaultModelId: String,
        overrideLanguage: DetectedLanguage? = null,
        modelsDir: File? = null,
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

        val audioDetected = detectLanguage(clip, window, modelsDir, installedModelIds)
        val detected = if (audioDetected != DetectedLanguage.UNKNOWN) {
            audioDetected
        } else {
            overrideLanguage ?: DetectedLanguage.UNKNOWN
        }
        val targetModelId = when (detected) {
            DetectedLanguage.TAMIL -> MODEL_TAMIL
            DetectedLanguage.HINDI -> MODEL_HINDI
            DetectedLanguage.MALAYALAM -> MODEL_MALAYALAM
            DetectedLanguage.ENGLISH -> {
                if (overrideLanguage == DetectedLanguage.ENGLISH && (defaultModelId.contains("indic") || defaultModelId.contains("ai4bharat"))) {
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

    private fun detectLanguage(
        clip: AudioClip,
        window: ByteArray,
        modelsDir: File?,
        installedModelIds: Set<String>,
    ): DetectedLanguage {
        if (isSilenceOrEmpty(window)) {
            return DetectedLanguage.UNKNOWN
        }
        if (modelsDir != null) {
            val neuralResult = detectWithSherpaLid(clip, modelsDir)
            if (neuralResult != null && neuralResult != DetectedLanguage.UNKNOWN) {
                return neuralResult
            }
        }
        return classifyAudioSnippet(window, clip.sampleRate, installedModelIds)
    }

    private fun isSilenceOrEmpty(pcmBytes: ByteArray): Boolean {
        if (pcmBytes.size < 320) return true
        val sampleCount = pcmBytes.size / 2
        var totalEnergy = 0.0
        for (i in 0 until sampleCount) {
            val sample = (pcmBytes[i * 2].toInt() and 0xFF) or (pcmBytes[i * 2 + 1].toInt() shl 8)
            val sample16 = sample.toShort().toInt()
            totalEnergy += sample16.toDouble() * sample16.toDouble()
        }
        return totalEnergy < 1000.0
    }

    private fun detectWithSherpaLid(clip: AudioClip, modelsDir: File): DetectedLanguage? {
        synchronized(lidLock) {
            val lid = getOrInitLidLocked(modelsDir) ?: return null
            return try {
                val stream = lid.createStream()
                try {
                    val samples = clip.toFloatSamples()
                    val maxSamples = (clip.sampleRate * 3.0f).toInt().coerceAtMost(samples.size)
                    val slice = if (samples.size > maxSamples) samples.copyOfRange(0, maxSamples) else samples
                    stream.acceptWaveform(slice, clip.sampleRate)
                    val code = lid.compute(stream)
                    DetectedLanguage.fromCode(code)
                } finally {
                    stream.release()
                }
            } catch (t: Throwable) {
                null
            }
        }
    }

    private fun getOrInitLidLocked(modelsDir: File): SpokenLanguageIdentification? {
        val whisperDir = File(modelsDir, "sherpa-onnx-whisper-tiny").takeIf { it.isDirectory }
            ?: File(modelsDir, "sherpa-onnx-whisper-base").takeIf { it.isDirectory }
            ?: return null

        if (cachedLid != null && cachedLidDir == whisperDir.absolutePath) {
            return cachedLid
        }

        cachedLid?.release()
        cachedLid = null
        cachedLidDir = null

            val onnxFiles = whisperDir.listFiles()?.filter { it.isFile && it.name.endsWith(".onnx") } ?: return null
            val encoder = onnxFiles.firstOrNull { it.name.contains("encoder") && it.name.contains("int8") }
                ?: onnxFiles.firstOrNull { it.name.contains("encoder") }
                ?: return null
            val decoder = onnxFiles.firstOrNull { it.name.contains("decoder") && it.name.contains("int8") }
                ?: onnxFiles.firstOrNull { it.name.contains("decoder") }
                ?: return null

            return try {
                val whisperConfig = SpokenLanguageIdentificationWhisperConfig(
                    encoder = encoder.absolutePath,
                    decoder = decoder.absolutePath,
                    tailPaddings = 0,
                )
                val config = SpokenLanguageIdentificationConfig(
                    whisper = whisperConfig,
                    numThreads = 2,
                    debug = false,
                    provider = "cpu",
                )
                SpokenLanguageIdentification(assetManager = null, config = config).also {
                    cachedLid = it
                    cachedLidDir = whisperDir.absolutePath
                }
            } catch (t: Throwable) {
                null
            }
        }

    /**
     * Acoustic fallback classifier when neural LID model is not installed.
     * Evaluates zero crossings and formant energy distribution.
     */
    fun classifyAudioSnippet(
        pcmBytes: ByteArray,
        sampleRate: Int = LID_SAMPLE_RATE,
        installedModelIds: Set<String> = emptySet(),
    ): DetectedLanguage {
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

        val hasIndicInstalled = installedModelIds.any { it.contains("indic") || it.contains("ai4bharat") }
        if (!hasIndicInstalled) {
            return DetectedLanguage.ENGLISH
        }

        // Voiced vowel speech in Indic Dravidian/Indo-Aryan phonetics has sustained fundamental frequencies (ZCR < 0.065)
        return when {
            zcr < 0.065 && highFreqRatio in 0.001..0.45 -> {
                when {
                    MODEL_TAMIL in installedModelIds -> DetectedLanguage.TAMIL
                    MODEL_HINDI in installedModelIds -> DetectedLanguage.HINDI
                    MODEL_MALAYALAM in installedModelIds -> DetectedLanguage.MALAYALAM
                    else -> DetectedLanguage.TAMIL
                }
            }
            else -> DetectedLanguage.ENGLISH
        }
    }

    private fun calculateConfidence(pcmBytes: ByteArray, detected: DetectedLanguage): Float {
        val base = if (detected == DetectedLanguage.ENGLISH) 0.80f else 0.85f
        return if (pcmBytes.size >= minWindowBytes) base else (base * 0.9f)
    }

    fun releaseLid() {
        synchronized(lidLock) {
            cachedLid?.release()
            cachedLid = null
            cachedLidDir = null
        }
    }
}
