package ai.sayso.dictation.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// Sayso Brand anchors from logo: Deep Navy (#1E2A44) & Golden Amber (#F4B942)
val SaysoBrandNavy = Color(0xFF1E2A44)
val SaysoBrandAmber = Color(0xFFF4B942)

private val BrandNavy = SaysoBrandNavy
private val BrandNavyDark = Color(0xFF0C1322)
private val BrandNavySurface = Color(0xFF151F33)
private val BrandNavyElevated = Color(0xFF1E2A44)
private val BrandNavyContainer = Color(0xFF263654)
private val BrandNavyLight = Color(0xFFE8EDF5)

private val BrandAmber = SaysoBrandAmber
private val BrandAmberDark = Color(0xFFD99B26)
private val BrandAmberContainerLight = Color(0xFFFEF3C7)
private val BrandAmberContainerDark = Color(0xFF453006)
private val OnAmberContainerLight = Color(0xFF92400E)
private val OnAmberContainerDark = Color(0xFFFDE68A)

private val CrimsonLight = Color(0xFFEF4444)
private val CrimsonDark = Color(0xFFF87171)

private val LightScheme = lightColorScheme(
    primary = BrandNavy,
    onPrimary = Color.White,
    primaryContainer = BrandNavyLight,
    onPrimaryContainer = BrandNavy,
    secondary = BrandAmberDark,
    onSecondary = Color.White,
    secondaryContainer = BrandAmberContainerLight,
    onSecondaryContainer = OnAmberContainerLight,
    tertiary = BrandAmber,
    onTertiary = BrandNavy,
    error = CrimsonLight,
    onError = Color.White,
    background = Color(0xFFF8FAFC),
    onBackground = Color(0xFF0F172A),
    surface = Color.White,
    onSurface = Color(0xFF0F172A),
    surfaceVariant = Color(0xFFF1F5F9),
    onSurfaceVariant = Color(0xFF475569),
    outline = Color(0xFFCBD5E1),
    outlineVariant = Color(0xFFE2E8F0),
)

private val DarkScheme = darkColorScheme(
    primary = BrandAmber,
    onPrimary = BrandNavyDark,
    primaryContainer = BrandAmberContainerDark,
    onPrimaryContainer = OnAmberContainerDark,
    secondary = Color(0xFF8EA7DC),
    onSecondary = BrandNavyDark,
    secondaryContainer = BrandNavyContainer,
    onSecondaryContainer = Color(0xFFDCE5F5),
    tertiary = BrandAmberDark,
    onTertiary = Color.White,
    error = CrimsonDark,
    onError = Color(0xFF450A0A),
    background = BrandNavyDark,
    onBackground = Color(0xFFF8FAFC),
    surface = BrandNavySurface,
    onSurface = Color(0xFFF8FAFC),
    surfaceVariant = BrandNavyElevated,
    onSurfaceVariant = Color(0xFF94A3B8),
    outline = Color(0xFF334668),
    outlineVariant = Color(0xFF1E2A44),
)

/**
 * Material 3 wrapper for every Sayso screen. Enforces Sayso's signature
 * Deep Navy & Golden Amber brand theme consistently across all Android versions.
 */
@Composable
fun SaysoTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val colorScheme = if (darkTheme) DarkScheme else LightScheme
    MaterialTheme(colorScheme = colorScheme, content = content)
}

