package com.shotclubhouse.sayso.models

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
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
        if (busy) return
        activeDirName = model.dirName
        state = DownloadState.Downloading(0f)
        scope.launch {
            downloader.download(model, modelsDir, cacheDir).collect { state = it }
            onFinished()
        }
    }

    fun isInstalled(model: LocalModel, modelsDir: File): Boolean =
        downloader.isInstalled(model, modelsDir)

    fun delete(model: LocalModel, modelsDir: File) {
        downloader.delete(model, modelsDir)
        if (activeDirName == model.dirName) {
            activeDirName = null
            state = null
        }
    }
}
