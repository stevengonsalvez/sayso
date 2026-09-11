package com.shotclubhouse.sayso.stt

import com.shotclubhouse.sayso.core.ApiKeys
import com.shotclubhouse.sayso.core.SttModel
import com.shotclubhouse.sayso.core.TranscriptionProvider
import com.shotclubhouse.sayso.core.TranscriptionRequest
import com.shotclubhouse.sayso.core.TranscriptionResult
import com.shotclubhouse.sayso.core.Wav
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** Longer biasing prompts are ignored or billed for nothing, so they are trimmed. */
private const val MAX_PROMPT_CHARS = 200

/**
 * Any service that speaks OpenAI's `/audio/transcriptions` multipart dialect.
 */
class OpenAiCompatProvider(
    override val id: String,
    override val displayName: String,
    private val baseUrl: String,
    override val models: List<SttModel>,
    override val apiKeyUrl: String?,
) : TranscriptionProvider {
    override val needsApiKey: Boolean = true

    override suspend fun transcribe(request: TranscriptionRequest, apiKey: String?): TranscriptionResult {
        if (apiKey.isNullOrBlank()) return TranscriptionResult.Failure(ApiKeys.missing(displayName))
        if (!ApiKeys.isSendable(apiKey)) return TranscriptionResult.Failure(ApiKeys.UNSUPPORTED)

        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart(
                "file",
                "audio.wav",
                Wav.encode(request.clip).toRequestBody("audio/wav".toMediaType()),
            )
            .addFormDataPart("model", request.modelName)
            .apply {
                request.language?.takeIf { it.isNotBlank() }?.let { addFormDataPart("language", it) }
                promptFrom(request.hints)?.let { addFormDataPart("prompt", it) }
            }
            .addFormDataPart("response_format", "json")
            .addFormDataPart("temperature", "0")
            .build()

        val http = Request.Builder()
            .url("$baseUrl/audio/transcriptions")
            .header("Authorization", "Bearer $apiKey")
            .post(body)
            .build()

        return transcribeCall(http, ::parseResponse)
    }

    internal fun parseResponse(json: String): TranscriptionResult =
        transcriptOrFailure(parseJsonObject(json)?.string("text"))

    private fun promptFrom(hints: List<String>): String? = hints
        .filter { it.isNotBlank() }
        .takeIf { it.isNotEmpty() }
        ?.joinToString(", ")
        ?.take(MAX_PROMPT_CHARS)
}

fun OpenAiProvider(baseUrl: String = "https://api.openai.com/v1") = OpenAiCompatProvider(
    id = "openai",
    displayName = "OpenAI",
    baseUrl = baseUrl,
    models = listOf(
        SttModel("openai/gpt-4o-mini-transcribe", "GPT-4o mini transcribe", "Fast, accurate"),
        SttModel("openai/gpt-4o-transcribe", "GPT-4o transcribe"),
        SttModel("openai/whisper-1", "Whisper v1"),
    ),
    apiKeyUrl = "https://platform.openai.com/api-keys",
)

fun GroqProvider(baseUrl: String = "https://api.groq.com/openai/v1") = OpenAiCompatProvider(
    id = "groq",
    displayName = "Groq",
    baseUrl = baseUrl,
    models = listOf(
        SttModel("groq/whisper-large-v3-turbo", "Whisper large v3 turbo", "Fast"),
        SttModel("groq/whisper-large-v3", "Whisper large v3"),
    ),
    apiKeyUrl = "https://console.groq.com/keys",
)
