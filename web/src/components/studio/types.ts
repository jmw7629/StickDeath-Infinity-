// StickDeath ∞ Studio — Type definitions
// FlipaClip-style rebuild: 5 main tools, canvas-first layout

export type ToolType =
  | "cursor"
  | "brush"
  | "eraser"
  | "lasso"
  | "fill"
  | "text"
  | "smudge"
  | "blur";

// Ruler sub-tools (accessible from brush settings)
export type RulerMode = "off" | "line" | "circle" | "rect" | "mirror";

export interface StrokePoint {
  x: number;
  y: number;
  pressure?: number;
  timestamp?: number;
}

export interface FrameData {
  index: number;
  layers: FrameLayerData[];
  thumbnail?: string;
}

export interface FrameLayerData {
  layerId: string;
  imageData: string | null;
  isEmpty: boolean;
}

export interface LayerData {
  id: string;
  name: string;
  visible: boolean;
  opacity: number;
  locked: boolean;
  blendMode: BlendMode;
}

export type BlendMode = "normal" | "multiply" | "screen" | "overlay" | "darken" | "lighten";

export interface OnionSkinSettings {
  enabled: boolean;
  framesBefore: number;
  framesAfter: number;
  opacityBefore: number;
  opacityAfter: number;
  colored: boolean;
  loop: boolean;
}

export interface GridSettings {
  enabled: boolean;
  horizontalSpacing: number;
  verticalSpacing: number;
  opacity: number;
  snap: boolean;
}

export interface BrushSettings {
  size: number;
  opacity: number;
  stabilizer: number;
  brushType: BrushType;
}

export type BrushType =
  | "pen"
  | "pencil"
  | "brush"
  | "marker"
  | "airbrush"
  | "crayon"
  | "ink"
  | "pixel"
  | "spray"
  | "calligraphy";

export interface EraserSettings {
  size: number;
  opacity: number;
  feather: number;
}

export interface FillSettings {
  tolerance: number;
}

export interface ColorSwatch {
  name: string;
  colors: string[];
}

export type ColorPickerMode = "wheel" | "classic" | "harmony" | "value" | "swatches";

// Lasso selection state
export interface SelectionBox {
  x: number;
  y: number;
  width: number;
  height: number;
  rotation: number;
  pivotX: number;
  pivotY: number;
  imageData: string;         // The cut-out content
  maskPath: StrokePoint[];   // Original lasso path
}

export type SelectionHandle =
  | "move"
  | "tl" | "tr" | "bl" | "br"     // corner scale
  | "t" | "r" | "b" | "l"          // side stretch
  | "rotate"                        // top rotation handle
  | "pivot";                        // rotation pivot

// Floating image inserted from vault (moveable/resizable before commit)
export interface InsertedImage {
  url: string;
  name: string;
  x: number;
  y: number;
  width: number;
  height: number;
  rotation: number;
  committed: boolean;
}

// Keyboard shortcut map (FlipaClip-style)
export const KEYBOARD_SHORTCUTS: Record<string, { tool?: ToolType; action?: string; label: string }> = {
  v: { tool: "cursor", label: "Cursor / Move" },
  b: { tool: "brush", label: "Brush" },
  e: { tool: "eraser", label: "Eraser" },
  a: { tool: "lasso", label: "Lasso / Select" },
  f: { tool: "fill", label: "Fill" },
  t: { tool: "text", label: "Text" },
  g: { action: "toggle-grid", label: "Toggle Grid" },
  o: { action: "toggle-onion", label: "Toggle Onion Skin" },
  " ": { action: "play-pause", label: "Play / Pause" },
  ArrowLeft: { action: "prev-frame", label: "Previous Frame" },
  ArrowRight: { action: "next-frame", label: "Next Frame" },
  ArrowUp: { action: "next-layer", label: "Next Layer" },
  ArrowDown: { action: "prev-layer", label: "Previous Layer" },
};

// ── Asset Vault types ──
export interface AssetCategory {
  id: string;
  name: string;
  icon: string;
  subcategories: AssetSubcategory[];
}

export interface AssetSubcategory {
  id: string;
  name: string;
  assets: AssetItem[];
}

export interface AssetItem {
  id: string;
  name: string;
  url: string;
  thumbnail?: string;
  tags: string[];
  type: "image" | "sound";
  duration?: number; // for sounds (seconds)
}

// ── Audio track types ──
export interface AudioTrack {
  id: string;
  name: string;
  url: string;
  startFrame: number;
  endFrame: number;
  volume: number;
  muted: boolean;
}
