package ai.sayso.dictation.stt

import ai.sayso.dictation.core.TranscriptionProvider
import ai.sayso.dictation.core.TranscriptionResult
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * OkHttp quotes a rejected header value back in its exception message unless the header is
 * one it treats as sensitive, and that message ends up in the feedback pill and the history
 * file. So a key that cannot be sent has to be caught before the request is built.
 */
class ApiKeyGuardTest {

    private lateinit var server: MockWebServer

    @Before fun start() { server = MockWebServer().also { it.start() } }
    @After fun stop() = server.shutdown()

    private fun providers(): List<TranscriptionProvider> = listOf(
        GeminiProvider(baseUrl = server.url("/v1beta").toString()),
        ElevenLabsProvider(baseUrl = server.url("/v1/speech-to-text").toString()),
        DeepgramProvider(baseUrl = server.url("/v1/listen").toString()),
        OpenAiProvider(baseUrl = server.url("/v1").toString()),
        GroqProvider(baseUrl = server.url("/openai/v1").toString()),
    )

    @Test
    fun `a key carrying a non-breaking space never reaches the wire`() = runTest {
        // What a key pasted out of a web console looks like; trim() does not remove it.
        val key = "sk-secret\u00a0value"

        providers().forEach { provider ->
            val result = provider.transcribe(testRequest(provider.models.first().modelName), apiKey = key)

            assertTrue(provider.id, result is TranscriptionResult.Failure)
            val message = (result as TranscriptionResult.Failure).message
            assertEquals(provider.id, "API key contains unsupported characters", message)
            assertFalse(provider.id, message.contains("sk-secret"))
        }

        assertEquals(0, server.requestCount)
    }

    @Test
    fun `a missing key is reported without opening a socket`() = runTest {
        providers().forEach { provider ->
            val result = provider.transcribe(testRequest(provider.models.first().modelName), apiKey = "  ")

            assertTrue(provider.id, result is TranscriptionResult.Failure)
            assertTrue(provider.id, (result as TranscriptionResult.Failure).message.endsWith("API key is missing"))
        }

        assertEquals(0, server.requestCount)
    }
}
