package ai.sayso.dictation.polish

import ai.sayso.dictation.core.PolishProvider
import ai.sayso.dictation.core.PolishResult
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Every cloud cleanup backend, driven against a local server. */
class HttpPolisherTest {

    private lateinit var server: MockWebServer

    @Before
    fun start() {
        server = MockWebServer()
        server.start()
    }

    @After
    fun stop() {
        server.shutdown()
    }

    private fun baseUrl() = server.url("/").toString()

    private suspend fun polish(provider: PolishProvider, modelName: String, apiKey: String? = "sk-test") =
        provider.polish(
            systemPrompt = "SYSTEM",
            userMessage = "USER",
            modelName = modelName,
            apiKey = apiKey,
        )

    private fun RecordedRequest.json(): JsonObject =
        Json.parseToJsonElement(body.readUtf8()) as JsonObject

    private fun JsonObject.str(key: String) = (getValue(key) as JsonPrimitive).content

    private fun JsonObject.arr(key: String) = getValue(key) as JsonArray

    private fun enqueue(body: String, code: Int = 200) {
        server.enqueue(MockResponse().setResponseCode(code).setBody(body))
    }

    // OpenAI-compatible chat completions.

    @Test
    fun `openai compatible sends a bearer chat completion and reads the choice`() = runTest {
        enqueue("""{"choices":[{"message":{"role":"assistant","content":"Cleaned text."}}]}""")

        val result = polish(OpenAiPolisher(baseUrl()), "gpt-4.1-mini")

        assertEquals(PolishResult.Success("Cleaned text."), result)

        val request = server.takeRequest()
        assertEquals("POST", request.method)
        assertEquals("/chat/completions", request.path)
        assertEquals("Bearer sk-test", request.getHeader("Authorization"))
        assertTrue(request.getHeader("Content-Type")!!.startsWith("application/json"))

        val body = request.json()
        assertEquals("gpt-4.1-mini", body.str("model"))
        assertEquals("0", (body.getValue("temperature") as JsonPrimitive).content)
        val messages = body.arr("messages").map { it as JsonObject }
        assertEquals(listOf("system", "user"), messages.map { it.str("role") })
        assertEquals(listOf("SYSTEM", "USER"), messages.map { it.str("content") })
    }

    @Test
    fun `groq and openrouter reuse the same endpoint shape`() = runTest {
        enqueue("""{"choices":[{"message":{"content":"a"}}]}""")
        polish(GroqPolisher(baseUrl()), "llama-3.3-70b-versatile")
        assertEquals("/chat/completions", server.takeRequest().path)

        enqueue("""{"choices":[{"message":{"content":"b"}}]}""")
        val result = polish(OpenRouterPolisher(baseUrl()), "anthropic/claude-haiku-4.5")
        assertEquals(PolishResult.Success("b"), result)

        val request = server.takeRequest()
        assertEquals("anthropic/claude-haiku-4.5", request.json().str("model"))
    }

    @Test
    fun `openai compatible surfaces the server error message`() = runTest {
        enqueue("""{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}""", code = 401)

        val result = polish(OpenAiPolisher(baseUrl()), "gpt-4.1-mini")

        assertEquals(PolishResult.Failure("Incorrect API key provided"), result)
    }

    @Test
    fun `unparseable error bodies fall back to the status code`() = runTest {
        enqueue("<html>gateway timeout</html>", code = 504)

        assertEquals(PolishResult.Failure("HTTP 504"), polish(OpenAiPolisher(baseUrl()), "gpt-4.1-mini"))
    }

    @Test
    fun `a plain string error field is used as the message`() = runTest {
        enqueue("""{"error":"rate limited"}""", code = 429)

        assertEquals(PolishResult.Failure("rate limited"), polish(GroqPolisher(baseUrl()), "llama-3.1-8b-instant"))
    }

    // Anthropic messages.

    @Test
    fun `anthropic sends the versioned key header and reads the first content block`() = runTest {
        enqueue("""{"content":[{"type":"text","text":"```\nCleaned.\n```"}]}""")

        val result = polish(AnthropicPolisher(baseUrl()), "claude-haiku-4-5")

        assertEquals(PolishResult.Success("Cleaned."), result)

        val request = server.takeRequest()
        assertEquals("/messages", request.path)
        assertEquals("sk-test", request.getHeader("x-api-key"))
        assertEquals("2023-06-01", request.getHeader("anthropic-version"))
        assertNull(request.getHeader("Authorization"))

        val body = request.json()
        assertEquals("claude-haiku-4-5", body.str("model"))
        assertEquals("SYSTEM", body.str("system"))
        assertEquals("2048", (body.getValue("max_tokens") as JsonPrimitive).content)
        val message = body.arr("messages").single() as JsonObject
        assertEquals("user", message.str("role"))
        assertEquals("USER", message.str("content"))
    }

