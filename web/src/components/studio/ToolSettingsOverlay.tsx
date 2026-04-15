// StickDeath ∞ — Expanded Tool Settings Panel (FlipaClip-style)
// Opens as overlay when tapping the active tool again
// Shows detailed settings: brush type grid, detailed sliders, ruler sub-tools
// Positioned above the ToolOptionsBar, dismisses on canvas tap

import { useState } from "react";
import type { ToolType, BrushSettings, BrushType, EraserSettings, FillSettings, RulerMode } from "./types";
import ColorPicker from "./ColorPicker";

interface Props {
  activeTool: ToolType;
  visible: boolean;
  onClose: () => void;
  // Brush
  brushColor: string;
  previousColor: string;
  recentColors: string[];
  brushSettings: BrushSettings;
  onColorChange: (c: string) => void;
  onBrushSettingsChange: (s: BrushSettings) => void;
  // Eraser
  eraserSettings: EraserSettings;
  onEraserSettingsChange: (s: EraserSettings) => void;
  // Fill
  fillSettings: FillSettings;
  onFillSettingsChange: (s: FillSettings) => void;
  // Ruler
  rulerMode: RulerMode;
  onRulerModeChange: (m: RulerMode) => void;
  // Color picker state (managed externally so ToolOptionsBar can also open it)
  showColorPicker: boolean;
  setShowColorPicker: (v: boolean) => void;
}

const BRUSH_TYPES: { type: BrushType; label: string; icon: string }[] = [
  { type: "pen",         label: "Pen",         icon: "✒️" },
  { type: "pencil",      label: "Pencil",      icon: "✏️" },
  { type: "brush",       label: "Brush",       icon: "🖌️" },
  { type: "marker",      label: "Marker",      icon: "🖍️" },
  { type: "airbrush",    label: "Airbrush",    icon: "💨" },
  { type: "crayon",      label: "Crayon",      icon: "🖍️" },
  { type: "ink",         label: "Ink",         icon: "🖋️" },
  { type: "pixel",       label: "Pixel",       icon: "▪️" },
  { type: "spray",       label: "Spray",       icon: "🎨" },
  { type: "calligraphy", label: "Calli",       icon: "🪶" },
];

const RULER_MODES: { mode: RulerMode; label: string; icon: string }[] = [
  { mode: "off",    label: "Off",       icon: "✕" },
  { mode: "line",   label: "Line",      icon: "╱" },
  { mode: "rect",   label: "Rect",      icon: "▭" },
  { mode: "circle", label: "Circle",    icon: "◯" },
  { mode: "mirror", label: "Mirror",    icon: "⌁" },
];

