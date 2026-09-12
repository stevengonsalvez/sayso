package com.shotclubhouse.sayso.settings

import com.shotclubhouse.sayso.core.LexiconRule
import com.shotclubhouse.sayso.core.SettingsStore

/** Test double for [SettingsStore] with the same defaults as the SharedPreferences version. */
class InMemorySettings(
    override var sttModelId: String = Settings.DEFAULT_STT_MODEL_ID,
    override var language: String? = null,
    override var hints: List<String> = emptyList(),
    override var polishEnabled: Boolean = false,
    override var polishModelId: String = Settings.DEFAULT_POLISH_MODEL_ID,
    override var customPrompt: String? = null,
    override var outputLanguage: String? = null,
    override var lexicon: List<LexiconRule> = emptyList(),
    override var maxRecordingSeconds: Int = Settings.DEFAULT_MAX_RECORDING_SECONDS,
    override var soundsEnabled: Boolean = true,
    override var historyEnabled: Boolean = true,
    override var bubbleX: Int = Settings.DEFAULT_BUBBLE_POSITION,
    override var bubbleY: Int = Settings.DEFAULT_BUBBLE_POSITION,
    override var bubbleAlwaysVisible: Boolean = false,
    override var wakeWordEnabled: Boolean = false,
) : SettingsStore
