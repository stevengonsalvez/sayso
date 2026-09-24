package ai.sayso.dictation.ui

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.RadioButtonChecked
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.unit.sp
import ai.sayso.dictation.core.SettingsStore
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import ai.sayso.dictation.AppGraph
import ai.sayso.dictation.R
import ai.sayso.dictation.core.SttModel
import ai.sayso.dictation.core.TranscriptionProvider
import ai.sayso.dictation.service.DictationService
import ai.sayso.dictation.service.WakeWordService
import ai.sayso.dictation.settings.Settings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

/** Spoken languages offered to providers that accept a hint; null means auto-detect. */
private val LANGUAGES: List<Pair<String?, Int>> = listOf(
    null to R.string.lang_auto,
    "en" to R.string.lang_en,
    "es" to R.string.lang_es,
    "fr" to R.string.lang_fr,
    "de" to R.string.lang_de,
    "it" to R.string.lang_it,
    "pt" to R.string.lang_pt,
    "nl" to R.string.lang_nl,
    "hi" to R.string.lang_hi,
    "ta" to R.string.lang_ta,
    "ml" to R.string.lang_ml,
    "ja" to R.string.lang_ja,
    "ko" to R.string.lang_ko,
    "zh" to R.string.lang_zh,
)

private const val RECORDING_STEP_SECONDS = 30

