package com.shotclubhouse.sayso.stt

import com.shotclubhouse.sayso.core.TranscriptionResult
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class DeepgramProviderTest {

    private lateinit var server: MockWebServer

    @Before fun start() { server = MockWebServer().also { it.start() } }
    @After fun stop() = server.shutdown()

    private fun provider() = DeepgramProvider(baseUrl = server.url("/v1/listen").toString())

    private val success = """
        {"metadata":{"request_id":"abc"},
         "results":{"channels":[{"alternatives":[{"transcript":"nova heard you","confidence":0.99}]}]}}
    """.trimIndent()

    @Test
    fun `sends raw wav with options as query parameters`() = runTest {
        server.enqueue(mockResponse(200, success))

        val result = provider().transcribe(
            testRequest("nova-3", language = "en", hints = listOf("Sayso", "sherpa-onnx")),
            apiKey = "dg-test",
        )

        assertEquals(TranscriptionResult.Success("nova heard you"), result)

        val sent = server.takeRequest()
        assertEquals("POST", sent.method)
        assertEquals("/v1/listen", sent.requestUrl!!.encodedPath)
        assertEquals("Token dg-test", sent.headers["Authorization"])
        assertEquals("audio/wav", sent.headers["Content-Type"])
        assertEquals("nova-3", sent.requestUrl!!.queryParameter("model"))
        assertEquals("true", sent.requestUrl!!.queryParameter("smart_format"))
        assertEquals("en", sent.requestUrl!!.queryParameter("language"))
        assertEquals(listOf("Sayso", "sherpa-onnx"), sent.requestUrl!!.queryParameterValues("keyterm"))
        assertTrue(sent.bodyText().startsWith("RIFF"))
    }

    @Test
    fun `drops keyterms and language when they do not apply`() = runTest {
        server.enqueue(mockResponse(200, success))

        provider().transcribe(testRequest("nova-2", hints = listOf("Sayso")), apiKey = "dg-test")

        val url = server.takeRequest().requestUrl!!
        assertNull(url.queryParameter("language"))
        assertTrue(url.queryParameterValues("keyterm").isEmpty())
    }

    @Test
    fun `surfaces the message field from a rejected request`() = runTest {
        server.enqueue(mockResponse(400, """{"err_code":"Bad Request","message":"failed to process audio"}"""))

        val result = provider().transcribe(testRequest("nova-3"), apiKey = "dg-test")

        assertEquals(TranscriptionResult.Failure("failed to process audio"), result)
    }

    @Test
    fun `an empty transcript is a failure not an empty success`() = runTest {
        server.enqueue(
            mockResponse(200, """{"results":{"channels":[{"alternatives":[{"transcript":""}]}]}}"""),
        )

        val result = provider().transcribe(testRequest("nova-3"), apiKey = "dg-test")

        assertEquals(TranscriptionResult.Failure("No speech detected"), result)
    }
}
