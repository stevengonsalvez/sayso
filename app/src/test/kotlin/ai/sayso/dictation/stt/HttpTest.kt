package ai.sayso.dictation.stt

import ai.sayso.dictation.core.TranscriptionResult
import kotlinx.coroutines.test.runTest
import okhttp3.Request
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The shared read cap, mirrored here so a change to it has to be deliberate. */
private const val BODY_CAP = 512 * 1024

class HttpTest {

    private lateinit var server: MockWebServer

    @Before fun start() { server = MockWebServer().also { it.start() } }
    @After fun stop() = server.shutdown()

    private fun call() = Request.Builder().url(server.url("/v1/transcribe")).build()

    @Test
    fun `a sprawling error message is cut down before it reaches the user`() = runTest {
        server.enqueue(mockResponse(400, """{"error":{"message":"${"z".repeat(5_000)}"}}"""))

        val result = transcribeCall(call()) { TranscriptionResult.Success(it) }

        assertEquals(TranscriptionResult.Failure("z".repeat(200)), result)
    }

    @Test
    fun `a success body past the cap is truncated rather than read whole`() = runTest {
        server.enqueue(mockResponse(200, "y".repeat(BODY_CAP * 2)))

        var seen = -1
        val result = transcribeCall(call()) { body ->
            seen = body.length
            TranscriptionResult.Success("parsed")
        }

        assertEquals(TranscriptionResult.Success("parsed"), result)
        assertTrue("the whole body was allocated: $seen characters", seen in 1..BODY_CAP)
    }
}
