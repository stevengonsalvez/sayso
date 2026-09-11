package com.shotclubhouse.sayso.polish

import com.shotclubhouse.sayso.core.ApiKeys
import com.shotclubhouse.sayso.core.PolishModel
import com.shotclubhouse.sayso.core.PolishProvider
import com.shotclubhouse.sayso.core.PolishResult
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import okhttp3.Request

class AnthropicPolisher(baseUrl: String = "https://api.anthropic.com/v1") : PolishProvider {

    private val endpoint = "${PolishHttp.normalise(baseUrl)}/messages"

    override val id = "anthropic"
    override val displayName = "Anthropic"
    override val needsApiKey = true
    override val apiKeyUrl = "https://console.anthropic.com/settings/keys"
    override val supportsCustomPrompt = true
    override val models = listOf(
        PolishModel("anthropic/claude-haiku-4-5", "Claude Haiku 4.5"),
        PolishModel("anthropic/claude-sonnet-4-5", "Claude Sonnet 4.5"),
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
            put("model", modelName)
            put("max_tokens", MAX_TOKENS)
            put("system", systemPrompt)
            putJsonArray("messages") {
                addJsonObject {
                    put("role", "user")
                    put("content", userMessage)
                }
            }
        }

        val request = Request.Builder()
            .url(endpoint)
            .header("x-api-key", apiKey)
            .header("anthropic-version", ANTHROPIC_VERSION)
            .post(PolishHttp.body(payload))
            .build()

        return PolishHttp.call(request) { root ->
            PolishHttp.string(PolishHttp.firstObject(root["content"])?.get("text"))
        }
    }

    private companion object {
        const val MAX_TOKENS = 2048
        const val ANTHROPIC_VERSION = "2023-06-01"
    }
}
