package com.shotclubhouse.sayso.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.shotclubhouse.sayso.AppGraph
import com.shotclubhouse.sayso.R
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Small capitalised label that introduces a block of rows. */
@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
        modifier = modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 6.dp),
    )
}

/**
 * One line of settings: a title, an optional explanation underneath, and an
 * optional control on the right. The whole row is the touch target when
 * [onClick] is given.
 */
@Composable
fun SettingRow(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
    onClick: (() -> Unit)? = null,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        leading?.invoke()
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            if (subtitle != null) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        trailing?.invoke()
    }
}

/** A [SettingRow] whose control is a switch, toggled by tapping anywhere on the row. */
@Composable
fun SwitchRow(
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
) {
    SettingRow(
        title = title,
        subtitle = subtitle,
        modifier = modifier,
        onClick = { onCheckedChange(!checked) },
        trailing = { Switch(checked = checked, onCheckedChange = onCheckedChange) },
    )
}

/** A [SettingRow] that behaves as one option of a single-choice list. */
@Composable
fun RadioRow(
    title: String,
    selected: Boolean,
    onSelect: () -> Unit,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    SettingRow(
        title = title,
        subtitle = subtitle,
        modifier = modifier,
        onClick = onSelect,
        leading = { RadioButton(selected = selected, onClick = onSelect) },
        trailing = trailing,
    )
}

/** Heading for the models and key belonging to one backend. */
@Composable
fun ProviderGroup(
    name: String,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Column(modifier.fillMaxWidth()) {
        SectionHeader(name)
        content()
    }
}

/**
 * Masked entry for one provider's API key. The current value is read from the
 * keystore-backed store once; typing only reaches storage when Save is tapped,
 * so a half-typed key never replaces a working one.
 */
@Composable
fun ApiKeyRow(
    providerId: String,
    providerName: String,
    apiKeyUrl: String?,
    modifier: Modifier = Modifier,
    onKeyChanged: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val secrets = AppGraph.secrets
    var value by remember(providerId) { mutableStateOf("") }
    var saved by remember(providerId) { mutableStateOf(false) }
    var saveFailed by remember(providerId) { mutableStateOf(false) }
    var visible by remember(providerId) { mutableStateOf(false) }

    // Unlocking the keystore costs tens of milliseconds on first use, and a
    // provider list builds several of these rows at once.
    LaunchedEffect(providerId) {
        val existing = withContext(Dispatchers.IO) { secrets.get(providerId) }
        if (!existing.isNullOrBlank() && value.isEmpty()) {
            value = existing
            saved = true
        }
    }

    Column(modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        OutlinedTextField(
            value = value,
            onValueChange = {
                value = it
                saveFailed = false
            },
            label = { Text(stringResource(R.string.api_key_label, providerName)) },
            singleLine = true,
            visualTransformation =
                if (visible) VisualTransformation.None else PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
            supportingText = {
                Text(
                    stringResource(
                        when {
                            saveFailed -> R.string.api_key_save_failed
                            saved -> R.string.api_key_saved
                            else -> R.string.api_key_none
                        },
                    ),
                )
            },
            trailingIcon = {
                IconButton(onClick = { visible = !visible }) {
                    Icon(
                        imageVector = if (visible) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                        contentDescription = stringResource(
                            if (visible) R.string.api_key_hide else R.string.api_key_show,
                        ),
                    )
                }
            },
            modifier = Modifier.fillMaxWidth(),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            TextButton(
                onClick = {
                    val key = value.trim()
                    scope.launch {
                        // A wiped or locked Keystore makes the store drop the value silently,
                        // so the row reports what was actually stored, not what was typed.
                        val stored = withContext(Dispatchers.IO) {
                            secrets.set(providerId, key)
                            secrets.get(providerId) == key
                        }
                        saved = stored
                        saveFailed = !stored
                        if (stored) onKeyChanged?.invoke()
                    }
                },
                enabled = value.isNotBlank(),
            ) { Text(stringResource(R.string.action_save)) }
            TextButton(
                onClick = {
                    scope.launch {
                        withContext(Dispatchers.IO) { secrets.remove(providerId) }
                        onKeyChanged?.invoke()
                    }
                    value = ""
                    saved = false
                    saveFailed = false
                },
                enabled = saved || value.isNotBlank(),
            ) { Text(stringResource(R.string.action_clear)) }
            if (apiKeyUrl != null) {
                TextButton(onClick = { context.openUrl(apiKeyUrl) }) {
                    Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = null)
                    Text(
                        stringResource(R.string.api_key_get),
                        modifier = Modifier.padding(start = 6.dp),
                    )
                }
            }
        }
    }
}

/** Opens a link in the browser, ignoring the case where no browser is installed. */
fun Context.openUrl(url: String) {
    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    try {
        startActivity(intent)
    } catch (_: ActivityNotFoundException) {
        // ponytail: a device with no browser gets nothing rather than a crash.
    }
}

/** Splits a comma separated field into trimmed, non-empty items. */
fun String.toCsvList(): List<String> =
    split(',').map { it.trim() }.filter { it.isNotEmpty() }
