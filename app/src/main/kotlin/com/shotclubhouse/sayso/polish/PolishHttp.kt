package com.shotclubhouse.sayso.polish

import com.shotclubhouse.sayso.core.PolishResult
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody

/** Shared plumbing for the cloud cleanup providers: one client, one error convention. */
internal object PolishHttp {

    val json = Json { ignoreUnknownKeys = true }

    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

    val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .callTimeout(90, TimeUnit.SECONDS)
            // An API key rides in a header; a redirect would hand it to another host.
            .followRedirects(false)
            .followSslRedirects(false)
            .build()
    }

    fun body(payload: JsonObject): RequestBody = payload.toString().toRequestBody(jsonMediaType)

    /** Trailing slashes vary between hardcoded bases and test server URLs. */
    fun normalise(baseUrl: String): String = baseUrl.trimEnd('/')

    /**
     * Runs [request], maps transport and HTTP problems to [PolishResult.Failure], and passes a
     * successful body to [extract]. Never throws.
     */
    suspend fun call(request: Request, extract: (JsonObject) -> String?): PolishResult =
        withContext(Dispatchers.IO) {
            try {
                client.newCall(request).execute().use { response ->
                    val raw = response.peekBody(MAX_BODY_BYTES).string()
                    if (!response.isSuccessful) {
                        return@use PolishResult.Failure(errorMessage(response.code, raw))
                    }
                    val root = parse(raw) as? JsonObject
                        ?: return@use PolishResult.Failure("Unexpected response from server")
                    val text = extract(root)
                    if (text.isNullOrBlank()) {
                        PolishResult.Failure("Cleanup model returned no text")
                    } else {
                        PolishResult.Success(CleanupPolicy.stripWrapping(text))
                    }
                }
            } catch (e: IOException) {
                PolishResult.Failure(e.message ?: "Network error")
            }
        }

    fun errorMessage(code: Int, body: String): String {
        val root = parse(body) as? JsonObject
        val message = root?.get("error").asMessage()
            ?: root?.get("message").asMessage()
            ?: root?.get("detail").asMessage()
        return message?.takeIf { it.isNotBlank() }?.take(MAX_MESSAGE_CHARS) ?: "HTTP $code"
    }

    fun string(element: JsonElement?): String? = (element as? JsonPrimitive)?.takeIf { it.isString }?.content

    fun firstObject(element: JsonElement?): JsonObject? = (element as? JsonArray)?.firstOrNull() as? JsonObject

    /** A cleaned transcript is a few kB; anything larger is a broken endpoint, not an answer. */
    private const val MAX_BODY_BYTES = 512L * 1024

    /** Server-controlled text ends up in the history file, so it does not get to be long. */
    private const val MAX_MESSAGE_CHARS = 200

    private fun parse(raw: String): JsonElement? =
        runCatching { json.parseToJsonElement(raw) }.getOrNull()

    private fun JsonElement?.asMessage(): String? = when (this) {
        is JsonPrimitive -> takeIf { it.isString }?.content
        is JsonObject -> string(this["message"]) ?: string(this["detail"])
        else -> null
    }
}
