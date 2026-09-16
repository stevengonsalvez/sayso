package ai.sayso.dictation.stt

import ai.sayso.dictation.core.AudioClip
import ai.sayso.dictation.core.TranscriptionRequest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.RecordedRequest

internal fun testClip(): AudioClip = AudioClip(ByteArray(640) { (it % 251 - 125).toByte() }, 16_000)

internal fun testRequest(
    modelName: String,
    language: String? = null,
    hints: List<String> = emptyList(),
) = TranscriptionRequest(clip = testClip(), modelName = modelName, language = language, hints = hints)

/** The bodies carry binary WAV data, so read them as latin-1 to keep byte offsets. */
internal fun RecordedRequest.bodyText(): String = String(body.readByteArray(), Charsets.ISO_8859_1)

internal fun mockResponse(code: Int, body: String): MockResponse =
    MockResponse().setResponseCode(code).setBody(body)
