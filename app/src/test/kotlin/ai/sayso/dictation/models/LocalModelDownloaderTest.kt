package ai.sayso.dictation.models

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.apache.commons.compress.archivers.tar.TarArchiveEntry
import org.apache.commons.compress.archivers.tar.TarArchiveOutputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

class LocalModelDownloaderTest {

    @get:Rule val temp = TemporaryFolder()

    /** bzip2 squeezes repeated text to nothing, which would let the transfer finish before throttling bites. */
    private fun incompressible(length: Int): String {
        val random = java.util.Random(7)
        return String(CharArray(length) { (32 + random.nextInt(95)).toChar() })
    }

    private fun tarBz2(vararg entries: Pair<String, String>): ByteArray {
        val bytes = ByteArrayOutputStream()
        TarArchiveOutputStream(BZip2CompressorOutputStream(bytes)).use { tar ->
            tar.setLongFileMode(TarArchiveOutputStream.LONGFILE_POSIX)
            entries.forEach { (name, content) ->
                val payload = content.toByteArray()
                tar.putArchiveEntry(TarArchiveEntry(name).apply { size = payload.size.toLong() })
                tar.write(payload)
                tar.closeArchiveEntry()
            }
        }
        return bytes.toByteArray()
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /** The catalog carries the real release checksum, which a fixture archive cannot match. */
    private fun pinnedTo(archive: ByteArray) = LocalModelCatalog.default.copy(sha256 = sha256(archive))

    /** These transfers fail before the digest is compared, so any pinned value will do. */
    private val pinned = LocalModelCatalog.default.copy(sha256 = "0".repeat(64))

    private fun extractInto(dest: File, bytes: ByteArray) = runBlocking {
        val archive = File(temp.root, "model.tar.bz2").apply { writeBytes(bytes) }
        extract(archive, dest)
    }

    @Test
    fun `unpacks a model directory with its nested files`() {
        val dest = File(temp.root, "models").apply { mkdirs() }

        extractInto(
            dest,
            tarBz2(
                "sherpa-onnx-demo/tokens.txt" to "a b c",
                "sherpa-onnx-demo/model.int8.onnx" to "weights",
                "sherpa-onnx-demo/test_wavs/0.wav" to "RIFF",
            ),
        )

        assertEquals("a b c", File(dest, "sherpa-onnx-demo/tokens.txt").readText())
        assertEquals("weights", File(dest, "sherpa-onnx-demo/model.int8.onnx").readText())
        assertTrue(File(dest, "sherpa-onnx-demo/test_wavs/0.wav").isFile)
    }

    @Test
    fun `refuses an entry that escapes the destination directory`() {
        val dest = File(temp.root, "models").apply { mkdirs() }
        val sibling = File(dest.parentFile, "owned.txt")

        val failure = try {
            extractInto(dest, tarBz2("sherpa-onnx-demo/tokens.txt" to "fine", "../owned.txt" to "pwned"))
            null
        } catch (e: IOException) {
            e
        }

        assertTrue("expected the traversal entry to be rejected", failure != null)
        assertTrue(failure!!.message!!.contains("outside the models directory"))
        assertFalse("the archive wrote outside its destination", sibling.exists())
    }

    @Test
    fun `refuses an escape buried inside an otherwise normal path`() {
        val dest = File(temp.root, "models").apply { mkdirs() }
        val sibling = File(dest.parentFile, "owned.txt")

        val failure = try {
            extractInto(dest, tarBz2("sherpa-onnx-demo/nested/../../../owned.txt" to "pwned"))
            null
        } catch (e: IOException) {
            e
        }

        assertTrue("expected the nested traversal to be rejected", failure != null)
        assertFalse(sibling.exists())
        assertFalse(File(temp.root, "owned.txt").exists())
    }

    @Test
    fun `a directory is only installed once it holds a model file`() {
        val downloader = LocalModelDownloader()
        val models = File(temp.root, "models").apply { mkdirs() }
        val model = LocalModelCatalog.default

        assertFalse(downloader.isInstalled(model, models))

        val dir = File(models, model.dirName).apply { mkdirs() }
        File(dir, "tokens.txt").writeText("a")
        assertFalse(downloader.isInstalled(model, models))

        File(dir, "model.int8.onnx").writeText("weights")
        assertTrue(downloader.isInstalled(model, models))

        assertTrue(downloader.delete(model, models))
        assertFalse(downloader.isInstalled(model, models))
    }

    @Test
    fun `accepts the dot slash entries the sherpa archives actually ship`() {
        val dest = File(temp.root, "models").apply { mkdirs() }
        val dir = LocalModelCatalog.default.dirName

        extractInto(
            dest,
            tarBz2(
                "./" to "",
                "./$dir/" to "",
                "./$dir/model.int8.onnx" to "weights",
                "./$dir/tokens.txt" to "a b c",
            ),
        )

        assertTrue(LocalModelDownloader().isInstalled(LocalModelCatalog.default, dest))
        assertEquals("a b c", File(dest, "$dir/tokens.txt").readText())
    }

    @Test
    fun `download reports progress, extracts, and installs the model`() = runBlocking {
        val dir = LocalModelCatalog.default.dirName
        val archive = tarBz2("./$dir/model.int8.onnx" to "weights".repeat(20_000), "./$dir/tokens.txt" to "a b c")
        val server = MockWebServer()
        server.start()
        server.enqueue(MockResponse().setResponseCode(200).setBody(Buffer().write(archive)))

        // Redirect the real release URL at the test server without bending the
        // downloader's production interface.
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            val to = server.url("/" + chain.request().url.pathSegments.last())
            chain.proceed(chain.request().newBuilder().url(to).build())
        }.build()

        val models = File(temp.root, "models")
        val states = LocalModelDownloader(client)
            .download(pinnedTo(archive), models, File(temp.root, "cache"))
            .toList()

        assertTrue(states.first() is DownloadState.Downloading)
        assertTrue(states.any { it is DownloadState.Extracting })
        assertEquals(DownloadState.Done, states.last())
        states.filterIsInstance<DownloadState.Downloading>().forEach {
            assertTrue("progress out of range: ${it.progress}", it.progress in 0f..1f)
        }
        assertEquals(1f, states.filterIsInstance<DownloadState.Downloading>().last().progress, 1e-6f)

        assertTrue(LocalModelDownloader().isInstalled(LocalModelCatalog.default, models))
        assertEquals("a b c", File(models, "$dir/tokens.txt").readText())
        assertTrue("the cached archive was not cleaned up", File(temp.root, "cache").listFiles().orEmpty().isEmpty())

        server.shutdown()
    }

