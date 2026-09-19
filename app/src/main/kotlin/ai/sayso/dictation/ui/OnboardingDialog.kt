package ai.sayso.dictation.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.AutoFixHigh
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Hearing
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.RadioButtonChecked
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Spellcheck
import androidx.compose.material.icons.filled.Translate
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.LifecycleResumeEffect
import ai.sayso.dictation.AppGraph
import ai.sayso.dictation.R
import ai.sayso.dictation.models.DownloadState
import ai.sayso.dictation.models.LocalModel
import ai.sayso.dictation.models.LocalModelCatalog
import ai.sayso.dictation.polish.SlmModelInfo
import ai.sayso.dictation.service.DictationService
import ai.sayso.dictation.service.WakeWordService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

/**
 * 3-step setup onboarding wizard:
 * 1. Speech engine selection and 1-tap model download
 * 2. Post-processing (AI Polish) configuration with before/after comparison
 * 3. Permissions grant (Microphone and Accessibility Service)
 */
@Composable
fun OnboardingDialog(
    onDismiss: () -> Unit,
    onNavigateToScreen: ((Screen) -> Unit)? = null,
) {
    val context = LocalContext.current
    val settings = AppGraph.settings
    val downloads = AppGraph.downloads
    val defaultModel = LocalModelCatalog.default

    var currentStep by remember { mutableIntStateOf(0) }
    var micGranted by remember { mutableStateOf(context.hasMicPermission()) }
    var serviceOn by remember { mutableStateOf(DictationService.isEnabled(context)) }
    var isModelInstalled by remember { mutableStateOf(false) }

    var interestedInIndianLanguages by remember {
        mutableStateOf(
            settings.language in listOf("ta", "hi", "ml") ||
                settings.sttModelId.contains("indicconformer") ||
                settings.transliterateIndicToLatin
        )
    }
    var interestedInForeignLanguages by remember {
        mutableStateOf(
            settings.language == "auto" || settings.autoLanguageRoutingEnabled
        )
    }
    var selectedIndicLanguage by remember {
        mutableStateOf(
            when {
                settings.language == "hi" || settings.sttModelId.contains("-hi") -> "hi"
                settings.language == "ml" || settings.sttModelId.contains("-ml") -> "ml"
                settings.language == "auto" -> "all"
                else -> "ta"
            }
        )
    }
    var transliterateToLatin by remember {
        mutableStateOf(if (settings.hasCompletedOnboarding) settings.transliterateIndicToLatin else true)
    }

    val recommendedSttModel = remember(interestedInIndianLanguages, interestedInForeignLanguages, selectedIndicLanguage) {
        LocalModelCatalog.resolveForLanguages(
            interestedInIndianLanguages = interestedInIndianLanguages,
            interestedInForeignLanguages = interestedInForeignLanguages,
            primaryIndicLanguage = selectedIndicLanguage,
        )
    }

    val initialIsCloud = settings.sttModelId.substringBefore('/') != "local"
    var selectedSttChoice by remember {
        mutableStateOf(if (initialIsCloud) SttEngineChoice.CLOUD else SttEngineChoice.LOCAL)
    }
    var selectedLocalModel by remember {
        mutableStateOf(
            LocalModelCatalog.byDirName(settings.sttModelId.removePrefix("local/")) ?: recommendedSttModel
        )
    }

    var showOtherModelsDialog by remember { mutableStateOf(false) }

    val slmDownloads = AppGraph.slmDownloads
    val slmStorageDir = remember { ai.sayso.dictation.polish.LocalSlmPolisher.storageDir }
    val defaultSlmModel = remember { ai.sayso.dictation.polish.LocalSlmCatalog.default }
    var isSlmInstalled by remember { mutableStateOf(false) }

    LaunchedEffect(slmDownloads.state) {
        if (slmStorageDir != null) {
            isSlmInstalled = withContext(Dispatchers.IO) {
                slmDownloads.isInstalled(defaultSlmModel, slmStorageDir)
            }
        }
    }

    var selectedPolishMode by remember {
        mutableStateOf(
            when {
                !settings.hasCompletedOnboarding -> PolishModeChoice.RULES
                !settings.polishEnabled -> PolishModeChoice.OFF
                settings.polishModelId.startsWith("rules/") -> PolishModeChoice.RULES
                settings.polishModelId.startsWith("local-slm/") -> PolishModeChoice.LOCAL_SLM
                else -> PolishModeChoice.CLOUD
            }
        )
    }
    var showAccessibilityDisclosure by remember { mutableStateOf(false) }

    val micLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        micGranted = granted
        if (granted && settings.wakeWordEnabled) {
            WakeWordService.start(context)
        }
    }

    LifecycleResumeEffect(Unit) {
        micGranted = context.hasMicPermission()
        serviceOn = DictationService.isEnabled(context)
        onPauseOrDispose { }
    }

    // Refresh model installed check
    LaunchedEffect(downloads.state, selectedLocalModel) {
        isModelInstalled = withContext(Dispatchers.IO) {
            downloads.isInstalled(selectedLocalModel, AppGraph.localModelsDir)
        }
    }

    var waitingForSttDownload by remember { mutableStateOf(false) }
    var waitingForSlmDownload by remember { mutableStateOf(false) }

    // Latch waiting state when active model download begins (Step 1 for STT, Step 2 for SLM)
    LaunchedEffect(downloads.busy, currentStep, selectedSttChoice) {
        if (downloads.busy && selectedSttChoice == SttEngineChoice.LOCAL && currentStep == 1) {
            waitingForSttDownload = true
        }
    }
    LaunchedEffect(slmDownloads.busy, currentStep, selectedPolishMode) {
        if (slmDownloads.busy && selectedPolishMode == PolishModeChoice.LOCAL_SLM && currentStep == 2) {
            waitingForSlmDownload = true
        }
    }

    // Auto-advance Step 1 when local STT model completes download
    LaunchedEffect(isModelInstalled, waitingForSttDownload, currentStep) {
        if (waitingForSttDownload && isModelInstalled && currentStep == 1) {
            waitingForSttDownload = false
            currentStep = 2
        }
    }

    // Auto-advance Step 2 when local SLM model completes download
    LaunchedEffect(isSlmInstalled, waitingForSlmDownload, currentStep) {
        if (waitingForSlmDownload && isSlmInstalled && currentStep == 2) {
            waitingForSlmDownload = false
            currentStep = 3
        }
    }

    // Reset waiting flags on error so user can retry or switch option
    LaunchedEffect(downloads.state) {
        if (downloads.state is DownloadState.Error) {
            waitingForSttDownload = false
        }
    }
    LaunchedEffect(slmDownloads.state) {
        if (slmDownloads.state is DownloadState.Error) {
            waitingForSlmDownload = false
        }
    }


    Dialog(
        onDismissRequest = {
            settings.hasCompletedOnboarding = true
            onDismiss()
        },
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            dismissOnBackPress = true,
            dismissOnClickOutside = false,
        ),
    ) {
        Surface(
            modifier = Modifier
                .fillMaxWidth(0.94f)
                .padding(vertical = 24.dp),
            shape = RoundedCornerShape(24.dp),
            color = MaterialTheme.colorScheme.surface,
            tonalElevation = 6.dp,
            shadowElevation = 8.dp,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(20.dp),
            ) {
                // Top Header: Logo + Title + Skip
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .clip(RoundedCornerShape(10.dp))
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
                            modifier = Modifier.size(20.dp),
                        )
                    }
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            text = stringResource(R.string.onboarding_title),
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Black,
                        )
                        Text(
                            text = "Step ${currentStep + 1} of 4",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.primary,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                    TextButton(
                        onClick = {
                            settings.hasCompletedOnboarding = true
                            onDismiss()
                        },
                    ) {
                        Text(
                            text = stringResource(R.string.onboarding_skip),
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }

                Spacer(Modifier.height(14.dp))

                // Step Indicators (1, 2, 3, 4)
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    for (i in 0..3) {
                        val active = i == currentStep
                        val done = i < currentStep
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .height(4.dp)
                                .clip(RoundedCornerShape(2.dp))
                                .background(
                                    when {
                                        active -> MaterialTheme.colorScheme.primary
                                        done -> MaterialTheme.colorScheme.primary.copy(alpha = 0.5f)
                                        else -> MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f)
                                    },
                                ),
                        )
                    }
                }

                Spacer(Modifier.height(16.dp))

                // Step Content
                AnimatedContent(
                    targetState = currentStep,
                    transitionSpec = {
                        if (targetState > initialState) {
                            slideInHorizontally { it } + fadeIn() togetherWith
                                slideOutHorizontally { -it } + fadeOut()
                        } else {
                            slideInHorizontally { -it } + fadeIn() togetherWith
                                slideOutHorizontally { it } + fadeOut()
                        }
                    },
                    label = "onboarding_step",
                ) { step ->
                    when (step) {
                        0 -> StepZeroLanguages(
                            interestedInIndianLanguages = interestedInIndianLanguages,
                            onToggleIndianLanguages = {
                                interestedInIndianLanguages = it
                                selectedLocalModel = LocalModelCatalog.resolveForLanguages(it, interestedInForeignLanguages, selectedIndicLanguage)
                            },
                            interestedInForeignLanguages = interestedInForeignLanguages,
                            onToggleForeignLanguages = {
                                interestedInForeignLanguages = it
                                selectedLocalModel = LocalModelCatalog.resolveForLanguages(interestedInIndianLanguages, it, selectedIndicLanguage)
                            },
                            selectedIndicLanguage = selectedIndicLanguage,
                            onSelectIndicLanguage = {
                                selectedIndicLanguage = it
                                selectedLocalModel = LocalModelCatalog.resolveForLanguages(interestedInIndianLanguages, interestedInForeignLanguages, it)
                            },
                            transliterateToLatin = transliterateToLatin,
                            onToggleTransliteration = { transliterateToLatin = it },
                            recommendedModel = recommendedSttModel,
                        )
                        1 -> StepOneSttEngine(
                            selectedChoice = selectedSttChoice,
                            onSelectChoice = { choice ->
                                selectedSttChoice = choice
                                if (choice != SttEngineChoice.LOCAL) {
                                    waitingForSttDownload = false
                                }
                                if (choice == SttEngineChoice.LOCAL) {
                                    if (isModelInstalled) {
                                        settings.sttModelId = "local/${selectedLocalModel.dirName}"
                                        DictationService.instance?.reloadLocalModel()
                                    }
                                } else {
                                    settings.sttModelId = "groq/whisper-large-v3-turbo"
                                }
                            },
                            selectedLocalModel = selectedLocalModel,
                            onOpenOtherModels = { showOtherModelsDialog = true },
                            isModelInstalled = isModelInstalled,
                            downloadState = downloads.state,
                            isDownloading = downloads.busy && downloads.activeDirName == selectedLocalModel.dirName,
                            onStartDownload = {
                                selectedSttChoice = SttEngineChoice.LOCAL
                                downloads.start(selectedLocalModel, AppGraph.localModelsDir, context.cacheDir) {
                                    if (downloads.state is DownloadState.Done && selectedSttChoice == SttEngineChoice.LOCAL) {
                                        settings.sttModelId = "local/${selectedLocalModel.dirName}"
                                        DictationService.instance?.reloadLocalModel()
                                    }
                                }
                            },
                        )
                        2 -> StepTwoPostProcessing(
                            selected = selectedPolishMode,
                            isSlmInstalled = isSlmInstalled,
                            isSlmDownloading = slmDownloads.busy && slmDownloads.activeModelId == defaultSlmModel.id,
                            slmDownloadState = slmDownloads.state,
                            defaultSlmModel = defaultSlmModel,
                            onStartSlmDownload = {
                                if (slmStorageDir != null) {
                                    slmDownloads.start(defaultSlmModel, slmStorageDir) {
                                        if (slmDownloads.state is DownloadState.Done && selectedPolishMode == PolishModeChoice.LOCAL_SLM) {
                                            settings.polishEnabled = true
                                            settings.polishModelId = defaultSlmModel.id
                                        }
                                    }
                                }
                            },
                            onSelect = { mode ->
                                selectedPolishMode = mode
                                if (mode != PolishModeChoice.LOCAL_SLM) {
                                    waitingForSlmDownload = false
                                }
                                when (mode) {
                                    PolishModeChoice.RULES -> {
                                        settings.polishEnabled = true
                                        settings.polishModelId = "rules/basic"
                                    }
                                    PolishModeChoice.LOCAL_SLM -> {
                                        if (isSlmInstalled) {
                                            settings.polishEnabled = true
                                            settings.polishModelId = defaultSlmModel.id
                                        }
                                    }
                                    PolishModeChoice.CLOUD -> {
                                        settings.polishEnabled = true
                                        if (settings.polishModelId.startsWith("rules/") || settings.polishModelId.startsWith("local-slm/")) {
                                            settings.polishModelId = "openai/gpt-4o-mini"
                                        }
                                    }
                                    PolishModeChoice.OFF -> {
                                        settings.polishEnabled = false
                                    }
                                }
                            },
                        )
                        3 -> StepThreePermissions(
                            micGranted = micGranted,
                            serviceOn = serviceOn,
                            onRequestMic = { micLauncher.launch(Manifest.permission.RECORD_AUDIO) },
                            onOpenAccessibility = {
                                if (serviceOn) {
                                    context.openAccessibilitySettings()
                                } else {
                                    showAccessibilityDisclosure = true
                                }
                            },
                        )
                    }
                }

                Spacer(Modifier.height(20.dp))
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
                Spacer(Modifier.height(14.dp))

                // Bottom Navigation Buttons
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (currentStep > 0) {
                        OutlinedButton(
                            onClick = {
                                waitingForSttDownload = false
                                waitingForSlmDownload = false
                                currentStep--
                            },
                            shape = RoundedCornerShape(12.dp),
                        ) {
                            Icon(
                                Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = null,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(stringResource(R.string.onboarding_back))
                        }
                    } else {
                        Spacer(Modifier.width(1.dp))
                    }

                    if (currentStep < 3) {
                        val isLangStep = currentStep == 0
                        val isSttStep = currentStep == 1
                        val isSlmStep = currentStep == 2

                        val isSttActiveDownloading = isSttStep && selectedSttChoice == SttEngineChoice.LOCAL && !isModelInstalled && downloads.busy
                        val isSlmActiveDownloading = isSlmStep && selectedPolishMode == PolishModeChoice.LOCAL_SLM && !isSlmInstalled && slmDownloads.busy

                        val isSttWaiting = isSttStep && selectedSttChoice == SttEngineChoice.LOCAL && !isModelInstalled
                        val isSlmWaiting = isSlmStep && selectedPolishMode == PolishModeChoice.LOCAL_SLM && !isSlmInstalled

                        val isDownloading = isSttActiveDownloading || isSlmActiveDownloading || (isSttStep && waitingForSttDownload) || (isSlmStep && waitingForSlmDownload)

                        Button(
                            onClick = {
                                when {
                                    isLangStep -> {
                                        settings.transliterateIndicToLatin = if (interestedInIndianLanguages) transliterateToLatin else false
                                        when {
                                            interestedInIndianLanguages && interestedInForeignLanguages -> {
                                                settings.language = "auto"
                                                settings.autoLanguageRoutingEnabled = true
                                            }
                                            interestedInForeignLanguages -> {
                                                settings.language = "auto"
                                                settings.autoLanguageRoutingEnabled = true
                                            }
                                            interestedInIndianLanguages -> {
                                                settings.language = if (selectedIndicLanguage == "all") "auto" else selectedIndicLanguage
                                                settings.autoLanguageRoutingEnabled = (selectedIndicLanguage == "all")
                                            }
                                            else -> {
                                                settings.language = "en"
                                                settings.autoLanguageRoutingEnabled = false
                                            }
                                        }
                                        if (isModelInstalled && selectedSttChoice == SttEngineChoice.LOCAL) {
                                            settings.sttModelId = "local/${selectedLocalModel.dirName}"
                                            DictationService.instance?.reloadLocalModel()
                                        }
                                        currentStep = 1
                                    }
                                    isSttWaiting -> {
                                        waitingForSttDownload = true
                                        if (!downloads.busy) {
                                            downloads.start(selectedLocalModel, AppGraph.localModelsDir, context.cacheDir) {
                                                if (downloads.state is DownloadState.Done && selectedSttChoice == SttEngineChoice.LOCAL) {
                                                    settings.sttModelId = "local/${selectedLocalModel.dirName}"
                                                    DictationService.instance?.reloadLocalModel()
                                                }
                                            }
                                        }
                                    }
                                    isSlmWaiting -> {
                                        waitingForSlmDownload = true
                                        if (!slmDownloads.busy && slmStorageDir != null) {
                                            slmDownloads.start(defaultSlmModel, slmStorageDir) {
                                                if (slmDownloads.state is DownloadState.Done && selectedPolishMode == PolishModeChoice.LOCAL_SLM) {
                                                    settings.polishEnabled = true
                                                    settings.polishModelId = defaultSlmModel.id
                                                }
                                            }
                                        }
                                    }
                                    isSttStep -> {
                                        if (selectedSttChoice == SttEngineChoice.LOCAL) {
                                            settings.sttModelId = "local/${selectedLocalModel.dirName}"
                                            DictationService.instance?.reloadLocalModel()
                                        } else {
                                            settings.sttModelId = "groq/whisper-large-v3-turbo"
                                        }
                                        currentStep = 2
                                    }
                                    isSlmStep -> {
                                        when (selectedPolishMode) {
                                            PolishModeChoice.RULES -> {
                                                settings.polishEnabled = true
                                                settings.polishModelId = "rules/basic"
                                            }
                                            PolishModeChoice.CLOUD -> {
                                                settings.polishEnabled = true
                                                if (settings.polishModelId.startsWith("rules/") || settings.polishModelId.startsWith("local-slm/")) {
                                                    settings.polishModelId = "openai/gpt-4o-mini"
                                                }
                                            }
                                            PolishModeChoice.OFF -> {
                                                settings.polishEnabled = false
                                            }
                                            PolishModeChoice.LOCAL_SLM -> {
                                                if (isSlmInstalled) {
                                                    settings.polishEnabled = true
                                                    settings.polishModelId = defaultSlmModel.id
                                                }
                                            }
                                        }
                                        currentStep = 3
                                    }
                                    else -> {
                                        currentStep++
                                    }
                                }
                            },
                            enabled = !isDownloading,
                            shape = RoundedCornerShape(12.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = MaterialTheme.colorScheme.primary,
                            ),
                        ) {
                            if (isDownloading) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(16.dp),
                                    color = MaterialTheme.colorScheme.onPrimary,
                                    strokeWidth = 2.dp,
                                )
                                Spacer(Modifier.width(8.dp))
                                val label = if (isSttStep) {
                                    when (val state = downloads.state) {
                                        is DownloadState.Extracting -> stringResource(R.string.onboarding_next_extracting)
                                        is DownloadState.Downloading -> {
                                            val pct = (state.progress * 100).roundToInt()
                                            stringResource(R.string.onboarding_next_downloading, pct)
                                        }
                                        else -> stringResource(R.string.onboarding_next_downloading, 0)
                                    }
                                } else {
                                    when (val state = slmDownloads.state) {
                                        is DownloadState.Extracting -> stringResource(R.string.onboarding_next_extracting_slm)
                                        is DownloadState.Downloading -> {
                                            val pct = (state.progress * 100).roundToInt()
                                            stringResource(R.string.onboarding_next_downloading_slm, pct)
                                        }
                                        else -> stringResource(R.string.onboarding_next_downloading_slm, 0)
                                    }
                                }
                                Text(label, fontWeight = FontWeight.Bold)
                            } else if (isSttWaiting || isSlmWaiting) {
                                Icon(
                                    Icons.Default.Download,
                                    contentDescription = null,
                                    modifier = Modifier.size(16.dp),
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(stringResource(R.string.onboarding_next_download), fontWeight = FontWeight.Bold)
                            } else {
                                Text(stringResource(R.string.onboarding_next), fontWeight = FontWeight.Bold)
                                Spacer(Modifier.width(6.dp))
                                Icon(
                                    Icons.AutoMirrored.Filled.ArrowForward,
                                    contentDescription = null,
                                    modifier = Modifier.size(16.dp),
                                )
                            }
                        }
                    } else {
                        Button(
                            onClick = {
                                settings.hasCompletedOnboarding = true
                                onDismiss()
                            },
                            shape = RoundedCornerShape(12.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = Color(0xFF16A34A),
                            ),
                        ) {
                            Icon(
                                Icons.Default.CheckCircle,
                                contentDescription = null,
                                modifier = Modifier.size(18.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(stringResource(R.string.onboarding_finish), fontWeight = FontWeight.Bold)
                        }
                    }
                }
            }
        }
    }

    if (showAccessibilityDisclosure) {
        AccessibilityDisclosureDialog(
            onAgree = {
                showAccessibilityDisclosure = false
                context.openAccessibilitySettings()
            },
            onDismiss = { showAccessibilityDisclosure = false },
        )
    }

    if (showOtherModelsDialog) {
        AlertDialog(
            onDismissRequest = { showOtherModelsDialog = false },
            title = {
                Text(
                    text = "Select On-Device Model",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                )
            },
            text = {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 420.dp)
                        .verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    for (model in LocalModelCatalog.all) {
                        val isSelected = selectedLocalModel.dirName == model.dirName
                        Surface(
                            onClick = {
                                selectedLocalModel = model
                                selectedSttChoice = SttEngineChoice.LOCAL
                                if (downloads.isInstalled(model, AppGraph.localModelsDir)) {
                                    settings.sttModelId = "local/${model.dirName}"
                                    DictationService.instance?.reloadLocalModel()
                                }
                                showOtherModelsDialog = false
                            },
                            shape = RoundedCornerShape(12.dp),
                            color = if (isSelected) MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.4f) else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.3f),
                            border = BorderStroke(
                                if (isSelected) 1.5.dp else 1.dp,
                                if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                            ),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(
                                modifier = Modifier.padding(12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                androidx.compose.material3.RadioButton(
                                    selected = isSelected,
                                    onClick = {
                                        selectedLocalModel = model
                                        selectedSttChoice = SttEngineChoice.LOCAL
                                        if (downloads.isInstalled(model, AppGraph.localModelsDir)) {
                                            settings.sttModelId = "local/${model.dirName}"
                                            DictationService.instance?.reloadLocalModel()
                                        }
                                        showOtherModelsDialog = false
                                    },
                                )
                                Spacer(Modifier.width(8.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = model.displayName,
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontWeight = FontWeight.SemiBold,
                                    )
                                    Text(
                                        text = "${model.note} · ${model.sizeMb} MB",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                            }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showOtherModelsDialog = false }) {
                    Text("Close")
                }
            },
        )
    }
}

