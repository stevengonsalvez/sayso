package ai.sayso.dictation.acceptance

import ai.sayso.dictation.core.AudioClip
import ai.sayso.dictation.core.PolishResult
import ai.sayso.dictation.core.Wav
import ai.sayso.dictation.pipeline.FakePolishProvider
import ai.sayso.dictation.voicenotes.AudioSampleSource
import ai.sayso.dictation.voicenotes.ChunkTranscriber
import ai.sayso.dictation.voicenotes.DiskAudioRecorder
import ai.sayso.dictation.voicenotes.DiskRecordResult
import ai.sayso.dictation.voicenotes.SherpaAudioChunker
import ai.sayso.dictation.voicenotes.VoiceNote
import ai.sayso.dictation.voicenotes.VoiceNotesStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * End-to-end acceptance tests for long-form voice notes recording,
 * chunked transcription, and studio lifecycle.
 */
class VoiceNotesStudioAcceptanceTest {

    private lateinit var tempDir: File
    private lateinit var store: VoiceNotesStore

    @Before
    fun setUp() {
        tempDir = Files.createTempDirectory("acceptance-voicenotes").toFile()
        store = VoiceNotesStore(dir = tempDir)
    }

    @After
    fun tearDown() {
        tempDir.deleteRecursively()
    }

    private class ContinuousFakeAudioSource(
        private val samplesPerSecond: Int = 16_000,
        private val totalSeconds: Int = 6,
    ) : AudioSampleSource {
        private var isRunning = false
        private var samplesGenerated = 0
        private val totalSamples = samplesPerSecond * totalSeconds

        override val isAvailable: Boolean = true

        override fun start() {
            isRunning = true
        }

        override fun read(buffer: ByteArray, offset: Int, size: Int): Int {
            if (!isRunning || samplesGenerated >= totalSamples) {
                return 0
            }
            val samplesToRead = minOf(size / 2, totalSamples - samplesGenerated)
            for (i in 0 until samplesToRead) {
                val sampleVal = ((samplesGenerated * 50) % 8000).toShort()
                buffer[offset + (i * 2)] = (sampleVal.toInt() and 0xFF).toByte()
                buffer[offset + (i * 2) + 1] = ((sampleVal.toInt() shr 8) and 0xFF).toByte()
                samplesGenerated++
            }
            return samplesToRead * 2
        }

        override fun stop() {
            isRunning = false
        }

        override fun release() {
            isRunning = false
        }
    }

