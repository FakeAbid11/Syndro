package dev.syndro.app

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

val SyndroBackground = Color(0xFF0B0B0C)
val SyndroSurface = Color(0xFF131315)
val SyndroSurfaceHigh = Color(0xFF19191C)
val SyndroLine = Color(0xFF26262B)
val SyndroLineStrong = Color(0xFF35353C)
val SyndroText = Color(0xFFECECEF)
val SyndroDim = Color(0xFF919199)
val SyndroFaint = Color(0xFF85858B)
val SyndroAmber = Color(0xFFFFB454)
val SyndroGreen = Color(0xFF6FBF97)
val SyndroRed = Color(0xFFE06C75)

private val SyndroTypography = Typography().let { base ->
    base.copy(
        titleSmall = base.titleSmall.copy(
            fontSize = 16.sp,
            lineHeight = 24.sp,
            fontWeight = FontWeight.Medium,
            letterSpacing = 0.sp,
        ),
        bodyMedium = base.bodyMedium.copy(
            fontSize = 14.sp,
            lineHeight = 20.sp,
            letterSpacing = 0.sp,
        ),
        bodySmall = base.bodySmall.copy(
            fontSize = 13.sp,
            lineHeight = 20.sp,
            letterSpacing = 0.sp,
        ),
        labelLarge = base.labelLarge.copy(
            fontSize = 14.sp,
            lineHeight = 20.sp,
            fontWeight = FontWeight.Medium,
            letterSpacing = 0.sp,
        ),
        labelMedium = base.labelMedium.copy(
            fontSize = 13.sp,
            lineHeight = 20.sp,
            fontWeight = FontWeight.Medium,
            letterSpacing = 0.sp,
        ),
        labelSmall = base.labelSmall.copy(
            fontSize = 12.sp,
            lineHeight = 16.sp,
            fontWeight = FontWeight.Normal,
            letterSpacing = 0.sp,
            fontFeatureSettings = "tnum",
        ),
    )
}

private val SyndroColors = darkColorScheme(
    primary = SyndroAmber,
    onPrimary = Color(0xFF1A1206),
    background = SyndroBackground,
    onBackground = SyndroText,
    surface = SyndroSurface,
    surfaceTint = Color.Transparent,
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
    MaterialTheme(colorScheme = SyndroColors, typography = SyndroTypography, content = content)
}
