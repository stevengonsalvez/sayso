package ai.sayso.dictation.models

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalModelCatalogTest {

    @Test
    fun `every entry points at a well formed download target`() {
        LocalModelCatalog.all.forEach { model ->
            if (model.files.isEmpty()) {
                val url = model.url.toHttpUrlOrNull()
                assertNotNull("${model.dirName} has an unparseable url", url)
                assertEquals("https", url!!.scheme)
                assertEquals("github.com", url.host)
                assertTrue(url.encodedPath.startsWith("/k2-fsa/sherpa-onnx/releases/download/asr-models/"))
                assertEquals("${model.dirName}.tar.bz2", url.pathSegments.last())
            } else {
                model.files.forEach { file ->
                    val url = file.url.toHttpUrlOrNull()
                    assertNotNull("${file.relativePath} has an unparseable url", url)
                    assertEquals("https", url!!.scheme)
                    assertTrue(file.sha256.matches(Regex("[0-9a-f]{64}")))
                }
            }
        }
    }

    @Test
    fun `entries are unique and described`() {
        val dirNames = LocalModelCatalog.all.map { it.dirName }

        assertEquals(dirNames.size, dirNames.toSet().size)
        LocalModelCatalog.all.forEach {
            assertTrue(it.displayName.isNotBlank())
            assertTrue(it.note.isNotBlank())
            assertTrue("${it.dirName} has an implausible size", it.sizeMb in 50..1000)
            if (it.files.isEmpty()) {
                assertTrue("${it.dirName} has no pinned checksum", it.sha256.matches(Regex("[0-9a-f]{64}")))
            } else {
                it.files.forEach { file ->
                    assertTrue("${file.relativePath} has no pinned checksum", file.sha256.matches(Regex("[0-9a-f]{64}")))
                }
            }
        }
    }

    @Test
    fun `exactly one model is recommended and it is the default`() {
        val recommended = LocalModelCatalog.all.filter { it.recommended }

        assertEquals(1, recommended.size)
        assertEquals(recommended.single(), LocalModelCatalog.default)
        assertEquals("sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8", LocalModelCatalog.default.dirName)
    }

    @Test
    fun `lookup by directory name matches what the downloader unpacks`() {
        assertEquals("Whisper Base (English)", LocalModelCatalog.byDirName("sherpa-onnx-whisper-base.en")?.displayName)
        assertEquals("AI4Bharat Tamil (Colloquial)", LocalModelCatalog.byDirName("ai4bharat-indicconformer-ta")?.displayName)
        assertEquals("Whisper Multilingual Tiny", LocalModelCatalog.byDirName("sherpa-onnx-whisper-tiny")?.displayName)
        assertNull(LocalModelCatalog.byDirName("sherpa-onnx-not-shipped"))
    }

    @Test
    fun `indicModels contains all AI4Bharat models for language routing`() {
        val indic = LocalModelCatalog.indicModels
        assertEquals(3, indic.size)
        val dirNames = indic.map { it.dirName }.toSet()
        assertTrue(dirNames.contains("ai4bharat-indicconformer-ta"))
        assertTrue(dirNames.contains("ai4bharat-indicconformer-hi"))
        assertTrue(dirNames.contains("ai4bharat-indicconformer-ml"))
    }

    @Test
    fun `resolveForLanguages routes to AI4Bharat for specific Indic languages`() {
        assertEquals("ai4bharat-indicconformer-ta", LocalModelCatalog.resolveForLanguages(true, false, "ta").dirName)
        assertEquals("ai4bharat-indicconformer-hi", LocalModelCatalog.resolveForLanguages(true, false, "hi").dirName)
        assertEquals("ai4bharat-indicconformer-ml", LocalModelCatalog.resolveForLanguages(true, false, "ml").dirName)
        assertEquals("ai4bharat-indicconformer-ta", LocalModelCatalog.resolveForLanguages(true, false, "all").dirName)
    }

    @Test
    fun `resolveForLanguages prioritizes AI4Bharat when Indian language is selected`() {
        assertEquals("ai4bharat-indicconformer-ta", LocalModelCatalog.resolveForLanguages(true, true, "ta").dirName)
        assertEquals("ai4bharat-indicconformer-hi", LocalModelCatalog.resolveForLanguages(true, true, "hi").dirName)
        assertEquals("ai4bharat-indicconformer-ml", LocalModelCatalog.resolveForLanguages(true, true, "ml").dirName)
        assertEquals("sherpa-onnx-whisper-tiny", LocalModelCatalog.resolveForLanguages(true, true, "all").dirName)
        assertEquals("sherpa-onnx-whisper-tiny", LocalModelCatalog.resolveForLanguages(false, true, "en").dirName)
    }

    @Test
    fun `resolveForLanguages routes to Parakeet for default English only`() {
        assertEquals("sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8", LocalModelCatalog.resolveForLanguages(false, false).dirName)
    }

    @Test
    fun `modelForLanguage directly resolves AI4Bharat for Indic codes and Parakeet for English`() {
        assertEquals("ai4bharat-indicconformer-ta", LocalModelCatalog.modelForLanguage("ta").dirName)
        assertEquals("ai4bharat-indicconformer-hi", LocalModelCatalog.modelForLanguage("hi").dirName)
        assertEquals("ai4bharat-indicconformer-ml", LocalModelCatalog.modelForLanguage("ml").dirName)
        assertEquals("sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8", LocalModelCatalog.modelForLanguage("en").dirName)
        assertEquals("sherpa-onnx-whisper-tiny", LocalModelCatalog.modelForLanguage("multi").dirName)
    }
}

