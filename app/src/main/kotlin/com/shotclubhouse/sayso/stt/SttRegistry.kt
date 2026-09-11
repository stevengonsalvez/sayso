package com.shotclubhouse.sayso.stt

import com.shotclubhouse.sayso.core.SttModel
import com.shotclubhouse.sayso.core.TranscriptionProvider
import com.shotclubhouse.sayso.models.LocalModelCatalog

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

    val defaultModelId: String = "local/${LocalModelCatalog.default.dirName}"

    fun provider(id: String): TranscriptionProvider? = providers.firstOrNull { it.id == id }

    fun allModels(): List<SttModel> = providers.flatMap { it.models }

    fun find(modelId: String): Pair<TranscriptionProvider, SttModel>? {
        val provider = provider(modelId.substringBefore('/')) ?: return null
        val model = provider.models.firstOrNull { it.id == modelId } ?: return null
        return provider to model
    }
}
