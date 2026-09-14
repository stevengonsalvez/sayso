package com.shotclubhouse.sayso.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.shotclubhouse.sayso.AppGraph
import com.shotclubhouse.sayso.R
import com.shotclubhouse.sayso.history.Insights
import com.shotclubhouse.sayso.history.InsightsSummary
import com.shotclubhouse.sayso.service.DictationService
import com.shotclubhouse.sayso.service.WakeWordService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.math.roundToInt

/** Hub screen: speech insights dashboard, setup readiness, and quick settings. */
@Composable
fun HomeScreen(onNavigate: (Screen) -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var micGranted by remember { mutableStateOf(context.hasMicPermission()) }
    var serviceOn by remember { mutableStateOf(DictationService.isEnabled(context)) }
    var wakeWord by remember { mutableStateOf(AppGraph.settings.wakeWordEnabled) }
    var bubbleAlwaysVisible by remember { mutableStateOf(AppGraph.settings.bubbleAlwaysVisible) }
    var sttSummary by remember { mutableStateOf("") }
    var cleanupSummary by remember { mutableStateOf<String?>(null) }
    var insightsSummary by remember { mutableStateOf<InsightsSummary?>(null) }
    var resumeTick by remember { mutableIntStateOf(0) }

    val micPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        micGranted = granted
        if (granted && AppGraph.settings.wakeWordEnabled) {
            WakeWordService.start(context)
        }
    }

    // Both the permission and the accessibility toggle are changed in system UI,
    // so the only reliable moment to re-read them is when we come back.
    LifecycleResumeEffect(Unit) {
        micGranted = context.hasMicPermission()
        serviceOn = DictationService.isEnabled(context)
        wakeWord = AppGraph.settings.wakeWordEnabled
        bubbleAlwaysVisible = AppGraph.settings.bubbleAlwaysVisible
        resumeTick++
        onPauseOrDispose { }
    }

    // Naming the transcription model walks the on-device models directory, which is a
    // disk read, so it happens off the main thread rather than during composition.
    // Tick 0 is skipped: the first resume always follows composition, so running here too
    // would read the directory twice at startup.
    LaunchedEffect(resumeTick) {
        if (resumeTick == 0) return@LaunchedEffect
        val (stt, cleanup, insights) = withContext(Dispatchers.IO) {
            Triple(
                sttSummary(),
                cleanupSummary(),
                Insights.compute(AppGraph.history.all()),
            )
        }
        sttSummary = stt
        cleanupSummary = cleanup
        insightsSummary = insights
    }

    val ready = micGranted && serviceOn

    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        // 1. Hero Speech Insights Widget
        HomeInsightsWidget(
            summary = insightsSummary,
            onSeeMore = { onNavigate(Screen.Insights) },
        )

        // 2. Dictation Engine Status Card
        EngineStatusCard(
            ready = ready,
            micGranted = micGranted,
            serviceOn = serviceOn,
            onRequestMic = { if (!micGranted) micPermission.launch(Manifest.permission.RECORD_AUDIO) },
            onOpenAccessibility = { context.openAccessibilitySettings() },
        )

        // 3. Hands-Free & Overlay Controls Card
        HandsFreeControlsCard(
            wakeWord = wakeWord,
            bubbleAlwaysVisible = bubbleAlwaysVisible,
            onWakeWordChange = { enabled ->
                if (enabled) {
                    if (!micGranted) {
                        micPermission.launch(Manifest.permission.RECORD_AUDIO)
                    } else {
                        wakeWord = true
                        AppGraph.settings.wakeWordEnabled = true
                        WakeWordService.start(context)
                    }
                } else {
                    wakeWord = false
                    AppGraph.settings.wakeWordEnabled = false
                    WakeWordService.stop(context)
                }
            },
            onBubbleAlwaysVisibleChange = { enabled ->
                bubbleAlwaysVisible = enabled
                AppGraph.settings.bubbleAlwaysVisible = enabled
                DictationService.instance?.updateBubbleVisibility()
            },
        )

        // 4. Speech & Cleanup Engines Card
        ActiveModelsCard(
            sttSummary = sttSummary,
            cleanupSummary = cleanupSummary,
            onOpenTranscription = { onNavigate(Screen.Transcription) },
            onOpenCleanup = { onNavigate(Screen.Cleanup) },
        )

        // 5. Tools & Capabilities Card
        CapabilitiesCard(onNavigate = onNavigate)

        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun HomeInsightsWidget(
    summary: InsightsSummary?,
    onSeeMore: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Card(
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(18.dp)) {
            // Header Row
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Box(
                    modifier = Modifier
                        .size(38.dp)
                        .clip(RoundedCornerShape(11.dp))
                        .background(
                            Brush.linearGradient(
                                listOf(
                                    MaterialTheme.colorScheme.primary,
                                    Color(0xFF0284C7),
                                ),
                            ),
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Default.Insights,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(20.dp),
                    )
                }
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(
                        text = "SPEECH INSIGHTS",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Black,
                        letterSpacing = 0.8.sp,
                    )
                    Text(
                        text = "Real-time speaking cadence & metrics",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(Modifier.weight(1f))
                Surface(
                    shape = RoundedCornerShape(20.dp),
                    color = if (summary != null && summary.sessions > 0) Color(0xFFDBEAFE) else Color(0xFFF1F5F9),
                    border = BorderStroke(
                        1.dp,
                        if (summary != null && summary.sessions > 0) Color(0xFFBFDBFE) else Color(0xFFE2E8F0),
                    ),
                ) {
                    Text(
                        text = if (summary != null && summary.sessions > 0) {
                            "${summary.sessions} SESSIONS"
                        } else {
                            "READY"
                        },
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = if (summary != null && summary.sessions > 0) {
                            MaterialTheme.colorScheme.primary
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                        letterSpacing = 0.6.sp,
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                    )
                }
            }

            Spacer(Modifier.height(16.dp))

            // Soundwave Visualizer Graphic Preview
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
                    .padding(horizontal = 14.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(3.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.height(26.dp),
                ) {
                    val heights = listOf(8.dp, 16.dp, 24.dp, 14.dp, 22.dp, 12.dp, 6.dp)
                    heights.forEach { h ->
                        Box(
                            modifier = Modifier
                                .width(3.5.dp)
                                .height(h)
                                .clip(CircleShape)
                                .background(
                                    Brush.verticalGradient(
                                        listOf(Color(0xFF2563EB), Color(0xFF38BDF8)),
                                    ),
                                ),
                        )
                    }
                }
                Text(
                    text = if (summary != null && summary.sessions > 0) {
                        "Voice session analysis active. Pacing and clarity tracking live."
                    } else {
                        "Tap floating microphone to record speech and track speaking cadence."
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    lineHeight = 16.sp,
                    modifier = Modifier.weight(1f),
                )
            }

            Spacer(Modifier.height(14.dp))

            // 3 High-End Metric Tiles
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val paceVal = if (summary != null && summary.sessions > 0) "${summary.averageWpm.roundToInt()}" else "--"
                val wordsVal = if (summary != null && summary.sessions > 0) "${summary.totalWords}" else "0"
                val fillerVal = if (summary != null && summary.sessions > 0) String.format(Locale.US, "%.1f", summary.fillerRatePer1k) else "0.0"

                InsightStatTile(
                    label = "PACE",
                    unit = "WPM",
                    value = paceVal,
                    modifier = Modifier.weight(1f),
                )
                InsightStatTile(
                    label = "SPOKEN",
                    unit = "WORDS",
                    value = wordsVal,
                    modifier = Modifier.weight(1f),
                )
                InsightStatTile(
                    label = "FILLERS",
                    unit = "/ 1K WORDS",
                    value = fillerVal,
                    modifier = Modifier.weight(1f),
                )
            }

            Spacer(Modifier.height(16.dp))

            // Primary Sonic Cobalt CTA Button
            Button(
                onClick = onSeeMore,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.primary,
                    contentColor = Color.White,
                ),
                elevation = ButtonDefaults.buttonElevation(defaultElevation = 2.dp),
            ) {
                Text(
                    text = "Explore Speech Insights",
                    fontWeight = FontWeight.Bold,
                    fontSize = 14.sp,
                    letterSpacing = 0.3.sp,
                )
                Spacer(Modifier.width(8.dp))
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

@Composable
private fun InsightStatTile(
    label: String,
    unit: String,
    value: String,
    modifier: Modifier = Modifier,
) {
    Surface(
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
        modifier = modifier,
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 10.dp),
            horizontalAlignment = Alignment.Start,
        ) {
            Text(
                text = value,
                fontSize = 20.sp,
                fontWeight = FontWeight.Black,
                color = MaterialTheme.colorScheme.primary,
                letterSpacing = (-0.5).sp,
            )
            Text(
                text = label,
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
                letterSpacing = 0.5.sp,
            )
            Text(
                text = unit,
                fontSize = 9.sp,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                letterSpacing = 0.3.sp,
            )
        }
    }
}

@Composable
private fun EngineStatusCard(
    ready: Boolean,
    micGranted: Boolean,
    serviceOn: Boolean,
    onRequestMic: () -> Unit,
    onOpenAccessibility: () -> Unit,
) {
    Card(
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Box(
                    modifier = Modifier
                        .size(34.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(Color(0xFFDBEAFE)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Default.Mic,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(18.dp),
                    )
                }
                Spacer(Modifier.width(10.dp))
                Column {
                    Text(
                        text = "DICTATION ENGINE",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 0.8.sp,
                    )
                    Text(
                        text = if (ready) "Floating bubble ready to capture audio" else "Finish setup to enable dictation",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(Modifier.weight(1f))
                Surface(
                    shape = RoundedCornerShape(20.dp),
                    color = if (ready) Color(0xFFDCFCE7) else Color(0xFFFEF3C7),
                    border = BorderStroke(1.dp, if (ready) Color(0xFF86EFAC) else Color(0xFFFCD34D)),
                ) {
                    Text(
                        text = if (ready) "READY" else "ACTION NEEDED",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = if (ready) Color(0xFF15803D) else Color(0xFFB45309),
                        letterSpacing = 0.5.sp,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                    )
                }
            }

            Spacer(Modifier.height(14.dp))
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
            Spacer(Modifier.height(10.dp))

            StatusActionRow(
                title = "Microphone Permission",
                subtitle = if (micGranted) "Audio access granted" else "Tap to allow audio recording",
                done = micGranted,
                onClick = onRequestMic,
            )
            Spacer(Modifier.height(8.dp))
            StatusActionRow(
                title = "Accessibility Service",
                subtitle = if (serviceOn) "Service active with floating overlay" else "Tap to enable in Android settings",
                done = serviceOn,
                onClick = onOpenAccessibility,
            )
        }
    }
}

@Composable
private fun StatusActionRow(
    title: String,
    subtitle: String,
    done: Boolean,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 6.dp, horizontal = 4.dp),
    ) {
        Box(
            modifier = Modifier
                .size(24.dp)
                .clip(CircleShape)
                .background(if (done) Color(0xFFDCFCE7) else Color(0xFFF1F5F9)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = if (done) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked,
                contentDescription = null,
                tint = if (done) Color(0xFF16A34A) else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(16.dp),
            )
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (!done) {
            Surface(
                shape = RoundedCornerShape(8.dp),
                color = MaterialTheme.colorScheme.primaryContainer,
            ) {
                Text(
                    text = "Grant",
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                )
            }
        }
    }
}

@Composable
private fun HandsFreeControlsCard(
    wakeWord: Boolean,
    bubbleAlwaysVisible: Boolean,
    onWakeWordChange: (Boolean) -> Unit,
    onBubbleAlwaysVisibleChange: (Boolean) -> Unit,
) {
    Column {
        Text(
            text = "HANDS-FREE & OVERLAY",
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            letterSpacing = 0.8.sp,
            modifier = Modifier.padding(start = 4.dp, bottom = 6.dp),
        )
        Card(
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(vertical = 4.dp)) {
                SwitchRow(
                    title = stringResource(R.string.transcription_wake_word),
                    subtitle = stringResource(R.string.transcription_wake_word_help),
                    checked = wakeWord,
                    onCheckedChange = onWakeWordChange,
                )
                HorizontalDivider(
                    color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
                SwitchRow(
                    title = stringResource(R.string.transcription_bubble_always_visible),
                    subtitle = stringResource(R.string.transcription_bubble_always_visible_help),
                    checked = bubbleAlwaysVisible,
                    onCheckedChange = onBubbleAlwaysVisibleChange,
                )
            }
        }
    }
}

@Composable
private fun ActiveModelsCard(
    sttSummary: String,
    cleanupSummary: String?,
    onOpenTranscription: () -> Unit,
    onOpenCleanup: () -> Unit,
) {
    Column {
        Text(
            text = "SPEECH & CLEANUP ENGINES",
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            letterSpacing = 0.8.sp,
            modifier = Modifier.padding(start = 4.dp, bottom = 6.dp),
        )
        Card(
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(vertical = 4.dp)) {
                PremiumSettingRow(
                    title = stringResource(R.string.home_stt_title),
                    subtitle = sttSummary,
                    icon = Icons.Default.Mic,
                    iconBg = Color(0xFFDBEAFE),
                    iconTint = MaterialTheme.colorScheme.primary,
                    onClick = onOpenTranscription,
                )
                HorizontalDivider(
                    color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
                PremiumSettingRow(
                    title = stringResource(R.string.home_cleanup_title),
                    subtitle = cleanupSummary ?: stringResource(R.string.home_cleanup_off),
                    icon = Icons.Default.AutoFixHigh,
                    iconBg = Color(0xFFF3E8FF),
                    iconTint = Color(0xFF7E22CE),
                    onClick = onOpenCleanup,
                )
            }
        }
    }
}

@Composable
private fun CapabilitiesCard(onNavigate: (Screen) -> Unit) {
    Column {
        Text(
            text = "FEATURES & TOOLS",
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            letterSpacing = 0.8.sp,
            modifier = Modifier.padding(start = 4.dp, bottom = 6.dp),
        )
        Card(
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(vertical = 4.dp)) {
                PremiumSettingRow(
                    title = stringResource(R.string.screen_vocabulary),
                    subtitle = "Pronunciation dictionary and word replacements",
                    icon = Icons.Default.Spellcheck,
                    iconBg = Color(0xFFFEF3C7),
                    iconTint = Color(0xFFB45309),
                    onClick = { onNavigate(Screen.Vocabulary) },
                )
                HorizontalDivider(
                    color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
                PremiumSettingRow(
                    title = stringResource(R.string.screen_history),
                    subtitle = "Audio recordings and transcription logs",
                    icon = Icons.Default.History,
                    iconBg = Color(0xFFE0E7FF),
                    iconTint = Color(0xFF4338CA),
                    onClick = { onNavigate(Screen.History) },
                )
                HorizontalDivider(
                    color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
                PremiumSettingRow(
                    title = stringResource(R.string.screen_insights),
                    subtitle = "Speaking pace, filler words, and stats",
                    icon = Icons.Default.Insights,
                    iconBg = Color(0xFFFFE4E6),
                    iconTint = Color(0xFFBE123C),
                    onClick = { onNavigate(Screen.Insights) },
                )
                HorizontalDivider(
                    color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
                PremiumSettingRow(
                    title = stringResource(R.string.screen_local_models),
                    subtitle = "On-device Sherpa-ONNX neural models",
                    icon = Icons.Default.Download,
                    iconBg = Color(0xFFDCFCE7),
                    iconTint = Color(0xFF15803D),
                    onClick = { onNavigate(Screen.LocalModels) },
                )
                HorizontalDivider(
                    color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
                PremiumSettingRow(
                    title = stringResource(R.string.screen_about),
                    subtitle = "Version, privacy policy, and open source licenses",
                    icon = Icons.Default.Info,
                    iconBg = Color(0xFFF1F5F9),
                    iconTint = Color(0xFF475569),
                    onClick = { onNavigate(Screen.About) },
                )
            }
        }
    }
}

@Composable
private fun PremiumSettingRow(
    title: String,
    subtitle: String,
    icon: ImageVector,
    iconBg: Color,
    iconTint: Color,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(iconBg),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = iconTint,
                modifier = Modifier.size(18.dp),
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
            modifier = Modifier.size(18.dp),
        )
    }
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


