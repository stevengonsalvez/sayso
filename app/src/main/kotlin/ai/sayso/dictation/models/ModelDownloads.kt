package ai.sayso.dictation.models

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import ai.sayso.dictation.core.SettingsStore
import ai.sayso.dictation.settings.Settings
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Owns the one download that may be in flight. Held in the object graph rather than in
 * composition so that leaving the screen, or rotating the phone, does not cancel a transfer
 * half way through 500 MB, and so a second tap cannot start a parallel one.
 */
class ModelDownloads(private val scope: CoroutineScope) {
    private val downloader = LocalModelDownloader()

    var activeDirName by mutableStateOf<String?>(null)
        private set
    var state by mutableStateOf<DownloadState?>(null)
        private set

    val busy: Boolean
        get() = state is DownloadState.Downloading || state is DownloadState.Extracting

    fun start(model: LocalModel, modelsDir: File, cacheDir: File, onFinished: () -> Unit) {
        if (busy) {
            onFinished()
            return
        }
        activeDirName = model.dirName
        state = DownloadState.Downloading(0f)
        scope.launch {
            downloader.download(model, modelsDir, cacheDir).collect { state = it }
            onFinished()
        }
    }

    /**
     * Downloads a sequence of models sequentially, skipping any already installed.
     * Runs on the long-lived scope so navigating away does not abort queue.
     */
    fun enqueue(
        models: List<LocalModel>,
        modelsDir: File,
        cacheDir: File,
        onAllFinished: () -> Unit = {},
    ) {
        if (models.isEmpty()) {
            onAllFinished()
            return
        }
        scope.launch(Dispatchers.IO) {
            for (model in models) {
                if (!isInstalled(model, modelsDir)) {
                    val done = CompletableDeferred<Unit>()
                    withContext(Dispatchers.Main) {
                        start(model, modelsDir, cacheDir) {
                            done.complete(Unit)
                        }
                    }
                    done.await()
                }
            }
            withContext(Dispatchers.Main) {
                onAllFinished()
            }
        }
    }

    fun isInstalled(model: LocalModel, modelsDir: File): Boolean =
        downloader.isInstalled(model, modelsDir)

    /**
     * Removes a model and repoints the transcription setting when it named that model, then
     * calls [onDone] on the main thread. Runs on the long-lived scope rather than the
     * caller's: a delete abandoned half way through would leave the setting pointing at
     * files that are gone, and every dictation failing until the user noticed.
     */
    fun deleteAndReset(model: LocalModel, modelsDir: File, settings: SettingsStore, onDone: () -> Unit) {
        scope.launch {
            delete(model, modelsDir)
            if (settings.sttModelId == "local/${model.dirName}") {
                settings.sttModelId = Settings.DEFAULT_STT_MODEL_ID
            }
            onDone()
        }
    }

    /** Suspending because removing half a gigabyte of weights is not a main-thread job. */
    private suspend fun delete(model: LocalModel, modelsDir: File) {
        withContext(Dispatchers.IO) { downloader.delete(model, modelsDir) }
        if (activeDirName == model.dirName) {
            activeDirName = null
            state = null
        }
    }
}
