package ai.sayso.dictation.ui

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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.rememberCoroutineScope
import ai.sayso.dictation.models.LocalModel
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import ai.sayso.dictation.models.DownloadState
import ai.sayso.dictation.models.LocalModelCatalog
import java.io.File
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
import ai.sayso.dictation.AppGraph
import ai.sayso.dictation.R
import ai.sayso.dictation.history.Insights
import ai.sayso.dictation.history.InsightsSummary
import ai.sayso.dictation.service.DictationService
import ai.sayso.dictation.service.WakeWordService
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.math.roundToInt

/** Hub screen: speech insights dashboard, setup readiness, and quick settings. */
@Composable
fun HomeScreen(onNavigate: (Screen) -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val downloads = AppGraph.downloads
    val settings = AppGraph.settings
    val modelsDir = AppGraph.localModelsDir
    val defaultLocalModel = LocalModelCatalog.default

    var micGranted by remember { mutableStateOf(context.hasMicPermission()) }
    var serviceOn by remember { mutableStateOf(DictationService.isEnabled(context)) }
    var wakeWord by remember { mutableStateOf(settings.wakeWordEnabled) }
    var bubbleAlwaysVisible by remember { mutableStateOf(settings.bubbleAlwaysVisible) }
    var autoLanguageRouting by remember { mutableStateOf(settings.autoLanguageRoutingEnabled) }
    var installedIndicModels by remember { mutableStateOf(emptySet<String>()) }
    var showLanguageDownloadDialog by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var sttSummary by remember { mutableStateOf("") }
    var cleanupSummary by remember { mutableStateOf<String?>(null) }
    var insightsSummary by remember { mutableStateOf<InsightsSummary?>(null) }
    var isSttReady by remember { mutableStateOf(false) }
    var showOnboarding by remember { mutableStateOf(false) }
    var showAccessibilityDisclosure by remember { mutableStateOf(false) }
    var resumeTick by remember { mutableIntStateOf(0) }

    val micPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        micGranted = granted
        if (granted && settings.wakeWordEnabled) {
            WakeWordService.start(context)
        }
    }

    // Both the permission and the accessibility toggle are changed in system UI,
    // so the only reliable moment to re-read them is when we come back.
    LifecycleResumeEffect(Unit) {
        micGranted = context.hasMicPermission()
        serviceOn = DictationService.isEnabled(context)
        wakeWord = settings.wakeWordEnabled
        bubbleAlwaysVisible = settings.bubbleAlwaysVisible
        autoLanguageRouting = settings.autoLanguageRoutingEnabled
        resumeTick++
        onPauseOrDispose { }
    }

    // Reading directory and settings off main thread
    LaunchedEffect(resumeTick, downloads.busy, settings.sttModelId) {
        val (stt, cleanup, readyStt) = withContext(Dispatchers.IO) {
            Triple(
                sttSummary(),
                cleanupSummary(),
                checkSttReady(settings, modelsDir),
            )
        }
        val indicInstalled = withContext(Dispatchers.IO) {
            val routingModels = listOfNotNull(LocalModelCatalog.byDirName("sherpa-onnx-whisper-tiny")) + LocalModelCatalog.indicModels
            routingModels
                .filter { downloads.isInstalled(it, modelsDir) }
                .map { it.dirName }
                .toSet()
        }
        val ins = if (resumeTick > 0) {
            withContext(Dispatchers.IO) { Insights.compute(AppGraph.history.all()) }
        } else {
            insightsSummary
        }
        sttSummary = stt
        cleanupSummary = cleanup
        insightsSummary = ins
        isSttReady = readyStt
        installedIndicModels = indicInstalled
    }

    val ready = micGranted && serviceOn && isSttReady

    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        // 0. Model Required Setup Banner (Actionable CTA when model is missing)
        if (!isSttReady) {
            ModelRequiredBanner(
                downloadState = downloads.state,
                isDownloading = downloads.busy,
                onDownload = {
                    downloads.start(defaultLocalModel, modelsDir, context.cacheDir) {
                        settings.sttModelId = "local/${defaultLocalModel.dirName}"
                        DictationService.instance?.reloadLocalModel()
                    }
                },
                onOpenWizard = { showOnboarding = true },
            )
        }

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
            sttReady = isSttReady,
            sttSummary = sttSummary,
            downloadState = downloads.state,
            isDownloading = downloads.busy,
            onRequestMic = { if (!micGranted) micPermission.launch(Manifest.permission.RECORD_AUDIO) },
            onOpenAccessibility = {
                if (serviceOn) {
                    context.openAccessibilitySettings()
                } else {
                    showAccessibilityDisclosure = true
                }
            },
            onDownloadModel = {
                downloads.start(defaultLocalModel, modelsDir, context.cacheDir) {
                    settings.sttModelId = "local/${defaultLocalModel.dirName}"
                    DictationService.instance?.reloadLocalModel()
                }
            },
            onOpenTranscription = { onNavigate(Screen.Transcription) },
        )

        if (showAccessibilityDisclosure) {
            AlertDialog(
                onDismissRequest = { showAccessibilityDisclosure = false },
                icon = {
                    Box(
                        modifier = Modifier
                            .size(44.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(
                                Brush.linearGradient(
                                    listOf(
                                        MaterialTheme.colorScheme.primary,
                                        SaysoBrandAmber,
                                    ),
                                ),
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            painter = painterResource(R.drawable.ic_bubble_idle),
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(24.dp),
                        )
                    }
                },
                title = {
                    Text(
                        text = "Accessibility Permission",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        textAlign = TextAlign.Center,
                    )
                },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(
                            text = "Sayso uses Android's AccessibilityService API solely to detect active text input fields and paste your dictated speech into them.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Surface(
                            shape = RoundedCornerShape(12.dp),
                            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
                            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Column(
                                modifier = Modifier.padding(12.dp),
                                verticalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Row(verticalAlignment = Alignment.Top) {
                                    Text("• ", fontWeight = FontWeight.Black, color = MaterialTheme.colorScheme.primary)
                                    Text(
                                        text = "Only active editable text fields are detected when you tap dictate.",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurface,
                                    )
                                }
                                Row(verticalAlignment = Alignment.Top) {
                                    Text("• ", fontWeight = FontWeight.Black, color = MaterialTheme.colorScheme.primary)
                                    Text(
                                        text = "No passwords, personal messages, or screen content are monitored.",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurface,
                                    )
                                }
                                Row(verticalAlignment = Alignment.Top) {
                                    Text("• ", fontWeight = FontWeight.Black, color = MaterialTheme.colorScheme.primary)
                                    Text(
                                        text = "Zero audio, text, or keystrokes are tracked or sent to external servers.",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurface,
                                    )
                                }
                            }
                        }
                        Text(
                            text = "Tap below to open Android Settings, select Sayso under Downloaded apps, and switch it on.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                confirmButton = {
                    Button(
                        onClick = {
                            showAccessibilityDisclosure = false
                            context.openAccessibilitySettings()
                        },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.primary,
                        ),
                        shape = RoundedCornerShape(10.dp),
                    ) {
                        Text("Agree & Open Settings", fontWeight = FontWeight.Bold)
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showAccessibilityDisclosure = false }) {
                        Text("Cancel", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                },
                shape = RoundedCornerShape(20.dp),
                containerColor = MaterialTheme.colorScheme.surface,
            )
        }

        if (showLanguageDownloadDialog) {
            LanguageRoutingDownloadDialog(
                installedDirNames = installedIndicModels,
                isDownloading = downloads.busy,
                onDismiss = { showLanguageDownloadDialog = false },
                onDownloadSelected = { selectedModels ->
                    showLanguageDownloadDialog = false
                    downloads.enqueue(selectedModels, modelsDir, context.cacheDir) {
                        resumeTick++
                    }
                },
            )
        }

        // 3. Hands-Free & Overlay Controls Card
        HandsFreeControlsCard(
            wakeWord = wakeWord,
            bubbleAlwaysVisible = bubbleAlwaysVisible,
            autoLanguageRouting = autoLanguageRouting,
            installedIndicCount = installedIndicModels.size,
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
            onAutoLanguageRoutingChange = { enabled ->
                autoLanguageRouting = enabled
                AppGraph.settings.autoLanguageRoutingEnabled = enabled
                if (enabled && installedIndicModels.isEmpty()) {
                    showLanguageDownloadDialog = true
                }
            },
            onOpenLanguageDownload = { showLanguageDownloadDialog = true },
        )

        // 4. Speech & Cleanup Engines Card
        ActiveModelsCard(
            sttSummary = sttSummary,
            cleanupSummary = cleanupSummary,
            onOpenTranscription = { onNavigate(Screen.Transcription) },
            onOpenCleanup = { onNavigate(Screen.Cleanup) },
        )

        // 5. Tools & Capabilities Card
        CapabilitiesCard(
            onNavigate = onNavigate,
            onOpenOnboarding = { showOnboarding = true },
        )

        Spacer(Modifier.height(16.dp))
    }

    if (showOnboarding) {
        OnboardingDialog(
            onDismiss = { showOnboarding = false },
            onNavigateToScreen = onNavigate,
        )
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
                                    SaysoBrandAmber,
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
                    color = if (summary != null && summary.sessions > 0) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceVariant,
                    border = BorderStroke(
                        1.dp,
                        if (summary != null && summary.sessions > 0) MaterialTheme.colorScheme.outline else MaterialTheme.colorScheme.outlineVariant,
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
                                        listOf(SaysoBrandAmber, Color(0xFFFBBF24)),
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
private fun ModelRequiredBanner(
    downloadState: DownloadState?,
    isDownloading: Boolean,
    onDownload: () -> Unit,
    onOpenWizard: () -> Unit,
) {
    Card(
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.35f),
        ),
        border = BorderStroke(1.5.dp, MaterialTheme.colorScheme.primary),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(18.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Box(
                    modifier = Modifier
                        .size(38.dp)
                        .clip(RoundedCornerShape(11.dp))
                        .background(MaterialTheme.colorScheme.primary),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Default.Download,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(20.dp),
                    )
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        text = stringResource(R.string.home_banner_model_needed_title),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Black,
                    )
                    Text(
                        text = "1-Tap Setup Required",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }

            Spacer(Modifier.height(10.dp))

            Text(
                text = stringResource(R.string.home_banner_model_needed_desc),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                lineHeight = 18.sp,
            )

            Spacer(Modifier.height(14.dp))

            if (isDownloading) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(MaterialTheme.colorScheme.surface)
                        .padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    when (downloadState) {
                        is DownloadState.Downloading -> {
                            val pct = (downloadState.progress * 100).roundToInt()
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                            ) {
                                Text(
                                    text = "Downloading Parakeet 110M...",
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
                                progress = { downloadState.progress },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(8.dp)
                                    .clip(RoundedCornerShape(4.dp)),
                            )
                        }
                        DownloadState.Extracting -> {
                            Text(
                                text = "Extracting neural weights...",
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.SemiBold,
                            )
                            LinearProgressIndicator(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(8.dp)
                                    .clip(RoundedCornerShape(4.dp)),
                            )
                        }
                        is DownloadState.Error -> {
                            Text(
                                text = "Download failed: ${downloadState.message}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.error,
                            )
                        }
                        else -> Unit
                    }
                }
            } else {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Button(
                        onClick = onDownload,
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(12.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.primary,
                        ),
                    ) {
                        Icon(
                            Icons.Default.Download,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            text = stringResource(R.string.home_banner_download_cta),
                            fontWeight = FontWeight.Bold,
                        )
                    }
                    OutlinedButton(
                        onClick = onOpenWizard,
                        shape = RoundedCornerShape(12.dp),
                    ) {
                        Text(stringResource(R.string.home_setup_wizard_cta), fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
    }
}

@Composable
private fun EngineStatusCard(
    ready: Boolean,
    micGranted: Boolean,
    serviceOn: Boolean,
    sttReady: Boolean,
    sttSummary: String,
    downloadState: DownloadState?,
    isDownloading: Boolean,
    onRequestMic: () -> Unit,
    onOpenAccessibility: () -> Unit,
    onDownloadModel: () -> Unit,
    onOpenTranscription: () -> Unit,
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
                        .background(MaterialTheme.colorScheme.primaryContainer),
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
            Spacer(Modifier.height(8.dp))
            ModelStatusRow(
                sttReady = sttReady,
                sttSummary = sttSummary,
                downloadState = downloadState,
                isDownloading = isDownloading,
                onDownload = onDownloadModel,
                onOpenTranscription = onOpenTranscription,
            )
        }
    }
}

