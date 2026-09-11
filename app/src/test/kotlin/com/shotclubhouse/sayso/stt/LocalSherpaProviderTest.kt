package com.shotclubhouse.sayso.stt

import com.shotclubhouse.sayso.core.TranscriptionResult
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * The sherpa archives carry no manifest, so the flavour is inferred from file
 * names. These cases mirror the real layout of each catalogue entry.
 */
class LocalSherpaProviderTest {

    @get:Rule val temp = TemporaryFolder()

    private fun modelDir(name: String, vararg files: String): File =
        File(temp.root, "models/$name").apply {
            mkdirs()
            files.forEach { File(this, it).writeText("x") }
        }

    @Test
    fun `parakeet ctc is read as a nemo ctc model`() {
        val config = detectConfig(
            modelDir("sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8", "model.int8.onnx", "tokens.txt"),
        )!!

        assertTrue(config.modelConfig.nemo.model.endsWith("model.int8.onnx"))
        assertTrue(config.modelConfig.tokens.endsWith("tokens.txt"))
        assertEquals(2, config.modelConfig.numThreads)
        assertEquals(16_000, config.featConfig.sampleRate)
    }

    @Test
    fun `moonshine is read from its four part pipeline`() {
        val config = detectConfig(
            modelDir(
                "sherpa-onnx-moonshine-tiny-en-int8",
                "preprocess.onnx",
                "encode.int8.onnx",
                "uncached_decode.int8.onnx",
                "cached_decode.int8.onnx",
                "tokens.txt",
            ),
        )!!

        val moonshine = config.modelConfig.moonshine
        assertTrue(moonshine.preprocessor.endsWith("preprocess.onnx"))
        assertTrue(moonshine.encoder.endsWith("encode.int8.onnx"))
        assertTrue(moonshine.uncachedDecoder.endsWith("uncached_decode.int8.onnx"))
        assertTrue(moonshine.cachedDecoder.endsWith("cached_decode.int8.onnx"))
        assertTrue(config.modelConfig.nemo.model.isEmpty())
    }

    @Test
    fun `an encoder decoder pair without a joiner is whisper, preferring int8`() {
        val config = detectConfig(
            modelDir(
                "sherpa-onnx-whisper-base.en",
                "base.en-encoder.onnx",
                "base.en-encoder.int8.onnx",
                "base.en-decoder.onnx",
                "base.en-decoder.int8.onnx",
                "base.en-tokens.txt",
            ),
        )!!

        assertEquals("whisper", config.modelConfig.modelType)
        assertTrue(config.modelConfig.whisper.encoder.endsWith("base.en-encoder.int8.onnx"))
        assertTrue(config.modelConfig.whisper.decoder.endsWith("base.en-decoder.int8.onnx"))
        assertTrue(config.modelConfig.tokens.endsWith("base.en-tokens.txt"))
    }

    @Test
    fun `a joiner alongside the pair makes it a nemo transducer`() {
        val config = detectConfig(
            modelDir(
                "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
                "encoder.int8.onnx",
                "decoder.int8.onnx",
                "joiner.int8.onnx",
                "tokens.txt",
            ),
        )!!

        assertEquals("nemo_transducer", config.modelConfig.modelType)
        assertTrue(config.modelConfig.transducer.joiner.endsWith("joiner.int8.onnx"))
        assertTrue(config.modelConfig.whisper.encoder.isEmpty())
    }

    @Test
    fun `sense voice is recognised by its directory name`() {
        val config = detectConfig(
            modelDir("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09", "model.int8.onnx", "tokens.txt"),
        )!!

        assertTrue(config.modelConfig.senseVoice.model.endsWith("model.int8.onnx"))
        assertTrue(config.modelConfig.senseVoice.useInverseTextNormalization)
        assertTrue(config.modelConfig.nemo.model.isEmpty())
    }

    @Test
    fun `a model name that is a path is refused before anything is loaded`() = runTest {
        val provider = LocalSherpaProvider(File(temp.root, "models").apply { mkdirs() })

        listOf("../../etc/passwd", "nested/model", "back\\slash", "..", "  ").forEach { name ->
            val result = provider.transcribe(testRequest(name), apiKey = null)

            assertTrue(name, result is TranscriptionResult.Failure)
            assertTrue(name, (result as TranscriptionResult.Failure).message.contains("not a valid model name"))
        }
    }

    @Test
    fun `a directory missing weights or tokens is not a model`() {
        assertNull(detectConfig(modelDir("empty")))
        assertNull(detectConfig(modelDir("no-tokens", "model.int8.onnx")))
        assertNull(detectConfig(modelDir("no-weights", "tokens.txt")))
    }

    @Test
    fun `only directories holding weights are offered as installed models`() {
        val models = File(temp.root, "installed").apply { mkdirs() }
        File(models, "sherpa-onnx-whisper-base.en").mkdirs()
        File(models, "sherpa-onnx-whisper-base.en/base.en-encoder.int8.onnx").writeText("x")
        File(models, "half-extracted").mkdirs()

        val offered = LocalSherpaProvider(models).models

        assertEquals(1, offered.size)
        assertEquals("local/sherpa-onnx-whisper-base.en", offered.single().id)
        assertEquals("Whisper Base", offered.single().displayName)
        assertEquals("English, strong punctuation", offered.single().note)
    }
}
