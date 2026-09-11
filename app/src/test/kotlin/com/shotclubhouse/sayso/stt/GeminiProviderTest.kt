package com.shotclubhouse.sayso.stt

import com.shotclubhouse.sayso.core.TranscriptionResult
import com.shotclubhouse.sayso.core.Wav
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.Base64

class GeminiProviderTest {

    private lateinit var server: MockWebServer

    @Before fun start() { server = MockWebServer().also { it.start() } }
    @After fun stop() = server.shutdown()

    private fun provider() = GeminiProvider(baseUrl = server.url("/v1beta").toString())

    private val success = """
        {"candidates":[{"content":{"parts":[{"text":"  gemini heard you  "}],"role":"model"},
         "finishReason":"STOP"}]}
    """.trimIndent()

    @Test
    fun `posts the clip inline as base64 next to the instruction`() = runTest {
        server.enqueue(mockResponse(200, success))

        val result = provider().transcribe(
            testRequest("gemini-2.5-flash", language = "en", hints = listOf("Sayso", "sherpa")),
            apiKey = "AIza-test",
        )

        assertEquals(TranscriptionResult.Success("gemini heard you"), result)

        val sent = server.takeRequest()
        assertEquals("POST", sent.method)
        assertEquals("/v1beta/models/gemini-2.5-flash:generateContent", sent.requestUrl!!.encodedPath)
        assertEquals("AIza-test", sent.headers["x-goog-api-key"])

        val parts = Json.parseToJsonElement(sent.bodyText())
            .jsonObject["contents"]!!.jsonArray[0]
            .jsonObject["parts"]!!.jsonArray

        val instruction = parts[0].jsonObject["text"]!!.jsonPrimitive.content
        assertTrue(instruction.startsWith("Transcribe this audio verbatim."))
        assertTrue(instruction.contains("Spoken language: en."))
        assertTrue(instruction.contains("Likely terms: Sayso, sherpa."))

        val inline = parts[1].jsonObject["inlineData"]!!.jsonObject
        assertEquals("audio/wav", inline["mimeType"]!!.jsonPrimitive.content)
        val decoded = Base64.getDecoder().decode(inline["data"]!!.jsonPrimitive.content)
        assertEquals(Wav.encode(testClip()).size, decoded.size)
        assertEquals("RIFF", String(decoded, 0, 4))
    }

    @Test
    fun `leaves language and term lines out when unset`() = runTest {
        server.enqueue(mockResponse(200, success))

        provider().transcribe(testRequest("gemini-2.5-flash-lite"), apiKey = "AIza-test")

        val instruction = Json.parseToJsonElement(server.takeRequest().bodyText())
            .jsonObject["contents"]!!.jsonArray[0]
            .jsonObject["parts"]!!.jsonArray[0]
            .jsonObject["text"]!!.jsonPrimitive.content

        assertTrue(!instruction.contains("Spoken language"))
        assertTrue(!instruction.contains("Likely terms"))
    }

    @Test
    fun `reports the google error message`() = runTest {
        server.enqueue(
            mockResponse(400, """{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT"}}"""),
        )

        val result = provider().transcribe(testRequest("gemini-2.5-flash"), apiKey = "nope")

        assertEquals(TranscriptionResult.Failure("API key not valid"), result)
    }

    @Test
    fun `a silent clip yields a failure rather than an empty transcript`() = runTest {
        server.enqueue(mockResponse(200, """{"candidates":[{"content":{"parts":[{"text":""}]}}]}"""))

        val result = provider().transcribe(testRequest("gemini-2.5-flash"), apiKey = "AIza-test")

        assertEquals(TranscriptionResult.Failure("No speech detected"), result)
    }

    @Test
    fun `a safety block is reported as the reason gemini gave`() = runTest {
        server.enqueue(
            mockResponse(
                200,
                """{"candidates":[{"finishReason":"SAFETY","index":0}],
                    "promptFeedback":{"blockReason":"SAFETY"}}""",
            ),
        )

        val result = provider().transcribe(testRequest("gemini-2.5-flash"), apiKey = "AIza-test")

        assertEquals(TranscriptionResult.Failure("Gemini stopped: SAFETY"), result)
    }

    @Test
    fun `an empty part alongside a block reason still names the block`() = runTest {
        server.enqueue(
            mockResponse(
                200,
                """{"candidates":[{"content":{"parts":[{"text":""}],"role":"model"},"finishReason":"SAFETY"}],
                    "promptFeedback":{"blockReason":"SAFETY"}}""",
            ),
        )

        val result = provider().transcribe(testRequest("gemini-2.5-flash"), apiKey = "AIza-test")

        assertEquals(TranscriptionResult.Failure("Gemini stopped: SAFETY"), result)
    }

    @Test
    fun `a cut off generation still hands back what was transcribed`() = runTest {
        server.enqueue(
            mockResponse(
                200,
                """{"candidates":[{"content":{"parts":[{"text":"half a sentence"}]},"finishReason":"MAX_TOKENS"}]}""",
            ),
        )

        val result = provider().transcribe(testRequest("gemini-2.5-flash"), apiKey = "AIza-test")

        assertEquals(TranscriptionResult.Success("half a sentence"), result)
    }

    @Test
    fun `a truncated generation names what cut it short`() = runTest {
        server.enqueue(mockResponse(200, """{"candidates":[{"content":{"role":"model"},"finishReason":"MAX_TOKENS"}]}"""))

        val result = provider().transcribe(testRequest("gemini-2.5-flash"), apiKey = "AIza-test")

        assertEquals(TranscriptionResult.Failure("Gemini stopped: MAX_TOKENS"), result)
    }

    @Test
    fun `a clean stop with nothing said is still no speech detected`() = runTest {
        server.enqueue(mockResponse(200, """{"candidates":[{"content":{"role":"model"},"finishReason":"STOP"}]}"""))

        val result = provider().transcribe(testRequest("gemini-2.5-flash"), apiKey = "AIza-test")

        assertEquals(TranscriptionResult.Failure("No speech detected"), result)
    }
}
