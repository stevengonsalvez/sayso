package ai.sayso.dictation.polish

import ai.sayso.dictation.models.DownloadState
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.security.MessageDigest

class SlmDownloaderTest {

    @get:Rule val temp = TemporaryFolder()

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    @Test
    fun `slm downloads to storage dir and verifies checksum`() = runBlocking {
        val server = MockWebServer()
        server.start()

        val fakeWeights = ByteArray(15_000_000) { 42 }
        server.enqueue(MockResponse().setBody(Buffer().write(fakeWeights)))

        val info = SlmModelInfo(
            id = "test/qwen",
            displayName = "Test Qwen",
            parameterCount = "0.5B",
            quantizedSizeMb = 15,
            description = "fixture",
            downloadUrl = server.url("/qwen.gguf").toString(),
            fileName = "qwen.gguf",
            sha256 = sha256(fakeWeights),
        )

        val storage = File(temp.root, "slm")
        val downloader = SlmDownloader(OkHttpClient())
        val states = downloader.download(info, storage).toList()

        assertEquals(DownloadState.Done, states.last())
        val installedFile = File(storage, info.fileName)
        assertTrue(installedFile.exists())
        assertEquals(15_000_000L, installedFile.length())
        assertTrue(downloader.isInstalled(info, storage))

        assertTrue(downloader.delete(info, storage))
        assertFalse(downloader.isInstalled(info, storage))

        server.shutdown()
    }

    @Test
    fun `slm download fails on checksum mismatch and cleans up tmp`() = runBlocking {
        val server = MockWebServer()
        server.start()

        val fakeWeights = ByteArray(12_000_000) { 1 }
        server.enqueue(MockResponse().setBody(Buffer().write(fakeWeights)))

        val info = SlmModelInfo(
            id = "test/mismatch",
            displayName = "Test Mismatch",
            parameterCount = "0.5B",
            quantizedSizeMb = 12,
            description = "fixture",
            downloadUrl = server.url("/mismatch.gguf").toString(),
            fileName = "mismatch.gguf",
            sha256 = "0".repeat(64),
        )

        val storage = File(temp.root, "slm")
        val downloader = SlmDownloader(OkHttpClient())
        val states = downloader.download(info, storage).toList()

        val last = states.last()
        assertTrue(last is DownloadState.Error)
        assertEquals("Downloaded SLM weights did not match checksum", (last as DownloadState.Error).message)
        assertFalse(File(storage, info.fileName).exists())
        assertFalse(File(storage, "${info.fileName}.tmp").exists())

        server.shutdown()
    }
}
