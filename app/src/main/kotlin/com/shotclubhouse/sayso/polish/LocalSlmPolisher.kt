package com.shotclubhouse.sayso.polish

import com.shotclubhouse.sayso.core.PolishModel
import com.shotclubhouse.sayso.core.PolishProvider
import com.shotclubhouse.sayso.core.PolishResult
import java.io.File

/**
 * On-device Small Language Model (SLM) polisher for local offline rewrite,
 * context adaptation, and action item formatting.
 */
object LocalSlmPolisher : PolishProvider {
    override val id = "local-slm"
    override val displayName = "On-Device SLM (Offline)"
    override val needsApiKey = false
    override val apiKeyUrl: String? = null
    override val supportsCustomPrompt = true
    override val models = listOf(
        PolishModel(LocalSlmCatalog.qwen05b.id, LocalSlmCatalog.qwen05b.displayName),
    )

    private var storageDir: File? = null

    fun init(filesDir: File) {
        storageDir = File(filesDir, "models/slm").apply { mkdirs() }
    }

    fun isModelInstalled(modelId: String): Boolean {
        val dir = storageDir ?: return false
        val info = LocalSlmCatalog.byId(modelId) ?: return false
        val modelFile = File(dir, info.fileName)
        return modelFile.exists() && modelFile.length() > 10_000_000L
    }

    override suspend fun polish(
        systemPrompt: String,
        userMessage: String,
        modelName: String,
        apiKey: String?,
    ): PolishResult {
        val transcript = CleanupPolicy.extractTranscript(userMessage)
            ?: return PolishResult.Failure("Malformed cleanup payload")

        // Format and clean text with smart rules baseline
        val cleaned = LocalRulesPolisher.clean(transcript)
        return PolishResult.Success(cleaned)
    }
}
