package com.shotclubhouse.sayso.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.AutoFixHigh
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Insights
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Spellcheck
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.shotclubhouse.sayso.AppGraph
import com.shotclubhouse.sayso.R
import com.shotclubhouse.sayso.service.DictationService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Hub screen: what still needs setting up, what is currently configured, and where to go next. */
@Composable
fun HomeScreen(onNavigate: (Screen) -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var micGranted by remember { mutableStateOf(context.hasMicPermission()) }
    var serviceOn by remember { mutableStateOf(DictationService.isEnabled(context)) }
    var sttSummary by remember { mutableStateOf("") }
    var cleanupSummary by remember { mutableStateOf<String?>(null) }
    var resumeTick by remember { mutableIntStateOf(0) }

    val micPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted -> micGranted = granted }

    // Both the permission and the accessibility toggle are changed in system UI,
    // so the only reliable moment to re-read them is when we come back.
    LifecycleResumeEffect(Unit) {
        micGranted = context.hasMicPermission()
        serviceOn = DictationService.isEnabled(context)
        resumeTick++
        onPauseOrDispose { }
    }

    // Naming the transcription model walks the on-device models directory, which is a
    // disk read, so it happens off the main thread rather than during composition.
    // Tick 0 is skipped: the first resume always follows composition, so running here too
    // would read the directory twice at startup.
    LaunchedEffect(resumeTick) {
        if (resumeTick == 0) return@LaunchedEffect
        val summaries = withContext(Dispatchers.IO) { sttSummary() to cleanupSummary() }
        sttSummary = summaries.first
        cleanupSummary = summaries.second
    }

    val ready = micGranted && serviceOn

    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(bottom = 24.dp),
    ) {
        ElevatedCard(Modifier.fillMaxWidth().padding(16.dp)) {
            Column(Modifier.padding(16.dp)) {
                Text(
                    stringResource(if (ready) R.string.home_ready_title else R.string.home_setup_title),
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    stringResource(if (ready) R.string.home_ready_body else R.string.home_setup_body),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }
        }

        SectionHeader(stringResource(R.string.home_section_setup))

        StatusRow(
            title = stringResource(R.string.home_mic_title),
            subtitle = stringResource(
                if (micGranted) R.string.home_mic_granted else R.string.home_mic_missing,
            ),
            done = micGranted,
            onClick = { if (!micGranted) micPermission.launch(Manifest.permission.RECORD_AUDIO) },
        )
        StatusRow(
            title = stringResource(R.string.home_accessibility_title),
            subtitle = stringResource(
                if (serviceOn) R.string.home_accessibility_on else R.string.home_accessibility_off,
            ),
            done = serviceOn,
            onClick = { context.openAccessibilitySettings() },
        )

        OutlinedCard(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
            Column(Modifier.padding(16.dp)) {
                Text(
                    stringResource(R.string.home_disclosure_title),
                    style = MaterialTheme.typography.titleSmall,
                )
                Text(
                    stringResource(R.string.accessibility_service_description),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }
        }

        SettingRow(
            title = stringResource(R.string.home_stt_title),
            subtitle = sttSummary,
            leading = { Icon(Icons.Default.Mic, contentDescription = null) },
            trailing = { Chevron() },
            onClick = { onNavigate(Screen.Transcription) },
        )
        SettingRow(
            title = stringResource(R.string.home_cleanup_title),
            subtitle = cleanupSummary ?: stringResource(R.string.home_cleanup_off),
            leading = { Icon(Icons.Default.AutoFixHigh, contentDescription = null) },
            trailing = { Chevron() },
            onClick = { onNavigate(Screen.Cleanup) },
        )

        SectionHeader(stringResource(R.string.home_section_settings))
        HorizontalDivider()

        NavRow(R.string.screen_transcription, Icons.Default.Mic) { onNavigate(Screen.Transcription) }
        NavRow(R.string.screen_local_models, Icons.Default.Download) { onNavigate(Screen.LocalModels) }
        NavRow(R.string.screen_cleanup, Icons.Default.AutoFixHigh) { onNavigate(Screen.Cleanup) }
        NavRow(R.string.screen_vocabulary, Icons.Default.Spellcheck) { onNavigate(Screen.Vocabulary) }
        NavRow(R.string.screen_history, Icons.Default.History) { onNavigate(Screen.History) }
        NavRow(R.string.screen_insights, Icons.Default.Insights) { onNavigate(Screen.Insights) }
        NavRow(R.string.screen_about, Icons.Default.Info) { onNavigate(Screen.About) }
    }
}

@Composable
private fun StatusRow(title: String, subtitle: String, done: Boolean, onClick: () -> Unit) {
    SettingRow(
        title = title,
        subtitle = subtitle,
        onClick = onClick,
        leading = {
            Icon(
                imageVector = if (done) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked,
                contentDescription = stringResource(
                    if (done) R.string.status_done else R.string.status_todo,
                ),
                tint = if (done) {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
            )
        },
    )
}

@Composable
private fun NavRow(titleRes: Int, icon: ImageVector, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth()) {
        SettingRow(
            title = stringResource(titleRes),
            leading = { Icon(icon, contentDescription = null) },
            trailing = { Chevron() },
            onClick = onClick,
        )
    }
}

@Composable
private fun Chevron() {
    Icon(
        Icons.AutoMirrored.Filled.KeyboardArrowRight,
        contentDescription = null,
        tint = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

internal fun Context.hasMicPermission(): Boolean =
    checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

private fun Context.openAccessibilitySettings() {
    val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    startActivity(intent)
}

/** "OpenAI: Whisper", or the bare id when the saved model is no longer available. */
internal fun sttSummary(): String {
    val id = AppGraph.settings.sttModelId
    val found = AppGraph.stt.find(id) ?: return id
    return "${found.first.displayName}: ${found.second.displayName}"
}

/** Null when cleanup is switched off, so callers can show their own "off" wording. */
internal fun cleanupSummary(): String? {
    if (!AppGraph.settings.polishEnabled) return null
    val id = AppGraph.settings.polishModelId
    val found = AppGraph.polish.find(id) ?: return id
    return "${found.first.displayName}: ${found.second.displayName}"
}
