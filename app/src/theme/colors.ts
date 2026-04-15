/**
 * StickDeath Infinity — Dark theme color tokens
 */

export const Colors = {
  // Backgrounds
  bg: '#0A0A0F',
  bgSurface: '#14141E',
  bgElevated: '#1C1C2A',
  bgPanel: 'rgba(18, 18, 28, 0.88)',
  bgPanelSolid: '#12121C',

  // Glass / Blur overlays
  glass: 'rgba(22, 22, 36, 0.72)',
  glassBorder: 'rgba(255, 255, 255, 0.08)',
  glassHighlight: 'rgba(255, 255, 255, 0.04)',

  // Text
  textPrimary: '#F0F0F5',
  textSecondary: '#8888A0',
  textMuted: '#555570',
  textInverse: '#0A0A0F',

  // Accent
  accent: '#6C5CE7',
  accentLight: '#A29BFE',
  accentDim: 'rgba(108, 92, 231, 0.25)',

  // Semantic
  success: '#00D68F',
  warning: '#FFB800',
  error: '#FF4757',
  info: '#4DABF7',

  // Onion skinning
  onionPrev: 'rgba(70, 130, 255, 0.35)',
  onionNext: 'rgba(70, 220, 120, 0.35)',

  // Canvas
  canvasBg: '#111118',
  canvasGrid: 'rgba(255, 255, 255, 0.05)',
  canvasGridMajor: 'rgba(255, 255, 255, 0.10)',

  // Joint handles
  jointHandle: 'rgba(108, 92, 231, 0.8)',
  jointHandleActive: '#A29BFE',
  jointHandleHover: 'rgba(162, 155, 254, 0.5)',

  // Toolbar
  toolActive: '#6C5CE7',
  toolInactive: '#555570',
  toolBg: 'rgba(22, 22, 36, 0.85)',

  // Divider
  divider: 'rgba(255, 255, 255, 0.06)',

  // Figure style presets (matching Swift FigureStyle.presets)
  figurePresets: [
    { r: 0, g: 0, b: 0, hex: '#000000', label: 'Black' },
    { r: 1, g: 1, b: 1, hex: '#FFFFFF', label: 'White' },
    { r: 0.95, g: 0.2, b: 0.2, hex: '#F23333', label: 'Red' },
    { r: 0.2, g: 0.4, b: 1.0, hex: '#3366FF', label: 'Blue' },
    { r: 0.1, g: 0.8, b: 0.3, hex: '#19CC4D', label: 'Green' },
    { r: 1.0, g: 0.6, b: 0.0, hex: '#FF9900', label: 'Orange' },
    { r: 0.6, g: 0.2, b: 0.9, hex: '#9933E6', label: 'Purple' },
    { r: 1.0, g: 0.85, b: 0.0, hex: '#FFD900', label: 'Yellow' },
    { r: 0.0, g: 0.85, b: 0.85, hex: '#00D9D9', label: 'Cyan' },
    { r: 1.0, g: 0.4, b: 0.7, hex: '#FF66B3', label: 'Pink' },
  ],
} as const;

/** Shared glass panel style properties (for StyleSheet use) */
export const GlassPanel = {
  backgroundColor: Colors.glass,
  borderColor: Colors.glassBorder,
  borderWidth: 1,
  borderRadius: 16,
} as const;

// ── Mobile App Theme Tokens ────────────────────────────

export const brandPink = '#ff2d55';
export const brandCyan = '#00D9D9';

export const surface = '#0A0A0F';
export const surfaceElevated = '#14141E';
export const surfaceCard = '#1C1C2A';
export const textPrimary = '#F0F0F5';
export const textSecondary = '#8888A0';
export const textMuted = '#555570';
export const border = 'rgba(255, 255, 255, 0.08)';
export const borderLight = 'rgba(255, 255, 255, 0.04)';

export const palette = {
  black: '#000000',
  white: '#FFFFFF',
  gray: {
    50: '#FAFAFA',
    100: '#F4F4F5',
    200: '#E4E4E7',
    300: '#D4D4D8',
    400: '#A1A1AA',
    500: '#71717A',
    600: '#52525B',
    700: '#3F3F46',
    800: '#27272A',
    900: '#18181B',
    950: '#09090B',
  } as Record<number, string>,
  success: '#00D68F',
  warning: '#FFB800',
  error: '#FF4757',
  info: '#4DABF7',
} as const;
