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
    fun `classifyAudioSnippet returns English for short or empty input`() {
        assertEquals(DetectedLanguage.ENGLISH, EarlyLidRouter.classifyAudioSnippet(ByteArray(0)))
        assertEquals(DetectedLanguage.ENGLISH, EarlyLidRouter.classifyAudioSnippet(ByteArray(1000)))
    }
}
