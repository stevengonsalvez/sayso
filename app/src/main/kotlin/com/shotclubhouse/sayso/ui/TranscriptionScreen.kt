package com.shotclubhouse.sayso.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.shotclubhouse.sayso.AppGraph
import com.shotclubhouse.sayso.R
import com.shotclubhouse.sayso.service.DictationService
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
    "ja" to R.string.lang_ja,
    "ko" to R.string.lang_ko,
    "zh" to R.string.lang_zh,
)

private const val MIN_RECORDING_SECONDS = 30f
private const val MAX_RECORDING_SECONDS = 600f
private const val RECORDING_STEP_SECONDS = 30

/** Which engine turns speech into text, and the knobs that shape a recording. */
@Composable
fun TranscriptionScreen(onOpenLocalModels: () -> Unit, modifier: Modifier = Modifier) {
    val settings = AppGraph.settings
    var selectedModel by remember { mutableStateOf(settings.sttModelId) }
    var language by remember { mutableStateOf(settings.language) }
    var hints by remember { mutableStateOf(settings.hints.joinToString(", ")) }
    var maxSeconds by remember { mutableFloatStateOf(settings.maxRecordingSeconds.toFloat()) }
    var sounds by remember { mutableStateOf(settings.soundsEnabled) }
    var history by remember { mutableStateOf(settings.historyEnabled) }

    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(bottom = 32.dp),
    ) {
        for (provider in AppGraph.stt.providers) {
            ProviderGroup(provider.displayName) {
                if (provider.needsApiKey) {
                    ApiKeyRow(
                        providerId = provider.id,
                        providerName = provider.displayName,
                        apiKeyUrl = provider.apiKeyUrl,
                    )
                }
                val models = provider.models
                if (models.isEmpty() && provider.id == "local") {
                    Text(
                        stringResource(R.string.transcription_local_empty),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 16.dp),
                    )
                    Button(
                        onClick = onOpenLocalModels,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    ) { Text(stringResource(R.string.transcription_local_open)) }
                }
                for (model in models) {
                    RadioRow(
                        title = model.displayName,
                        subtitle = model.note.takeIf { it.isNotBlank() },
                        selected = selectedModel == model.id,
                        onSelect = {
                            selectedModel = model.id
                            settings.sttModelId = model.id
                            if (provider.id == "local") DictationService.instance?.reloadLocalModel()
                        },
                    )
                }
            }
            HorizontalDivider()
        }

        SectionHeader(stringResource(R.string.transcription_section_recognition))

        LanguageDropdown(
            selected = language,
            onSelect = {
                language = it
                settings.language = it
            },
        )

        OutlinedTextField(
            value = hints,
            onValueChange = {
                hints = it
                settings.hints = it.toCsvList()
            },
            label = { Text(stringResource(R.string.transcription_hints)) },
            supportingText = { Text(stringResource(R.string.transcription_hints_help)) },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
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
                valueRange = MIN_RECORDING_SECONDS..MAX_RECORDING_SECONDS,
                steps = ((MAX_RECORDING_SECONDS - MIN_RECORDING_SECONDS) / RECORDING_STEP_SECONDS).toInt() - 1,
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
