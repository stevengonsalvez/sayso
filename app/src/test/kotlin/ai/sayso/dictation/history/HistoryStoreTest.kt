package ai.sayso.dictation.history

import ai.sayso.dictation.core.AudioClip
import ai.sayso.dictation.core.HistoryEntry
import ai.sayso.dictation.core.OutputMethod
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

class HistoryStoreTest {

    private lateinit var dir: File

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("history-test").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun entry(
        id: String,
        createdAt: Long,
        durationMs: Long = 5_000,
        audioPath: String? = null,
    ) = HistoryEntry(
        id = id,
        createdAt = createdAt,
        durationMs = durationMs,
        rawText = "hello world",
        polishedText = null,
        sttModelId = "local/tiny",
        polishModelId = null,
        outputMethod = OutputMethod.INSERTED,
        error = null,
        audioPath = audioPath,
    )

    @Test
    fun add_and_all_returnsNewestFirst() = runTest {
        val store = HistoryStore(dir)
        store.add(entry("1", createdAt = 100))
        store.add(entry("2", createdAt = 300))
        store.add(entry("3", createdAt = 200))

        assertEquals(listOf("2", "3", "1"), store.all().map { it.id })
    }

    @Test
    fun update_replacesById() = runTest {
        val store = HistoryStore(dir)
        store.add(entry("1", createdAt = 100))
        store.update(entry("1", createdAt = 100, durationMs = 9_999))

        val all = store.all()
        assertEquals(1, all.size)
        assertEquals(9_999L, all.first().durationMs)
    }

    @Test
    fun update_unknownId_isNoOp() = runTest {
        val store = HistoryStore(dir)
        store.add(entry("1", createdAt = 100))
        store.update(entry("missing", createdAt = 100))

        assertEquals(listOf("1"), store.all().map { it.id })
    }

    @Test
    fun delete_removesEntryAndAudio() = runTest {
        val store = HistoryStore(dir)
        val path = store.saveAudio("1", AudioClip(ByteArray(200) { it.toByte() }))
        store.add(entry("1", createdAt = 100, audioPath = path))

        store.delete("1")

        assertTrue(store.all().isEmpty())
        assertFalse(File(path).exists())
    }

    @Test
    fun clear_wipesEntriesAndAudio() = runTest {
        val store = HistoryStore(dir)
        val path = store.saveAudio("1", AudioClip(ByteArray(200) { it.toByte() }))
        store.add(entry("1", createdAt = 100, audioPath = path))

        store.clear()

        assertTrue(store.all().isEmpty())
        assertFalse(File(path).exists())
    }

    @Test
    fun trim_beyondMax_deletesOldestAndAudio() = runTest {
        val store = HistoryStore(dir, maxEntries = 2)
        val paths = (1..3).map { i ->
            val path = store.saveAudio("$i", AudioClip(ByteArray(10) { i.toByte() }))
            store.add(entry("$i", createdAt = i.toLong() * 100, audioPath = path))
            path
        }

        assertEquals(listOf("3", "2"), store.all().map { it.id })
        assertFalse(File(paths[0]).exists())
        assertTrue(File(paths[1]).exists())
        assertTrue(File(paths[2]).exists())
    }

    @Test
    fun corruptLine_isSkipped() = runTest {
        val store = HistoryStore(dir)
        store.add(entry("1", createdAt = 100))
        File(dir, "history.jsonl").appendText("not json\n")

        val all = store.all()
        assertEquals(1, all.size)
        assertEquals("1", all.first().id)
    }

    @Test
    fun wav_roundTrip() = runTest {
        val store = HistoryStore(dir)
        val pcm = ByteArray(2000) { (it % 256).toByte() }
        val clip = AudioClip(pcm, sampleRate = 16_000)

        val path = store.saveAudio("clip1", clip)
        val loaded = store.loadAudio(path)

        assertNotNull(loaded)
        assertEquals(16_000, loaded!!.sampleRate)
        assertArrayEquals(pcm, loaded.pcm16)
    }

    @Test
    fun loadAudio_missingFile_returnsNull() = runTest {
        val store = HistoryStore(dir)
        assertEquals(null, store.loadAudio(File(dir, "nope.wav").absolutePath))
    }

    /** A chunk size that reads back negative used to leave the parser walking on the spot. */
    @Test(timeout = 5_000)
    fun loadAudio_chunkSizeThatOverflows_returnsNull() = runTest {
        val store = HistoryStore(dir)
        val header = "RIFF".toByteArray() + intLe(120) + "WAVE".toByteArray() +
            "fmt ".toByteArray() + intLe(0xFFFFFFF8.toInt()) + ByteArray(16)
        val file = File(dir, "hostile.wav").apply { writeBytes(header) }

        assertNull(store.loadAudio(file.absolutePath))
    }

    @Test(timeout = 5_000)
    fun loadAudio_truncatedAfterTheHeader_returnsNull() = runTest {
        val store = HistoryStore(dir)
        val full = File(dir, "full.wav")
        val path = store.saveAudio("full", AudioClip(ByteArray(4_000) { it.toByte() }))
        // Keeps the 44-byte header, which still claims 4,000 bytes of samples follow.
        full.writeBytes(File(path).readBytes().copyOfRange(0, 44))

        assertNull(store.loadAudio(full.absolutePath))
    }

    @Test
    fun rewrite_leavesNoTemporaryFileBehind() = runTest {
        val store = HistoryStore(dir)
        store.add(entry("1", createdAt = 100))
        store.add(entry("2", createdAt = 200))

        store.delete("1")
        store.update(entry("2", createdAt = 200, durationMs = 7_777))

        // Names nothing: any staging file left behind at all is the failure.
        assertEquals(listOf("history.jsonl"), dir.listFiles().orEmpty().map { it.name }.sorted())
        assertEquals(listOf("2"), store.all().map { it.id })
        assertEquals(7_777L, store.all().first().durationMs)
        // The reload path has to see the same thing the cache does.
        assertEquals(listOf("2"), HistoryStore(dir).all().map { it.id })
    }

    private fun intLe(value: Int) = ByteArray(4) { (value ushr (8 * it)).toByte() }
}
