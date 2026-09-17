package ai.sayso.dictation.polish

/** Metadata for on-device small language models available for local download and execution. */
data class SlmModelInfo(
    val id: String,
    val displayName: String,
    val parameterCount: String,
    val quantizedSizeMb: Int,
    val description: String,
    val downloadUrl: String,
    val fileName: String,
    val sha256: String = "",
)

object LocalSlmCatalog {
    val qwen05b = SlmModelInfo(
        id = "local-slm/qwen2.5-0.5b",
        displayName = "Qwen 2.5 (0.5B) Instruct",
        parameterCount = "0.5B",
        quantizedSizeMb = 468,
        description = "Fast on-device SLM. Smart dictation, action items, and context rewrite with minimal battery usage.",
        downloadUrl = "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf",
        fileName = "qwen2.5-0.5b-instruct-q4_k_m.gguf",
    )

    val all: List<SlmModelInfo> = listOf(qwen05b)

    val default: SlmModelInfo = qwen05b

    fun byId(id: String): SlmModelInfo? = all.firstOrNull { it.id == id }
}
