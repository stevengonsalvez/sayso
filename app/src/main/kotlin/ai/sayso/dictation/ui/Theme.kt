package ai.sayso.dictation.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// Sonic Cobalt primary & Energetic Amber secondary brand anchors
private val SonicCobaltLight = Color(0xFF2563EB)
private val SonicCobaltDark = Color(0xFF60A5FA)
private val CobaltContainerLight = Color(0xFFDBEAFE)
private val CobaltContainerDark = Color(0xFF1E3A8A)
private val OnCobaltContainerLight = Color(0xFF1E40AF)
private val OnCobaltContainerDark = Color(0xFFDBEAFE)

private val AmberLight = Color(0xFFF59E0B)
private val AmberDark = Color(0xFFFBBF24)
private val AmberContainerLight = Color(0xFFFEF3C7)
private val AmberContainerDark = Color(0xFF78350F)
private val OnAmberContainerLight = Color(0xFF92400E)
private val OnAmberContainerDark = Color(0xFFFEF3C7)

private val CrimsonLight = Color(0xFFEF4444)
private val CrimsonDark = Color(0xFFF87171)

private val LightScheme = lightColorScheme(
    primary = SonicCobaltLight,
    onPrimary = Color.White,
    primaryContainer = CobaltContainerLight,
    onPrimaryContainer = OnCobaltContainerLight,
    secondary = AmberLight,
    onSecondary = Color.White,
    secondaryContainer = AmberContainerLight,
    onSecondaryContainer = OnAmberContainerLight,
    tertiary = Color(0xFF0284C7),
    onTertiary = Color.White,
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
    primary = SonicCobaltDark,
    onPrimary = Color(0xFF0B0F17),
    primaryContainer = CobaltContainerDark,
    onPrimaryContainer = OnCobaltContainerDark,
    secondary = AmberDark,
    onSecondary = Color(0xFF451A03),
    secondaryContainer = AmberContainerDark,
    onSecondaryContainer = OnAmberContainerDark,
    tertiary = Color(0xFF38BDF8),
    onTertiary = Color(0xFF082F49),
    error = CrimsonDark,
    onError = Color(0xFF450A0A),
    background = Color(0xFF0B0F17),
    onBackground = Color(0xFFF8FAFC),
    surface = Color(0xFF131B2A),
    onSurface = Color(0xFFF8FAFC),
    surfaceVariant = Color(0xFF1E293B),
    onSurfaceVariant = Color(0xFF94A3B8),
    outline = Color(0xFF334155),
    outlineVariant = Color(0xFF1E293B),
)

/**
 * Material 3 wrapper for every Sayso screen. Enforces Sayso's signature
 * Sonic Cobalt brand theme consistently across all Android versions.
 */
@Composable
fun SaysoTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val colorScheme = if (darkTheme) DarkScheme else LightScheme
    MaterialTheme(colorScheme = colorScheme, content = content)
}

