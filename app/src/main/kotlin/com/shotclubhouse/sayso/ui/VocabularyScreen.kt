package com.shotclubhouse.sayso.ui

import android.content.Context
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Badge
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.shotclubhouse.sayso.AppGraph
import com.shotclubhouse.sayso.R
import com.shotclubhouse.sayso.core.PronunciationCategory
import com.shotclubhouse.sayso.core.PronunciationEntry
import com.shotclubhouse.sayso.polish.Lexicon
import java.io.BufferedReader
import java.io.InputStreamReader

/** Pronunciation Dictionary: Category-tabbed technical vocabulary and spoken phonetic replacements. */
@Composable
fun VocabularyScreen(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val settings = AppGraph.settings
    val entries = remember { mutableStateListOf<PronunciationEntry>().apply { addAll(settings.pronunciations) } }

    var searchQuery by rememberSaveable { mutableStateOf("") }
    var selectedCategory by rememberSaveable { mutableStateOf<String?>(null) } // null = All
    var editingEntry by remember { mutableStateOf<PronunciationEntry?>(null) }
    var isAddingNew by rememberSaveable { mutableStateOf(false) }
    var pendingImportJson by remember { mutableStateOf<String?>(null) }

    fun persist() {
        settings.pronunciations = entries.toList()
    }

    // Export launcher
    val exportLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("application/json"),
    ) { uri: Uri? ->
        if (uri != null) {
            runCatching {
                val json = Lexicon.encodePronunciations(entries)
                context.contentResolver.openOutputStream(uri)?.use { stream ->
                    stream.write(json.toByteArray())
                }
                Toast.makeText(context, context.getString(R.string.pronunciation_exported_toast), Toast.LENGTH_SHORT).show()
            }.onFailure {
                Toast.makeText(context, "Export failed: ${it.message}", Toast.LENGTH_LONG).show()
            }
        }
    }

    // Import launcher
    val importLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument(),
    ) { uri: Uri? ->
        if (uri != null) {
            runCatching {
                val json = context.contentResolver.openInputStream(uri)?.use { stream ->
                    BufferedReader(InputStreamReader(stream)).readText()
                }
                if (!json.isNullOrBlank()) {
                    pendingImportJson = json
                }
            }.onFailure {
                Toast.makeText(context, "Import failed: ${it.message}", Toast.LENGTH_LONG).show()
            }
        }
    }

    val filteredEntries = remember(entries.toList(), searchQuery, selectedCategory) {
        entries.filter { entry ->
            val matchesCategory = selectedCategory == null || entry.category.name == selectedCategory
            val query = searchQuery.trim().lowercase()
            val matchesSearch = query.isEmpty() ||
                entry.word.lowercase().contains(query) ||
                entry.pronunciation.lowercase().contains(query) ||
                (entry.replacement?.lowercase()?.contains(query) == true) ||
                entry.category.displayName.lowercase().contains(query)
            matchesCategory && matchesSearch
        }
    }

    Box(modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            // Search and action toolbar
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    placeholder = { Text(stringResource(R.string.pronunciation_search_hint)) },
                    leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                    trailingIcon = {
                        if (searchQuery.isNotEmpty()) {
                            IconButton(onClick = { searchQuery = "" }) {
                                Icon(Icons.Default.Clear, contentDescription = stringResource(R.string.action_clear))
                            }
                        }
                    },
                    singleLine = true,
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth(),
                )

                Spacer(Modifier.height(8.dp))

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    OutlinedButton(
                        onClick = { importLauncher.launch(arrayOf("application/json", "text/*")) },
                        shape = RoundedCornerShape(8.dp),
                        modifier = Modifier.weight(1f),
                    ) {
                        Text(stringResource(R.string.pronunciation_import))
                    }

                    OutlinedButton(
                        onClick = { exportLauncher.launch("sayso_pronunciations.json") },
                        shape = RoundedCornerShape(8.dp),
                        modifier = Modifier.weight(1f),
                    ) {
                        Text(stringResource(R.string.pronunciation_export))
                    }
                }
            }

            // Category filter chips
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FilterChip(
                    selected = selectedCategory == null,
                    onClick = { selectedCategory = null },
                    label = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("All")
                            Spacer(Modifier.width(4.dp))
                            Badge { Text(entries.size.toString()) }
                        }
                    },
                    colors = FilterChipDefaults.filterChipColors(),
                )

                for (category in PronunciationCategory.entries) {
                    val count = entries.count { it.category == category }
                    FilterChip(
                        selected = selectedCategory == category.name,
                        onClick = { selectedCategory = if (selectedCategory == category.name) null else category.name },
                        label = {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(category.displayName)
                                if (count > 0) {
                                    Spacer(Modifier.width(4.dp))
                                    Badge { Text(count.toString()) }
                                }
                            }
                        },
                    )
                }
            }

            // Dictionary entries list
            LazyColumn(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // Suggested corrections from user edits
                val suggestions = runCatching { AppGraph.corrections.getActiveSuggestions() }.getOrDefault(emptyList())
                if (suggestions.isNotEmpty()) {
                    item {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(bottom = 8.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Text(
                                "Suggested from your edits",
                                style = MaterialTheme.typography.labelLarge,
                                fontWeight = FontWeight.SemiBold,
                                color = MaterialTheme.colorScheme.primary,
                            )
                            for (suggestion in suggestions) {
                                Card(
                                    shape = RoundedCornerShape(10.dp),
                                    colors = CardDefaults.cardColors(
                                        containerColor = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.4f),
                                    ),
                                    modifier = Modifier.fillMaxWidth(),
                                ) {
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .padding(10.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Column(modifier = Modifier.weight(1f)) {
                                            Text(
                                                "${suggestion.original} → ${suggestion.corrected}",
                                                style = MaterialTheme.typography.titleSmall,
                                                fontWeight = FontWeight.Bold,
                                            )
                                            Text(
                                                "Corrected ${suggestion.seenCount}×",
                                                style = MaterialTheme.typography.bodySmall,
                                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            )
                                        }
                                        TextButton(onClick = {
                                            AppGraph.corrections.promoteCandidate(suggestion.id)
                                            entries.clear()
                                            entries.addAll(settings.pronunciations)
                                        }) {
                                            Text("Add")
                                        }
                                        TextButton(onClick = {
                                            AppGraph.corrections.dismissCandidate(suggestion.id)
                                            entries.clear()
                                            entries.addAll(settings.pronunciations)
                                        }) {
                                            Text("Dismiss")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if (filteredEntries.isEmpty()) {
                    item {
                        Text(
                            text = if (searchQuery.isNotBlank()) "No entries match \"$searchQuery\"" else stringResource(R.string.vocabulary_empty),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(vertical = 32.dp),
                        )
                    }
                }

                items(filteredEntries, key = { it.id }) { entry ->
                    PronunciationEntryCard(
                        entry = entry,
                        onEdit = { editingEntry = entry },
                        onDelete = {
                            entries.removeAll { it.id == entry.id }
                            persist()
                        },
                    )
                }

                item { Box(Modifier.padding(40.dp)) }
            }
        }

        FloatingActionButton(
            onClick = { isAddingNew = true },
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(16.dp),
        ) {
            Icon(Icons.Default.Add, contentDescription = stringResource(R.string.vocabulary_add))
        }
    }

    // Add or Edit Dialog
    if (isAddingNew || editingEntry != null) {
        PronunciationEditDialog(
            initial = editingEntry,
            onDismiss = {
                isAddingNew = false
                editingEntry = null
            },
            onSave = { saved ->
                val existingIndex = entries.indexOfFirst { it.id == saved.id }
                if (existingIndex >= 0) {
                    entries[existingIndex] = saved
                } else {
                    entries.add(0, saved)
                }
                persist()
                isAddingNew = false
                editingEntry = null
            },
        )
    }

    // Import merge / replace dialog
    val importJson = pendingImportJson
    if (importJson != null) {
        AlertDialog(
            onDismissRequest = { pendingImportJson = null },
            title = { Text(stringResource(R.string.pronunciation_import_title)) },
            text = { Text(stringResource(R.string.pronunciation_import_message)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        val imported = Lexicon.decodePronunciations(importJson)
                        if (imported.isNotEmpty()) {
                            val existingWords = entries.map { it.word.lowercase() }.toSet()
                            val newItems = imported.filter { it.word.lowercase() !in existingWords }
                            entries.addAll(newItems)
                            persist()
                            Toast.makeText(context, context.getString(R.string.pronunciation_imported_toast, newItems.size), Toast.LENGTH_SHORT).show()
                        }
                        pendingImportJson = null
                    },
                ) {
                    Text(stringResource(R.string.pronunciation_merge))
                }
            },
            dismissButton = {
                TextButton(
                    onClick = {
                        val imported = Lexicon.decodePronunciations(importJson)
                        if (imported.isNotEmpty()) {
                            entries.clear()
                            entries.addAll(imported)
                            persist()
                            Toast.makeText(context, context.getString(R.string.pronunciation_imported_toast, imported.size), Toast.LENGTH_SHORT).show()
                        }
                        pendingImportJson = null
                    },
                ) {
                    Text(stringResource(R.string.pronunciation_replace), color = MaterialTheme.colorScheme.error)
                }
            },
        )
    }
}

@Composable
private fun PronunciationEntryCard(
    entry: PronunciationEntry,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    Card(
        onClick = onEdit,
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
        ),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = entry.word,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                    )
                    Spacer(Modifier.width(8.dp))
                    Surface(
                        shape = RoundedCornerShape(6.dp),
                        color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.7f),
                    ) {
                        Text(
                            text = entry.category.displayName,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onPrimaryContainer,
                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                    }
                    if (entry.isRegex) {
                        Spacer(Modifier.width(4.dp))
                        Surface(
                            shape = RoundedCornerShape(6.dp),
                            color = MaterialTheme.colorScheme.tertiaryContainer.copy(alpha = 0.7f),
                        ) {
                            Text(
                                text = "REGEX",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onTertiaryContainer,
                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                            )
                        }
                    }
                }

                Spacer(Modifier.height(4.dp))

                Text(
                    text = "Spoken: ${entry.pronunciation}",
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )

                if (!entry.replacement.isNullOrBlank() && entry.replacement != entry.pronunciation) {
                    Text(
                        text = "Alt: ${entry.replacement}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.outline,
                    )
                }
            }

            IconButton(onClick = onEdit) {
                Icon(
                    Icons.Default.Edit,
                    contentDescription = stringResource(R.string.vocabulary_edit),
                    tint = MaterialTheme.colorScheme.primary,
                )
            }

            IconButton(onClick = onDelete) {
                Icon(
                    Icons.Default.Delete,
                    contentDescription = stringResource(R.string.action_delete),
                    tint = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PronunciationEditDialog(
    initial: PronunciationEntry?,
    onDismiss: () -> Unit,
    onSave: (PronunciationEntry) -> Unit,
) {
    var word by rememberSaveable { mutableStateOf(initial?.word.orEmpty()) }
    var pronunciation by rememberSaveable { mutableStateOf(initial?.pronunciation.orEmpty()) }
    var replacement by rememberSaveable { mutableStateOf(initial?.replacement.orEmpty()) }
    var category by rememberSaveable { mutableStateOf(initial?.category ?: PronunciationCategory.TECHNICAL) }
    var isRegex by rememberSaveable { mutableStateOf(initial?.isRegex ?: false) }
    var caseSensitive by rememberSaveable { mutableStateOf(initial?.caseSensitive ?: false) }
    var categoryExpanded by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(stringResource(if (initial == null) R.string.vocabulary_add else R.string.vocabulary_edit))
        },
        text = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 4.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    value = word,
                    onValueChange = { word = it },
                    label = { Text(stringResource(R.string.pronunciation_word_label)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )

                OutlinedTextField(
                    value = pronunciation,
                    onValueChange = { pronunciation = it },
                    label = { Text(stringResource(R.string.pronunciation_pronun_label)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )

                OutlinedTextField(
                    value = replacement,
                    onValueChange = { replacement = it },
                    label = { Text(stringResource(R.string.pronunciation_repl_label)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )

                // Category selector
                ExposedDropdownMenuBox(
                    expanded = categoryExpanded,
                    onExpandedChange = { categoryExpanded = !categoryExpanded },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    OutlinedTextField(
                        value = category.displayName,
                        onValueChange = {},
                        readOnly = true,
                        label = { Text(stringResource(R.string.pronunciation_category_label)) },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = categoryExpanded) },
                        modifier = Modifier
                            .menuAnchor()
                            .fillMaxWidth(),
                    )
                    ExposedDropdownMenu(
                        expanded = categoryExpanded,
                        onDismissRequest = { categoryExpanded = false },
                    ) {
                        for (cat in PronunciationCategory.entries) {
                            DropdownMenuItem(
                                text = { Text(cat.displayName) },
                                onClick = {
                                    category = cat
                                    categoryExpanded = false
                                },
                            )
                        }
                    }
                }

                // Toggles
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(stringResource(R.string.pronunciation_regex_toggle), style = MaterialTheme.typography.bodyMedium)
                    Switch(checked = isRegex, onCheckedChange = { isRegex = it })
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(stringResource(R.string.pronunciation_case_toggle), style = MaterialTheme.typography.bodyMedium)
                    Switch(checked = caseSensitive, onCheckedChange = { caseSensitive = it })
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = word.isNotBlank() && pronunciation.isNotBlank(),
                onClick = {
                    val entry = PronunciationEntry(
                        id = initial?.id ?: java.util.UUID.randomUUID().toString(),
                        word = word.trim(),
                        pronunciation = pronunciation.trim(),
                        replacement = replacement.trim().ifBlank { null },
                        category = category,
                        isRegex = isRegex,
                        caseSensitive = caseSensitive,
                    )
                    onSave(entry)
                },
            ) {
                Text(stringResource(R.string.action_save))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.action_cancel))
            }
        },
    )
}
