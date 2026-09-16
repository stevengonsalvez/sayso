package ai.sayso.dictation.polish

import ai.sayso.dictation.core.ApiKeys
import ai.sayso.dictation.core.PolishModel
import ai.sayso.dictation.core.PolishProvider
import ai.sayso.dictation.core.PolishResult
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.Request

class GeminiPolisher(baseUrl: String = "https://generativelanguage.googleapis.com/v1beta") : PolishProvider {

    private val base = PolishHttp.normalise(baseUrl)

    override val id = "gemini"
    override val displayName = "Google Gemini"
    override val needsApiKey = true
    override val apiKeyUrl = "https://aistudio.google.com/app/apikey"
    override val supportsCustomPrompt = true
    override val models = listOf(
        PolishModel("gemini/gemini-2.5-flash", "Gemini 2.5 Flash"),
        PolishModel("gemini/gemini-2.5-flash-lite", "Gemini 2.5 Flash Lite"),
    )

    override suspend fun polish(
        systemPrompt: String,
        userMessage: String,
        modelName: String,
        apiKey: String?,
    ): PolishResult {
        if (apiKey.isNullOrBlank()) return PolishResult.Failure(ApiKeys.missing(displayName))
        if (!ApiKeys.isSendable(apiKey)) return PolishResult.Failure(ApiKeys.UNSUPPORTED)

        val payload = buildJsonObject {
            putJsonObject("systemInstruction") {
                putJsonArray("parts") { addJsonObject { put("text", systemPrompt) } }
            }
            putJsonArray("contents") {
                addJsonObject {
                    put("role", "user")
                    putJsonArray("parts") { addJsonObject { put("text", userMessage) } }
                }
            }
            putJsonObject("generationConfig") { put("temperature", 0) }
        }

        val request = Request.Builder()
            .url("$base/models/$modelName:generateContent")
            .header("x-goog-api-key", apiKey)
            .post(PolishHttp.body(payload))
            .build()

        return PolishHttp.call(request) { root ->
            val content = PolishHttp.firstObject(root["candidates"])?.get("content") as? JsonObject
            PolishHttp.string(PolishHttp.firstObject(content?.get("parts"))?.get("text"))
        }
    }
}
