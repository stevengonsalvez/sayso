package ai.sayso.dictation

import android.content.Context
import ai.sayso.dictation.core.DictationPipeline
import ai.sayso.dictation.core.PolishModel
import ai.sayso.dictation.core.PolishProvider
import ai.sayso.dictation.core.SecretStore
import ai.sayso.dictation.core.SttModel
import ai.sayso.dictation.core.TranscriptionProvider
import ai.sayso.dictation.history.HistoryStore
import ai.sayso.dictation.models.ModelDownloads
import ai.sayso.dictation.pipeline.DefaultDictationPipeline
import ai.sayso.dictation.pipeline.PolishCatalog
import ai.sayso.dictation.pipeline.SttCatalog
import ai.sayso.dictation.polish.PolishRegistry
import ai.sayso.dictation.settings.KeystoreSecretStore
import ai.sayso.dictation.settings.Settings
import ai.sayso.dictation.stt.LocalSherpaProvider
import ai.sayso.dictation.stt.SttRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import java.io.File

/**
 * Process-wide object graph. Plain singletons, initialised once from [SaysoApp].
 * The accessibility service and the UI run in the same process, so both see the
 * same instances.
 */
object AppGraph {
    lateinit var settings: Settings private set
    lateinit var secrets: SecretStore private set
    lateinit var localModelsDir: File private set
    lateinit var local: LocalSherpaProvider private set
    lateinit var stt: SttRegistry private set
    lateinit var polish: PolishRegistry private set
    lateinit var history: HistoryStore private set
    lateinit var pipeline: DictationPipeline private set
    lateinit var corrections: ai.sayso.dictation.correction.AutoCorrectionEngine private set

    /** Model downloads outlive any one screen, so the in-flight one lives here. */
    lateinit var downloads: ModelDownloads private set

    @Volatile private var initialised = false

    @Synchronized
    fun init(context: Context) {
        if (initialised) return
        val app = context.applicationContext
        settings = Settings.open(app)
        secrets = KeystoreSecretStore(app)
        localModelsDir = File(app.filesDir, "models").apply { mkdirs() }
        local = LocalSherpaProvider(localModelsDir)
        stt = SttRegistry(local)
        ai.sayso.dictation.polish.LocalSlmPolisher.init(app.filesDir)
        polish = PolishRegistry()
        history = HistoryStore(File(app.filesDir, "history"))
        pipeline = DefaultDictationPipeline(
            settings = settings,
            secrets = secrets,
            stt = object : SttCatalog {
                override fun find(modelId: String): Pair<TranscriptionProvider, SttModel>? = stt.find(modelId)
                override val localFallbackModelId: String?
                    get() = local.models.firstOrNull()?.id
            },
            polish = object : PolishCatalog {
                override fun find(modelId: String): Pair<PolishProvider, PolishModel>? = polish.find(modelId)
            },
            history = history,
        )
        corrections = ai.sayso.dictation.correction.AutoCorrectionEngine.open(app, settings)
        downloads = ModelDownloads(CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate))
        initialised = true
    }
}
