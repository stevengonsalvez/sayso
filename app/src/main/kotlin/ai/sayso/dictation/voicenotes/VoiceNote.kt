package ai.sayso.dictation.voicenotes

import kotlinx.serialization.Serializable

/**
 * A single timestamped segment within a voice note transcription.
 */
@Serializable
data class VoiceNoteSegment(
    val id: String = java.util.UUID.randomUUID().toString(),
    val startMs: Long,
    val endMs: Long,
    val text: String,
)

/**
 * Represents a long-form voice note, its audio recording file, timestamped transcript segments,
 * and optional AI summarization.
 */
@Serializable
data class VoiceNote(
    val id: String = java.util.UUID.randomUUID().toString(),
    val title: String,
    val createdAt: Long = System.currentTimeMillis(),
    val durationMs: Long = 0L,
    val audioPath: String,
    val fullText: String = "",
    val segments: List<VoiceNoteSegment> = emptyList(),
    val summary: String? = null,
    val isTranscribed: Boolean = false,
    val transcriptionProgress: Float = 0f,
    val modelUsed: String? = null,
)
