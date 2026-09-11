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
    /** SHA-256 of the release archive; required, a blank one fails the download. */
    val sha256: String,
    val recommended: Boolean = false,
) {
    val url: String get() = "$RELEASE_BASE/$dirName.tar.bz2"
}

/** Sizes and checksums measured from the release assets on 2026-09-11. */
object LocalModelCatalog {
    val all: List<LocalModel> = listOf(
        LocalModel(
            dirName = "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8",
            displayName = "Parakeet 110M",
            sizeMb = 104,
            note = "English, fast, good default",
            sha256 = "17f945007b52ccd8b7200ffc7c5652e9e8e961dfdf479cefcabd06cf5703630b",
            recommended = true,
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
            displayName = "Whisper Base",
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

    fun byDirName(dirName: String): LocalModel? = all.firstOrNull { it.dirName == dirName }
}
