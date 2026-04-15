// StickDeath ∞ — Persistent Tool Options Bar (FlipaClip-style)
// ALWAYS visible between canvas and frame strip
// Shows: color swatch + size/tolerance slider + onion/ruler toggles
// Adapts content based on active tool
// Tapping color swatch opens full color picker overlay

import type { ToolType, BrushSettings, EraserSettings, FillSettings, RulerMode } from "./types";

interface Props {
  activeTool: ToolType;
  // Brush/Color
  brushColor: string;
  brushSettings: BrushSettings;
  onColorSwatchTap: () => void;
  onBrushSizeChange: (size: number) => void;
  // Eraser
  eraserSettings: EraserSettings;
  onEraserSizeChange: (size: number) => void;
  // Fill
  fillSettings: FillSettings;
  onFillToleranceChange: (t: number) => void;
  // Toggles
  onionEnabled: boolean;
  onToggleOnion: () => void;
  rulerMode: RulerMode;
  onToggleRuler: () => void;
  // Selection
  hasSelection: boolean;
  onFlipH?: () => void;
  onFlipV?: () => void;
  onDeleteSelection?: () => void;
  onCopySelection?: () => void;
  onSelectAll?: () => void;
}

export default function ToolOptionsBar({
  activeTool,
  brushColor, brushSettings, onColorSwatchTap, onBrushSizeChange,
  eraserSettings, onEraserSizeChange,
  fillSettings, onFillToleranceChange,
  onionEnabled, onToggleOnion,
  rulerMode, onToggleRuler,
  hasSelection,
  onFlipH, onFlipV, onDeleteSelection, onCopySelection, onSelectAll,
}: Props) {
  return (
    <div className="flex items-center gap-2 px-3 py-1.5 bg-[#111118] border-t border-[#1a1a2a] shrink-0 min-h-[40px]">
      {/* ─── BRUSH OPTIONS ─── */}
      {activeTool === "brush" && (
        <>
          {/* Color swatch */}
          <button
            onClick={onColorSwatchTap}
            className="w-8 h-8 rounded-lg border-2 border-[#2a2a3a] hover:border-red-500/60 transition-colors shrink-0 shadow-inner"
            style={{ backgroundColor: brushColor }}
            title="Color picker"
          />
          {/* Size slider */}
          <div className="flex items-center gap-2 flex-1">
            <span className="text-[10px] text-[#555] w-6 text-right shrink-0">{brushSettings.size}</span>
            <input
              type="range" min={1} max={80} value={brushSettings.size}
              onChange={(e) => onBrushSizeChange(+e.target.value)}
              className="flex-1 accent-red-600 h-1.5"
            />
          </div>
          {/* Onion skin toggle */}
          <button
            onClick={onToggleOnion}
            className={`w-8 h-8 rounded-lg flex items-center justify-center shrink-0 transition-all text-sm ${
              onionEnabled ? "bg-red-600/15 text-red-400" : "text-[#555] hover:text-[#9090a8]"
            }`}
            title="Onion skin (O)"
          >
            🧅
          </button>
          {/* Ruler toggle */}
          <button
            onClick={onToggleRuler}
            className={`w-8 h-8 rounded-lg flex items-center justify-center shrink-0 transition-all text-sm ${
              rulerMode !== "off" ? "bg-red-600/15 text-red-400" : "text-[#555] hover:text-[#9090a8]"
            }`}
            title="Ruler tools"
          >
            📐
          </button>
        </>
      )}

      {/* ─── ERASER OPTIONS ─── */}
      {activeTool === "eraser" && (
        <>
          <div className="flex items-center gap-2 flex-1">
            <span className="text-[10px] text-[#72728a]">Size</span>
            <span className="text-[10px] text-[#555] w-6 text-right shrink-0">{eraserSettings.size}</span>
            <input
              type="range" min={4} max={100} value={eraserSettings.size}
              onChange={(e) => onEraserSizeChange(+e.target.value)}
              className="flex-1 accent-red-600 h-1.5"
            />
          </div>
          <button
            onClick={onToggleOnion}
            className={`w-8 h-8 rounded-lg flex items-center justify-center shrink-0 transition-all text-sm ${
              onionEnabled ? "bg-red-600/15 text-red-400" : "text-[#555] hover:text-[#9090a8]"
            }`}
            title="Onion skin (O)"
          >
            🧅
          </button>
        </>
      )}

      {/* ─── LASSO OPTIONS ─── */}
      {activeTool === "lasso" && (
        <>
          {hasSelection ? (
            <div className="flex items-center gap-1 flex-1">
              <span className="text-[10px] text-[#72728a] mr-2">Selection</span>
              <button onClick={onCopySelection}
                className="px-2 py-1 rounded text-[10px] text-[#9090a8] hover:bg-white/5 hover:text-white" title="Copy">
                📋 Copy
              </button>
              <button onClick={onFlipH}
                className="px-2 py-1 rounded text-[10px] text-[#9090a8] hover:bg-white/5 hover:text-white" title="Flip horizontal">
                ↔️ Flip H
              </button>
              <button onClick={onFlipV}
                className="px-2 py-1 rounded text-[10px] text-[#9090a8] hover:bg-white/5 hover:text-white" title="Flip vertical">
                ↕️ Flip V
              </button>
              <div className="flex-1" />
              <button onClick={onDeleteSelection}
                className="px-2 py-1 rounded text-[10px] text-red-400 hover:bg-red-500/10" title="Delete selection">
                🗑️ Delete
              </button>
            </div>
          ) : (
            <div className="flex items-center gap-2 flex-1">
              <span className="text-xs text-[#555]">Draw around an area to select · Double-tap to select all</span>
              <div className="flex-1" />
              <button onClick={onSelectAll}
                className="px-2 py-1 rounded text-[10px] text-[#9090a8] hover:bg-white/5 hover:text-white border border-[#2a2a3a]">
                Select All
              </button>
            </div>
          )}
        </>
      )}

      {/* ─── FILL OPTIONS ─── */}
      {activeTool === "fill" && (
        <>
          <button
            onClick={onColorSwatchTap}
            className="w-8 h-8 rounded-lg border-2 border-[#2a2a3a] hover:border-red-500/60 transition-colors shrink-0 shadow-inner"
            style={{ backgroundColor: brushColor }}
            title="Fill color"
          />
          <div className="flex items-center gap-2 flex-1">
            <span className="text-[10px] text-[#72728a]">Tolerance</span>
            <span className="text-[10px] text-[#555] w-6 text-right shrink-0">{fillSettings.tolerance}</span>
            <input
              type="range" min={0} max={100} value={fillSettings.tolerance}
              onChange={(e) => onFillToleranceChange(+e.target.value)}
              className="flex-1 accent-red-600 h-1.5"
            />
          </div>
        </>
      )}

      {/* ─── TEXT OPTIONS ─── */}
      {activeTool === "text" && (
        <>
          <button
            onClick={onColorSwatchTap}
            className="w-8 h-8 rounded-lg border-2 border-[#2a2a3a] hover:border-red-500/60 transition-colors shrink-0 shadow-inner"
            style={{ backgroundColor: brushColor }}
            title="Text color"
          />
          <span className="text-xs text-[#555]">Tap canvas to place text</span>
        </>
      )}

      {/* ─── CURSOR OPTIONS ─── */}
      {activeTool === "cursor" && (
        <>
          {hasSelection ? (
            <div className="flex items-center gap-1 flex-1">
              <span className="text-[10px] text-[#72728a] mr-2">Move</span>
              <button onClick={onFlipH}
                className="px-2 py-1 rounded text-[10px] text-[#9090a8] hover:bg-white/5 hover:text-white" title="Flip horizontal">
                ↔️ Flip H
              </button>
              <button onClick={onFlipV}
                className="px-2 py-1 rounded text-[10px] text-[#9090a8] hover:bg-white/5 hover:text-white" title="Flip vertical">
                ↕️ Flip V
              </button>
              <div className="flex-1" />
              <button onClick={onDeleteSelection}
                className="px-2 py-1 rounded text-[10px] text-red-400 hover:bg-red-500/10" title="Delete">
                🗑️ Delete
              </button>
            </div>
          ) : (
            <div className="flex items-center gap-2 flex-1">
              <span className="text-xs text-[#555]">Tap canvas to select &amp; move content</span>
            </div>
          )}
        </>
      )}
    </div>
  );
}
