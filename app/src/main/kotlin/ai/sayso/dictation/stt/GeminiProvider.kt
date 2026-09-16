package ai.sayso.dictation.stt

import ai.sayso.dictation.core.ApiKeys
import ai.sayso.dictation.core.SttModel
import ai.sayso.dictation.core.TranscriptionProvider
import ai.sayso.dictation.core.TranscriptionRequest
import ai.sayso.dictation.core.TranscriptionResult
import ai.sayso.dictation.core.Wav
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.Base64

private const val BASE_INSTRUCTION =
    "Transcribe this audio verbatim. Output only the spoken words as plain text, " +
        "with punctuation. If the audio contains no speech, output nothing."

/** The one finish reason that means the model simply had nothing more to say. */
private const val FINISH_REASON_OK = "STOP"

/**
 * Gemini is a general model, so the clip travels as inline base64 next to an
 * instruction. Inline data is capped at 20 MB, which a five-minute clip fits
 * inside once base64 expansion is accounted for.
 */
class GeminiProvider(
    private val baseUrl: String = "https://generativelanguage.googleapis.com/v1beta",
) : TranscriptionProvider {
    override val id: String = "gemini"
    override val displayName: String = "Gemini"
    override val needsApiKey: Boolean = true
    override val apiKeyUrl: String = "https://aistudio.google.com/apikey"
    override val models: List<SttModel> = listOf(
        SttModel("gemini/gemini-2.5-flash", "Gemini 2.5 Flash"),
        SttModel("gemini/gemini-2.5-flash-lite", "Gemini 2.5 Flash Lite", "Cheapest"),
    )

    override suspend fun transcribe(request: TranscriptionRequest, apiKey: String?): TranscriptionResult {
        if (apiKey.isNullOrBlank()) return TranscriptionResult.Failure(ApiKeys.missing(displayName))
        if (!ApiKeys.isSendable(apiKey)) return TranscriptionResult.Failure(ApiKeys.UNSUPPORTED)

        val audio = Base64.getEncoder().encodeToString(Wav.encode(request.clip))
        val payload = buildJsonObject {
            putJsonArray("contents") {
                add(
                    buildJsonObject {
                        putJsonArray("parts") {
                            add(buildJsonObject { put("text", instruction(request)) })
                            add(
                                buildJsonObject {
                                    putJsonObject("inlineData") {
                                        put("mimeType", "audio/wav")
                                        put("data", audio)
                                    }
                                },
                            )
                        }
                    },
                )
            }
        }

        val http = Request.Builder()
            .url("$baseUrl/models/${request.modelName}:generateContent")
            .header("x-goog-api-key", apiKey)
            .post(payload.toString().toRequestBody("application/json".toMediaType()))
            .build()

        return transcribeCall(http, ::parseResponse)
    }

    /**
     * A blocked or truncated generation comes back with no `parts`, or with an empty one.
     * Reporting either as "no speech detected" would send the user looking at their
     * microphone, so the reason Gemini gives is passed through instead.
     */
    internal fun parseResponse(json: String): TranscriptionResult {
        val root = parseJsonObject(json)
        val candidate = root?.child("candidates")?.at(0)
        val text = candidate
            ?.child("content")
            ?.child("parts")?.at(0)
            ?.string("text")

        // A block can arrive as an empty part rather than a missing one, so the reason is
        // read before the blank text is judged. Text that did come back still wins: a
        // MAX_TOKENS cut leaves a usable partial transcript.
        val stopped = candidate?.string("finishReason")?.takeIf { it != FINISH_REASON_OK }
            ?: root?.child("promptFeedback")?.string("blockReason")
        if (stopped != null && text.isNullOrBlank()) {
            return TranscriptionResult.Failure("Gemini stopped: $stopped")
        }
        return transcriptOrFailure(text)
    }

    private fun instruction(request: TranscriptionRequest): String = buildString {
        append(BASE_INSTRUCTION)
        request.language?.takeIf { it.isNotBlank() }?.let { append(" Spoken language: ").append(it).append(".") }
        request.hints.filter { it.isNotBlank() }.takeIf { it.isNotEmpty() }?.let {
            append(" Likely terms: ").append(it.joinToString(", ")).append(".")
        }
    }
}
