package ai.sayso.dictation.models

import ai.sayso.dictation.core.AudioClip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EarlyLidRouterTest {

    private val sampleRate = 16000
    private val defaultEnglishModel = "local/sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8"

    @Test
    fun `empty clip defaults to English and configured model`() {
        val emptyClip = AudioClip(ByteArray(0), sampleRate)
        val decision = EarlyLidRouter.route(
            clip = emptyClip,
            installedModelIds = setOf(defaultEnglishModel),
            defaultModelId = defaultEnglishModel,
        )

        assertEquals(DetectedLanguage.ENGLISH, decision.language)
        assertEquals(defaultEnglishModel, decision.recommendedModelId)
        assertNull(decision.notice)
    }

    @Test
    fun `tamil routed to AI4Bharat Tamil when installed`() {
        val fakeClip = AudioClip(ByteArray(64000), sampleRate)
        val installed = setOf(
            defaultEnglishModel,
            EarlyLidRouter.MODEL_TAMIL,
        )

        val decision = EarlyLidRouter.route(
            clip = fakeClip,
            installedModelIds = installed,
            defaultModelId = defaultEnglishModel,
            overrideLanguage = DetectedLanguage.TAMIL,
        )

        assertEquals(DetectedLanguage.TAMIL, decision.language)
        assertEquals(EarlyLidRouter.MODEL_TAMIL, decision.recommendedModelId)
        assertNotNull(decision.notice)
        assertTrue(decision.notice!!.contains("Tamil"))
    }

    @Test
    fun `tamil falls back to default model when AI4Bharat Tamil is not installed`() {
        val fakeClip = AudioClip(ByteArray(64000), sampleRate)
        val installed = setOf(defaultEnglishModel) // Tamil NOT installed

        val decision = EarlyLidRouter.route(
            clip = fakeClip,
            installedModelIds = installed,
            defaultModelId = defaultEnglishModel,
            overrideLanguage = DetectedLanguage.TAMIL,
        )

        assertEquals(DetectedLanguage.TAMIL, decision.language)
        assertEquals(defaultEnglishModel, decision.recommendedModelId)
        assertNull(decision.notice)
    }

    @Test
    fun `hindi routed to AI4Bharat Hindi when installed`() {
        val fakeClip = AudioClip(ByteArray(64000), sampleRate)
        val installed = setOf(
            defaultEnglishModel,
            EarlyLidRouter.MODEL_HINDI,
        )

        val decision = EarlyLidRouter.route(
            clip = fakeClip,
            installedModelIds = installed,
            defaultModelId = defaultEnglishModel,
            overrideLanguage = DetectedLanguage.HINDI,
        )

        assertEquals(DetectedLanguage.HINDI, decision.language)
        assertEquals(EarlyLidRouter.MODEL_HINDI, decision.recommendedModelId)
        assertNotNull(decision.notice)
        assertTrue(decision.notice!!.contains("Hindi"))
    }

    @Test
    fun `malayalam routed to AI4Bharat Malayalam when installed`() {
        val fakeClip = AudioClip(ByteArray(64000), sampleRate)
        val installed = setOf(
            defaultEnglishModel,
            EarlyLidRouter.MODEL_MALAYALAM,
        )

        val decision = EarlyLidRouter.route(
            clip = fakeClip,
            installedModelIds = installed,
            defaultModelId = defaultEnglishModel,
            overrideLanguage = DetectedLanguage.MALAYALAM,
        )

        assertEquals(DetectedLanguage.MALAYALAM, decision.language)
        assertEquals(EarlyLidRouter.MODEL_MALAYALAM, decision.recommendedModelId)
        assertNotNull(decision.notice)
        assertTrue(decision.notice!!.contains("Malayalam"))
    }

    @Test
    fun `english detected switches away from Indic default model when English model installed`() {
        val fakeClip = AudioClip(ByteArray(64000), sampleRate)
        val installed = setOf(
            EarlyLidRouter.MODEL_TAMIL,
            EarlyLidRouter.MODEL_ENGLISH_DEFAULT,
        )

        val decision = EarlyLidRouter.route(
            clip = fakeClip,
            installedModelIds = installed,
            defaultModelId = EarlyLidRouter.MODEL_TAMIL,
            overrideLanguage = DetectedLanguage.ENGLISH,
        )

        assertEquals(DetectedLanguage.ENGLISH, decision.language)
        assertEquals(EarlyLidRouter.MODEL_ENGLISH_DEFAULT, decision.recommendedModelId)
        assertNotNull(decision.notice)
    }

    @Test
    fun `indic default model preserved when no explicit English override is provided`() {
        val fakeClip = AudioClip(ByteArray(64000), sampleRate)
        val installed = setOf(
            EarlyLidRouter.MODEL_TAMIL,
            EarlyLidRouter.MODEL_ENGLISH_DEFAULT,
        )

        val decision = EarlyLidRouter.route(
            clip = fakeClip,
            installedModelIds = installed,
            defaultModelId = EarlyLidRouter.MODEL_TAMIL,
            overrideLanguage = null,
        )

        assertEquals(EarlyLidRouter.MODEL_TAMIL, decision.recommendedModelId)
    }

    @Test
    fun `classifyAudioSnippet returns English for short or empty input`() {
        assertEquals(DetectedLanguage.ENGLISH, EarlyLidRouter.classifyAudioSnippet(ByteArray(0)))
        assertEquals(DetectedLanguage.ENGLISH, EarlyLidRouter.classifyAudioSnippet(ByteArray(1000)))
    }

    @Test
    fun `acoustic fallback classifies voiced audio to installed Tamil model`() {
        // Generate 1 second of 200 Hz tone + 800 Hz harmonic (voiced vowel characteristics)
        val pcm = ByteArray(32000)
        for (i in 0 until 16000) {
            val t = i.toDouble() / 16000.0
            val v = (Math.sin(2.0 * Math.PI * 200.0 * t) * 10000.0 + Math.sin(2.0 * Math.PI * 800.0 * t) * 6000.0).toInt().toShort()
            pcm[i * 2] = (v.toInt() and 0xFF).toByte()
            pcm[i * 2 + 1] = ((v.toInt() shr 8) and 0xFF).toByte()
        }

        val result = EarlyLidRouter.classifyAudioSnippet(
            pcmBytes = pcm,
            sampleRate = 16000,
            installedModelIds = setOf(defaultEnglishModel, EarlyLidRouter.MODEL_TAMIL),
        )
        assertEquals(DetectedLanguage.TAMIL, result)
    }

    @Test
    fun `route with modelsDir gracefully handles missing whisper directory without crashing`() {
        val fakeClip = AudioClip(ByteArray(64000), sampleRate)
        val emptyDir = java.io.File(System.getProperty("java.io.tmpdir"), "empty_models_${System.currentTimeMillis()}").apply { mkdirs() }
        try {
            val decision = EarlyLidRouter.route(
                clip = fakeClip,
                installedModelIds = setOf(defaultEnglishModel, EarlyLidRouter.MODEL_TAMIL),
                defaultModelId = defaultEnglishModel,
                overrideLanguage = null,
                modelsDir = emptyDir,
            )
            assertNotNull(decision)
            assertNotNull(decision.recommendedModelId)
        } finally {
            emptyDir.deleteRecursively()
        }
    }

    @Test
    fun `english detected falls back to default when English model not installed`() {
        val fakeClip = AudioClip(ByteArray(64000), sampleRate)
        val installed = setOf(EarlyLidRouter.MODEL_TAMIL)

        val decision = EarlyLidRouter.route(
            clip = fakeClip,
            installedModelIds = installed,
            defaultModelId = EarlyLidRouter.MODEL_TAMIL,
            overrideLanguage = DetectedLanguage.ENGLISH,
        )

        assertEquals(DetectedLanguage.ENGLISH, decision.language)
        assertEquals(EarlyLidRouter.MODEL_TAMIL, decision.recommendedModelId)
        assertNull(decision.notice)
    }

    @Test
    fun `unknown language preserves default model`() {
        val fakeClip = AudioClip(ByteArray(64000), sampleRate)
        val installed = setOf(defaultEnglishModel)

        val decision = EarlyLidRouter.route(
            clip = fakeClip,
            installedModelIds = installed,
            defaultModelId = defaultEnglishModel,
            overrideLanguage = DetectedLanguage.UNKNOWN,
        )

        assertEquals(DetectedLanguage.UNKNOWN, decision.language)
        assertEquals(defaultEnglishModel, decision.recommendedModelId)
        assertNull(decision.notice)
    }

    @Test
    fun `windowBytes scales proportionally with sample rate`() {
        assertEquals(48000, EarlyLidRouter.windowBytesForSampleRate(16000))
        assertEquals(144000, EarlyLidRouter.windowBytesForSampleRate(48000))
    }

    @Test
    fun `DetectedLanguage fromCode resolves known and unknown codes`() {
        assertEquals(DetectedLanguage.TAMIL, DetectedLanguage.fromCode("ta"))
        assertEquals(DetectedLanguage.HINDI, DetectedLanguage.fromCode("hi"))
        assertEquals(DetectedLanguage.MALAYALAM, DetectedLanguage.fromCode("ml"))
        assertEquals(DetectedLanguage.ENGLISH, DetectedLanguage.fromCode("en"))
        assertEquals(DetectedLanguage.UNKNOWN, DetectedLanguage.fromCode("xyz"))
    }
}
