// StickDeath ∞ — Frames Viewer (Grid View)
// Full-screen overlay showing all frames as thumbnails in a grid
// Tap a frame to jump to it, long-press for context menu

import { useState, useCallback, useRef } from "react";
import { X, Plus, Copy, Trash2, Grid3X3 } from "lucide-react";

interface FrameThumb {
  index: number;
  isEmpty: boolean;
  imageData?: string | null;
}

interface Props {
  open: boolean;
  onClose: () => void;
  frames: FrameThumb[];
  currentFrameIndex: number;
  onSelectFrame: (index: number) => void;
  onAddFrame: (afterIndex: number, duplicate?: boolean) => void;
  onDeleteFrame: (index: number) => void;
  onCopyFrame: (index: number) => void;
  fps: number;
}

export default function FramesViewer({
  open, onClose, frames, currentFrameIndex,
  onSelectFrame, onAddFrame, onDeleteFrame, onCopyFrame, fps,
}: Props) {
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number; index: number } | null>(null);
  const longPressTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const handleSelect = useCallback((index: number) => {
    onSelectFrame(index);
    onClose();
  }, [onSelectFrame, onClose]);

  const handleLongPress = useCallback((index: number, e: React.TouchEvent | React.MouseEvent) => {
    const clientX = "touches" in e ? e.touches[0].clientX : e.clientX;
    const clientY = "touches" in e ? e.touches[0].clientY : e.clientY;
    longPressTimer.current = setTimeout(() => {
      setContextMenu({ x: clientX, y: clientY, index });
    }, 500);
  }, []);

  const cancelLongPress = useCallback(() => {
    if (longPressTimer.current) {
      clearTimeout(longPressTimer.current);
      longPressTimer.current = null;
    }
  }, []);

  if (!open) return null;

  const totalDuration = (frames.length / fps).toFixed(1);

  return (
    <div className="fixed inset-0 z-50 flex flex-col bg-[#0a0a0f]/95 backdrop-blur-md">
      {/* Header */}
      <div className="flex items-center justify-between px-4 py-3 border-b border-[#2a2a3a] shrink-0">
        <div className="flex items-center gap-2">
          <Grid3X3 size={18} className="text-red-500" />
          <h2 className="text-base font-bold text-white">Frames Viewer</h2>
        </div>
        <div className="flex items-center gap-3">
          <span className="text-xs text-[#72728a]">
            {frames.length} frames · {fps} FPS · {totalDuration}s
          </span>
          <button onClick={onClose} className="text-[#72728a] hover:text-white transition-colors">
            <X size={20} />
          </button>
        </div>
      </div>

      {/* Frame grid */}
      <div className="flex-1 overflow-y-auto p-3" data-allow-scroll="true">
        <div className="grid grid-cols-4 gap-2 sm:grid-cols-5 md:grid-cols-6">
          {frames.map((frame, i) => (
            <button
              key={i}
              onClick={() => handleSelect(i)}
              onContextMenu={(e) => { e.preventDefault(); setContextMenu({ x: e.clientX, y: e.clientY, index: i }); }}
              onMouseDown={(e) => handleLongPress(i, e)}
              onMouseUp={cancelLongPress}
              onMouseLeave={cancelLongPress}
              onTouchStart={(e) => handleLongPress(i, e)}
              onTouchEnd={cancelLongPress}
              className={`relative aspect-[9/16] rounded-lg border-2 overflow-hidden transition-all ${
                currentFrameIndex === i
                  ? "border-red-500 shadow-lg shadow-red-500/20 ring-1 ring-red-500/30"
                  : "border-[#2a2a3a] hover:border-[#3a3a4a]"
              }`}
            >
              {frame.imageData ? (
                <img src={frame.imageData} alt="" className="w-full h-full object-contain bg-white/90" />
              ) : (
                <div className="w-full h-full bg-[#111118] flex items-center justify-center">
                  <span className="text-[#333] text-lg">{i + 1}</span>
                </div>
              )}
              {/* Frame number badge */}
              <div className={`absolute bottom-0 left-0 right-0 text-center py-0.5 text-[10px] font-bold ${
                currentFrameIndex === i ? "bg-red-600 text-white" : "bg-black/60 text-[#72728a]"
              }`}>
                {i + 1}
              </div>
              {/* Time marker */}
              <div className="absolute top-1 right-1">
                <span className="text-[8px] text-[#555] bg-black/40 px-1 rounded">
                  {((i / fps) * 1000).toFixed(0)}ms
                </span>
              </div>
            </button>
          ))}

          {/* Add frame button */}
          <button
            onClick={() => onAddFrame(frames.length - 1)}
            className="aspect-[9/16] rounded-lg border-2 border-dashed border-[#2a2a3a] hover:border-[#3a3a4a] flex flex-col items-center justify-center gap-1 transition-colors group"
          >
            <Plus size={24} className="text-[#555] group-hover:text-green-400" />
            <span className="text-[10px] text-[#555] group-hover:text-green-400">Add Frame</span>
          </button>
        </div>
      </div>

      {/* Context menu */}
      {contextMenu && (
        <>
          <div className="fixed inset-0 z-40" onClick={() => setContextMenu(null)} />
          <div
            className="fixed z-50 bg-[#111118] border border-[#2a2a3a] rounded-xl shadow-2xl py-1.5 min-w-44"
            style={{
              left: Math.min(contextMenu.x, window.innerWidth - 190),
              top: Math.min(contextMenu.y, window.innerHeight - 200),
            }}
          >
            <div className="px-3 py-1 text-[10px] text-[#555] font-medium">Frame {contextMenu.index + 1}</div>
            <button
              onClick={() => { handleSelect(contextMenu.index); setContextMenu(null); }}
              className="w-full px-3 py-2 text-xs text-left text-[#9090a8] hover:bg-white/5 hover:text-white flex items-center gap-2"
            >
              ▶ Go to Frame
            </button>
            <button
              onClick={() => { onAddFrame(contextMenu.index, false); setContextMenu(null); }}
              className="w-full px-3 py-2 text-xs text-left text-[#9090a8] hover:bg-white/5 hover:text-white flex items-center gap-2"
            >
              <Plus size={12} /> Insert After
            </button>
            <button
              onClick={() => { onAddFrame(contextMenu.index, true); setContextMenu(null); }}
              className="w-full px-3 py-2 text-xs text-left text-[#9090a8] hover:bg-white/5 hover:text-white flex items-center gap-2"
            >
              <Copy size={12} /> Duplicate
            </button>
            <button
              onClick={() => { onCopyFrame(contextMenu.index); setContextMenu(null); }}
              className="w-full px-3 py-2 text-xs text-left text-[#9090a8] hover:bg-white/5 hover:text-white flex items-center gap-2"
            >
              <Copy size={12} /> Copy
            </button>
            <div className="border-t border-[#1a1a2a] my-1" />
            <button
              onClick={() => { if (frames.length > 1) { onDeleteFrame(contextMenu.index); } setContextMenu(null); }}
              className={`w-full px-3 py-2 text-xs text-left flex items-center gap-2 ${
                frames.length > 1 ? "text-red-400 hover:bg-red-500/10" : "text-[#333] cursor-not-allowed"
              }`}
            >
              <Trash2 size={12} /> Delete
            </button>
          </div>
        </>
      )}
    </div>
  );
}
