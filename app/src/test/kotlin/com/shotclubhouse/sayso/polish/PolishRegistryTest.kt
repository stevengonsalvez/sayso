package com.shotclubhouse.sayso.polish

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PolishRegistryTest {

    private val registry = PolishRegistry()

    @Test
    fun `lists every backend in a stable order`() {
        assertEquals(
            listOf("rules", "local-slm", "openai", "anthropic", "groq", "gemini", "openrouter"),
            registry.providers.map { it.id },
        )
        assertEquals("rules/basic", PolishRegistry.defaultModelId)
        assertTrue(registry.find(PolishRegistry.defaultModelId) != null)
    }

    @Test
    fun `every model id is unique and prefixed with its provider`() {
        val ids = registry.allModels().map { it.id }

        assertEquals(ids.size, ids.toSet().size)
        registry.providers.forEach { provider ->
            provider.models.forEach { model ->
                assertEquals(provider.id, model.providerId)
            }
        }
    }

    @Test
    fun `openrouter model names keep their vendor path`() {
        val (provider, model) = registry.find("openrouter/anthropic/claude-haiku-4.5")!!

        assertEquals("openrouter", provider.id)
        assertEquals("anthropic/claude-haiku-4.5", model.modelName)
    }

    @Test
    fun `unknown ids resolve to null`() {
        assertNull(registry.find("nope/nope"))
        assertNull(registry.find("openai/does-not-exist"))
        assertNull(registry.provider("nope"))
    }

    @Test
    fun `cloud providers advertise a key url`() {
        registry.providers.filter { it.needsApiKey }.forEach { provider ->
            assertTrue(provider.id, provider.apiKeyUrl?.startsWith("https://") == true)
        }
    }
}
