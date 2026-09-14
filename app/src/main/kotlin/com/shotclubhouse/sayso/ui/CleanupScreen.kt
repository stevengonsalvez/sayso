package com.shotclubhouse.sayso.ui

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.shotclubhouse.sayso.AppGraph
import com.shotclubhouse.sayso.R
import com.shotclubhouse.sayso.polish.CleanupPolicy

/** Shown in the preset list alongside the named presets. */
private const val CUSTOM_PRESET = "__custom__"

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

/** Cleanup backend, key, and the instructions the model is given. */
@Composable
fun CleanupScreen(modifier: Modifier = Modifier) {
    val settings = AppGraph.settings
    var enabled by remember { mutableStateOf(settings.polishEnabled) }
    var selectedModel by remember { mutableStateOf(settings.polishModelId) }
    var presetKey by remember { mutableStateOf(presetKeyFor(settings.customPrompt)) }
    var customText by remember {
        mutableStateOf(settings.customPrompt ?: CleanupPolicy.BASE_PROMPT)
    }
    var outputLanguage by remember { mutableStateOf(settings.outputLanguage.orEmpty()) }
    var previewOpen by remember { mutableStateOf(false) }

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

        for (provider in AppGraph.polish.providers) {
            ProviderGroup(provider.displayName) {
                if (provider.needsApiKey) {
                    ApiKeyRow(
                        providerId = provider.id,
                        providerName = provider.displayName,
                        apiKeyUrl = provider.apiKeyUrl,
                    )
                }
                for (model in provider.models) {
                    RadioRow(
                        title = model.displayName,
                        selected = selectedModel == model.id,
                        onSelect = {
                            selectedModel = model.id
                            settings.polishModelId = model.id
                        },
                    )
                }
            }
            HorizontalDivider()
        }

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
    }
}