    @Test
    fun `a failed download leaves no half installed model behind`() = runBlocking {
        val server = MockWebServer()
        server.start()
        server.enqueue(MockResponse().setResponseCode(404).setBody("not found"))
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            val to = server.url("/" + chain.request().url.pathSegments.last())
            chain.proceed(chain.request().newBuilder().url(to).build())
        }.build()

        val models = File(temp.root, "models")
        val states = LocalModelDownloader(client)
            .download(pinned, models, File(temp.root, "cache"))
            .toList()

        val error = states.last()
        assertTrue(error is DownloadState.Error)
        assertTrue((error as DownloadState.Error).message.contains("404"))
        assertFalse(LocalModelDownloader().isInstalled(LocalModelCatalog.default, models))
        assertFalse(File(models, LocalModelCatalog.default.dirName).exists())

        server.shutdown()
    }

    @Test
    fun `a failed download leaves the model that was already installed alone`() = runBlocking {
        val server = MockWebServer()
        server.start()
        server.enqueue(MockResponse().setResponseCode(500).setBody("boom"))
        val client = redirectingClient(server)

        val model = pinned
        val models = File(temp.root, "models")
        val installed = File(models, model.dirName).apply { mkdirs() }
        File(installed, "model.int8.onnx").writeText("the weights I already had")
        File(installed, "tokens.txt").writeText("a b c")

        val states = LocalModelDownloader(client)
            .download(model, models, File(temp.root, "cache"))
            .toList()

        assertTrue(states.last() is DownloadState.Error)
        assertTrue(LocalModelDownloader().isInstalled(model, models))
        assertEquals("the weights I already had", File(installed, "model.int8.onnx").readText())
        assertFalse(File(models, "${model.dirName}.tmp").exists())

        server.shutdown()
    }

    @Test
    fun `a cancelled download leaves the installed model untouched`() = runBlocking {
        val server = MockWebServer()
        server.start()
        val model = pinned
        server.enqueue(
            MockResponse()
                .setBody(Buffer().write(tarBz2(model.dirName + "/model.onnx" to incompressible(300_000))))
                .throttleBody(2_048, 50, TimeUnit.MILLISECONDS),
        )
        val client = redirectingClient(server)

        val models = File(temp.root, "models")
        val installed = File(models, model.dirName).apply { mkdirs() }
        File(installed, "model.int8.onnx").writeText("the weights I already had")

        // Takes one progress update, then walks away part way through the transfer.
        val state = LocalModelDownloader(client)
            .download(model, models, File(temp.root, "cache"))
            .first()

        assertTrue(state is DownloadState.Downloading)
        assertTrue("the installed model was removed", LocalModelDownloader().isInstalled(model, models))
        assertEquals("the weights I already had", File(installed, "model.int8.onnx").readText())

        server.shutdown()
    }

    @Test
    fun `an archive whose checksum does not match is thrown away`() = runBlocking {
        val dir = LocalModelCatalog.default.dirName
        val server = MockWebServer()
        server.start()
        server.enqueue(
            MockResponse().setBody(Buffer().write(tarBz2("./$dir/model.int8.onnx" to "tampered weights"))),
        )

        val model = LocalModelCatalog.default.copy(sha256 = "0".repeat(64))
        val models = File(temp.root, "models")
        val states = LocalModelDownloader(redirectingClient(server))
            .download(model, models, File(temp.root, "cache"))
            .toList()

        val error = states.last()
        assertTrue(error is DownloadState.Error)
        assertEquals("Downloaded archive did not match its checksum", (error as DownloadState.Error).message)
        assertFalse(LocalModelDownloader().isInstalled(model, models))
        assertFalse(File(models, model.dirName).exists())
        assertFalse(File(models, "${model.dirName}.tmp").exists())

        server.shutdown()
    }

    @Test
    fun `an archive with the expected checksum installs`() = runBlocking {
        val dir = LocalModelCatalog.default.dirName
        val archive = tarBz2("./$dir/model.int8.onnx" to "weights", "./$dir/tokens.txt" to "a b c")
        val server = MockWebServer()
        server.start()
        server.enqueue(MockResponse().setBody(Buffer().write(archive)))

        val model = LocalModelCatalog.default.copy(sha256 = sha256(archive))
        val models = File(temp.root, "models")
        val states = LocalModelDownloader(redirectingClient(server))
            .download(model, models, File(temp.root, "cache"))
            .toList()

        assertEquals(DownloadState.Done, states.last())
        assertTrue(LocalModelDownloader().isInstalled(model, models))

        server.shutdown()
    }

    @Test
    fun `a model without a pinned checksum is refused before anything is fetched`() = runBlocking {
        val dir = LocalModelCatalog.default.dirName
        val server = MockWebServer()
        server.start()
        // A perfectly good archive is waiting: the refusal has to come from the missing digest.
        server.enqueue(MockResponse().setBody(Buffer().write(tarBz2("./$dir/model.int8.onnx" to "weights"))))

        val models = File(temp.root, "models")
        val states = LocalModelDownloader(redirectingClient(server))
            .download(LocalModelCatalog.default.copy(sha256 = ""), models, File(temp.root, "cache"))
            .toList()

        assertEquals(DownloadState.Error("Model has no checksum"), states.single())
        assertTrue("the archive was fetched anyway", server.requestCount == 0)
        assertFalse(File(models, dir).exists())

        server.shutdown()
    }

    @Test
    fun `a body that runs past the size the catalog claims is stopped`() = runBlocking {
        val server = MockWebServer()
        server.start()
        // A one megabyte model is allowed two, so this body runs past the ceiling.
        server.enqueue(MockResponse().setBody(Buffer().write(ByteArray(2_500_000))))

        val model = LocalModel(
            dirName = "sherpa-onnx-endless",
            displayName = "Endless",
            sizeMb = 1,
            note = "fixture",
            sha256 = "0".repeat(64),
        )
        val models = File(temp.root, "models")
        val states = LocalModelDownloader(redirectingClient(server))
            .download(model, models, File(temp.root, "cache"))
            .toList()

        val error = states.last()
        assertTrue(error is DownloadState.Error)
        assertEquals("Download exceeded the expected size", (error as DownloadState.Error).message)
        assertFalse(File(models, model.dirName).exists())
        assertTrue("the partial archive was left behind", File(temp.root, "cache").listFiles().orEmpty().isEmpty())

        server.shutdown()
    }

    @Test
    fun `multi file model downloads and verifies all files directly`() = runBlocking {
        val server = MockWebServer()
        server.start()

        val onnxBytes = "fake onnx model".toByteArray()
        val tokensBytes = "token1\ntoken2".toByteArray()

        server.enqueue(MockResponse().setBody(Buffer().write(onnxBytes)))
        server.enqueue(MockResponse().setBody(Buffer().write(tokensBytes)))

        val model = LocalModel(
            dirName = "test-multi-file-model",
            displayName = "Test Multi File",
            sizeMb = 1,
            note = "fixture",
            files = listOf(
                ModelFile(
                    url = server.url("/model.int8.onnx").toString(),
                    relativePath = "model.int8.onnx",
                    sizeBytes = onnxBytes.size.toLong(),
                    sha256 = sha256(onnxBytes),
                ),
                ModelFile(
                    url = server.url("/tokens.txt").toString(),
                    relativePath = "tokens.txt",
                    sizeBytes = tokensBytes.size.toLong(),
                    sha256 = sha256(tokensBytes),
                ),
            ),
        )

        val models = File(temp.root, "models")
        val downloader = LocalModelDownloader(OkHttpClient())
        val states = downloader.download(model, models, File(temp.root, "cache")).toList()

        assertEquals(DownloadState.Done, states.last())
        val installedDir = File(models, model.dirName)
        assertTrue(installedDir.isDirectory)
        assertEquals("fake onnx model", File(installedDir, "model.int8.onnx").readText())
        assertEquals("token1\ntoken2", File(installedDir, "tokens.txt").readText())
        assertTrue(downloader.isInstalled(model, models))

        server.shutdown()
    }

    private fun redirectingClient(server: MockWebServer) = OkHttpClient.Builder().addInterceptor { chain ->
        val to = server.url("/" + chain.request().url.pathSegments.last())
        chain.proceed(chain.request().newBuilder().url(to).build())
    }.build()
}
