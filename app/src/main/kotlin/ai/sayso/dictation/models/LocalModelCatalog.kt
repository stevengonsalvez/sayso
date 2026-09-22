package ai.sayso.dictation.models

private const val RELEASE_BASE =
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
private const val AI4BHARAT_BASE =
    "https://huggingface.co/parismitaglobalsolutions/indicconformer-sherpa-onnx/resolve/main"

/** A single file to download directly when the model is not distributed as a tar archive. */
data class ModelFile(
    val url: String,
    val relativePath: String,
    val sizeBytes: Long,
    val sha256: String,
)

/**
 * A downloadable on-device model. For archive models, the archive unpacks to a directory
 * named after itself, so [dirName] doubles as the archive name and the installed folder name.
 * For multi-file models, [files] defines the remote URLs and relative target paths.
 */
data class LocalModel(
    val dirName: String,
    val displayName: String,
    val sizeMb: Int,
    val note: String,
    /** SHA-256 of the release archive; required for archive models. */
    val sha256: String = "",
    val recommended: Boolean = false,
    val files: List<ModelFile> = emptyList(),
) {
    val url: String get() = "$RELEASE_BASE/$dirName.tar.bz2"
}

/** Sizes and checksums measured from the release assets on 2026-09-11 and HF assets on 2026-09-17. */
object LocalModelCatalog {
    val all: List<LocalModel> = listOf(
        LocalModel(
            dirName = "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8",
            displayName = "Parakeet 110M",
            sizeMb = 104,
            note = "English, fast, good default (Recommended for English)",
            sha256 = "17f945007b52ccd8b7200ffc7c5652e9e8e961dfdf479cefcabd06cf5703630b",
            recommended = true,
        ),
        LocalModel(
            dirName = "sherpa-onnx-whisper-tiny",
            displayName = "Whisper Multilingual Tiny",
            sizeMb = 111,
            note = "Multilingual (English + Indic). Note: Lower dialect accuracy than AI4Bharat",
            sha256 = "c46116994e539aa165266d96b325252728429c12535eb9d8b6a2b10f129e66b1",
        ),
        LocalModel(
            dirName = "sherpa-onnx-whisper-base",
            displayName = "Whisper Multilingual Base",
            sizeMb = 198,
            note = "Multilingual (English + Indic). Higher Whisper accuracy, but lower dialect accuracy than AI4Bharat",
            sha256 = "911b2083efd7c0dca2ac3b358b75222660dc09fb716d64fbfc417ba6c99ff3de",
        ),
        LocalModel(
            dirName = "ai4bharat-indicconformer-ta",
            displayName = "AI4Bharat Tamil (Colloquial)",
            sizeMb = 189,
            note = "Best accuracy for colloquial Tamil, Tanglish, and dialects (Recommended for Tamil)",
            files = listOf(
                ModelFile(
                    url = "$AI4BHARAT_BASE/ta/model.int8.onnx",
                    relativePath = "model.int8.onnx",
                    sizeBytes = 197595513L,
                    sha256 = "abb7b59d706b8d27ba3fb5e5e3db7671c9e1a09bf7bc6122de507c60030e65fb",
                ),
                ModelFile(
                    url = "$AI4BHARAT_BASE/tokens.txt",
                    relativePath = "tokens.txt",
                    sizeBytes = 67605L,
                    sha256 = "ee60967630213f31951817ac8b402b92ec18cce80718a24a49b388e56672dfb2",
                ),
            ),
        ),
        LocalModel(
            dirName = "ai4bharat-indicconformer-hi",
            displayName = "AI4Bharat Hindi (Colloquial)",
            sizeMb = 189,
            note = "Best accuracy for colloquial Hindi, Hinglish, and dialects (Recommended for Hindi)",
            files = listOf(
                ModelFile(
                    url = "$AI4BHARAT_BASE/hi/model.int8.onnx",
                    relativePath = "model.int8.onnx",
                    sizeBytes = 197595593L,
                    sha256 = "915c71e04dd7e5378a4057fdebb252b3a587188e4e99db6d7ce0909ad5ad05fa",
                ),
                ModelFile(
                    url = "$AI4BHARAT_BASE/tokens.txt",
                    relativePath = "tokens.txt",
                    sizeBytes = 67605L,
                    sha256 = "ee60967630213f31951817ac8b402b92ec18cce80718a24a49b388e56672dfb2",
                ),
            ),
        ),
        LocalModel(
            dirName = "ai4bharat-indicconformer-ml",
            displayName = "AI4Bharat Malayalam (Colloquial)",
            sizeMb = 189,
            note = "Best accuracy for colloquial Malayalam and dialects (Recommended for Malayalam)",
            files = listOf(
                ModelFile(
                    url = "$AI4BHARAT_BASE/ml/model.int8.onnx",
                    relativePath = "model.int8.onnx",
                    sizeBytes = 197595555L,
                    sha256 = "dcbdfa9f773db910508b40b703cb76c5974e8d4c6f123ea81265b40853c3f0c2",
                ),
                ModelFile(
                    url = "$AI4BHARAT_BASE/tokens.txt",
                    relativePath = "tokens.txt",
                    sizeBytes = 67605L,
                    sha256 = "ee60967630213f31951817ac8b402b92ec18cce80718a24a49b388e56672dfb2",
                ),
            ),
        ),
        LocalModel(
            dirName = "sherpa-onnx-moonshine-tiny-en-int8",
            displayName = "Moonshine Tiny",
            sizeMb = 108,
            note = "English, smallest and quickest",
            sha256 = "d5fe6ec4334fef36255b2a4010412cad4c007e33103fec62fb5d17cad88086f2",
        ),
        LocalModel(
            dirName = "sherpa-onnx-moonshine-base-en-int8",
            displayName = "Moonshine Base",
            sizeMb = 251,
            note = "English, more accurate than Tiny",
            sha256 = "21870cecaa2e44e4e2bf63e02d1072bed183ccd10284871353bd9d24dad14e5e",
        ),
        LocalModel(
            dirName = "sherpa-onnx-whisper-base.en",
            displayName = "Whisper Base (English)",
            sizeMb = 209,
            note = "English, strong punctuation",
            sha256 = "475bc7052ce299c007f6d5d5407ba8601f819a2867f6eecee510ed17df581542",
        ),
        LocalModel(
            dirName = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
            displayName = "Parakeet 0.6B v3",
            sizeMb = 487,
            note = "Best quality, multilingual, needs more memory",
            sha256 = "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf",
        ),
        LocalModel(
            dirName = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09",
            displayName = "SenseVoice",
            sizeMb = 166,
            note = "Chinese, English, Japanese, Korean, Cantonese",
            sha256 = "7305f7905bfcf77fa0b39388a313f3da35c68d971661a65475b56fb2162c8e63",
        ),
    )

