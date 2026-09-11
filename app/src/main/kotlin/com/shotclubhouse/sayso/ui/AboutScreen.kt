package com.shotclubhouse.sayso.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Policy
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.shotclubhouse.sayso.R

private const val PRIVACY_URL = "https://github.com/stevengonsalvez/sayso/blob/main/PRIVACY.md"
private const val SOURCE_URL = "https://github.com/stevengonsalvez/sayso"

/** What this app is, which build it is, and where to read the rest. */
@Composable
fun AboutScreen(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val version = remember {
        runCatching {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        }.getOrNull().orEmpty()
    }

    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState()),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(stringResource(R.string.app_name), style = MaterialTheme.typography.headlineSmall)
            Text(
                stringResource(R.string.about_version, version),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                stringResource(R.string.about_body),
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 16.dp),
            )
        }
        HorizontalDivider()
        SettingRow(
            title = stringResource(R.string.about_privacy),
            leading = { Icon(Icons.Default.Policy, contentDescription = null) },
            onClick = { context.openUrl(PRIVACY_URL) },
        )
        SettingRow(
            title = stringResource(R.string.about_source),
            leading = { Icon(Icons.Default.Code, contentDescription = null) },
            onClick = { context.openUrl(SOURCE_URL) },
        )
    }
}
