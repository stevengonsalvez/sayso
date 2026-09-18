package ai.sayso.dictation.models

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

@OptIn(ExperimentalCoroutinesApi::class)
class ModelDownloadsTest {

    @get:Rule val temp = TemporaryFolder()

    @Test
    fun `enqueue on empty list invokes onAllFinished immediately`() = runTest {
        val testScope = TestScope(StandardTestDispatcher(testScheduler))
        val downloads = ModelDownloads(testScope)
        var finished = false

        downloads.enqueue(emptyList(), temp.newFolder("models"), temp.newFolder("cache")) {
            finished = true
        }

        testScope.advanceUntilIdle()
        assertTrue(finished)
    }

    @Test
    fun `enqueue skips already installed models`() = kotlinx.coroutines.runBlocking {
        val testScope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default)
        val downloads = ModelDownloads(testScope)
        val modelsDir = temp.newFolder("models")
        val cacheDir = temp.newFolder("cache")

        // Default model installed with .onnx file
        val model = LocalModelCatalog.default
        val dir = File(modelsDir, model.dirName).apply { mkdirs() }
        File(dir, "model.onnx").writeText("fake onnx")

        val finished = kotlinx.coroutines.CompletableDeferred<Unit>()
        downloads.enqueue(listOf(model), modelsDir, cacheDir) {
            finished.complete(Unit)
        }

        kotlinx.coroutines.withTimeout(5000) {
            finished.await()
        }
        assertFalse(downloads.busy)
    }

    @Test
    fun `start does not deadlock onFinished when busy`() = runTest {
        val testScope = TestScope(StandardTestDispatcher(testScheduler))
        val downloads = ModelDownloads(testScope)
        val modelsDir = temp.newFolder("models")
        val cacheDir = temp.newFolder("cache")

        // First start
        var firstFinished = false
        downloads.start(LocalModelCatalog.default, modelsDir, cacheDir) {
            firstFinished = true
        }

        assertTrue(downloads.busy)

        // Second start while busy
        var secondFinished = false
        downloads.start(LocalModelCatalog.default, modelsDir, cacheDir) {
            secondFinished = true
        }

        // Second start should immediately call onFinished and return
        assertTrue(secondFinished)
    }
}
