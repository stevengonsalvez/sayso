package ai.sayso.dictation.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.annotation.StringRes
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.foundation.clickable
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import ai.sayso.dictation.AppGraph
import ai.sayso.dictation.R
import ai.sayso.dictation.service.DictationService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Every destination in the settings app. Home is the hub; everything else is one level deep. */
enum class Screen(@StringRes val titleRes: Int) {
    Home(R.string.screen_home),
    Transcription(R.string.screen_transcription),
    LocalModels(R.string.screen_local_models),
    Cleanup(R.string.screen_cleanup),
    Vocabulary(R.string.screen_vocabulary),
    History(R.string.screen_history),
    Insights(R.string.screen_insights),
    About(R.string.screen_about),
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            SaysoTheme { SaysoApp() }
        }
    }
}

/**
 * The whole settings app. Navigation is a single enum and a back handler rather
 * than a graph, because every screen is reached from Home and returns to it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SaysoApp() {
    val context = LocalContext.current
    val settings = AppGraph.settings
    val downloads = AppGraph.downloads
    val modelsDir = AppGraph.localModelsDir

    var screen by rememberSaveable { mutableStateOf(Screen.Home) }
    var showOnboarding by rememberSaveable { mutableStateOf(!settings.hasCompletedOnboarding) }
    var micGranted by remember { mutableStateOf(context.hasMicPermission()) }
    var serviceOn by remember { mutableStateOf(DictationService.isEnabled(context)) }
    var isSttReady by remember { mutableStateOf(false) }

    LifecycleResumeEffect(Unit) {
        micGranted = context.hasMicPermission()
        serviceOn = DictationService.isEnabled(context)
        onPauseOrDispose { }
    }

    LaunchedEffect(downloads.state, settings.sttModelId) {
        isSttReady = withContext(Dispatchers.IO) {
            checkSttReady(settings, modelsDir)
        }
    }

    val isReady = micGranted && serviceOn && isSttReady

    BackHandler(enabled = screen != Screen.Home) { screen = Screen.Home }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    if (screen == Screen.Home) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(34.dp)
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
                            Column {
                                Text(
                                    text = "Sayso",
                                    style = MaterialTheme.typography.titleLarge,
                                    fontWeight = FontWeight.Black,
                                    letterSpacing = (-0.5).sp,
                                )
                                Text(
                                    text = "ON-DEVICE VOICE ENGINE",
                                    style = MaterialTheme.typography.labelSmall,
                                    fontWeight = FontWeight.Bold,
                                    color = MaterialTheme.colorScheme.primary,
                                    letterSpacing = 0.8.sp,
                                )
                            }
                        }
                    } else {
                        Text(
                            text = stringResource(screen.titleRes),
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                },
                actions = {
                    if (screen == Screen.Home) {
                        Surface(
                            shape = RoundedCornerShape(20.dp),
                            color = if (isReady) Color(0xFFDCFCE7) else Color(0xFFFEF3C7),
                            border = BorderStroke(1.dp, if (isReady) Color(0xFF86EFAC) else Color(0xFFFCD34D)),
                            modifier = Modifier
                                .padding(end = 12.dp)
                                .clickable { if (!isReady) showOnboarding = true },
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(7.dp)
                                        .clip(CircleShape)
                                        .background(if (isReady) Color(0xFF16A34A) else Color(0xFFD97706)),
                                )
                                Text(
                                    text = if (isReady) "READY" else "SETUP",
                                    style = MaterialTheme.typography.labelSmall,
                                    fontWeight = FontWeight.Bold,
                                    color = if (isReady) Color(0xFF15803D) else Color(0xFFB45309),
                                    letterSpacing = 0.5.sp,
                                )
                            }
                        }
                    }
                },
                navigationIcon = {
                    if (screen != Screen.Home) {
                        IconButton(onClick = { screen = Screen.Home }) {
                            Icon(
                                Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = stringResource(R.string.action_back),
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                ),
            )
        },
    ) { innerPadding ->
        Box(Modifier.fillMaxSize().padding(innerPadding)) {
            when (screen) {
                Screen.Home -> HomeScreen(onNavigate = { screen = it })
                Screen.Transcription -> TranscriptionScreen(onOpenLocalModels = { screen = Screen.LocalModels })
                Screen.LocalModels -> LocalModelsScreen()
                Screen.Cleanup -> CleanupScreen()
                Screen.Vocabulary -> VocabularyScreen()
                Screen.History -> HistoryScreen()
                Screen.Insights -> InsightsScreen()
                Screen.About -> AboutScreen()
            }
        }
    }

    if (showOnboarding) {
        OnboardingDialog(
            onDismiss = { showOnboarding = false },
            onNavigateToScreen = { screen = it },
        )
    }
}
