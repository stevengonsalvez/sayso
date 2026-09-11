package com.shotclubhouse.sayso.history

import com.shotclubhouse.sayso.core.AudioClip
import com.shotclubhouse.sayso.core.HistoryEntry
import com.shotclubhouse.sayso.core.OutputMethod
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
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
}