export default function ToolSettingsOverlay({
  activeTool, visible, onClose,
  brushColor, previousColor, recentColors,
  brushSettings, onColorChange, onBrushSettingsChange,
  eraserSettings, onEraserSettingsChange,
  fillSettings, onFillSettingsChange,
  rulerMode, onRulerModeChange,
  showColorPicker, setShowColorPicker,
}: Props) {
  const [showBrushGrid, setShowBrushGrid] = useState(false);

  if (!visible && !showColorPicker) return null;

  return (
    <>
      {/* Backdrop — tapping dismisses */}
      <div className="absolute inset-0 z-20" onClick={onClose} />

      <div className="absolute left-0 right-0 bottom-0 z-30" onClick={(e) => e.stopPropagation()}>
        {/* Color picker overlay (separate from settings panel) */}
        {showColorPicker && (
          <div className="mx-2 mb-1 bg-[#111118]/95 backdrop-blur-md border border-[#2a2a3a] rounded-xl shadow-2xl overflow-hidden">
            <ColorPicker
              color={brushColor}
              previousColor={previousColor}
              recentColors={recentColors}
              opacity={activeTool === "brush" ? brushSettings.opacity : 1}
              onColorChange={onColorChange}
              onOpacityChange={(o) => {
                if (activeTool === "brush") onBrushSettingsChange({ ...brushSettings, opacity: o });
              }}
              onClose={() => setShowColorPicker(false)}
              inline
            />
          </div>
        )}

        {/* Expanded settings panel */}
        {visible && (
          <div className="mx-2 mb-1 bg-[#111118]/95 backdrop-blur-md border border-[#2a2a3a] rounded-xl shadow-2xl overflow-hidden">
            {/* Drag handle */}
            <div className="flex justify-center pt-2 pb-1">
              <div className="w-8 h-1 rounded-full bg-[#2a2a3a]" />
            </div>

            <div className="px-3 pb-3">
              {/* ─── BRUSH SETTINGS ─── */}
              {activeTool === "brush" && (
                <div className="space-y-3">
                  {/* Current brush type + expand grid */}
                  <button
                    onClick={() => setShowBrushGrid(!showBrushGrid)}
                    className="flex items-center gap-2 text-sm text-white w-full"
                  >
                    <span className="text-lg">
                      {BRUSH_TYPES.find((b) => b.type === brushSettings.brushType)?.icon}
                    </span>
                    <span className="font-medium text-xs">
                      {BRUSH_TYPES.find((b) => b.type === brushSettings.brushType)?.label}
                    </span>
                    <svg className={`w-3 h-3 text-[#72728a] transition-transform ml-auto ${showBrushGrid ? "rotate-180" : ""}`} viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="2">
                      <path d="M2 4l4 4 4-4" />
                    </svg>
                  </button>

                  {/* Brush type grid */}
                  {showBrushGrid && (
                    <div className="grid grid-cols-5 gap-1">
                      {BRUSH_TYPES.map(({ type, label, icon }) => (
                        <button
                          key={type}
                          onClick={() => {
                            onBrushSettingsChange({ ...brushSettings, brushType: type });
                            setShowBrushGrid(false);
                          }}
                          className={`flex flex-col items-center gap-0.5 p-1.5 rounded-lg text-xs transition-all ${
                            brushSettings.brushType === type
                              ? "bg-red-600/20 text-red-400 ring-1 ring-red-500/40"
                              : "text-[#9090a8] hover:bg-white/5 hover:text-white"
                          }`}
                        >
                          <span className="text-lg">{icon}</span>
                          <span className="text-[9px]">{label}</span>
                        </button>
                      ))}
                    </div>
                  )}

                  {/* Size + Opacity + Stabilizer */}
                  <div className="space-y-2">
                    <SliderRow label="Size" value={brushSettings.size} min={1} max={80} unit="px"
                      onChange={(v) => onBrushSettingsChange({ ...brushSettings, size: v })} />
                    <SliderRow label="Opacity" value={Math.round(brushSettings.opacity * 100)} min={1} max={100} unit="%"
                      onChange={(v) => onBrushSettingsChange({ ...brushSettings, opacity: v / 100 })} />
                    <SliderRow label="Smooth" value={brushSettings.stabilizer} min={0} max={100} unit="%"
                      onChange={(v) => onBrushSettingsChange({ ...brushSettings, stabilizer: v })} />
                  </div>

                  {/* Ruler sub-tools */}
                  <div>
                    <span className="text-[10px] text-[#555] uppercase tracking-wider">Ruler</span>
                    <div className="flex gap-1 mt-1">
                      {RULER_MODES.map(({ mode, label, icon }) => (
                        <button
                          key={mode}
                          onClick={() => onRulerModeChange(mode)}
                          className={`flex-1 flex flex-col items-center gap-0.5 py-1.5 rounded-lg text-[10px] transition-all ${
                            rulerMode === mode
                              ? "bg-red-600/20 text-red-400 ring-1 ring-red-500/40"
                              : "text-[#72728a] hover:text-white hover:bg-white/5"
                          }`}
                        >
                          <span className="text-sm">{icon}</span>
                          <span>{label}</span>
                        </button>
                      ))}
                    </div>
                  </div>
                </div>
              )}

              {/* ─── ERASER SETTINGS ─── */}
              {activeTool === "eraser" && (
                <div className="space-y-2">
                  <SliderRow label="Size" value={eraserSettings.size} min={4} max={100} unit="px"
                    onChange={(v) => onEraserSettingsChange({ ...eraserSettings, size: v })} />
                  <SliderRow label="Opacity" value={Math.round(eraserSettings.opacity * 100)} min={10} max={100} unit="%"
                    onChange={(v) => onEraserSettingsChange({ ...eraserSettings, opacity: v / 100 })} />
                  <SliderRow label="Feather" value={eraserSettings.feather} min={0} max={20} unit="px"
                    onChange={(v) => onEraserSettingsChange({ ...eraserSettings, feather: v })} />
                </div>
              )}

              {/* ─── FILL SETTINGS ─── */}
              {activeTool === "fill" && (
                <div className="space-y-2">
                  <SliderRow label="Tolerance" value={fillSettings.tolerance} min={0} max={100} unit=""
                    onChange={(v) => onFillSettingsChange({ ...fillSettings, tolerance: v })} />
                  <p className="text-[10px] text-[#555]">Tap an area on the canvas to fill it with the current color.</p>
                </div>
              )}

              {/* ─── TEXT SETTINGS ─── */}
              {activeTool === "text" && (
                <div className="text-xs text-[#9090a8] space-y-1">
                  <p>Tap canvas to place text. Font: Special Elite.</p>
                  <p className="text-[10px] text-[#555]">Change color from the color swatch below.</p>
                </div>
              )}

              {/* ─── LASSO INFO ─── */}
              {activeTool === "lasso" && (
                <div className="text-xs text-[#9090a8] space-y-1">
                  <p className="text-white font-medium text-sm">Lasso / Select</p>
                  <p>• Draw around an area to select it</p>
                  <p>• Double-tap canvas to select all on layer</p>
                  <p>• Drag inside box to move</p>
                  <p>• Drag corner handles to scale</p>
                  <p>• Drag top handle to rotate</p>
                  <p>• Tap outside the box to commit</p>
                </div>
              )}
            </div>
          </div>
        )}
      </div>
    </>
  );
}

// ─── Reusable slider row ───
function SliderRow({ label, value, min, max, unit, onChange }: {
  label: string; value: number; min: number; max: number; unit: string;
  onChange: (v: number) => void;
}) {
  return (
    <div className="flex items-center gap-2">
      <span className="text-[10px] text-[#555] w-10 shrink-0">{label}</span>
      <input
        type="range" min={min} max={max} value={value}
        onChange={(e) => onChange(+e.target.value)}
        className="flex-1 accent-red-600 h-1.5"
      />
      <span className="text-[10px] text-white font-mono w-8 text-right shrink-0">{value}{unit}</span>
    </div>
  );
}
