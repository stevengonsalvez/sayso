package com.shotclubhouse.sayso.stt

import com.shotclubhouse.sayso.core.TranscriptionResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * One client for every provider so connections, the thread pool and the dispatcher
 * are shared. The timeouts cover a five-minute clip on a slow uplink, and the call
 * timeout bounds the whole exchange so a stalled upload cannot hang a dictation.
 *
 * Redirects are refused: an API key travels in a header, and a redirect would carry
 * it to whatever host the response names.
 */
internal val httpClient: OkHttpClient = OkHttpClient.Builder()
    .connectTimeout(15, TimeUnit.SECONDS)
    .writeTimeout(60, TimeUnit.SECONDS)
    .readTimeout(120, TimeUnit.SECONDS)
    .callTimeout(180, TimeUnit.SECONDS)
    .followRedirects(false)
    .followSslRedirects(false)
    .build()

internal val lenientJson = Json { ignoreUnknownKeys = true; isLenient = true }

/**
 * Runs [request] off the caller's thread and hands a 2xx body to [parse]. Network
 * faults and error responses become [TranscriptionResult.Failure]; nothing throws.
 */
internal suspend fun transcribeCall(
    request: Request,
    parse: (String) -> TranscriptionResult,
): TranscriptionResult = withContext(Dispatchers.IO) {
    try {
        httpClient.newCall(request).execute().use { response ->
            val body = response.peekBody(MAX_BODY_BYTES).string()
            if (response.isSuccessful) parse(body)
            else TranscriptionResult.Failure(errorMessage(response.code, body))
        }
    } catch (e: IOException) {
        TranscriptionResult.Failure(e.message ?: "Network error")
    }
}

/** Pulls a human-readable reason out of an error body, whatever shape it takes. */
internal fun errorMessage(code: Int, body: String): String {
    val root = parseJsonObject(body) ?: return "HTTP $code"
    val error = root["error"]
    val fromError = when (error) {
        is JsonObject -> error.string("message")
        is JsonPrimitive -> error.text()
        else -> null
    }
    val message = fromError ?: root.string("message") ?: root.string("detail")
    // Server-controlled text is shown to the user and stored in history, so it is capped.
    return message?.takeIf { it.isNotBlank() }?.take(MAX_MESSAGE_CHARS) ?: "HTTP $code"
}

/** Server-controlled text ends up in the history file, so it does not get to be long. */
private const val MAX_MESSAGE_CHARS = 200

/** A transcript of a five-minute clip is a few kB; past this it is a broken endpoint, not an answer. */
private const val MAX_BODY_BYTES = 512L * 1024

internal fun parseJsonObject(raw: String): JsonObject? =
    runCatching { lenientJson.parseToJsonElement(raw) as? JsonObject }.getOrNull()

internal fun JsonElement.string(key: String): String? = (this as? JsonObject)?.get(key)?.text()

internal fun JsonElement.at(index: Int): JsonElement? = (this as? JsonArray)?.getOrNull(index)

internal fun JsonElement.child(key: String): JsonElement? = (this as? JsonObject)?.get(key)

private fun JsonElement.text(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

/** A 2xx with nothing in it means the clip held no speech, not an empty success. */
internal fun transcriptOrFailure(text: String?): TranscriptionResult {
    val trimmed = text?.trim()
    return if (trimmed.isNullOrEmpty()) TranscriptionResult.Failure("No speech detected")
    else TranscriptionResult.Success(trimmed)
}
