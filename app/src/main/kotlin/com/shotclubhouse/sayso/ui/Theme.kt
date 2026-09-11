package com.shotclubhouse.sayso.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

private val Navy = Color(0xFF1E2A44)
private val Amber = Color(0xFFF4B942)

private val LightScheme = lightColorScheme(
    primary = Navy,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFDCE2F2),
    onPrimaryContainer = Color(0xFF101828),
    secondary = Amber,
    onSecondary = Color(0xFF3A2B00),
    secondaryContainer = Color(0xFFFDECC6),
    onSecondaryContainer = Color(0xFF3A2B00),
    tertiary = Color(0xFF4C6070),
    background = Color(0xFFFAFAFC),
    surface = Color(0xFFFAFAFC),
    surfaceVariant = Color(0xFFE3E5ED),
)

private val DarkScheme = darkColorScheme(
    primary = Color(0xFFB4C4E8),
    onPrimary = Color(0xFF1E2A44),
    primaryContainer = Color(0xFF2C3A58),
    onPrimaryContainer = Color(0xFFDCE2F2),
    secondary = Amber,
    onSecondary = Color(0xFF3A2B00),
    secondaryContainer = Color(0xFF554114),
    onSecondaryContainer = Color(0xFFFDECC6),
    tertiary = Color(0xFFB3C9DA),
    background = Color(0xFF12151C),
    surface = Color(0xFF12151C),
    surfaceVariant = Color(0xFF3F434D),
)

/**
 * Material 3 wrapper for every Sayso screen. Android 12 and newer follow the
 * wallpaper palette; older releases fall back to the navy and amber of the icon.
 */
@Composable
fun SaysoTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val colorScheme = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)

        darkTheme -> DarkScheme
        else -> LightScheme
    }
    MaterialTheme(colorScheme = colorScheme, content = content)
}
