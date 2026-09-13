package com.shotclubhouse.sayso.history

import com.shotclubhouse.sayso.core.HistoryEntry
import com.shotclubhouse.sayso.core.OutputMethod
import org.junit.Assert.assertEquals
import org.junit.Test

class HistoryFilterTest {

    private fun sampleEntry(id: String, raw: String, polished: String?, modelId: String) = HistoryEntry(
        id = id,
        createdAt = System.currentTimeMillis(),
        durationMs = 2000,
        rawText = raw,
        polishedText = polished,
        sttModelId = modelId,
        polishModelId = null,
        outputMethod = OutputMethod.INSERTED,
        error = null,
        audioPath = null,
    )

    private fun filterEntries(entries: List<HistoryEntry>, query: String): List<HistoryEntry> {
        if (query.isBlank()) return entries
        val q = query.trim()
        return entries.filter { entry ->
            entry.finalText.contains(q, ignoreCase = true) ||
                entry.rawText.contains(q, ignoreCase = true) ||
                entry.sttModelId.contains(q, ignoreCase = true)
        }
    }

    @Test
    fun `filters history by transcript text case-insensitively`() {
        val list = listOf(
            sampleEntry("1", "Meeting with Alice at 3pm", null, "openai/whisper-1"),
            sampleEntry("2", "Buy groceries tomorrow morning", null, "local/zipformer"),
            sampleEntry("3", "Schedule doctor appointment", null, "openai/whisper-1"),
        )

        val results = filterEntries(list, "alice")
        assertEquals(1, results.size)
        assertEquals("1", results.first().id)

        val groceries = filterEntries(list, "GROCERIES")
        assertEquals(1, groceries.size)
        assertEquals("2", groceries.first().id)
    }

    @Test
    fun `filters history by model id`() {
        val list = listOf(
            sampleEntry("1", "First dictation", null, "openai/whisper-1"),
            sampleEntry("2", "Second dictation", null, "local/zipformer"),
            sampleEntry("3", "Third dictation", null, "local/zipformer"),
        )

        val localOnly = filterEntries(list, "local")
        assertEquals(2, localOnly.size)
        assertEquals(listOf("2", "3"), localOnly.map { it.id })
    }

    @Test
    fun `blank query returns all entries`() {
        val list = listOf(
            sampleEntry("1", "One", null, "local/model"),
            sampleEntry("2", "Two", null, "local/model"),
        )
        assertEquals(2, filterEntries(list, "").size)
        assertEquals(2, filterEntries(list, "   ").size)
    }
}
