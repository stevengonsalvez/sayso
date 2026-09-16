package ai.sayso.dictation.polish

import ai.sayso.dictation.core.PolishModel
import ai.sayso.dictation.core.PolishProvider

/** Every cleanup backend the app ships with, keyed by the "<provider>/<model>" id scheme. */
class PolishRegistry {

    val providers: List<PolishProvider> = listOf(
        LocalRulesPolisher,
        LocalSlmPolisher,
        OpenAiPolisher(),
        AnthropicPolisher(),
        GroqPolisher(),
        GeminiPolisher(),
        OpenRouterPolisher(),
    )

    fun provider(id: String): PolishProvider? = providers.firstOrNull { it.id == id }

    fun allModels(): List<PolishModel> = providers.flatMap { it.models }

    fun find(modelId: String): Pair<PolishProvider, PolishModel>? {
        val provider = provider(modelId.substringBefore('/')) ?: return null
        val model = provider.models.firstOrNull { it.id == modelId } ?: return null
        return provider to model
    }

    companion object {
        const val defaultModelId = "rules/basic"
    }
}
