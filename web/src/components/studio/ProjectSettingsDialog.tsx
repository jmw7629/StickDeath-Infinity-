// StickDeath ∞ — Project Settings Dialog
// FPS, project name, canvas size — matches FlipaClip Project Settings flow

import { useState, useEffect } from "react";
import { X, Check, Settings } from "lucide-react";

interface Props {
  open: boolean;
  onClose: () => void;
  projectName: string;
  fps: number;
  canvasWidth: number;
  canvasHeight: number;
  onSave: (settings: { projectName: string; fps: number; canvasWidth: number; canvasHeight: number }) => void;
}

const FPS_OPTIONS = [6, 8, 10, 12, 15, 24, 30];

const CANVAS_PRESETS = [
  { label: "TikTok / Reels (9:16)", w: 1080, h: 1920 },
  { label: "YouTube (16:9)", w: 1920, h: 1080 },
  { label: "Instagram Post (1:1)", w: 1080, h: 1080 },
  { label: "HD Portrait (3:4)", w: 1080, h: 1440 },
  { label: "Custom", w: 0, h: 0 },
];

export default function ProjectSettingsDialog({ open, onClose, projectName, fps, canvasWidth, canvasHeight, onSave }: Props) {
  const [name, setName] = useState(projectName);
  const [selectedFps, setSelectedFps] = useState(fps);
  const [width, setWidth] = useState(canvasWidth);
  const [height, setHeight] = useState(canvasHeight);
  const [isCustomSize, setIsCustomSize] = useState(false);

  useEffect(() => {
    if (open) {
      setName(projectName);
      setSelectedFps(fps);
      setWidth(canvasWidth);
      setHeight(canvasHeight);
      const matchesPreset = CANVAS_PRESETS.some(p => p.w === canvasWidth && p.h === canvasHeight);
      setIsCustomSize(!matchesPreset);
    }
  }, [open, projectName, fps, canvasWidth, canvasHeight]);

  const handleSave = () => {
    onSave({ projectName: name, fps: selectedFps, canvasWidth: width, canvasHeight: height });
    onClose();
  };

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm">
      <div className="bg-[#111118] border border-[#2a2a3a] rounded-2xl w-full max-w-md shadow-2xl mx-4">
        {/* Header */}
        <div className="flex items-center justify-between px-5 py-4 border-b border-[#2a2a3a]">
          <div className="flex items-center gap-2">
            <Settings size={18} className="text-red-500" />
            <h2 className="text-base font-bold text-white">Project Settings</h2>
          </div>
          <button onClick={onClose} className="text-[#72728a] hover:text-white transition-colors">
            <X size={18} />
          </button>
        </div>

        {/* Content */}
        <div className="px-5 py-4 space-y-5">
          {/* Project Name */}
          <div className="space-y-1.5">
            <label className="text-xs font-medium text-[#9090a8]">Project Name</label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              className="w-full bg-[#0a0a0f] border border-[#2a2a3a] rounded-lg px-3 py-2 text-sm text-white placeholder:text-[#555] focus:border-red-500/50 focus:outline-none"
              placeholder="My Animation"
            />
          </div>

          {/* FPS Selection */}
          <div className="space-y-2">
            <label className="text-xs font-medium text-[#9090a8]">Frames Per Second (FPS)</label>
            <div className="grid grid-cols-7 gap-1.5">
              {FPS_OPTIONS.map((f) => (
                <button
                  key={f}
                  onClick={() => setSelectedFps(f)}
                  className={`py-2 rounded-lg text-sm font-bold transition-all ${
                    selectedFps === f
                      ? "bg-red-600 text-white shadow-md shadow-red-600/30"
                      : "bg-[#1a1a24] text-[#72728a] hover:text-white hover:bg-[#2a2a3a] border border-[#2a2a3a]"
                  }`}
                >
                  {f}
                </button>
              ))}
            </div>
            <p className="text-[10px] text-[#555]">
              {selectedFps <= 8 && "Choppy — good for sketch/comic style"}
              {selectedFps > 8 && selectedFps <= 12 && "Industry standard — smooth with manageable frame count"}
              {selectedFps > 12 && selectedFps <= 15 && "Smooth — great balance of quality and effort"}
              {selectedFps > 15 && selectedFps <= 24 && "Very smooth — film standard, requires many frames"}
              {selectedFps > 24 && "Ultra smooth — lots of frames needed per second"}
            </p>
          </div>

          {/* Canvas Size */}
          <div className="space-y-2">
            <label className="text-xs font-medium text-[#9090a8]">Canvas Size</label>
            <div className="space-y-1.5">
              {CANVAS_PRESETS.map((preset) => {
                if (preset.w === 0) return null;
                const isSelected = !isCustomSize && width === preset.w && height === preset.h;
                return (
                  <button
                    key={preset.label}
                    onClick={() => { setWidth(preset.w); setHeight(preset.h); setIsCustomSize(false); }}
                    className={`w-full text-left px-3 py-2 rounded-lg text-xs transition-all flex items-center justify-between ${
                      isSelected
                        ? "bg-red-600/15 text-white border border-red-600/40"
                        : "bg-[#0a0a0f] text-[#72728a] hover:text-white hover:bg-[#1a1a24] border border-[#2a2a3a]"
                    }`}
                  >
                    <span>{preset.label}</span>
                    <span className="text-[10px] text-[#555]">{preset.w}×{preset.h}</span>
                  </button>
                );
              })}

              {/* Custom */}
              <button
                onClick={() => setIsCustomSize(true)}
                className={`w-full text-left px-3 py-2 rounded-lg text-xs transition-all ${
                  isCustomSize
                    ? "bg-red-600/15 text-white border border-red-600/40"
                    : "bg-[#0a0a0f] text-[#72728a] hover:text-white hover:bg-[#1a1a24] border border-[#2a2a3a]"
                }`}
              >
                Custom Size
              </button>
              {isCustomSize && (
                <div className="flex gap-2">
                  <div className="flex-1">
                    <label className="text-[10px] text-[#555]">Width</label>
                    <input
                      type="number"
                      value={width}
                      onChange={(e) => setWidth(Math.max(100, Math.min(4096, +e.target.value || 100)))}
                      className="w-full bg-[#0a0a0f] border border-[#2a2a3a] rounded px-2 py-1.5 text-xs text-white focus:border-red-500/50 focus:outline-none"
                    />
                  </div>
                  <div className="flex-1">
                    <label className="text-[10px] text-[#555]">Height</label>
                    <input
                      type="number"
                      value={height}
                      onChange={(e) => setHeight(Math.max(100, Math.min(4096, +e.target.value || 100)))}
                      className="w-full bg-[#0a0a0f] border border-[#2a2a3a] rounded px-2 py-1.5 text-xs text-white focus:border-red-500/50 focus:outline-none"
                    />
                  </div>
                </div>
              )}
            </div>
          </div>
        </div>

        {/* Footer */}
        <div className="flex items-center justify-end gap-2 px-5 py-3 border-t border-[#2a2a3a]">
          <button
            onClick={onClose}
            className="px-4 py-2 rounded-lg text-sm text-[#72728a] hover:text-white hover:bg-white/5 transition-colors"
          >
            Cancel
          </button>
          <button
            onClick={handleSave}
            className="flex items-center gap-1.5 px-4 py-2 rounded-lg text-sm font-bold bg-red-600 text-white hover:bg-red-700 transition-colors shadow-md shadow-red-600/20"
          >
            <Check size={14} />
            Save Changes
          </button>
        </div>
      </div>
    </div>
  );
}