@Composable
private fun ModelStatusRow(
    sttReady: Boolean,
    sttSummary: String,
    downloadState: DownloadState?,
    isDownloading: Boolean,
    onDownload: () -> Unit,
    onOpenTranscription: () -> Unit,
) {
    if (isDownloading) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f))
                .padding(10.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            when (downloadState) {
                is DownloadState.Downloading -> {
                    val pct = (downloadState.progress * 100).roundToInt()
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text(
                            text = "Downloading Speech Model...",
                            style = MaterialTheme.typography.bodySmall,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            text = "$pct%",
                            style = MaterialTheme.typography.bodySmall,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.primary,
                        )
                    }
                    LinearProgressIndicator(
                        progress = { downloadState.progress },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(6.dp)
                            .clip(RoundedCornerShape(3.dp)),
                    )
                }
                DownloadState.Extracting -> {
                    Text(
                        text = "Extracting neural weights...",
                        style = MaterialTheme.typography.bodySmall,
                        fontWeight = FontWeight.SemiBold,
                    )
                    LinearProgressIndicator(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(6.dp)
                            .clip(RoundedCornerShape(3.dp)),
                    )
                }
                is DownloadState.Error -> {
                    Text(
                        text = "Download error: ${downloadState.message}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                else -> Unit
            }
        }
    } else {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .clickable(onClick = if (!sttReady) onDownload else onOpenTranscription)
                .padding(vertical = 6.dp, horizontal = 4.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(24.dp)
                    .clip(CircleShape)
                    .background(if (sttReady) Color(0xFFDCFCE7) else Color(0xFFFEF3C7)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = if (sttReady) Icons.Default.CheckCircle else Icons.Default.Download,
                    contentDescription = null,
                    tint = if (sttReady) Color(0xFF16A34A) else Color(0xFFB45309),
                    modifier = Modifier.size(16.dp),
                )
            }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    text = "Speech Recognition Engine",
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    text = if (sttReady) sttSummary else "Model not downloaded (104 MB required)",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (!sttReady) {
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = MaterialTheme.colorScheme.primary,
                ) {
                    Text(
                        text = "Download",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = Color.White,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                    )
                }
            }
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
    autoLanguageRouting: Boolean,
    installedIndicCount: Int,
    onWakeWordChange: (Boolean) -> Unit,
    onBubbleAlwaysVisibleChange: (Boolean) -> Unit,
    onAutoLanguageRoutingChange: (Boolean) -> Unit,
    onOpenLanguageDownload: () -> Unit,
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
                    title = "Automatic language routing",
                    subtitle = "Classify first 1.5s of audio to automatically switch between English (Parakeet) and Indic (AI4Bharat) models",
                    checked = autoLanguageRouting,
                    onCheckedChange = onAutoLanguageRoutingChange,
                )
                if (autoLanguageRouting) {
                    if (installedIndicCount == 0) {
                        Surface(
                            shape = RoundedCornerShape(10.dp),
                            color = MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.4f),
                            border = BorderStroke(1.dp, MaterialTheme.colorScheme.error.copy(alpha = 0.3f)),
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp, vertical = 6.dp)
                                .clickable(onClick = onOpenLanguageDownload),
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Text(
                                    text = "⚠️",
                                    fontSize = 14.sp,
                                )
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = "No Indic models downloaded",
                                        style = MaterialTheme.typography.labelMedium,
                                        fontWeight = FontWeight.Bold,
                                        color = MaterialTheme.colorScheme.onErrorContainer,
                                    )
                                    Text(
                                        text = "Tap to select and download languages for auto-routing",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onErrorContainer.copy(alpha = 0.8f),
                                    )
                                }
                                Icon(
                                    imageVector = Icons.Default.Download,
                                    contentDescription = "Download models",
                                    tint = MaterialTheme.colorScheme.error,
                                    modifier = Modifier.size(18.dp),
                                )
                            }
                        }
                    } else {
                        Surface(
                            shape = RoundedCornerShape(10.dp),
                            color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.3f),
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp, vertical = 6.dp)
                                .clickable(onClick = onOpenLanguageDownload),
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Text(
                                    text = "✓",
                                    fontWeight = FontWeight.Bold,
                                    color = MaterialTheme.colorScheme.primary,
                                    fontSize = 14.sp,
                                )
                                Text(
                                    text = "Active for $installedIndicCount Indic language(s) + English. Tap to manage.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurface,
                                    modifier = Modifier.weight(1f),
                                )
                            }
                        }
                    }
                }
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
private fun LanguageRoutingDownloadDialog(
    installedDirNames: Set<String>,
    isDownloading: Boolean,
    onDismiss: () -> Unit,
    onDownloadSelected: (List<LocalModel>) -> Unit,
) {
    val routingModels = remember {
        listOfNotNull(LocalModelCatalog.byDirName("sherpa-onnx-whisper-tiny")) + LocalModelCatalog.indicModels
    }
    val selectedDirNames = remember(installedDirNames) {
        mutableStateMapOf<String, Boolean>().apply {
            routingModels.forEach { model ->
                put(model.dirName, model.dirName !in installedDirNames)
            }
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        icon = {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(
                        Brush.linearGradient(
                            listOf(
                                MaterialTheme.colorScheme.primary,
                                SaysoBrandAmber,
                            ),
                        ),
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Default.Download,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(24.dp),
                )
            }
        },
        title = {
            Text(
                text = "Language Routing Models",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    text = "Select models to download for automatic routing. Whisper Multilingual Tiny classifies your speech in real-time to switch seamlessly between English and Indic models.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )

                Surface(
                    shape = RoundedCornerShape(12.dp),
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(modifier = Modifier.padding(vertical = 4.dp)) {
                        routingModels.forEach { model ->
                            val isInstalled = model.dirName in installedDirNames
                            val isChecked = selectedDirNames[model.dirName] == true

                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable(enabled = !isInstalled) {
                                        selectedDirNames[model.dirName] = !isChecked
                                    }
                                    .padding(horizontal = 12.dp, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Checkbox(
                                    checked = isInstalled || isChecked,
                                    onCheckedChange = if (isInstalled) null else { checked ->
                                        selectedDirNames[model.dirName] = checked
                                    },
                                    enabled = !isInstalled,
                                )
                                Spacer(Modifier.width(8.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = model.displayName,
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontWeight = FontWeight.SemiBold,
                                    )
                                    Text(
                                        text = if (isInstalled) "Installed" else "${model.sizeMb} MB · On-device",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = if (isInstalled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            val toDownload = routingModels.filter { model ->
                model.dirName !in installedDirNames && selectedDirNames[model.dirName] == true
            }
            Button(
                onClick = {
                    if (toDownload.isEmpty()) {
                        onDismiss()
                    } else {
                        onDownloadSelected(toDownload)
                    }
                },
                enabled = !isDownloading,
            ) {
                Text(if (toDownload.isEmpty()) "Done" else "Download (${toDownload.sumOf { it.sizeMb }} MB)")
            }
        },
        dismissButton = {
            OutlinedButton(onClick = onDismiss) {
                Text("Later")
            }
        },
        shape = RoundedCornerShape(20.dp),
        containerColor = MaterialTheme.colorScheme.surface,
    )
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
            text = "SPEECH & POST-PROCESSING ENGINES",
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
                    iconBg = MaterialTheme.colorScheme.primaryContainer,
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
private fun CapabilitiesCard(
    onNavigate: (Screen) -> Unit,
    onOpenOnboarding: () -> Unit,
) {
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
                    title = stringResource(R.string.home_setup_wizard_cta),
                    subtitle = stringResource(R.string.home_setup_wizard_subtitle),
                    icon = Icons.Default.AutoFixHigh,
                    iconBg = Color(0xFFFEF3C7),
                    iconTint = SaysoBrandAmber,
                    onClick = onOpenOnboarding,
                )
                HorizontalDivider(
                    color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
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

internal fun checkSttReady(settings: ai.sayso.dictation.core.SettingsStore, modelsDir: File): Boolean {
    val modelId = settings.sttModelId
    return if (modelId.startsWith("local/")) {
        val dirName = modelId.removePrefix("local/")
        val model = LocalModelCatalog.byDirName(dirName) ?: return false
        AppGraph.downloads.isInstalled(model, modelsDir)
    } else {
        val providerId = modelId.substringBefore('/')
        AppGraph.secrets.get(providerId)?.isNotBlank() == true
    }
}

/** Friendly description of active model, or uninstalled warning if local model is absent. */
internal fun sttSummary(): String {
    val id = AppGraph.settings.sttModelId
    if (id.startsWith("local/")) {
        val dirName = id.removePrefix("local/")
        val model = LocalModelCatalog.byDirName(dirName)
        val installed = model != null && AppGraph.downloads.isInstalled(model, AppGraph.localModelsDir)
        val name = model?.displayName ?: dirName
        return if (installed) {
            "On device: $name"
        } else {
            "On device: $name (Not installed)"
        }
    }
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