/** Which engine turns speech into text, and the knobs that shape a recording. */
@Composable
fun TranscriptionScreen(onOpenLocalModels: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val settings = AppGraph.settings
        var selectedModel by remember { mutableStateOf(settings.sttModelId) }
    val initialIsCloud = selectedModel.substringBefore('/') != "local"
    var isCloudMode by remember { mutableStateOf(initialIsCloud) }
    var selectedCloudProviderId by remember {
        mutableStateOf(if (initialIsCloud) selectedModel.substringBefore('/') else "openai")
    }
    var language by remember { mutableStateOf(settings.language) }
    var hints by remember { mutableStateOf(settings.hints.joinToString(", ")) }
    var maxSeconds by remember { mutableFloatStateOf(settings.maxRecordingSeconds.toFloat()) }
    var sounds by remember { mutableStateOf(settings.soundsEnabled) }
    var history by remember { mutableStateOf(settings.historyEnabled) }
    var bubbleAlwaysVisible by remember { mutableStateOf(settings.bubbleAlwaysVisible) }
    var wakeWord by remember { mutableStateOf(settings.wakeWordEnabled) }
    var wakeWordPhrase by remember { mutableStateOf(settings.wakeWordPhrase) }
    var wakeWordSensitivity by remember { mutableStateOf(settings.wakeWordSensitivity) }
    var autoStopSilence by remember { mutableStateOf(settings.autoStopSilenceEnabled) }
    var silenceTimeout by remember { mutableFloatStateOf(settings.silenceTimeoutSeconds) }
    var autoLanguageRouting by remember { mutableStateOf(settings.autoLanguageRoutingEnabled) }
    var transliterateIndicToLatin by remember { mutableStateOf(settings.transliterateIndicToLatin) }
    var modelsByProvider by remember { mutableStateOf(emptyMap<String, List<SttModel>>()) }

    // Leaving the screen with the keyboard still up never blurs the field, so the last edit
    // is flushed on the way out as well.
    val pendingHints by rememberUpdatedState(hints)
    DisposableEffect(Unit) {
        onDispose { settings.hints = pendingHints.toCsvList() }
    }

    // The on-device provider lists its models by walking the models directory, so the whole
    // catalogue is read once off the main thread instead of on every recomposition.
    LaunchedEffect(Unit) {
        modelsByProvider = withContext(Dispatchers.IO) {
            AppGraph.stt.providers.associate { it.id to it.models }
        }
    }

    val micPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            wakeWord = true
            settings.wakeWordEnabled = true
            WakeWordService.start(context)
        } else {
            wakeWord = false
            settings.wakeWordEnabled = false
        }
    }

    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(bottom = 32.dp),
    ) {
        SectionHeader(stringResource(R.string.transcription_section_floating_and_wake))
        SwitchRow(
            title = stringResource(R.string.transcription_wake_word),
            subtitle = stringResource(R.string.transcription_wake_word_help),
            checked = wakeWord,
            onCheckedChange = { enabled ->
                if (enabled) {
                    if (!context.hasMicPermission()) {
                        micPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                    } else {
                        wakeWord = true
                        settings.wakeWordEnabled = true
                        WakeWordService.start(context)
                    }
                } else {
                    wakeWord = false
                    settings.wakeWordEnabled = false
                    WakeWordService.stop(context)
                }
            },
        )
        if (wakeWord) {
            WakeWordPhraseSelector(
                selectedPhrase = wakeWordPhrase,
                onSelectPhrase = { phrase ->
                    wakeWordPhrase = phrase
                    settings.wakeWordPhrase = phrase
                    WakeWordService.updatePhrase(phrase)
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp),
            )
            WakeWordSensitivitySelector(
                selectedSensitivity = wakeWordSensitivity,
                onSelectSensitivity = { sens ->
                    wakeWordSensitivity = sens
                    settings.wakeWordSensitivity = sens
                    WakeWordService.restartWithSettings(context)
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }
        SwitchRow(
            title = "Hands-free silence auto-stop",
            subtitle = "Automatically end recording when you pause speaking",
            checked = autoStopSilence,
            onCheckedChange = {
                autoStopSilence = it
                settings.autoStopSilenceEnabled = it
            },
        )
        if (autoStopSilence) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(
                        text = "Silence timeout",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        text = "${String.format("%.1f", silenceTimeout)}s",
                        style = MaterialTheme.typography.bodySmall,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
                Slider(
                    value = silenceTimeout,
                    onValueChange = {
                        silenceTimeout = it
                        settings.silenceTimeoutSeconds = it
                    },
                    valueRange = 1.0f..3.5f,
                    steps = 4,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
        SwitchRow(
            title = "Automatic language routing",
            subtitle = "Uses Whisper neural detector to route Tamil, Hindi, or Malayalam to AI4Bharat and English to Parakeet",
            checked = autoLanguageRouting,
            onCheckedChange = {
                autoLanguageRouting = it
                settings.autoLanguageRoutingEnabled = it
            },
        )
        SwitchRow(
            title = stringResource(R.string.transcription_bubble_always_visible),
            subtitle = stringResource(R.string.transcription_bubble_always_visible_help),
            checked = bubbleAlwaysVisible,
            onCheckedChange = {
                bubbleAlwaysVisible = it
                settings.bubbleAlwaysVisible = it
                DictationService.instance?.updateBubbleVisibility()
            },
        )

        SectionHeader(stringResource(R.string.transcription_section_recognition))

        val cloudProviders = remember { AppGraph.stt.providers.filter { it.id != "local" } }
        var keyUpdateTrigger by remember { mutableIntStateOf(0) }
        var savedKeyProviders by remember { mutableStateOf<Set<String>>(emptySet()) }

        LaunchedEffect(keyUpdateTrigger) {
            savedKeyProviders = withContext(Dispatchers.IO) {
                cloudProviders.filter { !AppGraph.secrets.get(it.id).isNullOrBlank() }.map { it.id }.toSet()
            }
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Surface(
                onClick = {
                    isCloudMode = false
                    val localModels = modelsByProvider["local"].orEmpty()
                    if (localModels.isNotEmpty()) {
                        selectedModel = localModels.first().id
                        settings.sttModelId = selectedModel
                        DictationService.instance?.reloadLocalModel()
                    }
                },
                shape = RoundedCornerShape(12.dp),
                color = if (!isCloudMode) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
                border = BorderStroke(
                    1.5.dp,
                    if (!isCloudMode) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant,
                ),
                modifier = Modifier.weight(1f),
            ) {
                Column(
                    modifier = Modifier.padding(vertical = 12.dp, horizontal = 12.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(
                        imageVector = Icons.Default.Download,
                        contentDescription = null,
                        tint = if (!isCloudMode) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        text = stringResource(R.string.transcription_mode_local),
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.Bold,
                        color = if (!isCloudMode) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurface,
                    )
                }
            }

            Surface(
                onClick = {
                    isCloudMode = true
                    val currentProvider = cloudProviders.firstOrNull { it.id == selectedCloudProviderId } ?: cloudProviders.firstOrNull()
                    if (currentProvider != null) {
                        val models = modelsByProvider[currentProvider.id].orEmpty()
                        if (models.isNotEmpty() && selectedModel.substringBefore('/') != currentProvider.id) {
                            selectedModel = models.first().id
                            settings.sttModelId = selectedModel
                        }
                    }
                },
                shape = RoundedCornerShape(12.dp),
                color = if (isCloudMode) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
                border = BorderStroke(
                    1.5.dp,
                    if (isCloudMode) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant,
                ),
                modifier = Modifier.weight(1f),
            ) {
                Column(
                    modifier = Modifier.padding(vertical = 12.dp, horizontal = 12.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(
                        imageVector = Icons.Default.Cloud,
                        contentDescription = null,
                        tint = if (isCloudMode) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        text = stringResource(R.string.transcription_mode_cloud),
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.Bold,
                        color = if (isCloudMode) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
        }

        if (!isCloudMode) {
            val localModels = modelsByProvider["local"].orEmpty()
            if (localModels.isEmpty() && modelsByProvider.isNotEmpty()) {
                Text(
                    stringResource(R.string.transcription_local_empty),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
                )
                Button(
                    onClick = onOpenLocalModels,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                ) { Text(stringResource(R.string.transcription_local_open)) }
            } else {
                for (model in localModels) {
                    val isIndic = model.id.contains("indicconformer")
                    val isEnglishBest = model.id.contains("parakeet")
                    val isWhisper = model.id.contains("whisper")
                    RadioRow(
                        title = model.displayName,
                        subtitle = model.note.takeIf { it.isNotBlank() },
                        selected = selectedModel == model.id,
                        onSelect = {
                            selectedModel = model.id
                            settings.sttModelId = model.id
                            DictationService.instance?.reloadLocalModel()
                        },
                        trailing = {
                            if (isIndic) {
                                Surface(
                                    shape = RoundedCornerShape(6.dp),
                                    color = Color(0xFFFEF3C7),
                                ) {
                                    Text(
                                        text = "★ Best for Dialects",
                                        style = MaterialTheme.typography.labelSmall,
                                        fontWeight = FontWeight.Bold,
                                        color = Color(0xFFB45309),
                                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                                    )
                                }
                            } else if (isEnglishBest) {
                                Surface(
                                    shape = RoundedCornerShape(6.dp),
                                    color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.5f),
                                ) {
                                    Text(
                                        text = "★ Best for English",
                                        style = MaterialTheme.typography.labelSmall,
                                        fontWeight = FontWeight.Bold,
                                        color = MaterialTheme.colorScheme.primary,
                                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                                    )
                                }
                            } else if (isWhisper) {
                                Surface(
                                    shape = RoundedCornerShape(6.dp),
                                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f),
                                ) {
                                    Text(
                                        text = "Multilingual",
                                        style = MaterialTheme.typography.labelSmall,
                                        fontWeight = FontWeight.Medium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                                    )
                                }
                            }
                        },
                    )
                }

                Surface(
                    onClick = onOpenLocalModels,
                    shape = RoundedCornerShape(12.dp),
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                ) {
                    Row(
                        modifier = Modifier.padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = "Manage on-device models",
                                style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.SemiBold,
                            )
                            Text(
                                text = "Download Indic (Tamil, Hindi, Malayalam), Whisper, Moonshine, or delete models",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Icon(
                            imageVector = Icons.Default.Download,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    }
                }
            }
        } else {
            SttProviderDropdown(
                providers = cloudProviders,
                selectedId = selectedCloudProviderId,
                savedKeyProviders = savedKeyProviders,
                onSelect = { providerId ->
                    selectedCloudProviderId = providerId
                    val models = modelsByProvider[providerId].orEmpty()
                    if (models.isNotEmpty()) {
                        selectedModel = models.first().id
                        settings.sttModelId = selectedModel
                    }
                },
            )

            val activeProvider = cloudProviders.firstOrNull { it.id == selectedCloudProviderId }
            if (activeProvider != null) {
                ApiKeyRow(
                    providerId = activeProvider.id,
                    providerName = activeProvider.displayName,
                    apiKeyUrl = activeProvider.apiKeyUrl,
                    onKeyChanged = { keyUpdateTrigger++ },
                )

                val models = modelsByProvider[activeProvider.id].orEmpty()
                if (models.isNotEmpty()) {
                    SttModelDropdown(
                        models = models,
                        selectedId = selectedModel,
                        onSelect = { modelId ->
                            selectedModel = modelId
                            settings.sttModelId = modelId
                        },
                    )
                }
            }
        }

        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))

        LanguageDropdown(
            selected = language,
            onSelect = {
                language = it
                settings.language = it
            },
        )

        val isIndic = language in listOf("ta", "hi", "ml", "te", "kn", "mr", "bn", "gu") || selectedModel.contains("indicconformer")
        if (isIndic) {
            TransliterationSettingsCard(
                transliterateToLatin = transliterateIndicToLatin,
                languageCode = language,
                onToggle = { enabled ->
                    transliterateIndicToLatin = enabled
                    settings.transliterateIndicToLatin = enabled
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 6.dp),
            )
        }

        OutlinedTextField(
            value = hints,
            onValueChange = { hints = it },
            label = { Text(stringResource(R.string.transcription_hints)) },
            supportingText = { Text(stringResource(R.string.transcription_hints_help)) },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp)
                // Saved when the field is done with, not on every keystroke: each write is a
                // SharedPreferences commit, and a half-typed word is not a hint.
                .onFocusChanged { if (!it.isFocused) settings.hints = hints.toCsvList() },
        )

        SectionHeader(stringResource(R.string.transcription_section_recording))

        Column(Modifier.padding(horizontal = 16.dp)) {
            Text(stringResource(R.string.transcription_max_seconds))
            Text(
                stringResource(R.string.transcription_max_seconds_value, maxSeconds.roundToInt()),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Slider(
                value = maxSeconds,
                onValueChange = { maxSeconds = it },
                onValueChangeFinished = { settings.maxRecordingSeconds = maxSeconds.roundToInt() },
                valueRange = Settings.MIN_RECORDING_SECONDS.toFloat()..Settings.MAX_RECORDING_SECONDS.toFloat(),
                steps = (Settings.MAX_RECORDING_SECONDS - Settings.MIN_RECORDING_SECONDS) / RECORDING_STEP_SECONDS - 1,
            )
        }

        SwitchRow(
            title = stringResource(R.string.transcription_sounds),
            subtitle = stringResource(R.string.transcription_sounds_help),
            checked = sounds,
            onCheckedChange = {
                sounds = it
                settings.soundsEnabled = it
            },
        )
        SwitchRow(
            title = stringResource(R.string.transcription_history),
            subtitle = stringResource(R.string.transcription_history_help),
            checked = history,
            onCheckedChange = {
                history = it
                settings.historyEnabled = it
            },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LanguageDropdown(selected: String?, onSelect: (String?) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val label = LANGUAGES.firstOrNull { it.first == selected }?.second ?: R.string.lang_auto

    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { expanded = it },
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        OutlinedTextField(
            value = stringResource(label),
            onValueChange = {},
            readOnly = true,
            label = { Text(stringResource(R.string.transcription_language)) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier
                .menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable)
                .fillMaxWidth(),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for ((code, nameRes) in LANGUAGES) {
                DropdownMenuItem(
                    text = { Text(stringResource(nameRes)) },
                    onClick = {
                        expanded = false
                        onSelect(code)
                    },
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SttProviderDropdown(
    providers: List<TranscriptionProvider>,
    selectedId: String,
    savedKeyProviders: Set<String>,
    onSelect: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val currentProvider = providers.firstOrNull { it.id == selectedId } ?: providers.firstOrNull()
    val currentDisplayName = currentProvider?.displayName.orEmpty()
    val hasKey = currentProvider?.let { savedKeyProviders.contains(it.id) } == true

    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { expanded = it },
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
    ) {
        OutlinedTextField(
            value = if (hasKey) "$currentDisplayName (Key saved)" else currentDisplayName,
            onValueChange = {},
            readOnly = true,
            label = { Text(stringResource(R.string.transcription_provider)) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier
                .menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable)
                .fillMaxWidth(),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for (provider in providers) {
                val providerHasKey = savedKeyProviders.contains(provider.id)
                DropdownMenuItem(
                    text = {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = provider.displayName,
                                fontWeight = if (provider.id == selectedId) FontWeight.Bold else FontWeight.Normal,
                            )
                            if (providerHasKey) {
                                Text(
                                    text = "Key saved",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = Color(0xFF16A34A),
                                    fontWeight = FontWeight.SemiBold,
                                )
                            }
                        }
                    },
                    onClick = {
                        expanded = false
                        onSelect(provider.id)
                    },
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SttModelDropdown(
    models: List<SttModel>,
    selectedId: String,
    onSelect: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val currentModel = models.firstOrNull { it.id == selectedId } ?: models.firstOrNull()

    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { expanded = it },
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
    ) {
        OutlinedTextField(
            value = currentModel?.displayName.orEmpty(),
            onValueChange = {},
            readOnly = true,
            label = { Text(stringResource(R.string.transcription_model)) },
            supportingText = currentModel?.note?.takeIf { it.isNotBlank() }?.let { { Text(it) } },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier
                .menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable)
                .fillMaxWidth(),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for (model in models) {
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(
                                text = model.displayName,
                                fontWeight = if (model.id == selectedId) FontWeight.Bold else FontWeight.Normal,
                            )
                            if (model.note.isNotBlank()) {
                                Text(
                                    text = model.note,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    },
                    onClick = {
                        expanded = false
                        onSelect(model.id)
                    },
                )
            }
        }
    }
}

@Composable
fun WakeWordPhraseSelector(
    selectedPhrase: String,
    onSelectPhrase: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
        modifier = modifier,
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = stringResource(R.string.wake_word_phrase_label),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.Bold,
            )
            Text(
                text = stringResource(R.string.wake_word_phrase_subtitle),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            val options = listOf(
                SettingsStore.WAKE_PHRASE_BOTH to stringResource(R.string.wake_word_phrase_both),
                SettingsStore.WAKE_PHRASE_HEY to stringResource(R.string.wake_word_phrase_hey_only),
                SettingsStore.WAKE_PHRASE_SAYSO to stringResource(R.string.wake_word_phrase_sayso_only),
            )

            for ((phraseKey, label) in options) {
                val isSelected = selectedPhrase == phraseKey
                Surface(
                    onClick = { onSelectPhrase(phraseKey) },
                    shape = RoundedCornerShape(8.dp),
                    color = if (isSelected) MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.5f) else MaterialTheme.colorScheme.surface,
                    border = BorderStroke(
                        if (isSelected) 1.5.dp else 1.dp,
                        if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                    ),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(
                            imageVector = if (isSelected) Icons.Default.RadioButtonChecked else Icons.Default.RadioButtonUnchecked,
                            contentDescription = null,
                            tint = if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(18.dp),
                        )
                        Text(
                            text = label,
                            style = MaterialTheme.typography.bodySmall,
                            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                            color = if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun WakeWordSensitivitySelector(
    selectedSensitivity: String,
    onSelectSensitivity: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
        modifier = modifier,
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = stringResource(R.string.wake_word_sensitivity_label),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.Bold,
            )
            Text(
                text = stringResource(R.string.wake_word_sensitivity_subtitle),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            val options = remember {
                listOf(
                    Triple(
                        SettingsStore.WAKE_SENSITIVITY_HIGH,
                        R.string.wake_word_sensitivity_high,
                        R.string.wake_word_sensitivity_high_desc,
                    ),
                    Triple(
                        SettingsStore.WAKE_SENSITIVITY_DEFAULT,
                        R.string.wake_word_sensitivity_medium,
                        R.string.wake_word_sensitivity_medium_desc,
                    ),
                    Triple(
                        SettingsStore.WAKE_SENSITIVITY_LOW,
                        R.string.wake_word_sensitivity_low,
                        R.string.wake_word_sensitivity_low_desc,
                    ),
                )
            }

            for ((key, titleRes, descRes) in options) {
                val isSelected = selectedSensitivity == key
                Surface(
                    onClick = {
                        if (selectedSensitivity != key) {
                            onSelectSensitivity(key)
                        }
                    },
                    shape = RoundedCornerShape(8.dp),
                    color = if (isSelected) MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.5f) else MaterialTheme.colorScheme.surface,
                    border = BorderStroke(
                        if (isSelected) 1.5.dp else 1.dp,
                        if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                    ),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.Top,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(
                            imageVector = if (isSelected) Icons.Default.RadioButtonChecked else Icons.Default.RadioButtonUnchecked,
                            contentDescription = null,
                            tint = if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier
                                .size(18.dp)
                                .padding(top = 2.dp),
                        )
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(
                                text = stringResource(titleRes),
                                style = MaterialTheme.typography.bodySmall,
                                fontWeight = if (isSelected) FontWeight.Bold else FontWeight.SemiBold,
                                color = if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                            )
                            Text(
                                text = stringResource(descRes),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun TransliterationSettingsCard(
    transliterateToLatin: Boolean,
    languageCode: String?,
    onToggle: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val langTitle = when (languageCode) {
        "hi" -> "Hinglish"
        "ml" -> "Manglish"
        "ta" -> "Tanglish"
        else -> "Tanglish / Hinglish / Manglish"
    }

    val exampleLatin = when (languageCode) {
        "hi" -> "Namaste, aap kaise hain?"
        "ml" -> "Namaskaram, sugamano?"
        "ta" -> "Vanakkam, eppadi irukkeenga?"
        else -> "Vanakkam, eppadi irukkeenga?"
    }

    val exampleNative = when (languageCode) {
        "hi" -> "नमस्ते, आप कैसे हैं?"
        "ml" -> "നമസ്കാരം, സുഖമാണോ?"
        "ta" -> "வணக்கம், எப்படி இருக்கீங்க?"
        else -> "வணக்கம், எப்படி இருக்கீங்க?"
    }

    Surface(
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
        modifier = modifier,
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Indic Transliteration ($langTitle)",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        text = "Choose how spoken words are formatted when you dictate in Indian languages",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(
                    checked = transliterateToLatin,
                    onCheckedChange = onToggle,
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // Option 1: Tanglish / Hinglish / Manglish
                Surface(
                    onClick = { onToggle(true) },
                    shape = RoundedCornerShape(12.dp),
                    color = if (transliterateToLatin) {
                        MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.35f)
                    } else {
                        MaterialTheme.colorScheme.surface
                    },
                    border = BorderStroke(
                        if (transliterateToLatin) 1.5.dp else 1.dp,
                        if (transliterateToLatin) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f),
                    ),
                    modifier = Modifier.weight(1f),
                ) {
                    Column(Modifier.padding(10.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                imageVector = if (transliterateToLatin) Icons.Default.RadioButtonChecked else Icons.Default.RadioButtonUnchecked,
                                contentDescription = null,
                                tint = if (transliterateToLatin) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = langTitle,
                                style = MaterialTheme.typography.labelSmall,
                                fontWeight = FontWeight.Bold,
                            )
                        }
                        Spacer(Modifier.height(4.dp))
                        Text(
                            text = "English letters",
                            style = MaterialTheme.typography.bodySmall,
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Spacer(Modifier.height(6.dp))
                        Surface(
                            shape = RoundedCornerShape(6.dp),
                            color = MaterialTheme.colorScheme.surface,
                            border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Column(Modifier.padding(6.dp)) {
                                Text(
                                    text = "Example:",
                                    fontSize = 9.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = MaterialTheme.colorScheme.primary,
                                )
                                Text(
                                    text = "\"$exampleLatin\"",
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Medium,
                                    fontStyle = FontStyle.Italic,
                                )
                            }
                        }
                    }
                }

                // Option 2: Native Script
                Surface(
                    onClick = { onToggle(false) },
                    shape = RoundedCornerShape(12.dp),
                    color = if (!transliterateToLatin) {
                        MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.35f)
                    } else {
                        MaterialTheme.colorScheme.surface
                    },
                    border = BorderStroke(
                        if (!transliterateToLatin) 1.5.dp else 1.dp,
                        if (!transliterateToLatin) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f),
                    ),
                    modifier = Modifier.weight(1f),
                ) {
                    Column(Modifier.padding(10.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                imageVector = if (!transliterateToLatin) Icons.Default.RadioButtonChecked else Icons.Default.RadioButtonUnchecked,
                                contentDescription = null,
                                tint = if (!transliterateToLatin) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = stringResource(R.string.onboarding_translit_native_title),
                                style = MaterialTheme.typography.labelSmall,
                                fontWeight = FontWeight.Bold,
                            )
                        }
                        Spacer(Modifier.height(4.dp))
                        Text(
                            text = "Native script",
                            style = MaterialTheme.typography.bodySmall,
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Spacer(Modifier.height(6.dp))
                        Surface(
                            shape = RoundedCornerShape(6.dp),
                            color = MaterialTheme.colorScheme.surface,
                            border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Column(Modifier.padding(6.dp)) {
                                Text(
                                    text = "Example:",
                                    fontSize = 9.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = MaterialTheme.colorScheme.primary,
                                )
                                Text(
                                    text = "\"$exampleNative\"",
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Medium,
                                    fontStyle = FontStyle.Italic,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
