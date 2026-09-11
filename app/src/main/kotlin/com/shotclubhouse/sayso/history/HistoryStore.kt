package com.shotclubhouse.sayso.history

import com.shotclubhouse.sayso.core.AudioClip
import com.shotclubhouse.sayso.core.HistoryEntry
import com.shotclubhouse.sayso.core.HistoryRepository
import com.shotclubhouse.sayso.core.OutputMethod
import com.shotclubhouse.sayso.core.Wav
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * JSON mirror of [HistoryEntry] for kotlinx.serialization: the contract type itself is not
 * annotated, so every entry is converted to/from this shape at the storage boundary.
 */
@Serializable
private data class HistoryEntryJson(
    val id: String,
    val createdAt: Long,
    val durationMs: Long,
    val rawText: String,
    val polishedText: String? = null,
    val sttModelId: String,
    val polishModelId: String? = null,
    val outputMethod: String,
    val error: String? = null,
    val audioPath: String? = null,
)

private fun HistoryEntry.toJson() = HistoryEntryJson(
    id = id,
    createdAt = createdAt,
    durationMs = durationMs,
    rawText = rawText,
    polishedText = polishedText,
    sttModelId = sttModelId,
    polishModelId = polishModelId,
    outputMethod = outputMethod.name,
    error = error,
    audioPath = audioPath,
)

private fun HistoryEntryJson.toEntry() = HistoryEntry(
    id = id,
    createdAt = createdAt,
    durationMs = durationMs,
    rawText = rawText,
    polishedText = polishedText,
    sttModelId = sttModelId,
    polishModelId = polishModelId,
    outputMethod = runCatching { OutputMethod.valueOf(outputMethod) }.getOrDefault(OutputMethod.NONE),
    error = error,
    audioPath = audioPath,
)

private val json = Json { ignoreUnknownKeys = true }

/**
 * File-backed [HistoryRepository]. Entries live one-per-line as JSON in `history.jsonl`
 * (append on add, whole-file rewrite on update/delete/clear/trim); audio clips are saved as
 * WAV files under `audio/<id>.wav`.
 */
class HistoryStore(private val dir: File, private val maxEntries: Int = 500) : HistoryRepository {

    private val historyFile = File(dir, "history.jsonl")
    private val audioDir = File(dir, "audio")
    private val mutex = Mutex()

    // Oldest-first insertion order; null until first touched. Only ever read/written under mutex.
    private var cache: MutableList<HistoryEntry>? = null

    private suspend fun loaded(): MutableList<HistoryEntry> {
        cache?.let { return it }
        val entries = withContext(Dispatchers.IO) {
            if (!historyFile.exists()) return@withContext mutableListOf()
            historyFile.readLines()
                .mapNotNull { line ->
                    if (line.isBlank()) null
                    else runCatching { json.decodeFromString(HistoryEntryJson.serializer(), line).toEntry() }.getOrNull()
                }
                .toMutableList()
        }
        cache = entries
        return entries
    }

    /**
     * Writes the whole file again. A crash part way through a direct write would lose every
     * entry, so the new content is staged beside it and swapped in with one rename.
     */
    private suspend fun rewrite(entries: List<HistoryEntry>) = withContext(Dispatchers.IO) {
        dir.mkdirs()
        val staged = File(dir, historyFile.name + ".tmp")
        staged.writeText(entries.joinToString(separator = "") { line(it) })
        try {
            Files.move(
                staged.toPath(),
                historyFile.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (e: IOException) {
            // Not every filesystem Android mounts supports an atomic move.
            if (!staged.renameTo(historyFile)) {
                historyFile.delete()
                staged.renameTo(historyFile)
            }
        }
        Unit
    }

    private suspend fun appendLine(entry: HistoryEntry) = withContext(Dispatchers.IO) {
        dir.mkdirs()
        historyFile.appendText(line(entry))
    }

    private fun line(entry: HistoryEntry) = json.encodeToString(HistoryEntryJson.serializer(), entry.toJson()) + "\n"

    override suspend fun add(entry: HistoryEntry) = mutex.withLock {
        val entries = loaded()
        entries.add(entry)
        appendLine(entry)
        val overflow = entries.size - maxEntries
        if (overflow > 0) {
            repeat(overflow) {
                val removed = entries.removeAt(0)
                deleteAudio(removed)
            }
            rewrite(entries)
        }
    }

    override suspend fun update(entry: HistoryEntry) = mutex.withLock {
        val entries = loaded()
        val index = entries.indexOfFirst { it.id == entry.id }
        // ponytail: no-op when the id is unknown rather than treating update as upsert; callers
        // always update an entry they previously added.
        if (index < 0) return@withLock
        entries[index] = entry
        rewrite(entries)
    }

    override suspend fun all(): List<HistoryEntry> = mutex.withLock {
        loaded().sortedByDescending { it.createdAt }
    }

    override suspend fun delete(id: String) = mutex.withLock {
        val entries = loaded()
        val index = entries.indexOfFirst { it.id == id }
        if (index < 0) return@withLock
        deleteAudio(entries.removeAt(index))
        rewrite(entries)
    }

    override suspend fun clear(): Unit = mutex.withLock {
        loaded().clear()
        withContext(Dispatchers.IO) {
            historyFile.delete()
            audioDir.deleteRecursively()
            Unit
        }
    }

    private suspend fun deleteAudio(entry: HistoryEntry) {
        val path = entry.audioPath ?: return
        withContext(Dispatchers.IO) { File(path).delete() }
    }

    override suspend fun saveAudio(id: String, clip: AudioClip): String = withContext(Dispatchers.IO) {
        audioDir.mkdirs()
        val file = File(audioDir, "$id.wav")
        file.writeBytes(Wav.encode(clip))
        file.absolutePath
    }

    override suspend fun loadAudio(path: String): AudioClip? = withContext(Dispatchers.IO) {
        val file = File(path)
        if (!file.isFile) return@withContext null
        Wav.decode(file.readBytes())
    }
}

