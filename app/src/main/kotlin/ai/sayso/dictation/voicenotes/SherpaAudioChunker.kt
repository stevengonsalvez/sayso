package ai.sayso.dictation.voicenotes

import ai.sayso.dictation.core.AudioClip
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.ceil

/**
 * Interface for transcribing an audio chunk represented by in-memory float samples.
 */
fun interface ChunkTranscriber {
    suspend fun transcribeChunk(
        samples: FloatArray,
        sampleCount: Int,
        sampleRate: Int,
    ): String?
}

/**
 * Result returned after chunked streaming transcription completes.
 */
data class ChunkerResult(
    val fullText: String,
    val segments: List<VoiceNoteSegment>,
    val totalDurationMs: Long,
    val totalChunks: Int,
)

/**
 * Streaming audio chunker and stitcher for Sherpa-ONNX.
 *
 * Slices arbitrary-length WAV files from disk into 30-45s chunks with 2s overlap
 * using fixed, reusable ByteArray and FloatArray buffers to ensure RAM consumption
 * stays below 50 MB regardless of file duration. Adjusts segment timestamps and
 * stitches boundaries without word duplication.
 */
class SherpaAudioChunker(
    val chunkDurationSec: Int = DEFAULT_CHUNK_DURATION_SEC,
    val overlapSec: Int = DEFAULT_OVERLAP_SEC,
) {

    suspend fun transcribeFile(
        wavFile: File,
        transcriber: ChunkTranscriber,
        onProgress: ((progress: Float, currentChunk: Int, totalChunks: Int, segments: List<VoiceNoteSegment>) -> Unit)? = null,
    ): ChunkerResult = withContext(Dispatchers.IO) {
        if (!wavFile.exists() || wavFile.length() < 44) {
            return@withContext ChunkerResult("", emptyList(), 0L, 0)
        }

        val meta = parseWavMetadata(wavFile)
            ?: return@withContext ChunkerResult("", emptyList(), 0L, 0)

        val bytesPerSample = (meta.bitsPerSample / 8) * meta.channels
        val bytesPerSec = meta.sampleRate * bytesPerSample
        val totalDurationMs = meta.dataLength * 1000L / bytesPerSec

        val windowBytes = chunkDurationSec * bytesPerSec
        val overlapBytes = overlapSec * bytesPerSec
        val stepBytes = maxOf(bytesPerSec, windowBytes - overlapBytes)

        val totalChunks = if (meta.dataLength <= windowBytes) {
            1
        } else {
            val extraBytes = meta.dataLength - windowBytes
            ceil(extraBytes.toDouble() / stepBytes).toInt() + 1
        }

        // Fixed reusable memory buffers: allocated once, reused across all chunks.
        // Memory footprint: ~960 KB (rawBuffer) + ~1.92 MB (floatBuffer) < 3 MB total.
        val windowSamples = windowBytes / bytesPerSample
        val rawBuffer = ByteArray(windowBytes)
        val floatBuffer = FloatArray(windowSamples)

        val segments = mutableListOf<VoiceNoteSegment>()
        val textPieces = mutableListOf<String>()

        RandomAccessFile(wavFile, "r").use { raf ->
            for (chunkIndex in 0 until totalChunks) {
                currentCoroutineContext().ensureActive()

                val fileOffset = meta.dataOffset + (chunkIndex.toLong() * stepBytes)
                if (fileOffset >= meta.dataOffset + meta.dataLength) break

                raf.seek(fileOffset)
                val remainingBytes = (meta.dataOffset + meta.dataLength - fileOffset).toInt()
                val bytesToRead = minOf(windowBytes, remainingBytes)
                val readBytes = raf.read(rawBuffer, 0, bytesToRead)
                if (readBytes <= 0) break

                val sampleCount = readBytes / bytesPerSample
                // In-place conversion from 16-bit PCM bytes to normalized float samples [-1.0, 1.0]
                for (i in 0 until sampleCount) {
                    val low = rawBuffer[i * bytesPerSample].toInt() and 0xFF
                    val high = rawBuffer[i * bytesPerSample + 1].toInt()
                    floatBuffer[i] = ((high shl 8) or low).toShort() / 32768.0f
                }

                val chunkStartMs = (chunkIndex.toLong() * (chunkDurationSec - overlapSec) * 1000L).coerceAtLeast(0L)
                val chunkEndMs = minOf(chunkStartMs + (readBytes * 1000L / bytesPerSec), totalDurationMs)

                val chunkRawText = transcriber.transcribeChunk(floatBuffer, sampleCount, meta.sampleRate)?.trim().orEmpty()

                if (chunkRawText.isNotBlank()) {
                    val previousText = textPieces.lastOrNull().orEmpty()
                    val cleanedText = deduplicateOverlap(previousText, chunkRawText)

                    if (cleanedText.isNotBlank()) {
                        textPieces.add(cleanedText)
                        val segment = VoiceNoteSegment(
                            startMs = chunkStartMs,
                            endMs = chunkEndMs,
                            text = cleanedText,
                        )
                        segments.add(segment)
                    }
                }

                val progress = (chunkIndex + 1).toFloat() / totalChunks
                onProgress?.invoke(progress, chunkIndex + 1, totalChunks, segments.toList())
            }
        }

        val fullText = textPieces.joinToString(separator = " ").trim()
        ChunkerResult(
            fullText = fullText,
            segments = segments,
            totalDurationMs = totalDurationMs,
            totalChunks = totalChunks,
        )
    }

    companion object {
        const val DEFAULT_CHUNK_DURATION_SEC = 30
        const val DEFAULT_OVERLAP_SEC = 2

        data class WavMeta(
            val sampleRate: Int,
            val channels: Int,
            val bitsPerSample: Int,
            val dataOffset: Long,
            val dataLength: Long,
        )

        fun parseWavMetadata(file: File): WavMeta? {
            if (!file.exists() || file.length() < 44) return null
            RandomAccessFile(file, "r").use { raf ->
                val header = ByteArray(12)
                raf.readFully(header)
                if (readAscii(header, 0) != "RIFF" || readAscii(header, 8) != "WAVE") return null

                var sampleRate = AudioClip.DEFAULT_SAMPLE_RATE
                var channels = 1
                var bitsPerSample = 16
                var dataOffset = -1L
                var dataLength = -1L

                var offset = 12L
                val fileLen = raf.length()
                val chunkHeader = ByteArray(8)

                while (offset + 8 <= fileLen) {
                    raf.seek(offset)
                    raf.readFully(chunkHeader)
                    val id = readAscii(chunkHeader, 0)
                    val size = readInt32(chunkHeader, 4).toLong() and 0xFFFFFFFFL
                    val body = offset + 8

                    when (id) {
                        "fmt " -> {
                            val fmt = ByteArray(16)
                            raf.seek(body)
                            raf.readFully(fmt)
                            channels = readInt16(fmt, 2)
                            sampleRate = readInt32(fmt, 4)
                            bitsPerSample = readInt16(fmt, 14)
                        }
                        "data" -> {
                            dataOffset = body
                            dataLength = minOf(size, fileLen - body)
                            break
                        }
                    }
                    val next = body + size + (size and 1L)
                    if (next <= offset) break
                    offset = next
                }

                if (dataOffset < 0 || dataLength <= 0) return null
                return WavMeta(
                    sampleRate = sampleRate,
                    channels = channels,
                    bitsPerSample = bitsPerSample,
                    dataOffset = dataOffset,
                    dataLength = dataLength,
                )
            }
        }

        /**
         * De-duplicates overlapping boundary text between consecutive chunks.
         * Looks for an exact or normalized sequence of words from the end of [previousText]
         * that repeats at the start of [currentText] and removes that duplicate prefix.
         */
        fun deduplicateOverlap(
            previousText: String,
            currentText: String,
            maxOverlapWords: Int = 8,
        ): String {
            if (previousText.isBlank() || currentText.isBlank()) return currentText

            val prevWords = previousText.trim().split(Regex("\\s+"))
            val currWords = currentText.trim().split(Regex("\\s+"))

            val maxCheck = minOf(maxOverlapWords, prevWords.size, currWords.size)
            for (k in maxCheck downTo 1) {
                val prevSuffix = prevWords.takeLast(k).map { normalizeWord(it) }
                val currPrefix = currWords.take(k).map { normalizeWord(it) }

                if (prevSuffix == currPrefix) {
                    // Match found: drop the first k words from currentText
                    return currWords.drop(k).joinToString(separator = " ")
                }
            }

            return currentText
        }

        private fun normalizeWord(word: String): String =
            word.lowercase().replace(Regex("[^a-z0-9]"), "")

        private fun readAscii(bytes: ByteArray, at: Int): String =
            String(bytes, at, 4, Charsets.US_ASCII)

        private fun readInt32(bytes: ByteArray, at: Int): Int {
            var value = 0
            for (i in 0 until 4) value = value or ((bytes[at + i].toInt() and 0xFF) shl (8 * i))
            return value
        }

        private fun readInt16(bytes: ByteArray, at: Int): Int {
            var value = 0
            for (i in 0 until 2) value = value or ((bytes[at + i].toInt() and 0xFF) shl (8 * i))
            return value
        }
    }
}
