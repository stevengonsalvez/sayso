package com.shotclubhouse.sayso.stt

import com.shotclubhouse.sayso.core.SttModel
import com.shotclubhouse.sayso.core.TranscriptionProvider
import com.shotclubhouse.sayso.core.TranscriptionRequest
import com.shotclubhouse.sayso.core.TranscriptionResult
import com.shotclubhouse.sayso.core.Wav
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * Deepgram takes the WAV as the raw request body and every option as a query
 * parameter. Keyterm boosting is a nova-3 feature; older models reject it.
 */
class DeepgramProvider(
    private val baseUrl: String = "https://api.deepgram.com/v1/listen",
) : TranscriptionProvider {
    override val id: String = "deepgram"
    override val displayName: String = "Deepgram"
    override val needsApiKey: Boolean = true
    override val apiKeyUrl: String = "https://console.deepgram.com/"
    override val models: List<SttModel> = listOf(
        SttModel("deepgram/nova-3", "Nova 3", "Keyterm boosting"),
        SttModel("deepgram/nova-2", "Nova 2"),
    )

    override suspend fun transcribe(request: TranscriptionRequest, apiKey: String?): TranscriptionResult {
        if (apiKey.isNullOrBlank()) return TranscriptionResult.Failure("Missing $displayName API key")

        val url = baseUrl.toHttpUrl().newBuilder()
            .addQueryParameter("model", request.modelName)
            .addQueryParameter("smart_format", "true")
            .apply {
                request.language?.takeIf { it.isNotBlank() }?.let { addQueryParameter("language", it) }
                if (request.modelName.startsWith("nova-3")) {
                    request.hints.filter { it.isNotBlank() }.forEach { addQueryParameter("keyterm", it) }
                }
            }
            .build()

        val http = Request.Builder()
            .url(url)
            .header("Authorization", "Token $apiKey")
            .post(Wav.encode(request.clip).toRequestBody("audio/wav".toMediaType()))
            .build()

        return transcribeCall(http, ::parseResponse)
    }

    internal fun parseResponse(json: String): TranscriptionResult {
        val transcript = parseJsonObject(json)
            ?.child("results")
            ?.child("channels")?.at(0)
            ?.child("alternatives")?.at(0)
            ?.string("transcript")
        return transcriptOrFailure(transcript)
    }
}
