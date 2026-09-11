package com.shotclubhouse.sayso.stt

import com.shotclubhouse.sayso.core.TranscriptionResult
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class OpenAiCompatProviderTest {

    private lateinit var server: MockWebServer

    @Before fun start() { server = MockWebServer().also { it.start() } }
    @After fun stop() = server.shutdown()

    private fun provider() = OpenAiProvider(baseUrl = server.url("/v1").toString())

    @Test
    fun `posts a wav multipart with the model and biasing prompt`() = runTest {
        server.enqueue(mockResponse(200, """{"text":"hello there"}"""))

        val result = provider().transcribe(
            testRequest("gpt-4o-mini-transcribe", language = "en", hints = listOf("Sayso", "sherpa")),
            apiKey = "sk-test",
        )

        assertEquals(TranscriptionResult.Success("hello there"), result)

        val sent = server.takeRequest()
        assertEquals("POST", sent.method)
        assertEquals("/v1/audio/transcriptions", sent.requestUrl!!.encodedPath)
        assertEquals("Bearer sk-test", sent.headers["Authorization"])

        val body = sent.bodyText()
        assertTrue(body.contains("""name="file"; filename="audio.wav""""))
        assertTrue(body.contains("Content-Type: audio/wav"))
        assertTrue(body.contains("""name="model""""))
        assertTrue(body.contains("gpt-4o-mini-transcribe"))
        assertTrue(body.contains("""name="language""""))
        assertTrue(body.contains("""name="prompt""""))
        assertTrue(body.contains("Sayso, sherpa"))
        assertTrue(body.contains("""name="response_format""""))
        assertTrue(body.contains("""name="temperature""""))
        assertTrue(body.contains("RIFF"))
    }

    @Test
    fun `omits language and prompt when the user set neither`() = runTest {
        server.enqueue(mockResponse(200, """{"text":"ok"}"""))

        provider().transcribe(testRequest("whisper-1"), apiKey = "sk-test")

        val body = server.takeRequest().bodyText()
        assertTrue(!body.contains("""name="language""""))
        assertTrue(!body.contains("""name="prompt""""))
    }

    @Test
    fun `caps the prompt at 200 characters`() = runTest {
        server.enqueue(mockResponse(200, """{"text":"ok"}"""))

        provider().transcribe(
            testRequest("whisper-1", hints = List(40) { "supercalifragilistic" }),
            apiKey = "sk-test",
        )

        val body = server.takeRequest().bodyText()
        val prompt = body.substringAfter("""name="prompt"""").substringAfter("\r\n\r\n").substringBefore("\r\n--")
        assertEquals(200, prompt.length)
    }

    @Test
    fun `reports the api error message rather than the status code`() = runTest {
        server.enqueue(
            mockResponse(401, """{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"""),
        )

        val result = provider().transcribe(testRequest("whisper-1"), apiKey = "bad")

        assertEquals(TranscriptionResult.Failure("Incorrect API key provided"), result)
    }

    @Test
    fun `falls back to the status code when the error body is not json`() = runTest {
        server.enqueue(mockResponse(502, "<html>bad gateway</html>"))

        val result = provider().transcribe(testRequest("whisper-1"), apiKey = "sk-test")

        assertEquals(TranscriptionResult.Failure("HTTP 502"), result)
    }

    @Test
    fun `refuses to call out without a key`() = runTest {
        val result = provider().transcribe(testRequest("whisper-1"), apiKey = " ")

        assertEquals(TranscriptionResult.Failure("Missing OpenAI API key"), result)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `groq shares the dialect and defaults to the turbo model`() = runTest {
        server.enqueue(mockResponse(200, """{"text":"groq speaking"}"""))
        val groq = GroqProvider(baseUrl = server.url("/openai/v1").toString())

        val result = groq.transcribe(testRequest("whisper-large-v3-turbo"), apiKey = "gsk-test")

        assertEquals(TranscriptionResult.Success("groq speaking"), result)
        assertEquals("groq", groq.id)
        assertEquals("groq/whisper-large-v3-turbo", groq.models.first().id)
        assertEquals("/openai/v1/audio/transcriptions", server.takeRequest().requestUrl!!.encodedPath)
    }
}
