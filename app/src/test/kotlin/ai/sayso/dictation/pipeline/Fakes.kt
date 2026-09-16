package ai.sayso.dictation.pipeline

import ai.sayso.dictation.core.AudioClip
import ai.sayso.dictation.core.HistoryEntry
import ai.sayso.dictation.core.HistoryRepository
import ai.sayso.dictation.core.PolishModel
import ai.sayso.dictation.core.PolishProvider
import ai.sayso.dictation.core.PolishResult
import ai.sayso.dictation.core.SttModel
import ai.sayso.dictation.core.TranscriptionProvider
import ai.sayso.dictation.core.TranscriptionRequest
import ai.sayso.dictation.core.TranscriptionResult

class FakeSttProvider(
    override val id: String,
    override val needsApiKey: Boolean,
    private val result: TranscriptionResult = TranscriptionResult.Success("hello"),
    private val throws: Boolean = false,
) : TranscriptionProvider {
    override val displayName = id
    override val apiKeyUrl: String? = if (needsApiKey) "https://example.test/keys" else null
    override val models = listOf(SttModel("$id/model", "$id model"))

    var calls = 0
        private set
    var lastRequest: TranscriptionRequest? = null
        private set
    var lastKey: String? = null
        private set

    override suspend fun transcribe(request: TranscriptionRequest, apiKey: String?): TranscriptionResult {
        calls++
        lastRequest = request
        lastKey = apiKey
        if (throws) throw IllegalStateException("boom")
        return result
    }
}

class FakePolishProvider(
    override val id: String = "fake-polish",
    override val needsApiKey: Boolean = true,
    override val supportsCustomPrompt: Boolean = true,
    private val result: PolishResult = PolishResult.Success("Polished."),
) : PolishProvider {
    override val displayName = id
    override val apiKeyUrl: String? = if (needsApiKey) "https://example.test/keys" else null
    override val models = listOf(PolishModel("$id/model", "$id model"))

    var calls = 0
        private set
    var lastSystemPrompt: String? = null
        private set
    var lastUserMessage: String? = null
        private set

    override suspend fun polish(
        systemPrompt: String,
        userMessage: String,
        modelName: String,
        apiKey: String?,
    ): PolishResult {
        calls++
        lastSystemPrompt = systemPrompt
        lastUserMessage = userMessage
        return result
    }
}

class FakeSttCatalog(
    private val providers: List<TranscriptionProvider>,
    override val localFallbackModelId: String? = null,
) : SttCatalog {
    override fun find(modelId: String): Pair<TranscriptionProvider, SttModel>? {
        val provider = providers.firstOrNull { it.id == modelId.substringBefore('/') } ?: return null
        val model = provider.models.firstOrNull { it.id == modelId } ?: return null
        return provider to model
    }
}

class FakePolishCatalog(private val providers: List<PolishProvider>) : PolishCatalog {
    override fun find(modelId: String): Pair<PolishProvider, PolishModel>? {
        val provider = providers.firstOrNull { it.id == modelId.substringBefore('/') } ?: return null
        val model = provider.models.firstOrNull { it.id == modelId } ?: return null
        return provider to model
    }
}

class FakeHistory(private val failSaveAudio: Boolean = false) : HistoryRepository {
    val added = mutableListOf<HistoryEntry>()
    val updated = mutableListOf<HistoryEntry>()
    val savedAudio = mutableListOf<Pair<String, AudioClip>>()
    var storedClip: AudioClip? = null

    override suspend fun add(entry: HistoryEntry) {
        added += entry
    }

    override suspend fun update(entry: HistoryEntry) {
        updated += entry
    }

    override suspend fun all(): List<HistoryEntry> = added

    override suspend fun delete(id: String) {
        added.removeAll { it.id == id }
    }

    override suspend fun clear() {
        added.clear()
    }

    override suspend fun saveAudio(id: String, clip: AudioClip): String {
        if (failSaveAudio) throw java.io.IOException("disk full")
        savedAudio += id to clip
        return "/tmp/sayso/$id.wav"
    }

    override suspend fun loadAudio(path: String): AudioClip? = storedClip
}
