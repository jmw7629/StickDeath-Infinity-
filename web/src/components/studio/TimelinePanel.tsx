// StickDeath ∞ — Frame Strip (FlipaClip-style)
// Simple horizontal strip: prev/next, play/pause, frame thumbnails
// FPS is in project settings (menu), NOT shown on strip
// Long-press frame for context menu

import { useCallback, useRef, useState, useEffect } from "react";
import {
  Play, Pause, Plus, Copy, Trash2,
  ChevronLeft, ChevronRight,
} from "lucide-react";

interface FrameThumb {
  index: number;
  isEmpty: boolean;
  imageData?: string | null;
}

interface Props {
  frames: FrameThumb[];
  currentFrameIndex: number;
  setCurrentFrameIndex: (i: number) => void;
  onAddFrame: (afterIndex: number, duplicate?: boolean) => void;
  onDeleteFrame: (index: number) => void;
  onCopyFrame: (index: number) => void;
  onPasteFrame: (afterIndex: number) => void;
  hasCopiedFrame: boolean;
  isPlaying: boolean;
  setIsPlaying: (p: boolean) => void;
}

export default function TimelinePanel({
  frames, currentFrameIndex, setCurrentFrameIndex,
  onAddFrame, onDeleteFrame, onCopyFrame, onPasteFrame, hasCopiedFrame,
  isPlaying, setIsPlaying,
}: Props) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number; index: number } | null>(null);
  const longPressTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Auto-scroll to keep current frame visible
  useEffect(() => {
    if (scrollRef.current) {
      const el = scrollRef.current.children[currentFrameIndex] as HTMLElement;
      if (el) el.scrollIntoView({ behavior: "smooth", block: "nearest", inline: "center" });
    }
  }, [currentFrameIndex]);

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

  const handleContextMenuNative = useCallback((e: React.MouseEvent, index: number) => {
    e.preventDefault();
    setContextMenu({ x: e.clientX, y: e.clientY, index });
  }, []);

  return (
    <div className="bg-[#111118] border-t border-[#2a2a3a] shrink-0">
      <div className="flex items-center gap-1.5 px-2 py-1.5">
        {/* Transport: prev, play, next */}
        <button
          onClick={() => setCurrentFrameIndex(Math.max(0, currentFrameIndex - 1))}
          className="w-7 h-7 rounded-md flex items-center justify-center text-[#72728a] hover:text-white hover:bg-white/5 transition-colors shrink-0"
          title="Previous frame (←)"
        >
          <ChevronLeft size={16} />
        </button>

        <button
          onClick={() => setIsPlaying(!isPlaying)}
          className={`w-8 h-8 rounded-full flex items-center justify-center transition-all shrink-0 ${
            isPlaying ? "bg-red-600 text-white shadow-md shadow-red-600/30" : "bg-white/10 text-white hover:bg-white/20"
          }`}
          title="Play/Pause (Space)"
        >
          {isPlaying ? <Pause size={14} /> : <Play size={14} className="ml-0.5" />}
        </button>

        <button
          onClick={() => setCurrentFrameIndex(Math.min(frames.length - 1, currentFrameIndex + 1))}
          className="w-7 h-7 rounded-md flex items-center justify-center text-[#72728a] hover:text-white hover:bg-white/5 transition-colors shrink-0"
          title="Next frame (→)"
        >
          <ChevronRight size={16} />
        </button>

        {/* Separator */}
        <div className="w-px h-6 bg-[#2a2a3a] mx-0.5 shrink-0" />

        {/* Frame strip — scrollable */}
        <div
          ref={scrollRef}
          className="flex items-center gap-1 overflow-x-auto flex-1 scrollbar-none"
          data-allow-scroll="true"
          style={{ touchAction: "pan-x" }}
        >
          {frames.map((frame, i) => (
            <button
              key={i}
              onClick={() => setCurrentFrameIndex(i)}
              onContextMenu={(e) => handleContextMenuNative(e, i)}
              onMouseDown={(e) => handleLongPress(i, e)}
              onMouseUp={cancelLongPress}
              onMouseLeave={cancelLongPress}
              onTouchStart={(e) => handleLongPress(i, e)}
              onTouchEnd={cancelLongPress}
              className={`flex-shrink-0 w-12 h-10 rounded border-2 transition-all relative overflow-hidden ${
                currentFrameIndex === i
                  ? "border-red-500 shadow-md shadow-red-500/20"
                  : "border-[#2a2a3a] hover:border-[#3a3a4a]"
              }`}
            >
              {frame.imageData ? (
                <img src={frame.imageData} alt="" className="w-full h-full object-contain bg-white/90" />
              ) : (
                <div className="w-full h-full bg-[#0a0a0f] flex items-center justify-center">
                  <span className="text-[9px] text-[#333]">{i + 1}</span>
                </div>
              )}
              {/* Frame number */}
              <span className={`absolute bottom-0 left-0 right-0 text-center text-[7px] leading-tight py-px ${
                currentFrameIndex === i ? "bg-red-600/90 text-white" : "bg-black/50 text-[#72728a]"
              }`}>
                {i + 1}
              </span>
            </button>
          ))}
        </div>

        {/* Separator */}
        <div className="w-px h-6 bg-[#2a2a3a] mx-0.5 shrink-0" />

        {/* Add frame */}
        <button
          onClick={() => onAddFrame(currentFrameIndex)}
          className="w-8 h-8 rounded-md flex items-center justify-center text-[#72728a] hover:text-green-400 hover:bg-green-500/10 transition-all shrink-0"
          title="Add frame"
        >
          <Plus size={16} />
        </button>

        {/* Frame counter */}
        <span className="text-[10px] text-[#555] font-mono shrink-0 w-8 text-center">
          {currentFrameIndex + 1}/{frames.length}
        </span>
      </div>

      {/* Context menu (long-press / right-click) */}
      {contextMenu && (
        <>
          <div className="fixed inset-0 z-40" onClick={() => setContextMenu(null)} />
          <div
            className="fixed z-50 bg-[#111118] border border-[#2a2a3a] rounded-xl shadow-2xl py-1.5 min-w-40"
            style={{ left: Math.min(contextMenu.x, window.innerWidth - 170), top: contextMenu.y - 220 }}
          >
            <div className="px-3 py-1 text-[10px] text-[#555] font-medium">Frame {contextMenu.index + 1}</div>
            <button
              onClick={() => { onAddFrame(contextMenu.index); setContextMenu(null); }}
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
            {hasCopiedFrame && (
              <button
                onClick={() => { onPasteFrame(contextMenu.index); setContextMenu(null); }}
                className="w-full px-3 py-2 text-xs text-left text-[#9090a8] hover:bg-white/5 hover:text-white flex items-center gap-2"
              >
                📋 Paste After
              </button>
            )}
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
