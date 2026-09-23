package ai.sayso.dictation.service

import android.content.Context
import android.util.Log
import ai.sayso.dictation.core.SettingsStore
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.KeywordSpotter
import com.k2fsa.sherpa.onnx.KeywordSpotterConfig
import com.k2fsa.sherpa.onnx.OnlineModelConfig
import com.k2fsa.sherpa.onnx.OnlineStream
import com.k2fsa.sherpa.onnx.OnlineTransducerModelConfig

/**
 * On-device keyword spotting engine powered by sherpa-onnx.
 *
 * Uses a compact int8 Zipformer model stored in assets/kws to detect
 * wake phrases such as "Hey Sayso" or "Sayso" in real-time streaming audio.
 */
class WakeWordDetector(
    private val context: Context,
    private val wakeWordPhrase: String = SettingsStore.WAKE_PHRASE_BOTH,
    private val onWakeWordDetected: (String) -> Unit,
) {
    private var spotter: KeywordSpotter? = null
    private var stream: OnlineStream? = null

    /** Initializes the spotter and opens an active recognition stream. */
    fun start(): Boolean {
        if (spotter != null) return true
        return try {
            val transducerConfig = OnlineTransducerModelConfig(
                encoder = "kws/encoder.onnx",
                decoder = "kws/decoder.onnx",
                joiner = "kws/joiner.onnx",
            )
            val modelConfig = OnlineModelConfig(
                transducer = transducerConfig,
                tokens = "kws/tokens.txt",
                numThreads = 1,
                modelType = "zipformer2",
            )
            val config = KeywordSpotterConfig(
                featConfig = FeatureConfig(sampleRate = SAMPLE_RATE, featureDim = 80),
                modelConfig = modelConfig,
                maxActivePaths = 4,
                keywordsFile = "kws/keywords.txt",
                keywordsScore = 1.5f,
                keywordsThreshold = 0.20f,
                numTrailingBlanks = 1,
            )
            val s = KeywordSpotter(context.assets, config)
            val str = s.createStream()
            spotter = s
            stream = str
            Log.i(TAG, "KeywordSpotter initialized successfully from assets")
            true
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to initialize KeywordSpotter: ${t.message}", t)
            release()
            false
        }
    }

    /** Feeds 16 kHz audio samples into the keyword spotter stream. */
    fun acceptWaveform(samples: FloatArray) {
        val s = spotter ?: return
        val str = stream ?: return
        try {
            str.acceptWaveform(samples, sampleRate = SAMPLE_RATE)
            while (s.isReady(str)) {
                s.decode(str)
                val result = s.getResult(str)
                if (result.keyword.isNotEmpty()) {
                    Log.i(TAG, "Detected wake phrase: ${result.keyword}")
                    if (matchesWakePhrase(result.keyword, wakeWordPhrase)) {
                        onWakeWordDetected(result.keyword)
                    } else {
                        Log.d(TAG, "Wake phrase ${result.keyword} filtered by active setting: $wakeWordPhrase")
                    }
                    s.reset(str)
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "Error in KeywordSpotter decode: ${t.message}", t)
        }
    }

    /** Releases native stream and model resources. */
    fun release() {
        try {
            stream?.release()
        } catch (_: Throwable) {}
        stream = null

        try {
            spotter?.release()
        } catch (_: Throwable) {}
        spotter = null
    }

    companion object {
        private const val TAG = "SaysoWakeWord"
        const val SAMPLE_RATE = 16_000

        fun matchesWakePhrase(detectedKeyword: String, allowedPhrase: String): Boolean {
            val clean = detectedKeyword.lowercase()
            return when (allowedPhrase) {
                SettingsStore.WAKE_PHRASE_HEY -> clean.contains("hey")
                SettingsStore.WAKE_PHRASE_SAYSO -> clean.contains("sayso") && !clean.contains("hey")
                else -> true
            }
        }
    }
}
