package com.shotclubhouse.sayso.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.shotclubhouse.sayso.AppGraph
import com.shotclubhouse.sayso.R
import com.shotclubhouse.sayso.core.LexiconRule

/** Index of the rule being edited, or [NEW_RULE] when the dialog is adding one. */
private const val NEW_RULE = -1

/** Personal vocabulary: what the recogniser hears, and how it should be spelled. */
@Composable
fun VocabularyScreen(modifier: Modifier = Modifier) {
    val settings = AppGraph.settings
    val rules = remember { mutableStateListOf<LexiconRule>().apply { addAll(settings.lexicon) } }
    var editing by remember { mutableStateOf<Int?>(null) }

    fun persist() {
        settings.lexicon = rules.toList()
    }

    Box(modifier.fillMaxSize()) {
        LazyColumn(Modifier.fillMaxSize()) {
            item {
                Text(
                    stringResource(R.string.vocabulary_intro),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(16.dp),
                )
                if (rules.isEmpty()) {
                    Text(
                        stringResource(R.string.vocabulary_empty),
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.padding(horizontal = 16.dp),
                    )
                }
            }
            itemsIndexed(rules) { index, rule ->
                Column {
                    SettingRow(
                        title = rule.canonical,
                        subtitle = stringResource(
                            R.string.vocabulary_aliases_summary,
                            rule.aliases.joinToString(", "),
                        ),
                        onClick = { editing = index },
                        trailing = {
                            IconButton(
                                onClick = {
                                    rules.removeAt(index)
                                    persist()
                                },
                            ) {
                                Icon(
                                    Icons.Default.Delete,
                                    contentDescription = stringResource(R.string.action_delete),
                                )
                            }
                        },
                    )
                    HorizontalDivider()
                }
            }
            item { Box(Modifier.padding(48.dp)) }
        }

        FloatingActionButton(
            onClick = { editing = NEW_RULE },
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(16.dp),
        ) {
            Icon(Icons.Default.Add, contentDescription = stringResource(R.string.vocabulary_add))
        }
    }

    val index = editing
    if (index != null) {
        RuleDialog(
            rule = rules.getOrNull(index),
            onDismiss = { editing = null },
            onSave = { rule ->
                if (index == NEW_RULE || index !in rules.indices) rules.add(rule) else rules[index] = rule
                persist()
                editing = null
            },
        )
    }
}

@Composable
private fun RuleDialog(
    rule: LexiconRule?,
    onDismiss: () -> Unit,
    onSave: (LexiconRule) -> Unit,
) {
    var canonical by remember { mutableStateOf(rule?.canonical.orEmpty()) }
    var aliases by remember { mutableStateOf(rule?.aliases?.joinToString(", ").orEmpty()) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(stringResource(if (rule == null) R.string.vocabulary_add else R.string.vocabulary_edit))
        },
        text = {
            Column {
                OutlinedTextField(
                    value = canonical,
                    onValueChange = { canonical = it },
                    label = { Text(stringResource(R.string.vocabulary_canonical)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = aliases,
                    onValueChange = { aliases = it },
                    label = { Text(stringResource(R.string.vocabulary_aliases)) },
                    supportingText = { Text(stringResource(R.string.vocabulary_aliases_help)) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 8.dp),
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = canonical.isNotBlank() && aliases.toCsvList().isNotEmpty(),
                onClick = { onSave(LexiconRule(canonical.trim(), aliases.toCsvList())) },
            ) { Text(stringResource(R.string.action_save)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) }
        },
    )
}
