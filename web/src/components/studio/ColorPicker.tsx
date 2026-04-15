// StickDeath ∞ — Color Picker (FlipaClip-style)
// 5 modes: Wheel, Classic, Harmony, Value, Swatches
// Eyedropper button, opacity slider, recent colors
// Supports overlay and inline positioning

import { useState, useRef, useCallback, useEffect } from "react";
import type { ColorPickerMode } from "./types";

interface Props {
  color: string;
  previousColor: string;
  recentColors: string[];
  opacity: number;
  onColorChange: (c: string) => void;
  onOpacityChange: (o: number) => void;
  onClose: () => void;
  inline?: boolean;
  onEyedropper?: () => void;
}

// ─── Color utilities ───
function hexToHsl(hex: string): [number, number, number] {
  const r = parseInt(hex.slice(1, 3), 16) / 255;
  const g = parseInt(hex.slice(3, 5), 16) / 255;
  const b = parseInt(hex.slice(5, 7), 16) / 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  let h = 0, s = 0;
  const l = (max + min) / 2;
  if (max !== min) {
    const d = max - min;
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    switch (max) {
      case r: h = ((g - b) / d + (g < b ? 6 : 0)) / 6; break;
      case g: h = ((b - r) / d + 2) / 6; break;
      case b: h = ((r - g) / d + 4) / 6; break;
    }
  }
  return [Math.round(h * 360), Math.round(s * 100), Math.round(l * 100)];
}

function hslToHex(h: number, s: number, l: number): string {
  const sn = s / 100, ln = l / 100;
  const c = (1 - Math.abs(2 * ln - 1)) * sn;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = ln - c / 2;
  let r = 0, g = 0, b = 0;
  if (h < 60) { r = c; g = x; }
  else if (h < 120) { r = x; g = c; }
  else if (h < 180) { g = c; b = x; }
  else if (h < 240) { g = x; b = c; }
  else if (h < 300) { r = x; b = c; }
  else { r = c; b = x; }
  const toHex = (v: number) => Math.round((v + m) * 255).toString(16).padStart(2, "0");
  return `#${toHex(r)}${toHex(g)}${toHex(b)}`;
}

function hexToRgb(hex: string): [number, number, number] {
  return [
    parseInt(hex.slice(1, 3), 16),
    parseInt(hex.slice(3, 5), 16),
    parseInt(hex.slice(5, 7), 16),
  ];
}

function rgbToHex(r: number, g: number, b: number): string {
  return `#${[r, g, b].map(v => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, "0")).join("")}`;
}