    @Test
    fun complete_recording_transcription_and_summary_lifecycle() = runBlocking {
        // 1. Arrange: Create note placeholder in store
        val noteId = "note-test-1"
        val audioFile = store.getAudioFile(noteId)
        val initialNote = VoiceNote(
            id = noteId,
            title = "Strategy Meeting",
            createdAt = System.currentTimeMillis(),
            durationMs = 0L,
            audioPath = audioFile.absolutePath,
        )
        store.add(initialNote)

        // 2. Act: Record audio streaming to disk with pause and resume
        val fakeSource = ContinuousFakeAudioSource(totalSeconds = 4)
        val amplitudeHistory = mutableListOf<Float>()
        val tickHistory = mutableListOf<Long>()

        val recorder = DiskAudioRecorder(
            outputFile = audioFile,
            sampleSource = fakeSource,
            onAmplitude = { amplitudeHistory.add(it) },
            onDurationTick = { tickHistory.add(it) },
        )

        var recordResult: DiskRecordResult? = null
        val job = launch(Dispatchers.IO) {
            recordResult = recorder.record()
        }

        delay(100)
        recorder.pause()
        delay(50)
        recorder.resume()
        delay(100)
        recorder.stop()
        job.join()

        // 3. Assert Recording: Valid WAV file created with non-zero samples
        assertNotNull(recordResult)
        assertTrue("WAV file must exist", audioFile.exists())
        assertTrue("WAV file must be > 44 bytes", audioFile.length() > 44)
        assertTrue("Amplitude updates received", amplitudeHistory.isNotEmpty())

        val meta = SherpaAudioChunker.parseWavMetadata(audioFile)
        assertNotNull("WAV metadata must be valid", meta)
        assertEquals(16_000, meta!!.sampleRate)
        assertEquals(1, meta.channels)
        assertEquals(16, meta.bitsPerSample)

        // Update note with recorded duration
        val recordedNote = initialNote.copy(durationMs = recordResult!!.durationMs)
        store.update(recordedNote)

        // 4. Act: Chunked Transcription
        val chunker = SherpaAudioChunker(chunkDurationSec = 30, overlapSec = 2)
        val progressUpdates = mutableListOf<Float>()

        val fakeTranscriber = ChunkTranscriber { _, sampleCount, _ ->
            assertTrue("Chunk must have samples", sampleCount > 0)
            "Quarterly strategic planning discussion with leadership."
        }

        val chunkerResult = chunker.transcribeFile(
            wavFile = audioFile,
            transcriber = fakeTranscriber,
            onProgress = { prog, _, _, _ ->
                progressUpdates.add(prog)
            },
        )

        // 5. Assert Transcription: Monotonic progress, segments created, fullText populated
        assertTrue("Progress reached 1.0", progressUpdates.lastOrNull() == 1.0f)
        assertEquals("Quarterly strategic planning discussion with leadership.", chunkerResult.fullText)
        assertEquals(1, chunkerResult.segments.size)
        assertEquals(0L, chunkerResult.segments[0].startMs)

        val transcribedNote = recordedNote.copy(
            fullText = chunkerResult.fullText,
            segments = chunkerResult.segments,
            isTranscribed = true,
            transcriptionProgress = 1.0f,
        )
        store.update(transcribedNote)

        // 6. Act: AI Summarization
        val polisher = FakePolishProvider(
            result = PolishResult.Success("Key Action: Finalize Q4 strategic hiring and budget."),
        )

        val polishRes = polisher.polish(
            systemPrompt = "You are an executive assistant. Summarize this voice note.",
            userMessage = transcribedNote.fullText,
            modelName = "test-model",
            apiKey = "mock-key",
        )

        assertTrue(polishRes is PolishResult.Success)
        val finalSummary = (polishRes as PolishResult.Success).text

        val finalizedNote = transcribedNote.copy(summary = finalSummary)
        store.update(finalizedNote)

        // 7. Verify persistent state in VoiceNotesStore
        val retrieved = store.get(noteId)
        assertNotNull(retrieved)
        assertEquals("Strategy Meeting", retrieved!!.title)
        assertEquals(chunkerResult.fullText, retrieved.fullText)
        assertEquals(finalSummary, retrieved.summary)
        assertTrue(retrieved.isTranscribed)
        assertEquals(1, retrieved.segments.size)

        // Verify formatted export representation
        val exportedTranscript = buildString {
            appendLine(retrieved.title)
            appendLine("Duration: ${retrieved.durationMs}ms")
            appendLine("AI SUMMARY:\n${retrieved.summary}")
            appendLine("FULL TRANSCRIPT:\n${retrieved.fullText}")
        }
        assertTrue(exportedTranscript.contains("Strategy Meeting"))
        assertTrue(exportedTranscript.contains("Finalize Q4 strategic hiring"))
        assertTrue(exportedTranscript.contains("Quarterly strategic planning"))
    }

    @Test
    fun cancel_recording_cleans_up_audio_and_purges_note() = runBlocking {
        val noteId = "note-to-cancel"
        val audioFile = store.getAudioFile(noteId)
        val note = VoiceNote(
            id = noteId,
            title = "Discarded Draft",
            createdAt = System.currentTimeMillis(),
            durationMs = 0L,
            audioPath = audioFile.absolutePath,
        )
        store.add(note)
        assertTrue("Note added initially", store.all().any { it.id == noteId })

        val fakeSource = ContinuousFakeAudioSource(totalSeconds = 5)
        val recorder = DiskAudioRecorder(
            outputFile = audioFile,
            sampleSource = fakeSource,
        )

        val job = launch(Dispatchers.IO) {
            recorder.record()
        }
        delay(100)

        // User triggers cancel: stop recorder, purge file and delete note from store
        recorder.stop()
        job.join()
        if (audioFile.exists()) {
            audioFile.delete()
        }
        store.delete(noteId)

        // Verify clean cancellation
        assertFalse("Partial audio file must be purged", audioFile.exists())
        assertFalse("Store must not contain cancelled note", store.all().any { it.id == noteId })
    }

