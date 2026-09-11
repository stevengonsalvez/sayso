package com.shotclubhouse.sayso.models

private const val RELEASE_BASE =
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"

/**
 * A downloadable on-device model. The archive unpacks to a directory named after
 * itself, so [dirName] doubles as the archive name and the installed folder name.
 */
data class LocalModel(
    val dirName: String,
    val displayName: String,
    val sizeMb: Int,
    val note: String,
    val recommended: Boolean = false,
) {
    val url: String get() = "$RELEASE_BASE/$dirName.tar.bz2"
}

/** Sizes measured from the release assets on 2026-09-11. */
object LocalModelCatalog {
    val all: List<LocalModel> = listOf(
        LocalModel(
            dirName = "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8",
            displayName = "Parakeet 110M",
            sizeMb = 104,
            note = "English, fast, good default",
            recommended = true,
        ),
        LocalModel(
            dirName = "sherpa-onnx-moonshine-tiny-en-int8",
            displayName = "Moonshine Tiny",
            sizeMb = 108,
            note = "English, smallest and quickest",
        ),
        LocalModel(
            dirName = "sherpa-onnx-moonshine-base-en-int8",
            displayName = "Moonshine Base",
            sizeMb = 251,
            note = "English, more accurate than Tiny",
        ),
        LocalModel(
            dirName = "sherpa-onnx-whisper-base.en",
            displayName = "Whisper Base",
            sizeMb = 209,
            note = "English, strong punctuation",
        ),
        LocalModel(
            dirName = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
            displayName = "Parakeet 0.6B v3",
            sizeMb = 487,
            note = "Best quality, multilingual, needs more memory",
        ),
        LocalModel(
            dirName = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09",
            displayName = "SenseVoice",
            sizeMb = 166,
            note = "Chinese, English, Japanese, Korean, Cantonese",
        ),
    )

    val default: LocalModel = all.first { it.recommended }

    fun byDirName(dirName: String): LocalModel? = all.firstOrNull { it.dirName == dirName }
}
