package ai.sayso.dictation.stt

import ai.sayso.dictation.core.TranscriptionResult
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ElevenLabsProviderTest {

    private lateinit var server: MockWebServer

    @Before fun start() { server = MockWebServer().also { it.start() } }
    @After fun stop() = server.shutdown()

    private fun provider() = ElevenLabsProvider(baseUrl = server.url("/v1/speech-to-text").toString())

    @Test
    fun `posts a scribe multipart with the api key header`() = runTest {
        server.enqueue(mockResponse(200, """{"language_code":"eng","text":"scribe heard you"}"""))

        val result = provider().transcribe(testRequest("scribe_v2", language = "en"), apiKey = "xi-test")

        assertEquals(TranscriptionResult.Success("scribe heard you"), result)

        val sent = server.takeRequest()
        assertEquals("POST", sent.method)
        assertEquals("/v1/speech-to-text", sent.requestUrl!!.encodedPath)
        assertEquals("xi-test", sent.headers["xi-api-key"])

        val body = sent.bodyText()
        assertTrue(body.contains("""name="model_id""""))
        assertTrue(body.contains("scribe_v2"))
        assertTrue(body.contains("""name="file"; filename="audio.wav""""))
        assertTrue(body.contains("""name="language_code""""))
        assertTrue(body.contains("""name="tag_audio_events""""))
        assertTrue(body.contains("false"))
    }

    @Test
    fun `omits the language code when unset`() = runTest {
        server.enqueue(mockResponse(200, """{"text":"ok"}"""))

        provider().transcribe(testRequest("scribe_v1"), apiKey = "xi-test")

        assertTrue(!server.takeRequest().bodyText().contains("""name="language_code""""))
    }

    @Test
    fun `reports the detail field used by the elevenlabs error shape`() = runTest {
        server.enqueue(mockResponse(422, """{"detail":"model_id scribe_v0 does not exist"}"""))

        val result = provider().transcribe(testRequest("scribe_v0"), apiKey = "xi-test")

        assertEquals(TranscriptionResult.Failure("model_id scribe_v0 does not exist"), result)
    }
}
