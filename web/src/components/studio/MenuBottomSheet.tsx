// StickDeath ∞ — Studio Menu Bottom Sheet (FlipaClip-exact)
// Matches IMG_1129: Project Settings, Frames Viewer, Onion, Grid, Magic Cut, Add Image, Add Video, Make Movie

import {
  Settings, LayoutGrid, Eye, Grid3X3, Wand2, ImagePlus, Video,
} from "lucide-react";

interface Props {
  visible: boolean;
  onClose: () => void;
  onionEnabled: boolean;
  onToggleOnion: () => void;
  onEditOnion: () => void;
  gridEnabled: boolean;
  onToggleGrid: () => void;
  onEditGrid: () => void;
  onProjectSettings: () => void;
  onFramesViewer: () => void;
  onMagicCut: () => void;
  onAddImage: () => void;
  onAddVideo: () => void;
  onMakeMovie: () => void;
}

export default function MenuBottomSheet({
  visible, onClose,
  onionEnabled, onToggleOnion, onEditOnion,
  gridEnabled, onToggleGrid, onEditGrid,
  onProjectSettings, onFramesViewer, onMagicCut,
  onAddImage, onAddVideo, onMakeMovie,
}: Props) {
  if (!visible) return null;

  return (
    <>
      {/* Backdrop */}
      <div
        className="fixed inset-0 bg-black/40 z-40 transition-opacity"
        onClick={onClose}
      />

      {/* Bottom sheet */}
      <div className="fixed bottom-0 left-0 right-0 z-50 bg-[#111118] rounded-t-3xl border-t border-[#2a2a3a] shadow-2xl shadow-black/60 max-h-[70vh] animate-slide-up">
        {/* Drag handle */}
        <div className="flex justify-center py-3">
          <div className="w-10 h-1 rounded-full bg-[#333]" />
        </div>

        {/* Menu items */}
        <div className="px-4 pb-6 space-y-0.5 overflow-y-auto" data-allow-scroll="true" style={{ touchAction: "pan-y" }}>

          {/* Project Settings */}
          <button
            onClick={() => { onProjectSettings(); onClose(); }}
            className="w-full flex items-center gap-4 px-4 py-4 rounded-xl hover:bg-white/5 active:bg-white/10 transition-colors"
          >
            <Settings size={22} className="text-[#9090a8]" />
            <span className="text-[15px] text-white font-medium">Project Settings</span>
          </button>

          <Divider />

          {/* Frames Viewer */}
          <button
            onClick={() => { onFramesViewer(); onClose(); }}
            className="w-full flex items-center gap-4 px-4 py-4 rounded-xl hover:bg-white/5 active:bg-white/10 transition-colors"
          >
            <LayoutGrid size={22} className="text-[#9090a8]" />
            <span className="text-[15px] text-white font-medium">Frames Viewer</span>
          </button>

          <Divider />

          {/* Onion — with toggle and Edit */}
          <div className="flex items-center gap-4 px-4 py-4">
            <Eye size={22} className="text-[#9090a8]" />
            <span className="text-[15px] text-white font-medium flex-1">Onion</span>
            <button
              onClick={onEditOnion}
              className="text-[#ff2d55] text-sm font-semibold px-2 py-1 hover:bg-[#ff2d55]/10 rounded-lg transition-colors"
            >
              Edit
            </button>
            <button
              onClick={onToggleOnion}
              className={`w-12 h-7 rounded-full transition-colors relative ${
                onionEnabled ? "bg-[#ff2d55]" : "bg-[#333]"
              }`}
            >
              <div className={`absolute top-0.5 w-6 h-6 rounded-full bg-white shadow transition-transform ${
                onionEnabled ? "translate-x-5" : "translate-x-0.5"
              }`} />
            </button>
          </div>

          <Divider />

          {/* Grid — with toggle and Edit */}
          <div className="flex items-center gap-4 px-4 py-4">
            <Grid3X3 size={22} className="text-[#9090a8]" />
            <span className="text-[15px] text-white font-medium flex-1">Grid</span>
            <button
              onClick={onEditGrid}
              className="text-[#ff2d55] text-sm font-semibold px-2 py-1 hover:bg-[#ff2d55]/10 rounded-lg transition-colors"
            >
              Edit
            </button>
            <button
              onClick={onToggleGrid}
              className={`w-12 h-7 rounded-full transition-colors relative ${
                gridEnabled ? "bg-[#ff2d55]" : "bg-[#333]"
              }`}
            >
              <div className={`absolute top-0.5 w-6 h-6 rounded-full bg-white shadow transition-transform ${
                gridEnabled ? "translate-x-5" : "translate-x-0.5"
              }`} />
            </button>
          </div>

          <Divider />

          {/* Magic Cut */}
          <button
            onClick={() => { onMagicCut(); onClose(); }}
            className="w-full flex items-center gap-4 px-4 py-4 rounded-xl hover:bg-white/5 active:bg-white/10 transition-colors"
          >
            <Wand2 size={22} className="text-[#9090a8]" />
            <span className="text-[15px] text-white font-medium">Magic Cut</span>
          </button>

          <Divider />

          {/* Add Image */}
          <button
            onClick={() => { onAddImage(); onClose(); }}
            className="w-full flex items-center gap-4 px-4 py-4 rounded-xl hover:bg-white/5 active:bg-white/10 transition-colors"
          >
            <ImagePlus size={22} className="text-[#9090a8]" />
            <span className="text-[15px] text-white font-medium">Add Image</span>
          </button>

          <Divider />

          {/* Add Video */}
          <button
            onClick={() => { onAddVideo(); onClose(); }}
            className="w-full flex items-center gap-4 px-4 py-4 rounded-xl hover:bg-white/5 active:bg-white/10 transition-colors"
          >
            <Video size={22} className="text-[#9090a8]" />
            <span className="text-[15px] text-white font-medium">Add Video</span>
          </button>

          <Divider />

          {/* Make Movie (big CTA button) */}
          <div className="pt-4 pb-2">
            <button
              onClick={() => { onMakeMovie(); onClose(); }}
              className="w-full py-4 rounded-2xl bg-[#ff2d55] text-white font-bold text-[16px] tracking-wide hover:bg-[#ff1a47] active:bg-[#e6003d] transition-colors shadow-lg shadow-[#ff2d55]/30"
            >
              Make Movie
            </button>
          </div>
        </div>
      </div>
    </>
  );
}

function Divider() {
  return <div className="mx-4 border-t border-[#1a1a2a]" />;
}
