package com.shotclubhouse.sayso.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.text.format.DateUtils
import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.shotclubhouse.sayso.AppGraph
import com.shotclubhouse.sayso.R
import com.shotclubhouse.sayso.core.HistoryEntry
import com.shotclubhouse.sayso.core.OutputMethod
import kotlinx.coroutines.launch

/** Everything dictated so far, newest first, with copy, reprocess, and delete. */
@Composable
fun HistoryScreen(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var entries by remember { mutableStateOf(emptyList<HistoryEntry>()) }
    var searchQuery by remember { mutableStateOf("") }
    var expandedId by remember { mutableStateOf<String?>(null) }
    var confirmClear by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }

    val filteredEntries = remember(entries, searchQuery) {
        if (searchQuery.isBlank()) {
            entries
        } else {
            val query = searchQuery.trim()
            entries.filter { entry ->
                entry.finalText.contains(query, ignoreCase = true) ||
                    entry.rawText.contains(query, ignoreCase = true) ||
                    entry.sttModelId.contains(query, ignoreCase = true)
            }
        }
    }

    suspend fun reload() {
        entries = AppGraph.history.all()
    }

    LaunchedEffect(Unit) { reload() }

    LazyColumn(modifier.fillMaxSize()) {
        item {
            if (entries.isNotEmpty() || searchQuery.isNotBlank()) {
                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    placeholder = { Text(stringResource(R.string.history_search_placeholder)) },
                    leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                    trailingIcon = {
                        if (searchQuery.isNotEmpty()) {
                            IconButton(onClick = { searchQuery = "" }) {
                                Icon(Icons.Default.Clear, contentDescription = stringResource(R.string.action_clear))
                            }
                        }
                    },
                    singleLine = true,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp),
            ) {
                if (working) {
                    Text(
                        stringResource(R.string.history_working),
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.padding(start = 8.dp),
                    )
                }
                Spacer(Modifier.weight(1f))
                TextButton(
                    onClick = { confirmClear = true },
                    enabled = entries.isNotEmpty(),
                ) { Text(stringResource(R.string.history_clear_all)) }
            }
            if (entries.isEmpty()) {
                Text(
                    stringResource(R.string.history_empty),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(16.dp),
                )
            } else if (filteredEntries.isEmpty()) {
                Text(
                    stringResource(R.string.history_search_empty, searchQuery.trim()),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(16.dp),
                )
            }
        }

        items(filteredEntries, key = { it.id }) { entry ->
            HistoryRow(
                entry = entry,
                expanded = expandedId == entry.id,
                onToggle = { expandedId = if (expandedId == entry.id) null else entry.id },
                onCopy = { context.copyToClipboard(entry.finalText) },
                onDelete = {
                    scope.launch {
                        AppGraph.history.delete(entry.id)
                        reload()
                    }
                },
                onReprocess = {
                    scope.launch {
                        working = true
                        AppGraph.pipeline.reprocess(entry)
                        reload()
                        working = false
                    }
                },
            )
            HorizontalDivider()
        }
    }

    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text(stringResource(R.string.history_clear_title)) },
            text = { Text(stringResource(R.string.history_clear_body)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmClear = false
                        scope.launch {
                            AppGraph.history.clear()
                            reload()
                        }
                    },
                ) { Text(stringResource(R.string.history_clear_all)) }
            },
            dismissButton = {
                TextButton(onClick = { confirmClear = false }) {
                    Text(stringResource(R.string.action_cancel))
                }
            },
        )
    }
}

@Composable
private fun HistoryRow(
    entry: HistoryEntry,
    expanded: Boolean,
    onToggle: () -> Unit,
    onCopy: () -> Unit,
    onDelete: () -> Unit,
    onReprocess: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onToggle)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Text(
            text = entry.finalText.ifBlank { entry.rawText },
            style = MaterialTheme.typography.bodyLarge,
            maxLines = if (expanded) Int.MAX_VALUE else 2,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = entry.metaLine(),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 4.dp),
        )
        val error = entry.error
        if (error != null) {
            Text(
                text = error,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
            )
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(top = 4.dp),
        ) {
            AssistChip(
                onClick = onToggle,
                label = { Text(stringResource(entry.outputMethod.labelRes())) },
            )
        }

        if (expanded) {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = onCopy) { Text(stringResource(R.string.action_copy)) }
                TextButton(
                    onClick = onReprocess,
                    enabled = entry.audioPath != null,
                ) { Text(stringResource(R.string.history_reprocess)) }
                TextButton(onClick = onDelete) { Text(stringResource(R.string.action_delete)) }
            }
            if (entry.audioPath == null) {
                Text(
                    stringResource(R.string.history_no_audio),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/** "2 hours ago · 0:14 · whisper-1" */
private fun HistoryEntry.metaLine(): String {
    val when_ = DateUtils.getRelativeTimeSpanString(
        createdAt,
        System.currentTimeMillis(),
        DateUtils.MINUTE_IN_MILLIS,
    )
    val duration = DateUtils.formatElapsedTime(durationMs / 1000)
    return "$when_ · $duration · ${sttModelId.substringAfter('/')}"
}

private fun OutputMethod.labelRes(): Int = when (this) {
    OutputMethod.INSERTED -> R.string.output_inserted
    OutputMethod.CLIPBOARD -> R.string.output_clipboard
    OutputMethod.NONE -> R.string.output_none
}

private fun Context.copyToClipboard(text: String) {
    val clipboard = getSystemService(ClipboardManager::class.java) ?: return
    clipboard.setPrimaryClip(ClipData.newPlainText(getString(R.string.app_name), text))
    // Android 13 and newer show their own copy confirmation, so this would be a duplicate.
    if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.TIRAMISU) {
        Toast.makeText(this, R.string.history_copied, Toast.LENGTH_SHORT).show()
    }
}
