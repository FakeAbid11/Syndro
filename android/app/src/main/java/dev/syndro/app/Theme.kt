package dev.syndro.app

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val SyndroBackground = Color(0xFF0B0B0C)
val SyndroSurface = Color(0xFF131315)
val SyndroSurfaceHigh = Color(0xFF19191C)
val SyndroLine = Color(0xFF26262B)
val SyndroLineStrong = Color(0xFF35353C)
val SyndroText = Color(0xFFECECEF)
val SyndroDim = Color(0xFF919199)
val SyndroFaint = Color(0xFF5D5D66)
val SyndroAmber = Color(0xFFFFB454)
val SyndroGreen = Color(0xFF6FBF97)
val SyndroRed = Color(0xFFE06C75)

private val SyndroColors = darkColorScheme(
    primary = SyndroAmber,
    onPrimary = Color(0xFF1A1206),
    background = SyndroBackground,
    onBackground = SyndroText,
    surface = SyndroSurface,
    onSurface = SyndroText,
    surfaceVariant = SyndroSurfaceHigh,
    onSurfaceVariant = SyndroDim,
    outline = SyndroLine,
    outlineVariant = SyndroLineStrong,
    error = SyndroRed,
)

@Composable
fun SyndroTheme(content: @Composable () -> Unit) {
    // The brand is intentionally monochrome + amber in both light and dark
    // system settings; a file transfer tool has no reason to flash white.
    MaterialTheme(colorScheme = SyndroColors, content = content)
}
