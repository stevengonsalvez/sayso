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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.shotclubhouse.sayso.AppGraph
import com.shotclubhouse.sayso.R
import com.shotclubhouse.sayso.models.DownloadState
import com.shotclubhouse.sayso.models.LocalModelCatalog
import com.shotclubhouse.sayso.service.DictationService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

/** The catalog of on-device models: download, pick, or remove. */
@Composable
fun LocalModelsScreen(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val settings = AppGraph.settings
    val downloads = AppGraph.downloads
    val modelsDir = AppGraph.localModelsDir
    var refreshToken by remember { mutableIntStateOf(0) }
    var selectedModel by remember { mutableStateOf(settings.sttModelId) }
    // The directory name rather than the model, so the confirmation survives a rotation.
    var pendingDeleteDirName by rememberSaveable { mutableStateOf<String?>(null) }
    var installedDirNames by remember { mutableStateOf(emptySet<String>()) }

    // Whether a model is on disk is a directory listing, which composition must not do.
    LaunchedEffect(refreshToken) {
        installedDirNames = withContext(Dispatchers.IO) {
            LocalModelCatalog.all.filter { downloads.isInstalled(it, modelsDir) }.map { it.dirName }.toSet()
        }
    }

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
            val installed = model.dirName in installedDirNames
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
                            IconButton(onClick = { pendingDeleteDirName = model.dirName }) {
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

    val doomed = pendingDeleteDirName?.let(LocalModelCatalog::byDirName)
    if (doomed != null) {
        AlertDialog(
            onDismissRequest = { pendingDeleteDirName = null },
            title = { Text(stringResource(R.string.local_models_delete_title, doomed.displayName)) },
            text = { Text(stringResource(R.string.local_models_delete_body)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingDeleteDirName = null
                        // Deliberately not this screen's scope: navigating away mid-delete
                        // would otherwise skip the setting reset and the service reload.
                        downloads.deleteAndReset(doomed, modelsDir, settings) {
                            selectedModel = settings.sttModelId
                            refreshToken++
                            DictationService.instance?.reloadLocalModel()
                        }
                    },
                ) { Text(stringResource(R.string.action_delete)) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDeleteDirName = null }) {
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