enum class SttEngineChoice {
    LOCAL,
    CLOUD,
}

/** Step 0: Language selection and transliteration preferences */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StepZeroLanguages(
    interestedInIndianLanguages: Boolean,
    onToggleIndianLanguages: (Boolean) -> Unit,
    interestedInForeignLanguages: Boolean,
    onToggleForeignLanguages: (Boolean) -> Unit,
    selectedIndicLanguage: String,
    onSelectIndicLanguage: (String) -> Unit,
    transliterateToLatin: Boolean,
    onToggleTransliteration: (Boolean) -> Unit,
    recommendedModel: LocalModel,
) {
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Column {
            Text(
                text = stringResource(R.string.onboarding_lang_title),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
            )
            Text(
                text = stringResource(R.string.onboarding_lang_subtitle),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        // Card 1: Indian Languages
        Card(
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(
                containerColor = if (interestedInIndianLanguages) {
                    MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.25f)
                } else {
                    MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
                },
            ),
            border = BorderStroke(
                if (interestedInIndianLanguages) 1.5.dp else 1.dp,
                if (interestedInIndianLanguages) MaterialTheme.colorScheme.primary.copy(alpha = 0.8f) else MaterialTheme.colorScheme.outlineVariant,
            ),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(14.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .clickable { onToggleIndianLanguages(!interestedInIndianLanguages) },
                ) {
                    Checkbox(
                        checked = interestedInIndianLanguages,
                        onCheckedChange = { onToggleIndianLanguages(it) },
                        colors = CheckboxDefaults.colors(
                            checkedColor = MaterialTheme.colorScheme.primary,
                        ),
                    )
                    Spacer(Modifier.width(8.dp))
                    Box(
                        modifier = Modifier
                            .size(32.dp)
                            .clip(CircleShape)
                            .background(
                                if (interestedInIndianLanguages) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.Default.Language,
                            contentDescription = null,
                            tint = if (interestedInIndianLanguages) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            text = stringResource(R.string.onboarding_lang_indic_title),
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.Bold,
                        )
                        Text(
                            text = stringResource(R.string.onboarding_lang_indic_desc),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }

                if (interestedInIndianLanguages) {
                    Spacer(Modifier.height(12.dp))
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
                    Spacer(Modifier.height(12.dp))

                    Text(
                        text = stringResource(R.string.onboarding_lang_select_primary),
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Spacer(Modifier.height(8.dp))

                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        val allChips = listOf(
                            "ta" to stringResource(R.string.onboarding_lang_tamil),
                            "hi" to stringResource(R.string.onboarding_lang_hindi),
                            "ml" to stringResource(R.string.onboarding_lang_malayalam),
                            "all" to stringResource(R.string.onboarding_lang_all_indic),
                        )
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            allChips.take(2).forEach { (code, label) ->
                                val isSelected = selectedIndicLanguage == code
                                FilterChip(
                                    selected = isSelected,
                                    onClick = { onSelectIndicLanguage(code) },
                                    label = {
                                        Text(
                                            text = label,
                                            style = MaterialTheme.typography.labelSmall,
                                            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                                        )
                                    },
                                    modifier = Modifier.weight(1f),
                                    colors = FilterChipDefaults.filterChipColors(
                                        selectedContainerColor = MaterialTheme.colorScheme.primary,
                                        selectedLabelColor = MaterialTheme.colorScheme.onPrimary,
                                    ),
                                )
                            }
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            allChips.drop(2).forEach { (code, label) ->
                                val isSelected = selectedIndicLanguage == code
                                FilterChip(
                                    selected = isSelected,
                                    onClick = { onSelectIndicLanguage(code) },
                                    label = {
                                        Text(
                                            text = label,
                                            style = MaterialTheme.typography.labelSmall,
                                            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                                        )
                                    },
                                    modifier = Modifier.weight(1f),
                                    colors = FilterChipDefaults.filterChipColors(
                                        selectedContainerColor = MaterialTheme.colorScheme.primary,
                                        selectedLabelColor = MaterialTheme.colorScheme.onPrimary,
                                    ),
                                )
                            }
                        }
                    }

                    Spacer(Modifier.height(14.dp))

                    // Transliteration Section
                    Text(
                        text = stringResource(R.string.onboarding_translit_title),
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        text = stringResource(R.string.onboarding_translit_subtitle),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(8.dp))

                    val exampleSpoken = when (selectedIndicLanguage) {
                        "hi" -> "नमस्ते, आप कैसे हैं?"
                        "ml" -> "നമസ്കാരം, സുഖമാണോ?"
                        "all" -> "வணக்கம் / नमस्ते / നമസ്കാരം"
                        else -> "வணக்கம், எப்படி இருக்கீங்க?"
                    }
                    val exampleLatin = when (selectedIndicLanguage) {
                        "hi" -> "Namaste, aap kaise hain?"
                        "ml" -> "Namaskaram, sugamano?"
                        "all" -> "Vanakkam / Namaste / Namaskaram"
                        else -> "Vanakkam, eppadi irukkeenga?"
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        // Option 1: Tanglish / Hinglish / Manglish
                        Surface(
                            onClick = { onToggleTransliteration(true) },
                            shape = RoundedCornerShape(12.dp),
                            color = if (transliterateToLatin) {
                                MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.35f)
                            } else {
                                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.25f)
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
                                        text = when (selectedIndicLanguage) {
                                            "hi" -> "Hinglish"
                                            "ml" -> "Manglish"
                                            "ta" -> "Tanglish"
                                            else -> "Tanglish / Hinglish"
                                        },
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
                            onClick = { onToggleTransliteration(false) },
                            shape = RoundedCornerShape(12.dp),
                            color = if (!transliterateToLatin) {
                                MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.35f)
                            } else {
                                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.25f)
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
                                            text = "\"$exampleSpoken\"",
                                            fontSize = 11.sp,
                                            fontWeight = FontWeight.Medium,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Card 2: Foreign Languages
        Card(
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(
                containerColor = if (interestedInForeignLanguages) {
                    MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.25f)
                } else {
                    MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
                },
            ),
            border = BorderStroke(
                if (interestedInForeignLanguages) 1.5.dp else 1.dp,
                if (interestedInForeignLanguages) MaterialTheme.colorScheme.primary.copy(alpha = 0.8f) else MaterialTheme.colorScheme.outlineVariant,
            ),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .clickable { onToggleForeignLanguages(!interestedInForeignLanguages) }
                    .padding(14.dp),
            ) {
                Checkbox(
                    checked = interestedInForeignLanguages,
                    onCheckedChange = { onToggleForeignLanguages(it) },
                    colors = CheckboxDefaults.colors(
                        checkedColor = MaterialTheme.colorScheme.primary,
                    ),
                )
                Spacer(Modifier.width(8.dp))
                Box(
                    modifier = Modifier
                        .size(32.dp)
                        .clip(CircleShape)
                        .background(
                            if (interestedInForeignLanguages) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Default.Public,
                        contentDescription = null,
                        tint = if (interestedInForeignLanguages) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp),
                    )
                }
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        text = stringResource(R.string.onboarding_lang_foreign_title),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        text = stringResource(R.string.onboarding_lang_foreign_desc),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        // Note: English Default
        Surface(
            shape = RoundedCornerShape(12.dp),
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.3f),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f)),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(
                modifier = Modifier.padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    Icons.Default.Info,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(16.dp),
                )
                Text(
                    text = stringResource(R.string.onboarding_lang_english_default),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        // Recommended Model Box
        Card(
            shape = RoundedCornerShape(14.dp),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.4f),
            ),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.secondary.copy(alpha = 0.5f)),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(12.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Surface(
                        shape = RoundedCornerShape(8.dp),
                        color = SaysoBrandAmber,
                    ) {
                        Text(
                            text = "RECOMMENDED MODEL",
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.Bold,
                            color = SaysoBrandNavy,
                            fontSize = 9.sp,
                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                    }
                    Text(
                        text = stringResource(R.string.onboarding_model_recommendation_title),
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
                Spacer(Modifier.height(6.dp))
                Text(
                    text = "${recommendedModel.displayName} (${recommendedModel.sizeMb} MB)",
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    text = recommendedModel.note,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}


/** Step 1: Voice Engine selection and 1-tap download CTA */
@Composable
private fun StepOneSttEngine(
    selectedChoice: SttEngineChoice,
    onSelectChoice: (SttEngineChoice) -> Unit,
    selectedLocalModel: LocalModel,
    onOpenOtherModels: () -> Unit,
    isModelInstalled: Boolean,
    downloadState: DownloadState?,
    isDownloading: Boolean,
    onStartDownload: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Column {
            Text(
                text = stringResource(R.string.onboarding_stt_title),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
            )
            Text(
                text = stringResource(R.string.onboarding_stt_subtitle),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        // Card 1: On-Device Model (Recommended)
        val isLocalSelected = selectedChoice == SttEngineChoice.LOCAL
        Card(
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(
                containerColor = if (isLocalSelected) {
                    MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.25f)
                } else {
                    MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
                },
            ),
            border = BorderStroke(
                if (isLocalSelected) 1.5.dp else 1.dp,
                if (isLocalSelected) MaterialTheme.colorScheme.primary.copy(alpha = 0.8f) else MaterialTheme.colorScheme.outlineVariant,
            ),
            modifier = Modifier
                .fillMaxWidth()
                .clickable { onSelectChoice(SttEngineChoice.LOCAL) },
        ) {
            Column(Modifier.padding(16.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(
                        imageVector = if (isLocalSelected) Icons.Default.RadioButtonChecked else Icons.Default.RadioButtonUnchecked,
                        contentDescription = null,
                        tint = if (isLocalSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(20.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Box(
                        modifier = Modifier
                            .size(32.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.primary),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.Default.Download,
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            text = stringResource(R.string.onboarding_stt_local_title),
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.Bold,
                        )
                        Text(
                            text = selectedLocalModel.displayName,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.primary,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                    Surface(
                        shape = RoundedCornerShape(12.dp),
                        color = Color(0xFFDCFCE7),
                        border = BorderStroke(1.dp, Color(0xFF86EFAC)),
                    ) {
                        Text(
                            text = "RECOMMENDED",
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.Bold,
                            color = Color(0xFF15803D),
                            fontSize = 10.sp,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                        )
                    }
                }

                Spacer(Modifier.height(10.dp))

                Text(
                    text = stringResource(R.string.onboarding_stt_local_desc),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    lineHeight = 18.sp,
                )

                Spacer(Modifier.height(8.dp))

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = "${selectedLocalModel.note} · ${selectedLocalModel.sizeMb} MB",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(onClick = onOpenOtherModels) {
                        Text(
                            text = "See other models",
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }

                Spacer(Modifier.height(10.dp))

                if (isModelInstalled) {
                    Surface(
                        shape = RoundedCornerShape(10.dp),
                        color = Color(0xFFDCFCE7),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(
                                Icons.Default.CheckCircle,
                                contentDescription = null,
                                tint = Color(0xFF16A34A),
                                modifier = Modifier.size(20.dp),
                            )
                            Text(
                                text = "${selectedLocalModel.displayName} installed",
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Bold,
                                color = Color(0xFF15803D),
                            )
                        }
                    }
                } else if (isDownloading) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
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
                                        text = "Downloading ${selectedLocalModel.displayName}...",
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
                                    text = "Error: ${downloadState.message}",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.error,
                                )
                            }
                            else -> Unit
                        }
                    }
                } else {
                    Button(
                        onClick = onStartDownload,
                        modifier = Modifier.fillMaxWidth(),
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
                            text = "Download ${selectedLocalModel.displayName} (${selectedLocalModel.sizeMb} MB)",
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }
        }

        // Card 2: Cloud Speech (Alternative)
        val isCloudSelected = selectedChoice == SttEngineChoice.CLOUD
        Card(
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(
                containerColor = if (isCloudSelected) {
                    MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.25f)
                } else {
                    MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
                },
            ),
            border = BorderStroke(
                if (isCloudSelected) 1.5.dp else 1.dp,
                if (isCloudSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant,
            ),
            modifier = Modifier
                .fillMaxWidth()
                .clickable { onSelectChoice(SttEngineChoice.CLOUD) },
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(14.dp),
            ) {
                Icon(
                    imageVector = if (isCloudSelected) Icons.Default.RadioButtonChecked else Icons.Default.RadioButtonUnchecked,
                    contentDescription = null,
                    tint = if (isCloudSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(8.dp))
                Box(
                    modifier = Modifier
                        .size(32.dp)
                        .clip(CircleShape)
                        .background(if (isCloudSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Default.Cloud,
                        contentDescription = null,
                        tint = if (isCloudSelected) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp),
                    )
                }
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        text = stringResource(R.string.onboarding_stt_cloud_title),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = stringResource(R.string.onboarding_stt_cloud_desc),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        lineHeight = 16.sp,
                    )
                }
            }
        }
    }
}

private enum class PolishModeChoice {
    RULES,
    LOCAL_SLM,
    CLOUD,
    OFF,
}

/** Step 2: Post-Processing & AI Polish with visual before/after card */
@Composable
private fun StepTwoPostProcessing(
    selected: PolishModeChoice,
    isSlmInstalled: Boolean,
    isSlmDownloading: Boolean,
    slmDownloadState: DownloadState?,
    defaultSlmModel: SlmModelInfo,
    onStartSlmDownload: () -> Unit,
    onSelect: (PolishModeChoice) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Column {
            Text(
                text = stringResource(R.string.onboarding_cleanup_title),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
            )
            Text(
                text = stringResource(R.string.onboarding_cleanup_subtitle),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        // Transformation Example Box
        Surface(
            shape = RoundedCornerShape(14.dp),
            color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.2f),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.4f)),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = stringResource(R.string.onboarding_cleanup_example_header).uppercase(),
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Black,
                    color = MaterialTheme.colorScheme.primary,
                    letterSpacing = 0.8.sp,
                )

                // Raw spoken
                Column {
                    Text(
                        text = stringResource(R.string.onboarding_cleanup_raw_label),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        text = stringResource(R.string.onboarding_cleanup_raw_text),
                        style = MaterialTheme.typography.bodyMedium,
                        fontStyle = FontStyle.Italic,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                    )
                }

                // Arrow divider
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    HorizontalDivider(
                        modifier = Modifier.weight(1f),
                        color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f),
                    )
                    Icon(
                        Icons.Default.AutoFixHigh,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(16.dp),
                    )
                    HorizontalDivider(
                        modifier = Modifier.weight(1f),
                        color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f),
                    )
                }

                // Polished output
                Column {
                    Text(
                        text = stringResource(R.string.onboarding_cleanup_polished_label),
                        style = MaterialTheme.typography.labelSmall,
                        color = Color(0xFF15803D),
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        text = stringResource(R.string.onboarding_cleanup_polished_text),
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
        }

        // Option 1: Smart Rules Cleanup (Recommended)
        PolishOptionCard(
            title = stringResource(R.string.onboarding_cleanup_option_rules_title),
            subtitle = stringResource(R.string.onboarding_cleanup_option_rules_desc),
            badge = stringResource(R.string.onboarding_cleanup_option_rules_badge),
            selected = selected == PolishModeChoice.RULES,
            onClick = { onSelect(PolishModeChoice.RULES) },
        )

        // Option 2: On-Device SLM (Offline AI)
        PolishOptionCard(
            title = stringResource(R.string.onboarding_cleanup_option_slm_title),
            subtitle = stringResource(R.string.onboarding_cleanup_option_slm_desc),
            badge = stringResource(R.string.onboarding_cleanup_option_slm_badge),
            selected = selected == PolishModeChoice.LOCAL_SLM,
            onClick = { onSelect(PolishModeChoice.LOCAL_SLM) },
            extraContent = if (selected == PolishModeChoice.LOCAL_SLM) {
                {
                    if (isSlmInstalled) {
                        Surface(
                            shape = RoundedCornerShape(10.dp),
                            color = Color(0xFFDCFCE7),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Icon(
                                    Icons.Default.CheckCircle,
                                    contentDescription = null,
                                    tint = Color(0xFF16A34A),
                                    modifier = Modifier.size(18.dp),
                                )
                                Text(
                                    text = "${defaultSlmModel.displayName} installed",
                                    style = MaterialTheme.typography.bodySmall,
                                    fontWeight = FontWeight.Bold,
                                    color = Color(0xFF15803D),
                                )
                            }
                        }
                    } else if (isSlmDownloading) {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .background(MaterialTheme.colorScheme.surface)
                                .padding(10.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            val progress = (slmDownloadState as? DownloadState.Downloading)?.progress ?: 0f
                            val pct = (progress * 100).roundToInt()
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                            ) {
                                Text(
                                    text = "Downloading ${defaultSlmModel.displayName}...",
                                    style = MaterialTheme.typography.labelSmall,
                                    fontWeight = FontWeight.SemiBold,
                                )
                                Text(
                                    text = "$pct%",
                                    style = MaterialTheme.typography.labelSmall,
                                    fontWeight = FontWeight.Bold,
                                    color = MaterialTheme.colorScheme.primary,
                                )
                            }
                            LinearProgressIndicator(
                                progress = { progress },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(6.dp)
                                    .clip(RoundedCornerShape(3.dp)),
                            )
                        }
                    } else {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            if (slmDownloadState is DownloadState.Error) {
                                Text(
                                    text = "Download failed: ${slmDownloadState.message}",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.error,
                                )
                            }
                            Button(
                                onClick = onStartSlmDownload,
                                modifier = Modifier.fillMaxWidth(),
                                shape = RoundedCornerShape(10.dp),
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = MaterialTheme.colorScheme.primary,
                                ),
                            ) {
                                Icon(
                                    Icons.Default.Download,
                                    contentDescription = null,
                                    modifier = Modifier.size(16.dp),
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    text = "Download ${defaultSlmModel.displayName} (${defaultSlmModel.quantizedSizeMb} MB)",
                                    style = MaterialTheme.typography.labelMedium,
                                    fontWeight = FontWeight.Bold,
                                )
                            }
                        }
                    }
                }
            } else null,
        )

        // Option 3: Cloud LLM
        PolishOptionCard(
            title = stringResource(R.string.onboarding_cleanup_option_cloud_title),
            subtitle = stringResource(R.string.onboarding_cleanup_option_cloud_desc),
            badge = null,
            selected = selected == PolishModeChoice.CLOUD,
            onClick = { onSelect(PolishModeChoice.CLOUD) },
        )

        // Option 4: Raw Transcription (Off)
        PolishOptionCard(
            title = stringResource(R.string.onboarding_cleanup_option_off_title),
            subtitle = stringResource(R.string.onboarding_cleanup_option_off_desc),
            badge = null,
            selected = selected == PolishModeChoice.OFF,
            onClick = { onSelect(PolishModeChoice.OFF) },
        )
    }
}

