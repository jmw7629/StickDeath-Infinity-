// StickDeath ∞ — Layers Bottom Sheet (FlipaClip-exact)
// Matches IMG_1127: drag handles (≡), thumbnails, layer name, opacity %, expand arrow (>)
// Active layer highlighted with red accent, pink + button to add

import { useState } from "react";
import { GripHorizontal, ChevronRight, Plus, Eye, EyeOff, Lock, Unlock, Trash2, CopyPlus } from "lucide-react";
import type { LayerData } from "./types";

interface Props {
  visible: boolean;
  onClose: () => void;
  layers: LayerData[];
  activeLayerIndex: number;
  onSelectLayer: (index: number) => void;
  onAddLayer: () => void;
  onDeleteLayer: (index: number) => void;
  onToggleVisibility: (index: number) => void;
  onToggleLock: (index: number) => void;
  onOpacityChange: (index: number, opacity: number) => void;
  onReorder: (fromIndex: number, toIndex: number) => void;
  onMergeDown: (index: number) => void;
  onDuplicateLayer?: (index: number) => void;
}

export default function LayersPanel({
  visible, onClose, layers, activeLayerIndex,
  onSelectLayer, onAddLayer, onDeleteLayer,
  onToggleVisibility, onToggleLock, onOpacityChange,
  onReorder: _onReorder, onMergeDown: _onMergeDown, onDuplicateLayer,
}: Props) {
  const [expandedLayer, setExpandedLayer] = useState<number | null>(null);

  if (!visible) return null;

  // Display layers top-to-bottom (highest index first, like FlipaClip)
  const displayLayers = [...layers].reverse();

  return (
    <>
      {/* Backdrop */}
      <div
        className="fixed inset-0 bg-black/40 z-40"
        onClick={onClose}
      />

      {/* Bottom sheet */}
      <div className="fixed bottom-0 left-0 right-0 z-50 bg-[#111118] rounded-t-3xl border-t border-[#2a2a3a] shadow-2xl shadow-black/60 max-h-[50vh] animate-slide-up">
        {/* Drag handle */}
        <div className="flex justify-center py-3">
          <div className="w-10 h-1 rounded-full bg-[#333]" />
        </div>

        {/* Layer list */}
        <div
          className="overflow-y-auto pb-4"
          data-allow-scroll="true"
          style={{ touchAction: "pan-y", maxHeight: "calc(50vh - 80px)" }}
        >
          {displayLayers.map((layer) => {
            const realIndex = layers.findIndex(l => l.id === layer.id);
            const isActive = realIndex === activeLayerIndex;
            const isExpanded = expandedLayer === realIndex;

            return (
              <div key={layer.id}>
                {/* Main layer row */}
                <button
                  onClick={() => onSelectLayer(realIndex)}
                  className={`w-full flex items-center gap-3 px-3 py-3 transition-colors ${
                    isActive
                      ? "bg-[#ff2d55]/5 border-l-[3px] border-[#ff2d55]"
                      : "border-l-[3px] border-transparent hover:bg-white/3"
                  }`}
                >
                  {/* Drag handle */}
                  <div className="text-[#555] shrink-0 cursor-grab active:cursor-grabbing">
                    <GripHorizontal size={18} />
                  </div>

                  {/* Layer thumbnail (checkerboard for transparent) */}
                  <div className="w-14 h-10 rounded-lg overflow-hidden shrink-0 border border-[#2a2a3a] bg-[url('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAMUlEQVQ4T2NkYPj/n4EBFRgNpwcYGBkZsWuAMQbdAAZGRkb8BuAyYNANYGBkhAcVAMUhEBGIFHn/AAAAAElFTkSuQmCC')] bg-repeat">
                    {/* Placeholder thumbnail - would show actual layer content */}
                    <div className="w-full h-full" />
                  </div>

                  {/* Layer name */}
                  <span className={`flex-1 text-left text-sm font-medium ${
                    isActive ? "text-[#ff2d55]" : "text-white"
                  }`}>
                    {layer.name}
                  </span>

                  {/* Opacity */}
                  <span className={`text-sm tabular-nums ${
                    isActive ? "text-[#ff2d55]" : "text-[#72728a]"
                  }`}>
                    {Math.round(layer.opacity * 100)}%
                  </span>

                  {/* Expand arrow */}
                  <ChevronRight
                    size={18}
                    className={`text-[#555] transition-transform ${isExpanded ? "rotate-90" : ""}`}
                    onClick={(e) => {
                      e.stopPropagation();
                      setExpandedLayer(isExpanded ? null : realIndex);
                    }}
                  />
                </button>

                {/* Expanded layer settings */}
                {isExpanded && (
                  <div className="px-6 py-3 bg-[#0a0a0f] border-y border-[#1a1a2a] space-y-3">
                    {/* Opacity slider */}
                    <div className="flex items-center gap-3">
                      <span className="text-xs text-[#72728a] w-16">Opacity</span>
                      <input
                        type="range"
                        min={0}
                        max={100}
                        value={Math.round(layer.opacity * 100)}
                        onChange={(e) => onOpacityChange(realIndex, +e.target.value / 100)}
                        className="flex-1 accent-[#ff2d55] h-1"
                      />
                      <span className="text-xs text-white w-8 text-right tabular-nums">
                        {Math.round(layer.opacity * 100)}%
                      </span>
                    </div>

                    {/* Action buttons */}
                    <div className="flex items-center gap-2">
                      <button
                        onClick={() => onToggleVisibility(realIndex)}
                        className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs text-[#9090a8] hover:text-white hover:bg-white/5 transition-colors"
                      >
                        {layer.visible ? <Eye size={14} /> : <EyeOff size={14} />}
                        {layer.visible ? "Visible" : "Hidden"}
                      </button>
                      <button
                        onClick={() => onToggleLock(realIndex)}
                        className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs text-[#9090a8] hover:text-white hover:bg-white/5 transition-colors"
                      >
                        {layer.locked ? <Lock size={14} /> : <Unlock size={14} />}
                        {layer.locked ? "Locked" : "Unlocked"}
                      </button>
                      {onDuplicateLayer && (
                        <button
                          onClick={() => onDuplicateLayer(realIndex)}
                          className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs text-[#9090a8] hover:text-white hover:bg-white/5 transition-colors"
                        >
                          <CopyPlus size={14} /> Duplicate
                        </button>
                      )}
                      {layers.length > 1 && (
                        <button
                          onClick={() => onDeleteLayer(realIndex)}
                          className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs text-red-400 hover:text-red-300 hover:bg-red-500/10 transition-colors ml-auto"
                        >
                          <Trash2 size={14} /> Delete
                        </button>
                      )}
                    </div>
                  </div>
                )}
              </div>
            );
          })}
        </div>

        {/* Add layer button (pink +) */}
        <div className="flex justify-center py-3 border-t border-[#1a1a2a]">
          <button
            onClick={onAddLayer}
            className="text-[#ff2d55] hover:text-[#ff1a47] active:scale-95 transition-all"
          >
            <Plus size={28} strokeWidth={2.5} />
          </button>
        </div>
      </div>
    </>
  );
}
