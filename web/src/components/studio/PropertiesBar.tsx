import { useState } from "react";
import { Grid3x3, Eye, EyeOff } from "lucide-react";
import type { ToolType, BrushSettings, OnionSkinSettings, GridSettings } from "./types";
import ColorPicker from "./ColorPicker";

interface Props {
  activeTool: ToolType;
  brushColor: string;
  previousColor: string;
  recentColors: string[];
  brushSettings: BrushSettings;
  eraserSize: number;
  onionSkin: OnionSkinSettings;
  grid: GridSettings;
  onColorChange: (c: string) => void;
  onBrushSettingsChange: (s: BrushSettings) => void;
  onEraserSizeChange: (s: number) => void;
  onOnionSkinChange: (s: OnionSkinSettings) => void;
  onGridChange: (s: GridSettings) => void;
}

export default function PropertiesBar({
  activeTool, brushColor, previousColor, recentColors,
  brushSettings, eraserSize,
  onionSkin, grid,
  onColorChange, onBrushSettingsChange, onEraserSizeChange,
  onOnionSkinChange, onGridChange,
}: Props) {
  const [showColorPicker, setShowColorPicker] = useState(false);
  const [showOnionSettings, setShowOnionSettings] = useState(false);

  const isDrawTool = ["brush", "line", "rect", "circle", "text"].includes(activeTool);

  return (
    <div className="flex items-center gap-3 px-3 py-1.5 bg-[#111118] border-t border-[#2a2a3a] text-xs shrink-0 overflow-x-auto">
      {/* Color swatch (for drawing tools) */}
      {isDrawTool && (
        <div className="relative">
          <button
            onClick={() => setShowColorPicker(!showColorPicker)}
            className="w-7 h-7 rounded-md border-2 border-[#2a2a3a] hover:border-red-500 transition-colors shrink-0"
            style={{ backgroundColor: brushColor }}
            title="Color"
          />
          {showColorPicker && (
            <ColorPicker
              color={brushColor}
              previousColor={previousColor}
              recentColors={recentColors}
              opacity={brushSettings.opacity}
              onColorChange={(c) => onColorChange(c)}
              onOpacityChange={(o) => onBrushSettingsChange({ ...brushSettings, opacity: o })}
              onClose={() => setShowColorPicker(false)}
            />
          )}
        </div>
      )}

      {/* Brush settings */}
      {activeTool === "brush" && (
        <>
          <label className="flex items-center gap-1.5 text-[#9090a8]">
            Size
            <input
              type="range" min={1} max={80} value={brushSettings.size}
              onChange={(e) => onBrushSettingsChange({ ...brushSettings, size: +e.target.value })}
              className="w-20 accent-red-600"
            />
            <span className="w-6 text-right text-white">{brushSettings.size}</span>
          </label>

          <label className="flex items-center gap-1.5 text-[#9090a8]">
            Stabilizer
            <input
              type="range" min={0} max={100} value={brushSettings.stabilizer}
              onChange={(e) => onBrushSettingsChange({ ...brushSettings, stabilizer: +e.target.value })}
              className="w-20 accent-red-600"
            />
            <span className="w-6 text-right text-white">{brushSettings.stabilizer}</span>
          </label>

          <label className="flex items-center gap-1.5 text-[#9090a8]">
            Opacity
            <input
              type="range" min={1} max={100} value={Math.round(brushSettings.opacity * 100)}
              onChange={(e) => onBrushSettingsChange({ ...brushSettings, opacity: +e.target.value / 100 })}
              className="w-16 accent-red-600"
            />
            <span className="w-8 text-right text-white">{Math.round(brushSettings.opacity * 100)}%</span>
          </label>
        </>
      )}

      {/* Eraser settings */}
      {activeTool === "eraser" && (
        <label className="flex items-center gap-1.5 text-[#9090a8]">
          Size
          <input
            type="range" min={4} max={100} value={eraserSize}
            onChange={(e) => onEraserSizeChange(+e.target.value)}
            className="w-24 accent-red-600"
          />
          <span className="w-6 text-right text-white">{eraserSize}</span>
        </label>
      )}

      {/* Shape tool settings */}
      {["line", "rect", "circle"].includes(activeTool) && (
        <label className="flex items-center gap-1.5 text-[#9090a8]">
          Stroke
          <input
            type="range" min={1} max={40} value={brushSettings.size}
            onChange={(e) => onBrushSettingsChange({ ...brushSettings, size: +e.target.value })}
            className="w-20 accent-red-600"
          />
          <span className="w-6 text-right text-white">{brushSettings.size}</span>
        </label>
      )}

      {/* Spacer */}
      <div className="flex-1" />

      {/* Grid toggle */}
      <button
        onClick={() => onGridChange({ ...grid, enabled: !grid.enabled })}
        className={`flex items-center gap-1 px-2 py-1 rounded transition-all ${
          grid.enabled ? "bg-white/10 text-white" : "text-[#72728a] hover:text-white"
        }`}
        title="Toggle Grid (G)"
      >
        <Grid3x3 size={14} />
        <span className="hidden sm:inline">Grid</span>
      </button>

      {/* Onion skin toggle + settings */}
      <div className="relative">
        <button
          onClick={() => onOnionSkinChange({ ...onionSkin, enabled: !onionSkin.enabled })}
          onContextMenu={(e) => { e.preventDefault(); setShowOnionSettings(!showOnionSettings); }}
          className={`flex items-center gap-1 px-2 py-1 rounded transition-all ${
            onionSkin.enabled ? "bg-white/10 text-white" : "text-[#72728a] hover:text-white"
          }`}
          title="Toggle Onion Skin (O) — right-click for settings"
        >
          {onionSkin.enabled ? <Eye size={14} /> : <EyeOff size={14} />}
          <span className="hidden sm:inline">Onion</span>
          {onionSkin.colored && onionSkin.enabled && (
            <span className="flex gap-0.5 ml-1">
              <span className="w-2 h-2 rounded-full bg-red-500" />
              <span className="w-2 h-2 rounded-full bg-green-500" />
            </span>
          )}
        </button>

        {showOnionSettings && (
          <div
            className="absolute bottom-full right-0 mb-2 bg-[#111118] border border-[#2a2a3a] rounded-lg p-3 w-56 z-50 shadow-xl"
            onClick={(e) => e.stopPropagation()}
          >
            <h4 className="text-white text-xs font-bold mb-2">Onion Skin Settings</h4>

            <label className="flex items-center gap-2 text-[#9090a8] mb-2">
              <input
                type="checkbox" checked={onionSkin.colored}
                onChange={() => onOnionSkinChange({ ...onionSkin, colored: !onionSkin.colored })}
                className="accent-red-600"
              />
              Color mode (red/green)
            </label>

            <label className="flex items-center gap-2 text-[#9090a8] mb-2">
              <input
                type="checkbox" checked={onionSkin.loop}
                onChange={() => onOnionSkinChange({ ...onionSkin, loop: !onionSkin.loop })}
                className="accent-red-600"
              />
              Loop (seamless)
            </label>

            <label className="flex items-center gap-1.5 text-[#9090a8] mb-1">
              Before
              <input
                type="range" min={0} max={5} value={onionSkin.framesBefore}
                onChange={(e) => onOnionSkinChange({ ...onionSkin, framesBefore: +e.target.value })}
                className="flex-1 accent-red-600"
              />
              <span className="w-4 text-right text-white">{onionSkin.framesBefore}</span>
            </label>

            <label className="flex items-center gap-1.5 text-[#9090a8] mb-1">
              After
              <input
                type="range" min={0} max={5} value={onionSkin.framesAfter}
                onChange={(e) => onOnionSkinChange({ ...onionSkin, framesAfter: +e.target.value })}
                className="flex-1 accent-red-600"
              />
              <span className="w-4 text-right text-white">{onionSkin.framesAfter}</span>
            </label>

            <label className="flex items-center gap-1.5 text-[#9090a8] mb-1">
              Opacity
              <input
                type="range" min={5} max={60} value={Math.round(onionSkin.opacityBefore * 100)}
                onChange={(e) => onOnionSkinChange({
                  ...onionSkin,
                  opacityBefore: +e.target.value / 100,
                  opacityAfter: +e.target.value / 100 * 0.6,
                })}
                className="flex-1 accent-red-600"
              />
              <span className="w-8 text-right text-white">{Math.round(onionSkin.opacityBefore * 100)}%</span>
            </label>

            <button
              onClick={() => setShowOnionSettings(false)}
              className="mt-2 w-full text-center text-xs text-[#72728a] hover:text-white"
            >
              Close
            </button>
          </div>
        )}
      </div>
    </div>
  );
}