@Composable
private fun PolishOptionCard(
    title: String,
    subtitle: String,
    badge: String?,
    selected: Boolean,
    onClick: () -> Unit,
    extraContent: (@Composable () -> Unit)? = null,
) {
    Card(
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(
            containerColor = if (selected) {
                MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.25f)
            } else {
                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
            },
        ),
        border = BorderStroke(
            if (selected) 1.5.dp else 1.dp,
            if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant,
        ),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
    ) {
        Column(Modifier.padding(14.dp)) {
            Row(
                verticalAlignment = Alignment.Top,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(
                    imageVector = if (selected) Icons.Default.RadioButtonChecked else Icons.Default.RadioButtonUnchecked,
                    contentDescription = null,
                    tint = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier
                        .size(20.dp)
                        .padding(top = 2.dp),
                )
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            text = title,
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.Bold,
                        )
                        if (badge != null) {
                            Surface(
                                shape = RoundedCornerShape(10.dp),
                                color = Color(0xFFDCFCE7),
                            ) {
                                Text(
                                    text = badge.uppercase(),
                                    style = MaterialTheme.typography.labelSmall,
                                    fontWeight = FontWeight.Bold,
                                    color = Color(0xFF15803D),
                                    fontSize = 9.sp,
                                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                                )
                            }
                        }
                    }
                    Spacer(Modifier.height(4.dp))
                    Text(
                        text = subtitle,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        lineHeight = 16.sp,
                    )
                }
            }
            if (extraContent != null) {
                Spacer(Modifier.height(10.dp))
                extraContent()
            }
        }
    }
}

