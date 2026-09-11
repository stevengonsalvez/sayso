package com.shotclubhouse.sayso.polish

import com.shotclubhouse.sayso.core.PolishModel
import com.shotclubhouse.sayso.core.PolishProvider
import com.shotclubhouse.sayso.core.PolishResult
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import okhttp3.Request

/** Any `/chat/completions` endpoint: OpenAI, Groq, OpenRouter. */
class OpenAiCompatPolisher(
    override val id: String,
    override val displayName: String,
    override val models: List<PolishModel>,
    override val apiKeyUrl: String?,
    baseUrl: String,
) : PolishProvider {

    private val endpoint = "${PolishHttp.normalise(baseUrl)}/chat/completions"

    override val needsApiKey = true
    override val supportsCustomPrompt = true

    override suspend fun polish(
        systemPrompt: String,
        userMessage: String,
        modelName: String,
        apiKey: String?,
    ): PolishResult {
        if (apiKey.isNullOrBlank()) return missingKey(displayName)
        if (!isSendableKey(apiKey)) return unsendableKey(displayName)

        val payload = buildJsonObject {
            put("model", modelName)
            putJsonArray("messages") {
                addJsonObject {
                    put("role", "system")
                    put("content", systemPrompt)
                }
                addJsonObject {
                    put("role", "user")
                    put("content", userMessage)
                }
            }
            put("temperature", 0)
        }

        val request = Request.Builder()
            .url(endpoint)
            .header("Authorization", "Bearer $apiKey")
            .post(PolishHttp.body(payload))
            .build()

        return PolishHttp.call(request) { root ->
            val message = PolishHttp.firstObject(root["choices"])?.get("message")
            PolishHttp.string((message as? JsonObject)?.get("content"))
        }
    }
}

fun OpenAiPolisher(baseUrl: String = "https://api.openai.com/v1") = OpenAiCompatPolisher(
    id = "openai",
    displayName = "OpenAI",
    models = listOf(
        PolishModel("openai/gpt-4.1-mini", "GPT-4.1 mini"),
        PolishModel("openai/gpt-4.1-nano", "GPT-4.1 nano"),
        PolishModel("openai/gpt-4o-mini", "GPT-4o mini"),
    ),
    apiKeyUrl = "https://platform.openai.com/api-keys",
    baseUrl = baseUrl,
)

fun GroqPolisher(baseUrl: String = "https://api.groq.com/openai/v1") = OpenAiCompatPolisher(
    id = "groq",
    displayName = "Groq",
    models = listOf(
        PolishModel("groq/llama-3.3-70b-versatile", "Llama 3.3 70B"),
        PolishModel("groq/llama-3.1-8b-instant", "Llama 3.1 8B instant"),
    ),
    apiKeyUrl = "https://console.groq.com/keys",
    baseUrl = baseUrl,
)

fun OpenRouterPolisher(baseUrl: String = "https://openrouter.ai/api/v1") = OpenAiCompatPolisher(
    id = "openrouter",
    displayName = "OpenRouter",
    models = listOf(
        PolishModel("openrouter/anthropic/claude-haiku-4.5", "Claude Haiku 4.5"),
        PolishModel("openrouter/openai/gpt-4.1-mini", "GPT-4.1 mini"),
        PolishModel("openrouter/google/gemini-2.5-flash", "Gemini 2.5 Flash"),
    ),
    apiKeyUrl = "https://openrouter.ai/keys",
    baseUrl = baseUrl,
)
