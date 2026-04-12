/**
 * StickDeath Infinity — Theme
 *
 * Single source of truth for colors, spacing, typography,
 * border radii, shadows, and layout constants.
 */

import {
  palette,
  brandPink,
  brandCyan,
  surface,
  surfaceElevated,
  surfaceCard,
  textPrimary,
  textSecondary,
  textMuted,
  border,
  borderLight,
} from './colors';

// ── Spacing scale (4-pt grid) ──────────────────────────
export const spacing = {
  xxs: 2,
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
  xxxl: 48,
  huge: 64,
} as const;

// ── Typography ─────────────────────────────────────────
export const fontFamily = {
  regular: 'Inter_400Regular',
  medium: 'Inter_500Medium',
  semibold: 'Inter_600SemiBold',
  bold: 'Inter_700Bold',
  black: 'Inter_900Black',
} as const;

export const fontSize = {
  xs: 11,
  sm: 13,
  md: 15,
  lg: 17,
  xl: 20,
  xxl: 24,
  xxxl: 32,
  display: 40,
} as const;

export const lineHeight = {
  xs: 14,
  sm: 18,
  md: 20,
  lg: 24,
  xl: 28,
  xxl: 32,
  xxxl: 40,
  display: 48,
} as const;

// ── Border radii ───────────────────────────────────────
export const radii = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  full: 9999,
} as const;

// ── Shadows (iOS + Android) ────────────────────────────
export const shadows = {
  sm: {
    shadowColor: palette.black,
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.3,
    shadowRadius: 2,
    elevation: 2,
  },
  md: {
    shadowColor: palette.black,
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.4,
    shadowRadius: 6,
    elevation: 4,
  },
  lg: {
    shadowColor: palette.black,
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.5,
    shadowRadius: 12,
    elevation: 8,
  },
  glow: (color: string) => ({
    shadowColor: color,
    shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.6,
    shadowRadius: 16,
    elevation: 10,
  }),
} as const;

// ── Layout constants ───────────────────────────────────
export const layout = {
  screenPaddingH: spacing.lg,
  tabBarHeight: 88,
  headerHeight: 56,
  studioToolbarHeight: 52,
  maxContentWidth: 600,
} as const;

// ── Animation durations (ms) ───────────────────────────
export const durations = {
  fast: 150,
  normal: 250,
  slow: 400,
  xslow: 600,
} as const;

// ── Unified theme object ───────────────────────────────
export const theme = {
  colors: {
    // Brand
    primary: brandPink,
    secondary: brandCyan,
    accent: brandPink,

    // Surfaces
    background: surface,
    surface: surfaceElevated,
    card: surfaceCard,

    // Text
    text: textPrimary,
    textSecondary,
    textMuted,

    // Borders
    border,
    borderLight,

    // Semantic
    success: palette.success,
    warning: palette.warning,
    error: palette.error,
    info: palette.info,

    // Raw palette access
    ...palette,
  },
  spacing,
  fontFamily,
  fontSize,
  lineHeight,
  radii,
  shadows,
  layout,
  durations,
} as const;

export type Theme = typeof theme;
export type ThemeColors = typeof theme.colors;

export { palette, brandPink, brandCyan };
export default theme;
