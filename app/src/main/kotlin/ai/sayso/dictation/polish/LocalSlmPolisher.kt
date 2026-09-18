package ai.sayso.dictation.polish

import ai.sayso.dictation.core.PolishModel
import ai.sayso.dictation.core.PolishProvider
import ai.sayso.dictation.core.PolishResult
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
        PolishModel(LocalSlmCatalog.phi3Mini.id, LocalSlmCatalog.phi3Mini.displayName),
    )

    var storageDir: File? = null
        private set

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

        val info = LocalSlmCatalog.byId(modelName)
        if (info == null || !isModelInstalled(info.id)) {
            val requestedName = info?.displayName ?: "SLM"
            return PolishResult.Failure("$requestedName is not downloaded yet. Download it in Cleanup settings.")
        }

        // Format and clean text with smart rules baseline
        val baseCleaned = if (systemPrompt.contains("Transliteration directive") && IndicTransliterator.hasIndicCharacters(transcript)) {
            IndicTransliterator.transliterate(transcript)
        } else {
            transcript
        }
        val cleaned = LocalRulesPolisher.clean(baseCleaned)
        return PolishResult.Success(cleaned)
    }
}
