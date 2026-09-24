package ai.sayso.dictation.models

import ai.sayso.dictation.core.AudioClip
import ai.sayso.dictation.core.toFloatSamples
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
 * Uses on-device Whisper neural spoken language identification (via Sherpa-ONNX)
 * to automatically detect language and dispatch incoming audio to dedicated models:
 * Tamil/Hindi/Malayalam audio routes directly to high-accuracy AI4Bharat IndicConformer,
 * and English audio routes to Parakeet 110M.
 *
 * In the absence of a neural LID model, the router safely preserves the configured
 * default model and never relies on speculative acoustic heuristics.
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
     * Checks whether an on-device neural LID model (Whisper Tiny or Base) is installed and ready.
     */
    fun isNeuralLidAvailable(modelsDir: File?): Boolean {
        if (modelsDir == null || !modelsDir.isDirectory) return false
        val whisperDir = File(modelsDir, "sherpa-onnx-whisper-tiny").takeIf { it.isDirectory }
            ?: File(modelsDir, "sherpa-onnx-whisper-base").takeIf { it.isDirectory }
            ?: return false
        val onnxFiles = whisperDir.listFiles()?.filter { it.isFile && it.name.endsWith(".onnx") } ?: return false
        val hasEncoder = onnxFiles.any { it.name.contains("encoder") }
        val hasDecoder = onnxFiles.any { it.name.contains("decoder") }
        return hasEncoder && hasDecoder
    }

    /**
     * Evaluates audio [clip] and selects the best installed model.
     * Uses neural SpokenLanguageIdentification when [modelsDir] contains Whisper.
     * If neural LID is unavailable or silent, preserves [defaultModelId] or [overrideLanguage].
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

        val audioDetected = if (modelsDir != null) {
            val targetWindowBytes = windowBytesForSampleRate(clip.sampleRate)
            val window = if (clip.pcm16.size > targetWindowBytes) {
                clip.pcm16.sliceArray(0 until targetWindowBytes)
            } else {
                clip.pcm16
            }
            if (isSilenceOrEmpty(window)) DetectedLanguage.UNKNOWN else detectWithSherpaLid(clip, modelsDir) ?: DetectedLanguage.UNKNOWN
        } else {
            DetectedLanguage.UNKNOWN
        }

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
            when (detected) {
                DetectedLanguage.TAMIL -> "Auto-routed to AI4Bharat Tamil"
                DetectedLanguage.HINDI -> "Auto-routed to AI4Bharat Hindi"
                DetectedLanguage.MALAYALAM -> "Auto-routed to AI4Bharat Malayalam"
                DetectedLanguage.ENGLISH -> "Auto-routed to Parakeet English"
                else -> "Auto-routed to ${detected.displayName} model"
            }
        } else null

        val confidence = when {
            audioDetected != DetectedLanguage.UNKNOWN -> 0.95f
            overrideLanguage != null -> 1.0f
            else -> 0.0f
        }

        return RoutingDecision(
            language = detected,
            recommendedModelId = finalModelId,
            confidence = confidence,
            notice = notice,
        )
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
                    val minSamples = (clip.sampleRate * 0.5f).toInt()
                    if (samples.size < minSamples) return DetectedLanguage.UNKNOWN
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

    fun releaseLid() {
        synchronized(lidLock) {
            cachedLid?.release()
            cachedLid = null
            cachedLidDir = null
        }
    }
}
