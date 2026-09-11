package com.shotclubhouse.sayso.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Badge
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.shotclubhouse.sayso.AppGraph
import com.shotclubhouse.sayso.R
import com.shotclubhouse.sayso.models.DownloadState
import com.shotclubhouse.sayso.models.LocalModel
import com.shotclubhouse.sayso.models.LocalModelCatalog
import com.shotclubhouse.sayso.models.LocalModelDownloader
import com.shotclubhouse.sayso.service.DictationService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.io.File
import kotlin.math.roundToInt

/**
 * Owns the one download that may be in flight. Held above the screens so that
 * leaving Local models mid-download does not cancel it, and so a second tap
 * cannot start a parallel 500 MB transfer.
 */
class ModelDownloads(private val scope: CoroutineScope) {
    private val downloader = LocalModelDownloader()

    var activeDirName by mutableStateOf<String?>(null)
        private set
    var state by mutableStateOf<DownloadState?>(null)
        private set

    val busy: Boolean
        get() = state is DownloadState.Downloading || state is DownloadState.Extracting

    fun start(model: LocalModel, modelsDir: File, cacheDir: File, onFinished: () -> Unit) {
        if (busy) return
        activeDirName = model.dirName
        state = DownloadState.Downloading(0f)
        scope.launch {
            downloader.download(model, modelsDir, cacheDir).collect { state = it }
            onFinished()
        }
    }

    fun isInstalled(model: LocalModel, modelsDir: File): Boolean =
        downloader.isInstalled(model, modelsDir)

    fun delete(model: LocalModel, modelsDir: File) {
        downloader.delete(model, modelsDir)
        if (activeDirName == model.dirName) {
            activeDirName = null
            state = null
        }
    }
}

/** The catalog of on-device models: download, pick, or remove. */
@Composable
fun LocalModelsScreen(downloads: ModelDownloads, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val settings = AppGraph.settings
    val modelsDir = AppGraph.localModelsDir
    var refreshToken by remember { mutableIntStateOf(0) }
    var selectedModel by remember { mutableStateOf(settings.sttModelId) }
    var pendingDelete by remember { mutableStateOf<LocalModel?>(null) }

    LazyColumn(modifier.fillMaxSize()) {
        item {
            Text(
                stringResource(R.string.local_models_intro),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(16.dp),
            )
        }
        items(LocalModelCatalog.all, key = { it.dirName }) { model ->
            val installed = remember(model.dirName, refreshToken) {
                downloads.isInstalled(model, modelsDir)
            }
            val modelId = "local/${model.dirName}"
            val active = downloads.activeDirName == model.dirName

            Column {
                if (installed) {
                    RadioRow(
                        title = model.displayName,
                        subtitle = model.note,
                        selected = selectedModel == modelId,
                        onSelect = {
                            selectedModel = modelId
                            settings.sttModelId = modelId
                            DictationService.instance?.reloadLocalModel()
                        },
                        trailing = {
                            IconButton(onClick = { pendingDelete = model }) {
                                Icon(
                                    Icons.Default.Delete,
                                    contentDescription = stringResource(R.string.action_delete),
                                )
                            }
                        },
                    )
                } else {
                    SettingRow(
                        title = model.displayName,
                        subtitle = "${stringResource(R.string.local_models_size, model.sizeMb)} · ${model.note}",
                        trailing = {
                            Button(
                                enabled = !downloads.busy,
                                onClick = {
                                    downloads.start(model, modelsDir, context.cacheDir) {
                                        refreshToken++
                                        DictationService.instance?.reloadLocalModel()
                                    }
                                },
                            ) { Text(stringResource(R.string.local_models_download)) }
                        },
                    )
                }

                if (model.recommended) {
                    Badge(
                        containerColor = MaterialTheme.colorScheme.secondaryContainer,
                        contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
                        modifier = Modifier.padding(start = 16.dp, bottom = 8.dp),
                    ) { Text(stringResource(R.string.local_models_recommended)) }
                }

                if (active) {
                    DownloadProgress(downloads.state)
                }
                HorizontalDivider()
            }
        }
    }

    val doomed = pendingDelete
    if (doomed != null) {
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(stringResource(R.string.local_models_delete_title, doomed.displayName)) },
            text = { Text(stringResource(R.string.local_models_delete_body)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        downloads.delete(doomed, modelsDir)
                        pendingDelete = null
                        refreshToken++
                        DictationService.instance?.reloadLocalModel()
                    },
                ) { Text(stringResource(R.string.action_delete)) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) {
                    Text(stringResource(R.string.action_cancel))
                }
            },
        )
    }
}

@Composable
private fun DownloadProgress(state: DownloadState?) {
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        when (state) {
            is DownloadState.Downloading -> {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    LinearProgressIndicator(
                        progress = { state.progress },
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        stringResource(
                            R.string.local_models_downloading,
                            (state.progress * 100).roundToInt(),
                        ),
                        style = MaterialTheme.typography.labelMedium,
                    )
                }
            }

            DownloadState.Extracting -> {
                LinearProgressIndicator(Modifier.fillMaxWidth())
                Text(
                    stringResource(R.string.local_models_extracting),
                    style = MaterialTheme.typography.labelMedium,
                )
            }

            is DownloadState.Error -> Text(
                state.message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error,
            )

            DownloadState.Done, null -> Unit
        }
    }
}