/** Step 3: Required permissions */
@Composable
private fun StepThreePermissions(
    micGranted: Boolean,
    serviceOn: Boolean,
    onRequestMic: () -> Unit,
    onOpenAccessibility: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Column {
            Text(
                text = stringResource(R.string.onboarding_permissions_title),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
            )
            Text(
                text = stringResource(R.string.onboarding_permissions_subtitle),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        // Permission 1: Microphone
        PermissionRowCard(
            title = stringResource(R.string.onboarding_perm_mic_title),
            desc = stringResource(R.string.onboarding_perm_mic_desc),
            granted = micGranted,
            icon = Icons.Default.Mic,
            onAction = onRequestMic,
            actionLabel = stringResource(R.string.onboarding_perm_grant),
        )

        // Permission 2: Accessibility
        PermissionRowCard(
            title = stringResource(R.string.onboarding_perm_acc_title),
            desc = stringResource(R.string.onboarding_perm_acc_desc),
            granted = serviceOn,
            icon = Icons.Default.Security,
            onAction = onOpenAccessibility,
            actionLabel = stringResource(R.string.onboarding_perm_enable),
        )

        // Customization Cues Guide Card
        QuickSettingsGuideCard()
    }
}

@Composable
private fun QuickSettingsGuideCard() {
    Card(
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
        ),
        border = BorderStroke(
            1.dp,
            MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f),
        ),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    imageVector = Icons.Default.Info,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(18.dp),
                )
                Text(
                    text = stringResource(R.string.onboarding_guide_title),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold,
                )
            }

            Text(
                text = stringResource(R.string.onboarding_guide_desc),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                lineHeight = 16.sp,
            )

            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))

            GuideItemRow(
                icon = Icons.Default.Translate,
                title = stringResource(R.string.onboarding_guide_routing_title),
                locationBadge = stringResource(R.string.onboarding_guide_routing_badge),
                description = stringResource(R.string.onboarding_guide_routing_desc),
            )

            GuideItemRow(
                icon = Icons.Default.Spellcheck,
                title = stringResource(R.string.onboarding_guide_translit_title),
                locationBadge = stringResource(R.string.onboarding_guide_translit_badge),
                description = stringResource(R.string.onboarding_guide_translit_desc),
            )

            GuideItemRow(
                icon = Icons.Default.Tune,
                title = stringResource(R.string.onboarding_guide_models_title),
                locationBadge = stringResource(R.string.onboarding_guide_models_badge),
                description = stringResource(R.string.onboarding_guide_models_desc),
            )

            GuideItemRow(
                icon = Icons.Default.Hearing,
                title = stringResource(R.string.onboarding_guide_wake_title),
                locationBadge = stringResource(R.string.onboarding_guide_wake_badge),
                description = stringResource(R.string.onboarding_guide_wake_desc),
            )
        }
    }
}

