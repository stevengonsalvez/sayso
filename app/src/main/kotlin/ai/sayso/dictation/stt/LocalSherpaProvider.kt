package ai.sayso.dictation.stt

import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineMoonshineModelConfig
import com.k2fsa.sherpa.onnx.OfflineNemoEncDecCtcModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineSenseVoiceModelConfig
import com.k2fsa.sherpa.onnx.OfflineTransducerModelConfig
import com.k2fsa.sherpa.onnx.OfflineWhisperModelConfig
import ai.sayso.dictation.core.AudioClip
import ai.sayso.dictation.core.SttModel
import ai.sayso.dictation.core.TranscriptionProvider
import ai.sayso.dictation.core.TranscriptionRequest
import ai.sayso.dictation.core.TranscriptionResult
import ai.sayso.dictation.core.toFloatSamples
import ai.sayso.dictation.models.LocalModelCatalog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

/** Two threads keeps a phone's big cores busy without starving the UI. */
private const val INFERENCE_THREADS = 2

/**
 * On-device recognition through sherpa-onnx. Model directories are whatever the
 * downloader unpacked into [modelsDir]; the flavour is worked out from the files
 * present rather than from a manifest, because the upstream archives carry none.
 *
 * One recogniser is held at a time. It is expensive to build (hundreds of MB
 * mapped) so it is kept until a different model is asked for, guarded by a mutex
 * because the service and the settings screen can both trigger a reload.
 */
class LocalSherpaProvider(private val modelsDir: File) : TranscriptionProvider {
    override val id: String = "local"
    override val displayName: String = "On device"
    override val needsApiKey: Boolean = false
    override val apiKeyUrl: String? = null

    private val mutex = Mutex()
    private var recognizer: OfflineRecognizer? = null
    private var loadedModel: String? = null

    override val models: List<SttModel>
        get() = installedDirs().map { dir ->
            val known = LocalModelCatalog.byDirName(dir.name)
            SttModel(
                id = "$id/${dir.name}",
                displayName = known?.displayName ?: dir.name,
                note = known?.note.orEmpty(),
            )
        }

    override suspend fun transcribe(request: TranscriptionRequest, apiKey: String?): TranscriptionResult =
        withContext(Dispatchers.Default) {
            mutex.withLock {
                try {
                    transcribeLocked(request.modelName, request.clip)
                } catch (e: CancellationException) {
                    throw e
                } catch (t: Throwable) {
                    // Covers UnsatisfiedLinkError on a device without the native libs.
                    release()
                    TranscriptionResult.Failure(t.message ?: "On-device model failed to run")
                }
            }
        }

    /** Frees the native recogniser, for example when the user picks a cloud provider. */
    suspend fun unload() = mutex.withLock { release() }

    private fun transcribeLocked(modelName: String, clip: AudioClip): TranscriptionResult {
        if (clip.isEmpty) return TranscriptionResult.Failure("No audio recorded")
        // The name comes from a stored setting and is joined onto a path, so it stays one
        // directory name: no separators, no walking up out of the models directory.
        if (modelName.isBlank() || modelName.any { it in PATH_SEPARATORS } || modelName.contains("..")) {
            return TranscriptionResult.Failure("\"$modelName\" is not a valid model name")
        }
        val active = recognizerFor(modelName)
            ?: return TranscriptionResult.Failure("Model \"$modelName\" is not installed")

        val stream = active.createStream()
        return try {
            stream.acceptWaveform(clip.toFloatSamples(), clip.sampleRate)
            active.decode(stream)
            val text = active.getResult(stream).text.trim()
            if (text.isEmpty()) TranscriptionResult.Failure("No speech detected")
            else TranscriptionResult.Success(text)
        } finally {
            stream.release()
        }
    }

    private fun recognizerFor(modelName: String): OfflineRecognizer? {
        recognizer?.let { if (loadedModel == modelName) return it }
        release()

        val dir = File(modelsDir, modelName)
        if (!dir.isDirectory) return null
        val config = detectConfig(dir) ?: return null

        return OfflineRecognizer(config = config).also {
            recognizer = it
            loadedModel = modelName
        }
    }

    private fun release() {
        recognizer?.release()
        recognizer = null
        loadedModel = null
    }

    private companion object {
        val PATH_SEPARATORS = charArrayOf('/', '\\')
    }

    private fun installedDirs(): List<File> = modelsDir.listFiles()
        .orEmpty()
        .filter { it.isDirectory && it.listFiles().orEmpty().any { file -> file.name.endsWith(".onnx") } }
        .sortedBy { it.name }
}

/**
 * Works out which sherpa model family a directory holds. Checked most specific
 * first: moonshine has a preprocessor, a transducer has a joiner, an
 * encoder/decoder pair without one is whisper.
 */
internal fun detectConfig(dir: File): OfflineRecognizerConfig? {
    val onnx = dir.listFiles().orEmpty().filter { it.isFile && it.name.endsWith(".onnx") }
    if (onnx.isEmpty()) return null
    val tokens = dir.listFiles().orEmpty().firstOrNull { it.name.endsWith("tokens.txt") } ?: return null

    fun pick(match: (String) -> Boolean): String? = onnx
        .filter { match(it.name) }
        .let { candidates -> candidates.firstOrNull { it.name.contains("int8") } ?: candidates.firstOrNull() }
        ?.absolutePath

    val preprocessor = pick { it.contains("preprocess") }
    val encoder = pick { it.contains("encoder") }
    val decoder = pick { it.contains("decoder") }
    val joiner = pick { it.contains("joiner") }

    val modelConfig = when {
        preprocessor != null -> {
            val encode = pick { it.contains("encode") && !it.contains("decode") } ?: return null
            val uncached = pick { it.contains("uncached_decode") } ?: return null
            val cached = pick { it.contains("cached_decode") && !it.contains("uncached") } ?: return null
            OfflineModelConfig(
                moonshine = OfflineMoonshineModelConfig(
                    preprocessor = preprocessor,
                    encoder = encode,
                    uncachedDecoder = uncached,
                    cachedDecoder = cached,
                ),
                tokens = tokens.absolutePath,
                numThreads = INFERENCE_THREADS,
            )
        }

        encoder != null && decoder != null && joiner != null -> OfflineModelConfig(
            transducer = OfflineTransducerModelConfig(encoder = encoder, decoder = decoder, joiner = joiner),
            tokens = tokens.absolutePath,
            numThreads = INFERENCE_THREADS,
            modelType = "nemo_transducer",
        )

        encoder != null && decoder != null -> OfflineModelConfig(
            whisper = OfflineWhisperModelConfig(encoder = encoder, decoder = decoder),
            tokens = tokens.absolutePath,
            numThreads = INFERENCE_THREADS,
            modelType = "whisper",
        )

        dir.name.contains("sense-voice") -> OfflineModelConfig(
            senseVoice = OfflineSenseVoiceModelConfig(
                model = pick { it.contains("model") } ?: return null,
                useInverseTextNormalization = true,
            ),
            tokens = tokens.absolutePath,
            numThreads = INFERENCE_THREADS,
        )

        else -> OfflineModelConfig(
            nemo = OfflineNemoEncDecCtcModelConfig(model = pick { it.contains("model") } ?: return null),
            tokens = tokens.absolutePath,
            numThreads = INFERENCE_THREADS,
        )
    }

    return OfflineRecognizerConfig(
        featConfig = FeatureConfig(sampleRate = AudioClip.DEFAULT_SAMPLE_RATE, featureDim = 80),
        modelConfig = modelConfig,
    )
}
