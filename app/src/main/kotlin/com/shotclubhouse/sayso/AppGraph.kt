package com.shotclubhouse.sayso

import android.content.Context
import com.shotclubhouse.sayso.core.DictationPipeline
import com.shotclubhouse.sayso.core.PolishModel
import com.shotclubhouse.sayso.core.PolishProvider
import com.shotclubhouse.sayso.core.SecretStore
import com.shotclubhouse.sayso.core.SttModel
import com.shotclubhouse.sayso.core.TranscriptionProvider
import com.shotclubhouse.sayso.history.HistoryStore
import com.shotclubhouse.sayso.models.ModelDownloads
import com.shotclubhouse.sayso.pipeline.DefaultDictationPipeline
import com.shotclubhouse.sayso.pipeline.PolishCatalog
import com.shotclubhouse.sayso.pipeline.SttCatalog
import com.shotclubhouse.sayso.polish.PolishRegistry
import com.shotclubhouse.sayso.settings.KeystoreSecretStore
import com.shotclubhouse.sayso.settings.Settings
import com.shotclubhouse.sayso.stt.LocalSherpaProvider
import com.shotclubhouse.sayso.stt.SttRegistry
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
        downloads = ModelDownloads(CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate))
        initialised = true
    }
}
