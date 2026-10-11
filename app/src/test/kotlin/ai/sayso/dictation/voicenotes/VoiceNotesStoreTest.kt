package ai.sayso.dictation.voicenotes

import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

class VoiceNotesStoreTest {

    private lateinit var dir: File

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("voice-notes-test").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun sampleNote(
        id: String,
        title: String = "Test Note",
        createdAt: Long = 1_000L,
        durationMs: Long = 60_000L,
        audioPath: String = "",
        segments: List<VoiceNoteSegment> = emptyList(),
    ) = VoiceNote(
        id = id,
        title = title,
        createdAt = createdAt,
        durationMs = durationMs,
        audioPath = audioPath,
        fullText = segments.joinToString(" ") { it.text },
        segments = segments,
        summary = null,
        isTranscribed = segments.isNotEmpty(),
    )

    @Test
    fun add_and_all_ordersDescendingByCreatedAt() = runTest {
        val store = VoiceNotesStore(dir)
        store.add(sampleNote("1", createdAt = 100))
        store.add(sampleNote("2", createdAt = 300))
        store.add(sampleNote("3", createdAt = 200))

        val all = store.all()
        assertEquals(listOf("2", "3", "1"), all.map { it.id })
    }

    @Test
    fun get_returnsCorrectNoteById() = runTest {
        val store = VoiceNotesStore(dir)
        store.add(sampleNote("n1", title = "First"))
        store.add(sampleNote("n2", title = "Second"))

        val found = store.get("n2")
        assertNotNull(found)
        assertEquals("Second", found?.title)
        assertNull(store.get("missing"))
    }

    @Test
    fun update_replacesExistingNote() = runTest {
        val store = VoiceNotesStore(dir)
        store.add(sampleNote("1", title = "Old Title"))
        val updated = sampleNote("1", title = "New Title", durationMs = 120_000L)
        store.update(updated)

        val found = store.get("1")
        assertEquals("New Title", found?.title)
        assertEquals(120_000L, found?.durationMs)
    }

    @Test
    fun delete_removesNoteAndAudioFile() = runTest {
        val store = VoiceNotesStore(dir)
        val audioFile = store.getAudioFile("1").apply {
            writeBytes(ByteArray(128))
        }
        store.add(sampleNote("1", audioPath = audioFile.absolutePath))

        assertTrue(audioFile.exists())
        store.delete("1")

        assertTrue(store.all().isEmpty())
        assertFalse(audioFile.exists())
    }

    @Test
    fun clear_removesAllNotesAndAudio() = runTest {
        val store = VoiceNotesStore(dir)
        val a1 = store.getAudioFile("1").apply { writeBytes(ByteArray(64)) }
        val a2 = store.getAudioFile("2").apply { writeBytes(ByteArray(64)) }
        store.add(sampleNote("1", audioPath = a1.absolutePath))
        store.add(sampleNote("2", audioPath = a2.absolutePath))

        store.clear()

        assertTrue(store.all().isEmpty())
        assertFalse(a1.exists())
        assertFalse(a2.exists())
    }

    @Test
    fun trimming_beyondMaxNotes_removesOldestAndDeletesAudio() = runTest {
        val store = VoiceNotesStore(dir, maxNotes = 2)
        val a1 = store.getAudioFile("1").apply { writeBytes(ByteArray(64)) }
        val a2 = store.getAudioFile("2").apply { writeBytes(ByteArray(64)) }
        val a3 = store.getAudioFile("3").apply { writeBytes(ByteArray(64)) }

        store.add(sampleNote("1", createdAt = 100, audioPath = a1.absolutePath))
        store.add(sampleNote("2", createdAt = 200, audioPath = a2.absolutePath))
        store.add(sampleNote("3", createdAt = 300, audioPath = a3.absolutePath))

        val all = store.all()
        assertEquals(listOf("3", "2"), all.map { it.id })
        assertFalse(a1.exists())
        assertTrue(a2.exists())
        assertTrue(a3.exists())
    }

    @Test
    fun segment_serialization_roundTrip() = runTest {
        val store = VoiceNotesStore(dir)
        val segments = listOf(
            VoiceNoteSegment(id = "s1", startMs = 0, endMs = 30_000, text = "Hello and welcome."),
            VoiceNoteSegment(id = "s2", startMs = 28_000, endMs = 60_000, text = "This is a long test recording."),
        )
        val note = sampleNote("seg-note", segments = segments)
        store.add(note)

        // Reload fresh from disk
        val freshStore = VoiceNotesStore(dir)
        val loaded = freshStore.get("seg-note")
        assertNotNull(loaded)
        assertEquals(2, loaded?.segments?.size)
        assertEquals("Hello and welcome.", loaded?.segments?.get(0)?.text)
        assertEquals(30_000L, loaded?.segments?.get(0)?.endMs)
        assertEquals("This is a long test recording.", loaded?.segments?.get(1)?.text)
    }
}
