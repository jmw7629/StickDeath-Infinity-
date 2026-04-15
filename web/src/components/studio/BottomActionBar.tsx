// StickDeath ∞ — Bottom Action Bar (FlipaClip-exact)
// Layout: AUDIO | UNDO | REDO | COPY | PASTE | LAYER
// Sits at the very bottom of the screen, below frame strip

import { Music, Undo2, Redo2, Copy, ClipboardPaste, Layers } from "lucide-react";

interface Props {
  canUndo: boolean;
  canRedo: boolean;
  onUndo: () => void;
  onRedo: () => void;
  onCopy: () => void;
  onPaste: () => void;
  hasCopied: boolean;
  onAudioTap: () => void;
  onLayerTap: () => void;
  layerCount: number;
}

export default function BottomActionBar({
  canUndo, canRedo, onUndo, onRedo,
  onCopy, onPaste, hasCopied,
  onAudioTap, onLayerTap, layerCount,
}: Props) {
  const actions = [
    { label: "AUDIO", icon: Music, onClick: onAudioTap, disabled: false, badge: null },
    { label: "UNDO", icon: Undo2, onClick: onUndo, disabled: !canUndo, badge: null },
    { label: "REDO", icon: Redo2, onClick: onRedo, disabled: !canRedo, badge: null },
    { label: "COPY", icon: Copy, onClick: onCopy, disabled: false, badge: null },
    { label: "PASTE", icon: ClipboardPaste, onClick: onPaste, disabled: !hasCopied, badge: null },
    { label: "LAYER", icon: Layers, onClick: onLayerTap, disabled: false, badge: layerCount },
  ];

  return (
    <div className="flex items-center justify-around px-1 py-1 bg-[#111118] border-t border-[#2a2a3a] shrink-0 safe-area-bottom">
      {actions.map(({ label, icon: Icon, onClick, disabled, badge }) => (
        <button
          key={label}
          onClick={onClick}
          disabled={disabled}
          className={`flex flex-col items-center gap-0.5 px-2 py-1 rounded-lg transition-colors min-w-[48px] ${
            disabled
              ? "text-[#333] cursor-default"
              : "text-[#72728a] hover:text-white active:text-white active:bg-white/5"
          }`}
        >
          <div className="relative">
            <Icon size={18} />
            {badge !== null && (
              <span className="absolute -top-1.5 -right-2 bg-[#ff2d55] text-white text-[8px] font-bold rounded-full w-3.5 h-3.5 flex items-center justify-center leading-none">
                {badge}
              </span>
            )}
          </div>
          <span className="text-[9px] font-semibold tracking-wider">{label}</span>
        </button>
      ))}
    </div>
  );
}