export default function ColorPicker({
  color, previousColor, recentColors, opacity,
  onColorChange, onOpacityChange, onClose,
  inline = false, onEyedropper,
}: Props) {
  const [mode, setMode] = useState<ColorPickerMode>("wheel");
  const [hsl, setHsl] = useState<[number, number, number]>(hexToHsl(color));
  const [hexInput, setHexInput] = useState(color);
  const wheelRef = useRef<HTMLCanvasElement>(null);
  const satRef = useRef<HTMLCanvasElement>(null);
  const isDraggingWheel = useRef(false);
  const isDraggingSat = useRef(false);

  useEffect(() => {
    setHsl(hexToHsl(color));
    setHexInput(color);
  }, [color]);

  const updateFromHsl = useCallback((h: number, s: number, l: number) => {
    setHsl([h, s, l]);
    const hex = hslToHex(h, s, l);
    setHexInput(hex);
    onColorChange(hex);
  }, [onColorChange]);

  // ─── Draw hue wheel ───
  useEffect(() => {
    const canvas = wheelRef.current;
    if (!canvas || mode !== "wheel") return;
    const size = canvas.width;
    const ctx = canvas.getContext("2d")!;
    const cx = size / 2, cy = size / 2;
    const outerR = size / 2 - 2;
    const innerR = outerR - 20;
    ctx.clearRect(0, 0, size, size);
    for (let deg = 0; deg < 360; deg++) {
      const rad1 = ((deg - 0.5) * Math.PI) / 180;
      const rad2 = ((deg + 0.5) * Math.PI) / 180;
      ctx.beginPath();
      ctx.arc(cx, cy, outerR, rad1, rad2);
      ctx.arc(cx, cy, innerR, rad2, rad1, true);
      ctx.closePath();
      ctx.fillStyle = `hsl(${deg}, 100%, 50%)`;
      ctx.fill();
    }
    const hueRad = ((hsl[0] - 90) * Math.PI) / 180;
    const indR = (outerR + innerR) / 2;
    const indX = cx + Math.cos(hueRad) * indR;
    const indY = cy + Math.sin(hueRad) * indR;
    ctx.beginPath(); ctx.arc(indX, indY, 7, 0, Math.PI * 2);
    ctx.strokeStyle = "#fff"; ctx.lineWidth = 2; ctx.stroke();
    ctx.beginPath(); ctx.arc(indX, indY, 5, 0, Math.PI * 2);
    ctx.fillStyle = hslToHex(hsl[0], 100, 50); ctx.fill();
  }, [hsl, mode]);

  // ─── Draw sat/lightness square ───
  useEffect(() => {
    const canvas = satRef.current;
    if (!canvas || mode !== "wheel") return;
    const size = canvas.width;
    const ctx = canvas.getContext("2d")!;
    ctx.clearRect(0, 0, size, size);
    const gradH = ctx.createLinearGradient(0, 0, size, 0);
    gradH.addColorStop(0, "#fff");
    gradH.addColorStop(1, hslToHex(hsl[0], 100, 50));
    ctx.fillStyle = gradH; ctx.fillRect(0, 0, size, size);
    const gradV = ctx.createLinearGradient(0, 0, 0, size);
    gradV.addColorStop(0, "rgba(0,0,0,0)");
    gradV.addColorStop(1, "#000");
    ctx.fillStyle = gradV; ctx.fillRect(0, 0, size, size);
    const px = (hsl[1] / 100) * size;
    const py = (1 - hsl[2] / 100) * size;
    ctx.beginPath(); ctx.arc(px, py, 6, 0, Math.PI * 2);
    ctx.strokeStyle = "#fff"; ctx.lineWidth = 2; ctx.stroke();
    ctx.beginPath(); ctx.arc(px, py, 4, 0, Math.PI * 2);
    ctx.fillStyle = color; ctx.fill();
  }, [hsl, mode, color]);

  const handleWheelPointer = useCallback((e: React.PointerEvent) => {
    const canvas = wheelRef.current;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const cx = rect.width / 2, cy = rect.height / 2;
    const x = e.clientX - rect.left - cx, y = e.clientY - rect.top - cy;
    const dist = Math.sqrt(x * x + y * y);
    const outerR = rect.width / 2 - 2, innerR = outerR - 20;
    if (dist >= innerR && dist <= outerR) {
      isDraggingWheel.current = true;
      let deg = (Math.atan2(y, x) * 180) / Math.PI + 90;
      if (deg < 0) deg += 360;
      updateFromHsl(Math.round(deg), hsl[1], hsl[2]);
    }
  }, [hsl, updateFromHsl]);

  const handleWheelMove = useCallback((e: React.PointerEvent) => {
    if (!isDraggingWheel.current) return;
    const canvas = wheelRef.current;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const x = e.clientX - rect.left - rect.width / 2;
    const y = e.clientY - rect.top - rect.height / 2;
    let deg = (Math.atan2(y, x) * 180) / Math.PI + 90;
    if (deg < 0) deg += 360;
    updateFromHsl(Math.round(deg), hsl[1], hsl[2]);
  }, [hsl, updateFromHsl]);

  const handleSatPointer = useCallback((e: React.PointerEvent) => {
    isDraggingSat.current = true;
    const canvas = satRef.current;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const x = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
    const y = Math.max(0, Math.min(1, (e.clientY - rect.top) / rect.height));
    updateFromHsl(hsl[0], Math.round(x * 100), Math.round((1 - y) * 100));
  }, [hsl, updateFromHsl]);

  const handleSatMove = useCallback((e: React.PointerEvent) => {
    if (!isDraggingSat.current) return;
    const canvas = satRef.current;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const x = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
    const y = Math.max(0, Math.min(1, (e.clientY - rect.top) / rect.height));
    updateFromHsl(hsl[0], Math.round(x * 100), Math.round((1 - y) * 100));
  }, [hsl, updateFromHsl]);

  const handlePointerUp = useCallback(() => {
    isDraggingWheel.current = false;
    isDraggingSat.current = false;
  }, []);

  // ─── Harmony colors ───
  const harmonyColors = {
    complementary: hslToHex((hsl[0] + 180) % 360, hsl[1], hsl[2]),
    analogous1: hslToHex((hsl[0] + 30) % 360, hsl[1], hsl[2]),
    analogous2: hslToHex((hsl[0] + 330) % 360, hsl[1], hsl[2]),
    triadic1: hslToHex((hsl[0] + 120) % 360, hsl[1], hsl[2]),
    triadic2: hslToHex((hsl[0] + 240) % 360, hsl[1], hsl[2]),
    splitComp1: hslToHex((hsl[0] + 150) % 360, hsl[1], hsl[2]),
    splitComp2: hslToHex((hsl[0] + 210) % 360, hsl[1], hsl[2]),
  };

  const MODES: { mode: ColorPickerMode; label: string }[] = [
    { mode: "wheel", label: "Wheel" },
    { mode: "classic", label: "Classic" },
    { mode: "harmony", label: "Harmony" },
    { mode: "value", label: "Value" },
    { mode: "swatches", label: "Swatch" },
  ];

  const wrapperClass = inline
    ? "p-3"
    : "absolute bottom-full left-0 mb-2 bg-[#111118] border border-[#2a2a3a] rounded-xl shadow-2xl p-3 w-72 z-50";

  return (
    <div className={wrapperClass} onClick={(e) => e.stopPropagation()} onPointerUp={handlePointerUp}>
      {/* Mode tabs */}
      <div className="flex gap-0.5 mb-3 bg-[#0a0a0f] rounded-lg p-0.5">
        {MODES.map(({ mode: m, label }) => (
          <button
            key={m}
            onClick={() => setMode(m)}
            className={`flex-1 py-1.5 text-[9px] rounded-md transition-all font-semibold uppercase tracking-wider ${
              mode === m
                ? "bg-red-600/20 text-red-400 shadow-sm"
                : "text-[#555] hover:text-[#9090a8]"
            }`}
          >
            {label}
          </button>
        ))}
      </div>

      {/* ─── WHEEL ─── */}
      {mode === "wheel" && (
        <div className="space-y-3">
          <div className="relative mx-auto" style={{ width: 170, height: 170 }}>
            <canvas ref={wheelRef} width={170} height={170}
              className="absolute inset-0 cursor-crosshair touch-none"
              onPointerDown={handleWheelPointer} onPointerMove={handleWheelMove} onPointerUp={handlePointerUp} />
            <canvas ref={satRef} width={90} height={90}
              className="absolute cursor-crosshair touch-none rounded-sm"
              style={{ left: 40, top: 40 }}
              onPointerDown={handleSatPointer} onPointerMove={handleSatMove} onPointerUp={handlePointerUp} />
          </div>
          <ColorSwatchRow color={color} previousColor={previousColor} hexInput={hexInput}
            setHexInput={setHexInput} onColorChange={onColorChange} onEyedropper={onEyedropper} />
        </div>
      )}

      {/* ─── CLASSIC (HSL sliders) ─── */}
      {mode === "classic" && (
        <div className="space-y-2.5">
          <div>
            <div className="flex justify-between mb-0.5">
              <span className="text-[10px] text-[#555]">Hue</span>
              <span className="text-[10px] text-white font-mono">{hsl[0]}°</span>
            </div>
            <input type="range" min={0} max={360} value={hsl[0]}
              onChange={(e) => updateFromHsl(+e.target.value, hsl[1], hsl[2])}
              className="w-full h-2 rounded-full appearance-none cursor-pointer"
              style={{ background: "linear-gradient(to right, #f00, #ff0, #0f0, #0ff, #00f, #f0f, #f00)" }} />
          </div>
          <div>
            <div className="flex justify-between mb-0.5">
              <span className="text-[10px] text-[#555]">Saturation</span>
              <span className="text-[10px] text-white font-mono">{hsl[1]}%</span>
            </div>
            <input type="range" min={0} max={100} value={hsl[1]}
              onChange={(e) => updateFromHsl(hsl[0], +e.target.value, hsl[2])}
              className="w-full accent-red-600 h-1.5" />
          </div>
          <div>
            <div className="flex justify-between mb-0.5">
              <span className="text-[10px] text-[#555]">Lightness</span>
              <span className="text-[10px] text-white font-mono">{hsl[2]}%</span>
            </div>
            <input type="range" min={0} max={100} value={hsl[2]}
              onChange={(e) => updateFromHsl(hsl[0], hsl[1], +e.target.value)}
              className="w-full accent-red-600 h-1.5" />
          </div>
          <ColorSwatchRow color={color} previousColor={previousColor} hexInput={hexInput}
            setHexInput={setHexInput} onColorChange={onColorChange} onEyedropper={onEyedropper} />
        </div>
      )}

      {/* ─── HARMONY ─── */}
      {mode === "harmony" && (
        <div className="space-y-3">
          {/* Current color large swatch */}
          <div className="flex items-center gap-2">
            <div className="w-10 h-10 rounded-lg border border-[#2a2a3a]" style={{ backgroundColor: color }} />
            <div className="text-xs text-[#9090a8]">
              <p className="text-white font-medium">Current</p>
              <p className="font-mono text-[10px]">{color}</p>
            </div>
          </div>

          {/* Harmony groups */}
          <HarmonyGroup label="Complementary" colors={[harmonyColors.complementary]} onPick={onColorChange} />
          <HarmonyGroup label="Analogous" colors={[harmonyColors.analogous1, harmonyColors.analogous2]} onPick={onColorChange} />
          <HarmonyGroup label="Triadic" colors={[harmonyColors.triadic1, harmonyColors.triadic2]} onPick={onColorChange} />
          <HarmonyGroup label="Split Complement" colors={[harmonyColors.splitComp1, harmonyColors.splitComp2]} onPick={onColorChange} />
        </div>
      )}

      {/* ─── VALUE (exact number input) ─── */}
      {mode === "value" && (
        <div className="space-y-3">
          {(() => {
            const [r, g, b] = hexToRgb(color);
            return (
              <>
                <div className="flex items-center gap-2">
                  <div className="w-10 h-10 rounded-lg border border-[#2a2a3a]" style={{ backgroundColor: color }} />
                  <input type="text" value={hexInput}
                    onChange={(e) => {
                      setHexInput(e.target.value);
                      if (/^#[0-9a-fA-F]{6}$/.test(e.target.value)) onColorChange(e.target.value);
                    }}
                    className="flex-1 bg-[#0a0a0f] border border-[#2a2a3a] rounded-lg px-2 py-1.5 text-sm text-white font-mono focus:outline-none focus:border-red-500" />
                </div>
                <div className="grid grid-cols-3 gap-2">
                  <NumberInput label="R" value={r} max={255}
                    onChange={(v) => onColorChange(rgbToHex(v, g, b))} accent="#dc2626" />
                  <NumberInput label="G" value={g} max={255}
                    onChange={(v) => onColorChange(rgbToHex(r, v, b))} accent="#22c55e" />
                  <NumberInput label="B" value={b} max={255}
                    onChange={(v) => onColorChange(rgbToHex(r, g, v))} accent="#3b82f6" />
                </div>
                <div className="grid grid-cols-3 gap-2">
                  <NumberInput label="H" value={hsl[0]} max={360}
                    onChange={(v) => updateFromHsl(v, hsl[1], hsl[2])} />
                  <NumberInput label="S" value={hsl[1]} max={100}
                    onChange={(v) => updateFromHsl(hsl[0], v, hsl[2])} />
                  <NumberInput label="L" value={hsl[2]} max={100}
                    onChange={(v) => updateFromHsl(hsl[0], hsl[1], v)} />
                </div>
              </>
            );
          })()}
        </div>
      )}

      {/* ─── SWATCHES ─── */}
      {mode === "swatches" && (
        <div className="space-y-3">
          {recentColors.length > 0 && (
            <SwatchGroup label="Recent" colors={recentColors} current={color} onPick={onColorChange} />
          )}
          <SwatchGroup label="Basics" colors={[
            "#000000", "#333333", "#666666", "#999999", "#cccccc", "#ffffff",
            "#dc2626", "#ef4444", "#f97316", "#eab308", "#22c55e", "#14b8a6",
            "#3b82f6", "#6366f1", "#a855f7", "#ec4899",
          ]} current={color} onPick={onColorChange} />
          <SwatchGroup label="Skin" colors={[
            "#fde8d0", "#f5d0a9", "#e8b88a", "#c9956b", "#a67856", "#855c41", "#6b4530", "#4a3020",
          ]} current={color} onPick={onColorChange} />
          <SwatchGroup label="StickDeath" colors={[
            "#dc2626", "#b91c1c", "#7f1d1d", "#450a0a",
            "#111118", "#1a1a2a", "#2a2a3a", "#0a0a0f",
            "#f5f5f4", "#a8a29e", "#78716c", "#44403c",
          ]} current={color} onPick={onColorChange} />
        </div>
      )}

      {/* Opacity slider (all modes) */}
      <div className="mt-3 pt-2 border-t border-[#1a1a2a]">
        <div className="flex items-center justify-between mb-0.5">
          <span className="text-[10px] text-[#555] uppercase tracking-wider">Opacity</span>
          <span className="text-[10px] text-white font-mono">{Math.round(opacity * 100)}%</span>
        </div>
        <input type="range" min={1} max={100} value={Math.round(opacity * 100)}
          onChange={(e) => onOpacityChange(+e.target.value / 100)}
          className="w-full accent-red-600 h-1.5" />
      </div>

      {!inline && (
        <button onClick={onClose}
          className="mt-2 w-full text-center text-xs text-[#555] hover:text-white py-1">
          Close
        </button>
      )}
    </div>
  );
}

// ─── Sub-components ───
function ColorSwatchRow({ color, previousColor, hexInput, setHexInput, onColorChange, onEyedropper }: {
  color: string; previousColor: string; hexInput: string;
  setHexInput: (v: string) => void; onColorChange: (c: string) => void; onEyedropper?: () => void;
}) {
  return (
    <div className="flex items-center gap-2">
      <div className="flex gap-1">
        <div className="w-7 h-7 rounded-md border border-[#2a2a3a]" style={{ backgroundColor: color }} title="Current" />
        <button className="w-7 h-7 rounded-md border border-[#2a2a3a] hover:border-[#3a3a4a]"
          style={{ backgroundColor: previousColor }} onClick={() => onColorChange(previousColor)} title="Previous" />
      </div>
      {onEyedropper && (
        <button onClick={onEyedropper}
          className="w-7 h-7 rounded-md border border-[#2a2a3a] flex items-center justify-center text-sm hover:border-[#3a3a4a] text-[#72728a] hover:text-white"
          title="Eyedropper">
          💧
        </button>
      )}
      <input type="text" value={hexInput}
        onChange={(e) => {
          setHexInput(e.target.value);
          if (/^#[0-9a-fA-F]{6}$/.test(e.target.value)) onColorChange(e.target.value);
        }}
        className="flex-1 bg-[#0a0a0f] border border-[#2a2a3a] rounded px-1.5 py-0.5 text-xs text-white font-mono focus:outline-none focus:border-red-500" />
    </div>
  );
}

function HarmonyGroup({ label, colors, onPick }: { label: string; colors: string[]; onPick: (c: string) => void }) {
  return (
    <div>
      <span className="text-[10px] text-[#555] uppercase tracking-wider">{label}</span>
      <div className="flex gap-1.5 mt-1">
        {colors.map((c, i) => (
          <button key={i} onClick={() => onPick(c)}
            className="flex-1 h-8 rounded-lg border border-[#2a2a3a] hover:border-white/30 transition-colors relative group"
            style={{ backgroundColor: c }}>
            <span className="absolute inset-x-0 -bottom-4 text-[8px] text-[#555] font-mono opacity-0 group-hover:opacity-100 transition-opacity">
              {c}
            </span>
          </button>
        ))}
      </div>
    </div>
  );
}

function SwatchGroup({ label, colors, current, onPick }: {
  label: string; colors: string[]; current: string; onPick: (c: string) => void;
}) {
  return (
    <div>
      <span className="text-[10px] text-[#555] uppercase tracking-wider">{label}</span>
      <div className="grid grid-cols-8 gap-1 mt-1">
        {colors.map((c, i) => (
          <button key={i} onClick={() => onPick(c)}
            className={`w-full aspect-square rounded-md border transition-all ${
              current === c ? "border-red-500 ring-1 ring-red-500/40 scale-110" : "border-[#2a2a3a] hover:border-[#3a3a4a]"
            }`}
            style={{ backgroundColor: c }} />
        ))}
      </div>
    </div>
  );
}

function NumberInput({ label, value, max, onChange, accent }: {
  label: string; value: number; max: number; onChange: (v: number) => void; accent?: string;
}) {
  return (
    <div>
      <span className="text-[10px] font-mono mb-0.5 block" style={{ color: accent || "#555" }}>{label}</span>
      <input type="number" min={0} max={max} value={value}
        onChange={(e) => onChange(Math.max(0, Math.min(max, +e.target.value)))}
        className="w-full bg-[#0a0a0f] border border-[#2a2a3a] rounded px-2 py-1 text-xs text-white font-mono focus:outline-none focus:border-red-500" />
    </div>
  );
}