    val default: LocalModel = all.first { it.recommended }

    val indicModels: List<LocalModel> = all.filter { it.dirName.startsWith("ai4bharat-") }

    fun byDirName(dirName: String): LocalModel? = all.firstOrNull { it.dirName == dirName }

    /**
     * Resolves the recommended on-device speech model based on user language preferences.
     * Foreign languages or multilingual Indian selection route to Whisper Multilingual Tiny.
     * Specific Indian languages route to dedicated colloquial AI4Bharat IndicConformer models.
     * Default English-only preference routes to Parakeet 110M.
     */
    fun resolveForLanguages(
        interestedInIndianLanguages: Boolean,
        interestedInForeignLanguages: Boolean,
        primaryIndicLanguage: String = "ta",
    ): LocalModel {
        return when {
            interestedInIndianLanguages -> {
                when (primaryIndicLanguage.lowercase()) {
                    "ta", "tamil" -> byDirName("ai4bharat-indicconformer-ta") ?: default
                    "hi", "hindi" -> byDirName("ai4bharat-indicconformer-hi") ?: default
                    "ml", "malayalam" -> byDirName("ai4bharat-indicconformer-ml") ?: default
                    "all" -> if (interestedInForeignLanguages) (byDirName("sherpa-onnx-whisper-tiny") ?: default) else (byDirName("ai4bharat-indicconformer-ta") ?: default)
                    else -> byDirName("ai4bharat-indicconformer-ta") ?: default
                }
            }
            interestedInForeignLanguages -> {
                byDirName("sherpa-onnx-whisper-tiny") ?: default
            }
            else -> default
        }
    }

    /**
     * Resolves model for a direct language selection ("en", "ta", "hi", "ml", "multi").
     */
    fun modelForLanguage(languageCode: String): LocalModel {
        return when (languageCode.lowercase().trim()) {
            "ta", "tamil" -> byDirName("ai4bharat-indicconformer-ta") ?: default
            "hi", "hindi" -> byDirName("ai4bharat-indicconformer-hi") ?: default
            "ml", "malayalam" -> byDirName("ai4bharat-indicconformer-ml") ?: default
            "multi", "multilingual", "auto" -> byDirName("sherpa-onnx-whisper-tiny") ?: default
            else -> default
        }
    }
}

