package ai.sayso.dictation.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.draw.clip
import kotlin.math.roundToInt
import ai.sayso.dictation.models.DownloadState
import ai.sayso.dictation.polish.LocalSlmCatalog
import ai.sayso.dictation.polish.LocalSlmPolisher
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.sayso.dictation.AppGraph
import ai.sayso.dictation.R
import ai.sayso.dictation.core.PolishModel
import ai.sayso.dictation.core.PolishProvider
import ai.sayso.dictation.polish.CleanupPolicy
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Shown in the preset list alongside the named presets. */
private const val CUSTOM_PRESET = "__custom__"

private enum class PostProcessingMode {
    NO_LLM,
    LOCAL_LLM,
    CLOUD_LLM,
}

/**
 * Which preset the saved prompt corresponds to. A null prompt means the built-in
 * one, anything that is not byte-identical to a preset is the user's own text.
 */
private fun presetKeyFor(prompt: String?): String {
    if (prompt == null) return CleanupPolicy.PRESETS.keys.first()
    return CleanupPolicy.PRESETS.entries
        .filter { it.value != CleanupPolicy.BASE_PROMPT }
        .firstOrNull { it.value == prompt }?.key ?: CUSTOM_PRESET
}

/** Post-processing backend, key, and the instructions the model is given. */
@Composable
fun CleanupScreen(modifier: Modifier = Modifier) {
    val settings = AppGraph.settings
    var enabled by remember { mutableStateOf(settings.polishEnabled) }
    var selectedModel by remember { mutableStateOf(settings.polishModelId) }
    val initialMode = when {
        selectedModel.startsWith("rules/") -> PostProcessingMode.NO_LLM
        selectedModel.startsWith("local-slm/") -> PostProcessingMode.LOCAL_LLM
        else -> PostProcessingMode.CLOUD_LLM
    }
    var mode by remember { mutableStateOf(initialMode) }

    val cloudProviders = remember {
        AppGraph.polish.providers.filter { it.id != "rules" && it.id != "local-slm" }
    }
    var selectedCloudProviderId by remember {
        mutableStateOf(if (initialMode == PostProcessingMode.CLOUD_LLM) selectedModel.substringBefore('/') else "openai")
    }
    var keyUpdateTrigger by remember { mutableIntStateOf(0) }
    var savedKeyProviders by remember { mutableStateOf<Set<String>>(emptySet()) }

    LaunchedEffect(keyUpdateTrigger) {
        savedKeyProviders = withContext(Dispatchers.IO) {
            cloudProviders.filter { !AppGraph.secrets.get(it.id).isNullOrBlank() }.map { it.id }.toSet()
        }
    }

    var presetKey by remember { mutableStateOf(presetKeyFor(settings.customPrompt)) }
    var customText by remember {
        mutableStateOf(settings.customPrompt ?: CleanupPolicy.BASE_PROMPT)
    }
    var outputLanguage by remember { mutableStateOf(settings.outputLanguage.orEmpty()) }
    var appContextAware by remember { mutableStateOf(settings.appContextAwarenessEnabled) }
    var smartDictation by remember { mutableStateOf(settings.smartDictationModesEnabled) }
    var transliterateIndic by remember { mutableStateOf(settings.transliterateIndicToLatin) }
    var previewOpen by remember { mutableStateOf(false) }

    val slmDownloads = AppGraph.slmDownloads
    val slmStorageDir = remember { LocalSlmPolisher.storageDir }
    var slmRefreshTrigger by remember { mutableIntStateOf(0) }
    var installedSlmIds by remember { mutableStateOf(emptySet<String>()) }
    var pendingDeleteSlm by remember { mutableStateOf<ai.sayso.dictation.polish.SlmModelInfo?>(null) }
    var previewPromptPreset by remember { mutableStateOf<Pair<String, String>?>(null) }

    LaunchedEffect(slmRefreshTrigger, slmDownloads.busy) {
        if (slmStorageDir != null) {
            installedSlmIds = withContext(Dispatchers.IO) {
                LocalSlmCatalog.all.filter { slmDownloads.isInstalled(it, slmStorageDir) }.map { it.id }.toSet()
            }
        }
    }

    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(bottom = 32.dp),
    ) {
        SwitchRow(
            title = stringResource(R.string.cleanup_enabled),
            subtitle = stringResource(R.string.cleanup_enabled_help),
            checked = enabled,
            onCheckedChange = {
                enabled = it
                settings.polishEnabled = it
            },
        )
        HorizontalDivider()

        SectionHeader(stringResource(R.string.screen_cleanup))

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            ModeOptionCard(
                title = "No LLM",
                subtitle = "Fast rules",
                icon = Icons.Default.Bolt,
                selected = mode == PostProcessingMode.NO_LLM,
                onClick = {
                    mode = PostProcessingMode.NO_LLM
                    selectedModel = "rules/basic"
                    settings.polishModelId = "rules/basic"
                },
                modifier = Modifier.weight(1f),
            )
            ModeOptionCard(
                title = "Local LLM",
                subtitle = "Offline",
                icon = Icons.Default.Memory,
                selected = mode == PostProcessingMode.LOCAL_LLM,
                onClick = {
                    mode = PostProcessingMode.LOCAL_LLM
                    if (!selectedModel.startsWith("local-slm/")) {
                        val first = LocalSlmCatalog.default.id
                        selectedModel = first
                        settings.polishModelId = first
                    }
                },
                modifier = Modifier.weight(1f),
            )
            ModeOptionCard(
                title = "Cloud LLM",
                subtitle = "BYOK",
                icon = Icons.Default.Cloud,
                selected = mode == PostProcessingMode.CLOUD_LLM,
                onClick = {
                    mode = PostProcessingMode.CLOUD_LLM
                    val provider = cloudProviders.firstOrNull { it.id == selectedCloudProviderId } ?: cloudProviders.firstOrNull()
                    if (provider != null) {
                        val currentModelInProvider = provider.models.firstOrNull { it.id == selectedModel }
                        if (currentModelInProvider == null) {
                            val defaultModel = provider.models.firstOrNull()?.id ?: "openai/gpt-4o-mini"
                            selectedModel = defaultModel
                            settings.polishModelId = defaultModel
                        }
                    }
                },
                modifier = Modifier.weight(1f),
            )
        }

        when (mode) {
            PostProcessingMode.NO_LLM -> {
                Surface(
                    shape = RoundedCornerShape(12.dp),
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                ) {
                    Row(
                        modifier = Modifier.padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            imageVector = Icons.Default.Info,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(20.dp),
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(
                            text = stringResource(R.string.postprocessing_mode_none_desc),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
            PostProcessingMode.LOCAL_LLM -> {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    for (slm in LocalSlmCatalog.all) {
                        val isInstalled = slm.id in installedSlmIds
                        val isSelected = selectedModel == slm.id
                        val slmActive = slmDownloads.activeModelId == slm.id
                        val slmState = slmDownloads.state

                        Surface(
                            onClick = {
                                selectedModel = slm.id
                                settings.polishModelId = slm.id
                            },
                            shape = RoundedCornerShape(14.dp),
                            color = if (isSelected) {
                                MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.25f)
                            } else {
                                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)
                            },
                            border = BorderStroke(
                                if (isSelected) 1.5.dp else 1.dp,
                                if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                            ),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Column(modifier = Modifier.padding(14.dp)) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier.fillMaxWidth(),
                                ) {
                                    androidx.compose.material3.RadioButton(
                                        selected = isSelected,
                                        onClick = {
                                            selectedModel = slm.id
                                            settings.polishModelId = slm.id
                                        },
                                    )
                                    Spacer(Modifier.width(8.dp))
                                    Column(Modifier.weight(1f)) {
                                        Text(
                                            text = slm.displayName,
                                            style = MaterialTheme.typography.titleSmall,
                                            fontWeight = FontWeight.Bold,
                                        )
                                        Text(
                                            text = "${slm.parameterCount} params · ${slm.quantizedSizeMb} MB · GGUF",
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }

                                    if (isInstalled) {
                                        IconButton(onClick = { pendingDeleteSlm = slm }) {
                                            Icon(
                                                imageVector = Icons.Default.Delete,
                                                contentDescription = "Delete SLM model",
                                                tint = MaterialTheme.colorScheme.error,
                                            )
                                        }
                                    }
                                }

                                Spacer(Modifier.height(6.dp))
                                Text(
                                    text = slm.description,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )

                                Spacer(Modifier.height(10.dp))

                                if (isInstalled) {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .background(
                                                androidx.compose.ui.graphics.Color(0xFF16A34A).copy(alpha = 0.12f),
                                                RoundedCornerShape(8.dp),
                                            )
                                            .padding(horizontal = 12.dp, vertical = 8.dp),
                                    ) {
                                        Icon(
                                            imageVector = Icons.Default.CheckCircle,
                                            contentDescription = null,
                                            tint = androidx.compose.ui.graphics.Color(0xFF16A34A),
                                            modifier = Modifier.size(18.dp),
                                        )
                                        Spacer(Modifier.width(8.dp))
                                        Text(
                                            text = "Model installed · Ready for offline rewrite",
                                            style = MaterialTheme.typography.labelMedium,
                                            fontWeight = FontWeight.SemiBold,
                                            color = androidx.compose.ui.graphics.Color(0xFF15803D),
                                        )
                                    }
                                } else if (slmActive && slmState is DownloadState.Downloading) {
                                    val pct = (slmState.progress * 100).roundToInt()
                                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.SpaceBetween,
                                        ) {
                                            Text(
                                                text = "Downloading ${slm.displayName}...",
                                                style = MaterialTheme.typography.labelMedium,
                                                fontWeight = FontWeight.SemiBold,
                                            )
                                            Text(
                                                text = "$pct%",
                                                style = MaterialTheme.typography.labelMedium,
                                                fontWeight = FontWeight.Bold,
                                                color = MaterialTheme.colorScheme.primary,
                                            )
                                        }
                                        LinearProgressIndicator(
                                            progress = { slmState.progress },
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .height(8.dp)
                                                .clip(RoundedCornerShape(4.dp)),
                                        )
                                    }
                                } else {
                                    if (slmActive && slmState is DownloadState.Error) {
                                        Text(
                                            text = "Error: ${slmState.message}",
                                            style = MaterialTheme.typography.bodySmall,
                                            color = MaterialTheme.colorScheme.error,
                                            modifier = Modifier.padding(bottom = 8.dp),
                                        )
                                    }

                                    Button(
                                        enabled = !slmDownloads.busy && slmStorageDir != null,
                                        onClick = {
                                            if (slmStorageDir != null) {
                                                selectedModel = slm.id
                                                settings.polishModelId = slm.id
                                                slmDownloads.start(slm, slmStorageDir) {
                                                    slmRefreshTrigger++
                                                }
                                            }
                                        },
                                        shape = RoundedCornerShape(10.dp),
                                        modifier = Modifier.fillMaxWidth(),
                                    ) {
                                        Icon(
                                            imageVector = Icons.Default.Download,
                                            contentDescription = null,
                                            modifier = Modifier.size(18.dp),
                                        )
                                        Spacer(Modifier.width(8.dp))
                                        Text(
                                            text = "Download Model (${slm.quantizedSizeMb} MB)",
                                            fontWeight = FontWeight.Bold,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
            PostProcessingMode.CLOUD_LLM -> {
                PolishProviderDropdown(
                    providers = cloudProviders,
                    selectedId = selectedCloudProviderId,
                    savedKeyProviders = savedKeyProviders,
                    onSelect = { providerId ->
                        selectedCloudProviderId = providerId
                        val provider = cloudProviders.firstOrNull { it.id == providerId }
                        val firstModel = provider?.models?.firstOrNull()?.id
                        if (firstModel != null) {
                            selectedModel = firstModel
                            settings.polishModelId = firstModel
                        }
                    },
                )

                val activeProvider = cloudProviders.firstOrNull { it.id == selectedCloudProviderId }
                if (activeProvider != null) {
                    if (activeProvider.needsApiKey) {
                        ApiKeyRow(
                            providerId = activeProvider.id,
                            providerName = activeProvider.displayName,
                            apiKeyUrl = activeProvider.apiKeyUrl,
                            onKeyChanged = { keyUpdateTrigger++ },
                        )
                    }

                    if (activeProvider.models.isNotEmpty()) {
                        PolishModelDropdown(
                            models = activeProvider.models,
                            selectedId = selectedModel,
                            onSelect = { modelId ->
                                selectedModel = modelId
                                settings.polishModelId = modelId
                            },
                        )
                    }
                }
            }
        }

        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))

        SectionHeader(stringResource(R.string.cleanup_section_smart_capabilities))
        SwitchRow(
            title = stringResource(R.string.cleanup_app_context),
            subtitle = stringResource(R.string.cleanup_app_context_help),
            checked = appContextAware,
            onCheckedChange = {
                appContextAware = it
                settings.appContextAwarenessEnabled = it
            },
        )
        SwitchRow(
            title = stringResource(R.string.cleanup_smart_dictation),
            subtitle = stringResource(R.string.cleanup_smart_dictation_help),
            checked = smartDictation,
            onCheckedChange = {
                smartDictation = it
                settings.smartDictationModesEnabled = it
            },
        )
        SwitchRow(
            title = "Transliterate to Tanglish / Hinglish / Manglish",
            subtitle = "Phonetically convert Tamil, Hindi, and Malayalam speech into English letters (Tanglish, Hinglish, Manglish).",
            checked = transliterateIndic,
            onCheckedChange = {
                transliterateIndic = it
                settings.transliterateIndicToLatin = it
            },
        )
        HorizontalDivider()

        SectionHeader(stringResource(R.string.cleanup_section_prompt))

        for ((name, text) in CleanupPolicy.PRESETS) {
            RadioRow(
                title = name,
                selected = presetKey == name,
                onSelect = {
                    presetKey = name
                    customText = text
                    // The built-in prompt is the default, so it is stored as "no override".
                    settings.customPrompt = text.takeIf { it != CleanupPolicy.BASE_PROMPT }
                },
                trailing = {
                    TextButton(onClick = { previewPromptPreset = name to text }) {
                        Text(
                            text = "Preview prompt",
                            style = MaterialTheme.typography.labelSmall,
                        )
                    }
                },
            )
        }
        RadioRow(
            title = stringResource(R.string.cleanup_preset_custom),
            selected = presetKey == CUSTOM_PRESET,
            onSelect = {
                presetKey = CUSTOM_PRESET
                if (customText.isBlank()) {
                    customText = CleanupPolicy.BASE_PROMPT
                }
                settings.customPrompt = customText
            },
        )

        if (presetKey == CUSTOM_PRESET) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 6.dp),
            ) {
                OutlinedTextField(
                    value = customText,
                    onValueChange = {
                        customText = it
                        settings.customPrompt = it.takeIf { text -> text.isNotBlank() }
                    },
                    label = { Text(stringResource(R.string.cleanup_custom_prompt)) },
                    minLines = 6,
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(8.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End,
                ) {
                    OutlinedButton(
                        onClick = {
                            customText = CleanupPolicy.BASE_PROMPT
                            settings.customPrompt = CleanupPolicy.BASE_PROMPT
                        },
                        shape = RoundedCornerShape(10.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Default.Refresh,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(stringResource(R.string.cleanup_reset_default_prompt))
                    }
                }
            }
        }

        OutlinedTextField(
            value = outputLanguage,
            onValueChange = {
                outputLanguage = it
                settings.outputLanguage = it.takeIf { text -> text.isNotBlank() }
            },
            label = { Text(stringResource(R.string.cleanup_output_language)) },
            supportingText = { Text(stringResource(R.string.cleanup_output_language_help)) },
            singleLine = true,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
        )

        TextButton(
            onClick = { previewOpen = !previewOpen },
            modifier = Modifier.padding(horizontal = 8.dp),
        ) {
            Text(
                stringResource(
                    if (previewOpen) R.string.cleanup_preview_hide else R.string.cleanup_preview,
                ),
            )
        }

        if (previewOpen) {
            val preview = CleanupPolicy.systemPrompt(
                base = if (presetKey == CleanupPolicy.PRESETS.keys.first()) {
                    CleanupPolicy.BASE_PROMPT
                } else {
                    customText
                },
                outputLanguage = outputLanguage.takeIf { it.isNotBlank() },
                lexicon = settings.lexicon,
                enableSmartDictation = smartDictation,
                transliterateIndicToLatin = transliterateIndic,
            )
            Surface(
                color = MaterialTheme.colorScheme.surfaceVariant,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
                    .heightIn(max = 400.dp),
            ) {
                Text(
                    preview,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier
                        .verticalScroll(rememberScrollState())
                        .padding(12.dp),
                )
            }
        }

        val slmToDelete = pendingDeleteSlm
        if (slmToDelete != null && slmStorageDir != null) {
            AlertDialog(
                onDismissRequest = { pendingDeleteSlm = null },
                title = { Text("Delete ${slmToDelete.displayName}?") },
                text = { Text("This will remove the ${slmToDelete.quantizedSizeMb} MB model file from device storage. You can redownload it anytime.") },
                confirmButton = {
                    TextButton(
                        onClick = {
                            pendingDeleteSlm = null
                            slmDownloads.delete(slmToDelete, slmStorageDir) {
                                slmRefreshTrigger++
                            }
                        },
                    ) {
                        Text("Delete", color = MaterialTheme.colorScheme.error)
                    }
                },
                dismissButton = {
                    TextButton(onClick = { pendingDeleteSlm = null }) {
                        Text("Cancel")
                    }
                },
            )
        }

        val promptPreview = previewPromptPreset
        if (promptPreview != null) {
            AlertDialog(
                onDismissRequest = { previewPromptPreset = null },
                title = {
                    Text(
                        text = "${promptPreview.first} Prompt",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                    )
                },
                text = {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 320.dp)
                            .verticalScroll(rememberScrollState()),
                    ) {
                        Surface(
                            shape = RoundedCornerShape(8.dp),
                            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(
                                text = promptPreview.second,
                                style = MaterialTheme.typography.bodySmall,
                                modifier = Modifier.padding(12.dp),
                                lineHeight = 18.sp,
                            )
                        }
                    }
                },
                confirmButton = {
                    TextButton(onClick = { previewPromptPreset = null }) {
                        Text("Close")
                    }
                },
            )
        }
    }
}

@Composable
private fun ModeOptionCard(
    title: String,
    subtitle: String,
    icon: ImageVector,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(12.dp),
        color = if (selected) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
        border = BorderStroke(
            1.5.dp,
            if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant,
        ),
        modifier = modifier,
    ) {
        Column(
            modifier = Modifier.padding(vertical = 12.dp, horizontal = 6.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = title,
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.Bold,
                color = if (selected) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.labelSmall,
                color = if (selected) MaterialTheme.colorScheme.onPrimaryContainer.copy(alpha = 0.8f) else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PolishProviderDropdown(
    providers: List<PolishProvider>,
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
            label = { Text(stringResource(R.string.postprocessing_provider)) },
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
private fun PolishModelDropdown(
    models: List<PolishModel>,
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
            label = { Text(stringResource(R.string.postprocessing_model)) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier
                .menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable)
                .fillMaxWidth(),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for (model in models) {
                DropdownMenuItem(
                    text = {
                        Text(
                            text = model.displayName,
                            fontWeight = if (model.id == selectedId) FontWeight.Bold else FontWeight.Normal,
                        )
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
