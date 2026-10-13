package com.stickdeath.studio

import androidx.compose.material3.Typography
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily

// Bundled locally: the Studio remains usable offline. Preserve Material's type
// sizes and spacing while matching the native/reference Special Elite family.
private val studioFont = FontFamily(Font(R.font.special_elite_regular))
private val defaultTypography = Typography()
val studioTypography = Typography(
    displayLarge = defaultTypography.displayLarge.copy(fontFamily = studioFont),
    displayMedium = defaultTypography.displayMedium.copy(fontFamily = studioFont),
    displaySmall = defaultTypography.displaySmall.copy(fontFamily = studioFont),
    headlineLarge = defaultTypography.headlineLarge.copy(fontFamily = studioFont),
    headlineMedium = defaultTypography.headlineMedium.copy(fontFamily = studioFont),
    headlineSmall = defaultTypography.headlineSmall.copy(fontFamily = studioFont),
    titleLarge = defaultTypography.titleLarge.copy(fontFamily = studioFont),
    titleMedium = defaultTypography.titleMedium.copy(fontFamily = studioFont),
    titleSmall = defaultTypography.titleSmall.copy(fontFamily = studioFont),
    bodyLarge = defaultTypography.bodyLarge.copy(fontFamily = studioFont),
    bodyMedium = defaultTypography.bodyMedium.copy(fontFamily = studioFont),
    bodySmall = defaultTypography.bodySmall.copy(fontFamily = studioFont),
    labelLarge = defaultTypography.labelLarge.copy(fontFamily = studioFont),
    labelMedium = defaultTypography.labelMedium.copy(fontFamily = studioFont),
    labelSmall = defaultTypography.labelSmall.copy(fontFamily = studioFont)
)