@Composable
private fun GuideItemRow(
    icon: ImageVector,
    title: String,
    locationBadge: String,
    description: String,
) {
    Row(
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.5f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(16.dp),
            )
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Bold,
                )
                Surface(
                    shape = RoundedCornerShape(6.dp),
                    color = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.6f),
                ) {
                    Text(
                        text = locationBadge,
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSecondaryContainer,
                        fontSize = 9.sp,
                        modifier = Modifier.padding(horizontal = 5.dp, vertical = 1.dp),
                    )
                }
            }
            Text(
                text = description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                lineHeight = 15.sp,
            )
        }
    }
}

@Composable
private fun PermissionRowCard(
    title: String,
    desc: String,
    granted: Boolean,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    onAction: () -> Unit,
    actionLabel: String,
) {
    Card(
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(
            containerColor = if (granted) {
                Color(0xFFF0FDF4)
            } else {
                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
            },
        ),
        border = BorderStroke(
            1.dp,
            if (granted) Color(0xFF86EFAC) else MaterialTheme.colorScheme.outlineVariant,
        ),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(14.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Box(
                    modifier = Modifier
                        .size(34.dp)
                        .clip(CircleShape)
                        .background(if (granted) Color(0xFFDCFCE7) else Color(0xFFE2E8F0)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = if (granted) Icons.Default.CheckCircle else icon,
                        contentDescription = null,
                        tint = if (granted) Color(0xFF16A34A) else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp),
                    )
                }
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        text = title,
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        text = if (granted) stringResource(R.string.onboarding_perm_granted) else "Action required",
                        style = MaterialTheme.typography.labelSmall,
                        color = if (granted) Color(0xFF16A34A) else Color(0xFFB45309),
                        fontWeight = FontWeight.SemiBold,
                    )
                }
                if (!granted) {
                    Button(
                        onClick = onAction,
                        shape = RoundedCornerShape(10.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.primary,
                        ),
                    ) {
                        Text(actionLabel, fontWeight = FontWeight.Bold)
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
            Text(
                text = desc,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                lineHeight = 16.sp,
            )
        }
    }
}

/** Accessibility disclosure dialog required by Google Play policy */
@Composable
private fun AccessibilityDisclosureDialog(
    onAgree: () -> Unit,
    onDismiss: () -> Unit,
) {
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
                onClick = onAgree,
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.primary,
                ),
                shape = RoundedCornerShape(10.dp),
            ) {
                Text("Agree & Open Settings", fontWeight = FontWeight.Bold)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        shape = RoundedCornerShape(20.dp),
        containerColor = MaterialTheme.colorScheme.surface,
    )
}

internal fun Context.openAccessibilitySettings() {
    val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    startActivity(intent)
}
