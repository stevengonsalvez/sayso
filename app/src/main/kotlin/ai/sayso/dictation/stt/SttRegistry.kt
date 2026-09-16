package ai.sayso.dictation.stt

import ai.sayso.dictation.core.SttModel
import ai.sayso.dictation.core.TranscriptionProvider

/** The set of speech-to-text backends the app offers, and lookup by model id. */
class SttRegistry(local: LocalSherpaProvider) {
    val providers: List<TranscriptionProvider> = listOf(
        local,
        OpenAiProvider(),
        DeepgramProvider(),
        GroqProvider(),
        ElevenLabsProvider(),
        GeminiProvider(),
    )

    fun provider(id: String): TranscriptionProvider? = providers.firstOrNull { it.id == id }

    fun find(modelId: String): Pair<TranscriptionProvider, SttModel>? {
        val provider = provider(modelId.substringBefore('/')) ?: return null
        val model = provider.models.firstOrNull { it.id == modelId } ?: return null
        return provider to model
    }
}