    @Test
    fun multi_chunk_boundary_deduplication_assembles_coherent_text() = runTest {
        // Arrange: Create a 70s audio file requiring 3 chunks with 30s window and 2s overlap
        val pcmBytes = ByteArray(70 * 16_000 * 2) { (it % 100).toByte() }
        val wavBytes = Wav.encode(AudioClip(pcmBytes, 16_000))
        val audioFile = File(tempDir, "long_70s.wav").apply { writeBytes(wavBytes) }

        val chunker = SherpaAudioChunker(chunkDurationSec = 30, overlapSec = 2)

        val chunkResponses = listOf(
            "We are introducing Sayso voice notes studio for hands free dictation",
            "hands free dictation with continuous disk streaming and offline AI",
            "offline AI running locally on Android devices without external network",
        )

        var callCount = 0
        val fakeTranscriber = ChunkTranscriber { _, _, _ ->
            val text = chunkResponses.getOrElse(callCount) { "chunk $callCount" }
            callCount++
            text
        }

        val result = chunker.transcribeFile(audioFile, fakeTranscriber)

        assertEquals(3, result.totalChunks)
        assertEquals(3, result.segments.size)

        // Verify seamless boundary stitching without duplicate phrases
        val expectedFullText = "We are introducing Sayso voice notes studio for hands free dictation with continuous disk streaming and offline AI running locally on Android devices without external network"
        assertEquals(expectedFullText, result.fullText)

        // Verify segment timestamps are strictly increasing
        for (i in 0 until result.segments.size - 1) {
            val currSeg = result.segments[i]
            val nextSeg = result.segments[i + 1]
            assertTrue(
                "Segment start time must increase: ${currSeg.startMs} < ${nextSeg.startMs}",
                currSeg.startMs < nextSeg.startMs,
            )
            assertTrue(
                "Segment end time must be after start time: ${currSeg.startMs} < ${currSeg.endMs}",
                currSeg.startMs < currSeg.endMs,
            )
        }
    }

    @Test
    fun search_and_filter_notes_in_store() = runBlocking {
        val note1 = VoiceNote(
            id = "1",
            title = "Doctor consultation",
            createdAt = 1000L,
            durationMs = 60_000L,
            audioPath = "/dummy/1.wav",
            fullText = "Patient complains of headache and fever",
        )
        val note2 = VoiceNote(
            id = "2",
            title = "Sprint Planning",
            createdAt = 2000L,
            durationMs = 120_000L,
            audioPath = "/dummy/2.wav",
            fullText = "Assign tickets for the audio engine refactor",
        )
        val note3 = VoiceNote(
            id = "3",
            title = "Grocery list",
            createdAt = 3000L,
            durationMs = 15_000L,
            audioPath = "/dummy/3.wav",
            fullText = "Milk eggs butter and bread",
        )

        store.add(note1)
        store.add(note2)
        store.add(note3)

        // Default list returns newest first
        val allNotes = store.all()
        assertEquals(listOf("3", "2", "1"), allNotes.map { it.id })

        // Search by title
        val doctorNotes = allNotes.filter { it.title.contains("Doctor", ignoreCase = true) }
        assertEquals(1, doctorNotes.size)
        assertEquals("Doctor consultation", doctorNotes[0].title)

        // Search by transcript body
        val audioNotes = allNotes.filter { it.fullText.contains("audio", ignoreCase = true) }
        assertEquals(1, audioNotes.size)
        assertEquals("Sprint Planning", audioNotes[0].title)

        // Search by non-existent term
        val nonExistent = allNotes.filter { it.fullText.contains("submarine", ignoreCase = true) }
        assertTrue(nonExistent.isEmpty())
    }

    @Test
    fun discard_in_progress_recording_deletes_note_and_audio_cleanly() = runBlocking {
        val noteId = "note-discard-1"
        val audioFile = store.getAudioFile(noteId)
        val initialNote = VoiceNote(
            id = noteId,
            title = "Discarded Recording",
            createdAt = System.currentTimeMillis(),
            durationMs = 0L,
            audioPath = audioFile.absolutePath,
        )
        store.add(initialNote)

        val fakeSource = ContinuousFakeAudioSource(totalSeconds = 2)
        val recorder = DiskAudioRecorder(
            outputFile = audioFile,
            sampleSource = fakeSource,
        )

        val recordJob = launch(Dispatchers.IO) {
            recorder.record()
        }

        delay(50)
        recorder.stop()
        recordJob.cancel()

        store.delete(noteId)
        if (audioFile.exists()) {
            audioFile.delete()
        }

        assertFalse("Discarded note must not exist in store", store.all().any { it.id == noteId })
        assertFalse("Discarded audio file must be deleted", audioFile.exists())
    }
}
