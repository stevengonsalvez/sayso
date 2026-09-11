package com.shotclubhouse.sayso.stt

import com.shotclubhouse.sayso.core.SttModel
import com.shotclubhouse.sayso.core.TranscriptionProvider
import com.shotclubhouse.sayso.core.TranscriptionRequest
import com.shotclubhouse.sayso.core.TranscriptionResult
import com.shotclubhouse.sayso.core.Wav
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

class ElevenLabsProvider(
    private val baseUrl: String = "https://api.elevenlabs.io/v1/speech-to-text",
) : TranscriptionProvider {
    override val id: String = "elevenlabs"
    override val displayName: String = "ElevenLabs"
    override val needsApiKey: Boolean = true
    override val apiKeyUrl: String = "https://elevenlabs.io/app/settings/api-keys"
    override val models: List<SttModel> = listOf(
        SttModel("elevenlabs/scribe_v2", "Scribe v2"),
        SttModel("elevenlabs/scribe_v1", "Scribe v1"),
    )

    override suspend fun transcribe(request: TranscriptionRequest, apiKey: String?): TranscriptionResult {
        if (apiKey.isNullOrBlank()) return TranscriptionResult.Failure("Missing $displayName API key")

        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("model_id", request.modelName)
            .addFormDataPart(
                "file",
                "audio.wav",
                Wav.encode(request.clip).toRequestBody("audio/wav".toMediaType()),
            )
            .apply {
                request.language?.takeIf { it.isNotBlank() }?.let { addFormDataPart("language_code", it) }
            }
            // Dictation wants words only, not "(laughter)" markers spliced into the text.
            .addFormDataPart("tag_audio_events", "false")
            .build()

        val http = Request.Builder()
            .url(baseUrl)
            .header("xi-api-key", apiKey)
            .post(body)
            .build()

        return transcribeCall(http, ::parseResponse)
    }

    internal fun parseResponse(json: String): TranscriptionResult =
        transcriptOrFailure(parseJsonObject(json)?.string("text"))
}
