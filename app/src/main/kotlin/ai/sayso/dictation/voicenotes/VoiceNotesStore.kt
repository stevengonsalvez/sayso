package ai.sayso.dictation.voicenotes

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

interface VoiceNotesRepository {
    suspend fun add(note: VoiceNote)
    suspend fun update(note: VoiceNote)
    suspend fun all(): List<VoiceNote>
    suspend fun get(id: String): VoiceNote?
    suspend fun delete(id: String)
    suspend fun clear()
    suspend fun getAudioFile(id: String): File
}

private val json = Json { ignoreUnknownKeys = true }

/**
 * File-backed [VoiceNotesRepository].
 * Voice note metadata is serialized line-by-line in `notes.jsonl`.
 * Audio files live in `audio/<id>.wav`.
 */
class VoiceNotesStore(
    private val dir: File,
    private val maxNotes: Int = 1000,
) : VoiceNotesRepository {

    private val notesFile = File(dir, "notes.jsonl")
    val audioDir = File(dir, "audio")
    private val mutex = Mutex()

    private var cache: MutableList<VoiceNote>? = null

    private suspend fun loaded(): MutableList<VoiceNote> {
        cache?.let { return it }
        val notes = withContext(Dispatchers.IO) {
            if (!notesFile.exists()) return@withContext mutableListOf()
            notesFile.readLines()
                .mapNotNull { line ->
                    if (line.isBlank()) null
                    else runCatching { json.decodeFromString<VoiceNote>(line) }.getOrNull()
                }
                .toMutableList()
        }
        cache = notes
        return notes
    }

    private suspend fun rewrite(notes: List<VoiceNote>) = withContext(Dispatchers.IO) {
        dir.mkdirs()
        val staged = File(dir, notesFile.name + ".tmp")
        staged.writeText(notes.joinToString(separator = "") { line(it) })
        try {
            Files.move(
                staged.toPath(),
                notesFile.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (e: IOException) {
            if (!staged.renameTo(notesFile)) {
                notesFile.delete()
                staged.renameTo(notesFile)
            }
        }
    }

    private suspend fun appendLine(note: VoiceNote) = withContext(Dispatchers.IO) {
        dir.mkdirs()
        notesFile.appendText(line(note))
    }

    private fun line(note: VoiceNote): String =
        json.encodeToString(VoiceNote.serializer(), note) + "\n"

    override suspend fun add(note: VoiceNote) = mutex.withLock {
        val notes = loaded()
        notes.add(note)
        appendLine(note)
        val overflow = notes.size - maxNotes
        if (overflow > 0) {
            repeat(overflow) {
                val removed = notes.removeAt(0)
                deleteAudio(removed)
            }
            rewrite(notes)
        }
    }

    override suspend fun update(note: VoiceNote) = mutex.withLock {
        val notes = loaded()
        val index = notes.indexOfFirst { it.id == note.id }
        if (index < 0) return@withLock
        notes[index] = note
        rewrite(notes)
    }

    override suspend fun all(): List<VoiceNote> = mutex.withLock {
        loaded().sortedByDescending { it.createdAt }
    }

    override suspend fun get(id: String): VoiceNote? = mutex.withLock {
        loaded().firstOrNull { it.id == id }
    }

    override suspend fun delete(id: String) = mutex.withLock {
        val notes = loaded()
        val index = notes.indexOfFirst { it.id == id }
        if (index < 0) return@withLock
        deleteAudio(notes.removeAt(index))
        rewrite(notes)
    }

    override suspend fun clear(): Unit = mutex.withLock {
        loaded().clear()
        withContext(Dispatchers.IO) {
            notesFile.delete()
            audioDir.deleteRecursively()
        }
    }

    override suspend fun getAudioFile(id: String): File = withContext(Dispatchers.IO) {
        audioDir.mkdirs()
        File(audioDir, "$id.wav")
    }

    private suspend fun deleteAudio(note: VoiceNote) {
        withContext(Dispatchers.IO) {
            val file = File(note.audioPath)
            if (file.exists()) file.delete()
        }
    }
}
