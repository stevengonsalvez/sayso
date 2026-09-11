package com.shotclubhouse.sayso.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.shotclubhouse.sayso.R

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
    var screen by rememberSaveable { mutableStateOf(Screen.Home) }
    // Scoped to the whole app rather than to Local models, so navigating away
    // does not cancel a download that is half way through 500 MB.
    val appScope = rememberCoroutineScope()
    val downloads = remember(appScope) { ModelDownloads(appScope) }

    BackHandler(enabled = screen != Screen.Home) { screen = Screen.Home }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(screen.titleRes)) },
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
            )
        },
    ) { innerPadding ->
        Box(Modifier.fillMaxSize().padding(innerPadding)) {
            when (screen) {
                Screen.Home -> HomeScreen(onNavigate = { screen = it })
                Screen.Transcription -> TranscriptionScreen(onOpenLocalModels = { screen = Screen.LocalModels })
                Screen.LocalModels -> LocalModelsScreen(downloads)
                Screen.Cleanup -> CleanupScreen()
                Screen.Vocabulary -> VocabularyScreen()
                Screen.History -> HistoryScreen()
                Screen.Insights -> InsightsScreen()
                Screen.About -> AboutScreen()
            }
        }
    }
}
