package ai.sayso.dictation.models

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class ModelDownloadsTest {

    @get:Rule val temp = TemporaryFolder()

    private class FakeDownloader(
        var installedResult: Boolean = false,
        var hangDownload: Boolean = false,
    ) : LocalModelDownloader() {
        var downloadCallCount = 0
        val downloadStarted = CompletableDeferred<Unit>()
        val allowComplete = CompletableDeferred<Unit>()

        override fun isInstalled(model: LocalModel, modelsDir: File): Boolean = installedResult

        override fun download(model: LocalModel, modelsDir: File, cacheDir: File): Flow<DownloadState> = flow {
            downloadCallCount++
            emit(DownloadState.Downloading(0.5f))
            if (hangDownload) {
                downloadStarted.complete(Unit)
                allowComplete.await()
            }
            emit(DownloadState.Done)
        }
    }

    @Test
    fun `enqueue on empty list invokes onAllFinished immediately`() = runBlocking {
        val fake = FakeDownloader()
        val downloads = ModelDownloads(CoroutineScope(Dispatchers.Default), fake)
        val finished = CompletableDeferred<Unit>()

        downloads.enqueue(emptyList(), temp.newFolder("models"), temp.newFolder("cache")) {
            finished.complete(Unit)
        }

        withTimeout(5000) {
            finished.await()
        }
        assertEquals(0, fake.downloadCallCount)
    }

    @Test
    fun `enqueue skips already installed models`() = runBlocking {
        val fake = FakeDownloader(installedResult = true)
        val downloads = ModelDownloads(CoroutineScope(Dispatchers.Default), fake)
        val finished = CompletableDeferred<Unit>()

        downloads.enqueue(listOf(LocalModelCatalog.default), temp.newFolder("models"), temp.newFolder("cache")) {
            finished.complete(Unit)
        }

        withTimeout(5000) {
            finished.await()
        }
        assertEquals(0, fake.downloadCallCount)
        assertFalse(downloads.busy)
    }

    @Test
    fun `enqueue downloads uninstalled models sequentially`() = runBlocking {
        val fake = FakeDownloader(installedResult = false)
        val downloads = ModelDownloads(CoroutineScope(Dispatchers.Default), fake)
        val finished = CompletableDeferred<Unit>()

        downloads.enqueue(listOf(LocalModelCatalog.default), temp.newFolder("models"), temp.newFolder("cache")) {
            finished.complete(Unit)
        }

        withTimeout(5000) {
            finished.await()
        }
        assertEquals(1, fake.downloadCallCount)
    }

    @Test
    fun `start does not deadlock onFinished when busy`() = runBlocking {
        val fake = FakeDownloader(hangDownload = true)
        val downloads = ModelDownloads(CoroutineScope(Dispatchers.Default), fake)
        val modelsDir = temp.newFolder("models")
        val cacheDir = temp.newFolder("cache")

        // First start
        val firstFinished = CompletableDeferred<Unit>()
        downloads.start(LocalModelCatalog.default, modelsDir, cacheDir) {
            firstFinished.complete(Unit)
        }
        fake.downloadStarted.await()
        assertTrue(downloads.busy)

        // Second start while busy
        val secondFinished = CompletableDeferred<Unit>()
        downloads.start(LocalModelCatalog.default, modelsDir, cacheDir) {
            secondFinished.complete(Unit)
        }

        // Second start should immediately call onFinished and return
        withTimeout(5000) {
            secondFinished.await()
        }
        fake.allowComplete.complete(Unit)
        withTimeout(5000) {
            firstFinished.await()
        }
    }
}