    @Test
    fun `anthropic error json is surfaced`() = runTest {
        enqueue("""{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}""", code = 529)

        assertEquals(PolishResult.Failure("Overloaded"), polish(AnthropicPolisher(baseUrl()), "claude-haiku-4-5"))
    }

    // Gemini generateContent.

    @Test
    fun `gemini sends system instruction and contents and reads the first part`() = runTest {
        enqueue("""{"candidates":[{"content":{"role":"model","parts":[{"text":"Cleaned."}]}}]}""")

        val result = polish(GeminiPolisher(baseUrl()), "gemini-2.5-flash")

        assertEquals(PolishResult.Success("Cleaned."), result)

        val request = server.takeRequest()
        assertEquals("/models/gemini-2.5-flash:generateContent", request.path)
        assertEquals("sk-test", request.getHeader("x-goog-api-key"))

        val body = request.json()
        val systemPart = (body.getValue("systemInstruction") as JsonObject).arr("parts").single() as JsonObject
        assertEquals("SYSTEM", systemPart.str("text"))

        val content = body.arr("contents").single() as JsonObject
        assertEquals("user", content.str("role"))
        assertEquals("USER", (content.arr("parts").single() as JsonObject).str("text"))
        assertEquals("0", ((body.getValue("generationConfig") as JsonObject).getValue("temperature") as JsonPrimitive).content)
    }

    @Test
    fun `gemini error json is surfaced`() = runTest {
        enqueue("""{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT"}}""", code = 400)

        assertEquals(PolishResult.Failure("API key not valid"), polish(GeminiPolisher(baseUrl()), "gemini-2.5-flash"))
    }

    // Shared behaviour.

    @Test
    fun `a missing key fails before any request is made`() = runTest {
        val providers = listOf(
            OpenAiPolisher(baseUrl()),
            GroqPolisher(baseUrl()),
            OpenRouterPolisher(baseUrl()),
            AnthropicPolisher(baseUrl()),
            GeminiPolisher(baseUrl()),
        )

        providers.forEach { provider ->
            val result = polish(provider, "any-model", apiKey = null)
            assertTrue(provider.id, result is PolishResult.Failure)
            assertTrue(provider.id, (result as PolishResult.Failure).message.contains("API key is missing"))
        }
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `a key with characters that cannot be sent is rejected before the wire`() = runTest {
        val providers = listOf(
            OpenAiPolisher(baseUrl()),
            AnthropicPolisher(baseUrl()),
            GeminiPolisher(baseUrl()),
        )

        // A non-breaking space survives trim() when a key is pasted from a web console.
        providers.forEach { provider ->
            val result = polish(provider, "any-model", apiKey = "sk-te\u00a0st")
            assertTrue(provider.id, result is PolishResult.Failure)
            assertTrue(provider.id, (result as PolishResult.Failure).message.contains("unsupported characters"))
            assertFalse(provider.id, result.message.contains("sk-te"))
        }
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `an overlong server error message is truncated before it is persisted`() = runTest {
        enqueue("""{"error":{"message":"${"x".repeat(5_000)}"}}""", code = 500)

        val result = polish(OpenAiPolisher(baseUrl()), "gpt-4.1-mini")

        assertEquals(200, (result as PolishResult.Failure).message.length)
    }

    @Test
    fun `a success with no text is reported as a failure`() = runTest {
        enqueue("""{"choices":[]}""")

        val result = polish(OpenAiPolisher(baseUrl()), "gpt-4.1-mini")

        assertEquals(PolishResult.Failure("Cleanup model returned no text"), result)
    }

    @Test
    fun `a transport failure becomes a failure result`() = runTest {
        val url = baseUrl()
        server.shutdown()

        val result = polish(OpenAiPolisher(url), "gpt-4.1-mini")

        assertTrue(result is PolishResult.Failure)
        assertFalse((result as PolishResult.Failure).message.isBlank())

        server = MockWebServer().also { it.start() }
    }
}
