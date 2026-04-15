// StickDeath ∞ — FlipaClip-style Tool Strip
// Main tools + "..." overflow for Smudge/Blur
// Top floating toolbar: [V] [🖌] [🧽] [⭕] [🪣] [T] [···]

import { useState, useRef, useEffect } from "react";
import { MousePointer2, Paintbrush, Eraser, Lasso, PaintBucket, Type, MoreHorizontal, GripVertical, Droplets, Wind } from "lucide-react";
import type { ToolType } from "./types";

interface Props {
  activeTool: ToolType;
  onToolSelect: (t: ToolType) => void;
  onDragHandle?: () => void;
}

const MAIN_TOOLS: { tool: ToolType; icon: typeof Paintbrush; label: string; shortcut: string }[] = [
  { tool: "cursor", icon: MousePointer2, label: "Cursor", shortcut: "V" },
  { tool: "brush",  icon: Paintbrush,    label: "Brush",  shortcut: "B" },
  { tool: "eraser", icon: Eraser,        label: "Eraser", shortcut: "E" },
  { tool: "lasso",  icon: Lasso,         label: "Select", shortcut: "A" },
  { tool: "fill",   icon: PaintBucket,   label: "Fill",   shortcut: "F" },
  { tool: "text",   icon: Type,          label: "Text",   shortcut: "T" },
];

const OVERFLOW_TOOLS: { tool: ToolType; icon: typeof Paintbrush; label: string }[] = [
  { tool: "smudge", icon: Wind,     label: "SMUDGE" },
  { tool: "blur",   icon: Droplets, label: "BLUR" },
];

export default function StudioToolbar({ activeTool, onToolSelect, onDragHandle }: Props) {
  const [showOverflow, setShowOverflow] = useState(false);
  const overflowRef = useRef<HTMLDivElement>(null);

  // Check if active tool is in overflow
  const isOverflowActive = OVERFLOW_TOOLS.some(t => t.tool === activeTool);

  // Close overflow when clicking outside
  useEffect(() => {
    if (!showOverflow) return;
    const handleClick = (e: MouseEvent) => {
      if (overflowRef.current && !overflowRef.current.contains(e.target as Node)) {
        setShowOverflow(false);
      }
    };
    document.addEventListener("mousedown", handleClick);
    return () => document.removeEventListener("mousedown", handleClick);
  }, [showOverflow]);

  return (
    <div className="flex items-center justify-center px-2 py-1.5 bg-[#111118] border-b border-[#2a2a3a] shrink-0">
      {/* Floating pill toolbar (FlipaClip-style with rounded container) */}
      <div className="flex items-center gap-0.5 bg-[#1a1a24] rounded-2xl px-1.5 py-1 border border-[#2a2a3a]/50">
        {/* Drag handle */}
        <button
          onClick={onDragHandle}
          className="w-8 h-8 rounded-xl flex items-center justify-center text-[#555] hover:text-[#72728a] transition-colors"
        >
          <GripVertical size={16} />
        </button>

        {/* Main tools (now includes cursor) */}
        {MAIN_TOOLS.map(({ tool, icon: Icon, label, shortcut }) => (
          <button
            key={tool}
            onClick={() => { onToolSelect(tool); setShowOverflow(false); }}
            className={`w-10 h-10 rounded-xl flex items-center justify-center transition-all ${
              activeTool === tool
                ? "bg-[#ff2d55] text-white shadow-lg shadow-[#ff2d55]/20"
                : "text-[#72728a] hover:text-white hover:bg-white/5 active:bg-white/10"
            }`}
            title={`${label} (${shortcut})`}
          >
            <Icon size={20} />
          </button>
        ))}

        {/* "..." overflow menu for Smudge/Blur */}
        <div className="relative" ref={overflowRef}>
          <button
            onClick={() => setShowOverflow(!showOverflow)}
            className={`w-10 h-10 rounded-xl flex items-center justify-center transition-all ${
              isOverflowActive
                ? "bg-[#ff2d55] text-white shadow-lg shadow-[#ff2d55]/20"
                : "text-[#72728a] hover:text-white hover:bg-white/5"
            }`}
            title="More tools"
          >
            <MoreHorizontal size={20} />
          </button>

          {/* Overflow dropdown */}
          {showOverflow && (
            <div className="absolute top-full left-1/2 -translate-x-1/2 mt-2 bg-[#1a1a24] border border-[#2a2a3a] rounded-2xl shadow-2xl shadow-black/40 p-3 z-50 min-w-[160px]">
              <div className="flex items-center justify-center gap-6">
                {OVERFLOW_TOOLS.map(({ tool, icon: Icon, label }) => (
                  <button
                    key={tool}
                    onClick={() => { onToolSelect(tool); setShowOverflow(false); }}
                    className={`flex flex-col items-center gap-1.5 transition-all ${
                      activeTool === tool ? "text-white" : "text-[#72728a] hover:text-white"
                    }`}
                  >
                    <div className={`w-12 h-12 rounded-xl flex items-center justify-center ${
                      activeTool === tool ? "bg-[#ff2d55]/20 ring-1 ring-[#ff2d55]/40" : "hover:bg-white/5"
                    }`}>
                      <Icon size={24} />
                    </div>
                    <span className="text-[10px] font-bold tracking-wider">{label}</span>
                  </button>
                ))}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
