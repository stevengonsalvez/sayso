package com.shotclubhouse.sayso.history

import com.shotclubhouse.sayso.core.AudioClip
import com.shotclubhouse.sayso.core.HistoryEntry
import com.shotclubhouse.sayso.core.HistoryRepository
import com.shotclubhouse.sayso.core.OutputMethod
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

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

    private suspend fun rewrite(entries: List<HistoryEntry>) = withContext(Dispatchers.IO) {
        dir.mkdirs()
        historyFile.writeText(entries.joinToString(separator = "") { line(it) })
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
        writeWav(file, clip)
        file.absolutePath
    }

    override suspend fun loadAudio(path: String): AudioClip? = withContext(Dispatchers.IO) {
        readWav(File(path))
    }
}

// --- Tiny WAV encoder/decoder: PCM16 mono only, 44-byte canonical header. ---

private fun writeWav(file: File, clip: AudioClip) {
    val data = clip.pcm16
    val byteRate = clip.sampleRate * 2 // mono * 16-bit
    val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
        put("RIFF".toByteArray(Charsets.US_ASCII))
        putInt(36 + data.size)
        put("WAVE".toByteArray(Charsets.US_ASCII))
        put("fmt ".toByteArray(Charsets.US_ASCII))
        putInt(16) // fmt chunk size
        putShort(1.toShort()) // PCM
        putShort(1.toShort()) // mono
        putInt(clip.sampleRate)
        putInt(byteRate)
        putShort(2.toShort()) // block align
        putShort(16.toShort()) // bits per sample
        put("data".toByteArray(Charsets.US_ASCII))
        putInt(data.size)
    }.array()
    file.outputStream().use { out ->
        out.write(header)
        out.write(data)
    }
}

private fun readWav(file: File): AudioClip? {
    if (!file.exists()) return null
    val bytes = file.readBytes()
    if (bytes.size < 12 ||
        String(bytes, 0, 4, Charsets.US_ASCII) != "RIFF" ||
        String(bytes, 8, 4, Charsets.US_ASCII) != "WAVE"
    ) return null

    var offset = 12
    var audioFormat = 0
    var channels = 0
    var sampleRate = 0
    var bitsPerSample = 0
    var dataStart = -1
    var dataSize = 0

    while (offset + 8 <= bytes.size) {
        val chunkId = String(bytes, offset, 4, Charsets.US_ASCII)
        val chunkSize = readIntLe(bytes, offset + 4)
        val body = offset + 8
        when (chunkId) {
            "fmt " -> {
                audioFormat = readShortLe(bytes, body)
                channels = readShortLe(bytes, body + 2)
                sampleRate = readIntLe(bytes, body + 4)
                bitsPerSample = readShortLe(bytes, body + 14)
            }
            "data" -> {
                dataStart = body
                dataSize = chunkSize
            }
        }
        offset = body + chunkSize + (chunkSize and 1) // chunks are word-aligned
    }

    if (dataStart < 0 || audioFormat != 1 || channels != 1 || bitsPerSample != 16) return null
    val end = minOf(dataStart + dataSize, bytes.size)
    if (end <= dataStart) return AudioClip(ByteArray(0), sampleRate)
    return AudioClip(bytes.copyOfRange(dataStart, end), sampleRate)
}

private fun readIntLe(b: ByteArray, off: Int): Int =
    (b[off].toInt() and 0xFF) or
        ((b[off + 1].toInt() and 0xFF) shl 8) or
        ((b[off + 2].toInt() and 0xFF) shl 16) or
        ((b[off + 3].toInt() and 0xFF) shl 24)

private fun readShortLe(b: ByteArray, off: Int): Int =
    (b[off].toInt() and 0xFF) or ((b[off + 1].toInt() and 0xFF) shl 8)
