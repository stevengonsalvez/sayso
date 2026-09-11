package com.shotclubhouse.sayso.stt

import com.shotclubhouse.sayso.models.LocalModelCatalog
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class SttRegistryTest {

    @get:Rule val temp = TemporaryFolder()

    private fun registry() = SttRegistry(LocalSherpaProvider(File(temp.root, "models").apply { mkdirs() }))

    @Test
    fun `lists every backend once, local first`() {
        val ids = registry().providers.map { it.id }

        assertEquals(listOf("local", "openai", "deepgram", "groq", "elevenlabs", "gemini"), ids)
    }

    @Test
    fun `every cloud model id is namespaced by its provider`() {
        registry().providers.forEach { provider ->
            provider.models.forEach { model ->
                assertEquals(provider.id, model.providerId)
                assertTrue(model.displayName.isNotBlank())
            }
        }
    }

    @Test
    fun `find resolves a model id back to its provider`() {
        val (provider, model) = registry().find("deepgram/nova-3")!!

        assertEquals("deepgram", provider.id)
        assertEquals("nova-3", model.modelName)
    }

    @Test
    fun `find returns null for an unknown provider or model`() {
        assertNull(registry().find("nosuch/model"))
        assertNull(registry().find("openai/not-a-model"))
    }

    @Test
    fun `the default model is the recommended local one`() {
        assertEquals("local/${LocalModelCatalog.default.dirName}", registry().defaultModelId)
    }

    @Test
    fun `an empty models directory means no local models are offered`() {
        assertTrue(registry().provider("local")!!.models.isEmpty())
    }
}
