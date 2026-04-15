// StickDeath ∞ — Studio Editor (FlipaClip-exact layout)
//
// Layout top→bottom (matching FlipaClip screenshots):
// ┌───────────────────────────────────────┐
// │  [←]  Project Name        [⬆] [⋯]    │  Top bar (share + 3-dot menu)
// ├───────────────────────────────────────┤
// │  [V][🖌][🧽][⭕][🪣][T][···]         │  Floating pill toolbar + overflow
// ├───────────────────────────────────────┤
// │                                       │
// │             CANVAS                    │  Canvas (ALL remaining space)
// │             (white bg)                │
// │                                       │
// ├───────────────────────────────────────┤
// │  [🎨] [━━━ Size ━━━] [🧅][📐]        │  Persistent tool options
// ├───────────────────────────────────────┤
// │  ◀ ▶ ⏯  [f1][f2][f3]...  [+] 1/12   │  Frame strip
// ├───────────────────────────────────────┤
// │ AUDIO  UNDO  REDO  COPY  PASTE  LAYER│  Bottom action bar
// └───────────────────────────────────────┘
//
// Overlays (slide-up sheets):
// - MenuBottomSheet: Project Settings, Frames Viewer, Onion, Grid, Magic Cut, etc.
// - LayersPanel: bottom sheet with drag handles, thumbnails, opacity
// - ImageVault: full-screen asset browser
// - SoundVault: full-screen sound browser
// - ToolSettingsOverlay: expanded settings when tapping active tool again
// - ColorPicker: when tapping color swatch
// - SpatterStudioPanel: from 3-dot menu
// - ProjectSettingsDialog: FPS, name, canvas size
// - FramesViewer: grid view of all frames

import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { ArrowLeft, MoreHorizontal, Upload } from "lucide-react";
import StudioCanvas from "@/components/studio/StudioCanvas";
import StudioToolbar from "@/components/studio/StudioToolbar";
import ToolOptionsBar from "@/components/studio/ToolOptionsBar";
import ToolSettingsOverlay from "@/components/studio/ToolSettingsOverlay";
import TimelinePanel from "@/components/studio/TimelinePanel";
import LayersPanel from "@/components/studio/LayersPanel";
import BottomActionBar from "@/components/studio/BottomActionBar";
import MenuBottomSheet from "@/components/studio/MenuBottomSheet";
import ImageVault from "@/components/studio/ImageVault";
import SoundVault from "@/components/studio/SoundVault";
import SpatterStudioPanel from "@/components/studio/SpatterStudioPanel";
import ExportDialog from "@/components/studio/ExportDialog";
import ProjectSettingsDialog from "@/components/studio/ProjectSettingsDialog";
import FramesViewer from "@/components/studio/FramesViewer";
import { useStudioState } from "@/components/studio/useStudioState";
import type { FrameData, InsertedImage } from "@/components/studio/types";

export default function StudioPage() {
  const navigate = useNavigate();
  const studio = useStudioState();
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const playIntervalRef = useRef<number | null>(null);

  // ─── Panel/overlay state ───
  const [copiedFrame, setCopiedFrame] = useState<FrameData | null>(null);
  const [showSpatter, setShowSpatter] = useState(false);
  const [showExport, setShowExport] = useState(false);
  const [showMenu, setShowMenu] = useState(false);
  const [showLayers, setShowLayers] = useState(false);
  const [showImageVault, setShowImageVault] = useState(false);
  const [showSoundVault, setShowSoundVault] = useState(false);
  const [showProjectSettings, setShowProjectSettings] = useState(false);
  const [showFramesViewer, setShowFramesViewer] = useState(false);
  const [hasCopiedContent, setHasCopiedContent] = useState(false);

  // ─── Inserted image state (moveable overlay on canvas) ───
  const [insertedImage, setInsertedImage] = useState<InsertedImage | null>(null);

  // ─── Project-level state (synced with useStudioState where possible) ───
  const [projectName, setProjectName] = useState("Untitled Animation");

  // ─── Canvas callbacks ───
  const onCanvasReady = useCallback((canvas: HTMLCanvasElement) => {
    canvasRef.current = canvas;
  }, []);

  const onStrokeStart = useCallback(() => {
    if (!canvasRef.current || !studio.activeLayer) return;
    const data = canvasRef.current.toDataURL();
    studio.pushUndo(studio.currentFrameIndex, studio.activeLayer.id, data);
  }, [studio]);

  const onStrokeEnd = useCallback(
    (imageData: string) => {
      if (!studio.activeLayer) return;
      studio.updateFrameLayer(studio.currentFrameIndex, studio.activeLayer.id, imageData);
    },
    [studio],
  );

  // ─── Undo / Redo ───
  const handleUndo = useCallback(() => {
    if (!canvasRef.current || !studio.activeLayer) return;
    const currentData = canvasRef.current.toDataURL();
    const previous = studio.undo(studio.currentFrameIndex, studio.activeLayer.id, currentData);
    if (previous) studio.updateFrameLayer(studio.currentFrameIndex, studio.activeLayer.id, previous);
  }, [studio]);

  const handleRedo = useCallback(() => {
    if (!canvasRef.current || !studio.activeLayer) return;
    const currentData = canvasRef.current.toDataURL();
    const next = studio.redo(studio.currentFrameIndex, studio.activeLayer.id, currentData);
    if (next) studio.updateFrameLayer(studio.currentFrameIndex, studio.activeLayer.id, next);
  }, [studio]);

  // ─── Copy/paste frames ───
  const handleCopyFrame = useCallback((index: number) => {
    setCopiedFrame(studio.copyFrame(index));
  }, [studio]);

  const handlePasteFrame = useCallback((afterIndex: number) => {
    if (copiedFrame) studio.pasteFrame(copiedFrame, afterIndex);
  }, [copiedFrame, studio]);

  // ─── Bottom action bar handlers ───
  const handleCopy = useCallback(() => {
    handleCopyFrame(studio.currentFrameIndex);
    setHasCopiedContent(true);
  }, [handleCopyFrame, studio.currentFrameIndex]);

  const handlePaste = useCallback(() => {
    if (copiedFrame) {
      handlePasteFrame(studio.currentFrameIndex);
    }
  }, [copiedFrame, handlePasteFrame, studio.currentFrameIndex]);

  // ─── Image vault handler — creates floating inserted image ───
  const handleSelectImage = useCallback((url: string, name: string) => {
    // Load image to get natural dimensions
    const img = new window.Image();
    img.onload = () => {
      // Scale image to fit nicely on canvas (max 60% of canvas size)
      const maxW = 1080 * 0.6;
      const maxH = 1920 * 0.6;
      let w = img.naturalWidth || 400;
      let h = img.naturalHeight || 400;
      if (w > maxW || h > maxH) {
        const scale = Math.min(maxW / w, maxH / h);
        w = w * scale;
        h = h * scale;
      }
      // Center on canvas
      const x = (1080 - w) / 2;
      const y = (1920 - h) / 2;
      setInsertedImage({ url, name, x, y, width: w, height: h, rotation: 0, committed: false });
    };
    img.onerror = () => {
      // Fallback: use SVG inline data as-is with default size
      setInsertedImage({
        url, name,
        x: 1080 * 0.2, y: 1920 * 0.2,
        width: 1080 * 0.6, height: 1080 * 0.6,
        rotation: 0, committed: false,
      });
    };

    // For data URIs and SVG inline, set src directly
    if (url.startsWith("data:") || url.startsWith("http")) {
      img.src = url;
    } else {
      // SVG string — wrap in data URI
      const svgDataUrl = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(url)}`;
      img.src = svgDataUrl;
      // Update the URL in insertedImage to the data URI form
      setInsertedImage(prev => prev ? { ...prev, url: svgDataUrl } : null);
    }

    setShowImageVault(false);
  }, []);

  // ─── Commit inserted image to canvas ───
  const handleCommitInsertedImage = useCallback(() => {
    if (!insertedImage || !canvasRef.current) return;
    const canvas = canvasRef.current;
    const ctx = canvas.getContext("2d")!;

    // Save undo state
    if (studio.activeLayer) {
      studio.pushUndo(studio.currentFrameIndex, studio.activeLayer.id, canvas.toDataURL());
    }

    // Draw the image onto the canvas at its current position/size
    const img = new window.Image();
    img.onload = () => {
      ctx.drawImage(img, insertedImage.x, insertedImage.y, insertedImage.width, insertedImage.height);
      // Save the result
      if (studio.activeLayer) {
        studio.updateFrameLayer(studio.currentFrameIndex, studio.activeLayer.id, canvas.toDataURL());
      }
      setInsertedImage(null);
    };
    img.onerror = () => {
      console.error("Failed to commit inserted image");
      setInsertedImage(null);
    };
    img.crossOrigin = "anonymous";
    img.src = insertedImage.url;
  }, [insertedImage, studio]);

  // ─── Sound vault handler ───
  const handleSelectSound = useCallback((_sound: unknown) => {
    // TODO: Add sound to audio tracks
    setShowSoundVault(false);
  }, []);

  // ─── Project settings save handler ───
  const handleSaveProjectSettings = useCallback((settings: { projectName: string; fps: number; canvasWidth: number; canvasHeight: number }) => {
    setProjectName(settings.projectName);
    studio.setFps(settings.fps);
    // Note: canvas size change would require more complex handling (resize all frames)
    // For now we store it but don't resize existing content
  }, [studio]);

  // ─── Dismiss ALL overlays on canvas tap ───
  const handleCanvasTap = useCallback(() => {
    studio.setShowToolSettings(false);
    studio.setShowColorPicker(false);
  }, [studio]);

  // ─── Lock viewport on mobile (prevent page scroll while drawing) ───
  useEffect(() => {
    const prevOverflow = document.body.style.overflow;
    const prevPosition = document.body.style.position;
    const prevWidth = document.body.style.width;
    const prevHeight = document.body.style.height;
    const prevTouchAction = document.body.style.touchAction;
    const prevOverscroll = document.body.style.overscrollBehavior;

    document.body.style.overflow = "hidden";
    document.body.style.position = "fixed";
    document.body.style.width = "100%";
    document.body.style.height = "100%";
    document.body.style.touchAction = "none";
    document.body.style.overscrollBehavior = "none";

    const html = document.documentElement;
    const prevHtmlOverflow = html.style.overflow;
    const prevHtmlOverscroll = html.style.overscrollBehavior;
    html.style.overflow = "hidden";
    html.style.overscrollBehavior = "none";

    const preventOverscroll = (e: TouchEvent) => {
      const target = e.target as HTMLElement;
      const scrollable = target.closest("[data-allow-scroll]");
      if (!scrollable) {
        e.preventDefault();
      }
    };

    const preventGesture = (e: Event) => { e.preventDefault(); };

    document.addEventListener("touchmove", preventOverscroll, { passive: false });
    document.addEventListener("gesturestart", preventGesture, { passive: false });

    return () => {
      document.body.style.overflow = prevOverflow;
      document.body.style.position = prevPosition;
      document.body.style.width = prevWidth;
      document.body.style.height = prevHeight;
      document.body.style.touchAction = prevTouchAction;
      document.body.style.overscrollBehavior = prevOverscroll;
      html.style.overflow = prevHtmlOverflow;
      html.style.overscrollBehavior = prevHtmlOverscroll;
      document.removeEventListener("touchmove", preventOverscroll);
      document.removeEventListener("gesturestart", preventGesture);
    };
  }, []);

  // ─── Keyboard shortcuts ───
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement || e.target instanceof HTMLSelectElement) return;
      const key = e.key.toLowerCase();
      const meta = e.metaKey || e.ctrlKey;

      if (meta && key === "z" && e.shiftKey) { e.preventDefault(); handleRedo(); }
      else if (meta && key === "z") { e.preventDefault(); handleUndo(); }
      else if (meta && key === "c") { e.preventDefault(); handleCopy(); }
      else if (meta && key === "v") { e.preventDefault(); handlePaste(); }
      else if (key === "v" && !meta) studio.setActiveTool("cursor");
      else if (key === "b") studio.setActiveTool("brush");
      else if (key === "e") studio.setActiveTool("eraser");
      else if (key === "a" && !meta) studio.setActiveTool("lasso");
      else if (key === "f") studio.setActiveTool("fill");
      else if (key === "t") studio.setActiveTool("text");
      else if (key === "g") studio.setGrid({ ...studio.grid, enabled: !studio.grid.enabled });
      else if (key === "o") studio.setOnionSkin({ ...studio.onionSkin, enabled: !studio.onionSkin.enabled });
      else if (key === " ") { e.preventDefault(); studio.setIsPlaying(!studio.isPlaying); }
      else if (key === "arrowright" || key === ".") studio.setCurrentFrameIndex(Math.min(studio.currentFrameIndex + 1, studio.frames.length - 1));
      else if (key === "arrowleft" || key === ",") studio.setCurrentFrameIndex(Math.max(studio.currentFrameIndex - 1, 0));
      else if (key === "arrowup") studio.setActiveLayerIndex(Math.min(studio.activeLayerIndex + 1, studio.layers.length - 1));
      else if (key === "arrowdown") studio.setActiveLayerIndex(Math.max(studio.activeLayerIndex - 1, 0));
      else if (key === "escape") {
        // Cancel inserted image or close overlays
        if (insertedImage) setInsertedImage(null);
        else if (showMenu) setShowMenu(false);
        else if (showLayers) setShowLayers(false);
        else if (showProjectSettings) setShowProjectSettings(false);
        else if (showFramesViewer) setShowFramesViewer(false);
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [handleUndo, handleRedo, handleCopy, handlePaste, studio, insertedImage, showMenu, showLayers, showProjectSettings, showFramesViewer]);

  // ─── Playback loop ───
  useEffect(() => {
    if (studio.isPlaying) {
      playIntervalRef.current = window.setInterval(() => {
        studio.setCurrentFrameIndex(
          studio.currentFrameIndex >= studio.frames.length - 1 ? 0 : studio.currentFrameIndex + 1,
        );
      }, 1000 / studio.fps);
    } else if (playIntervalRef.current) {
      clearInterval(playIntervalRef.current);
      playIntervalRef.current = null;
    }
    return () => { if (playIntervalRef.current) clearInterval(playIntervalRef.current); };
  }, [studio.isPlaying, studio.fps, studio.frames.length, studio.currentFrameIndex]);

  // ─── Derived data ───
  const currentLayerData = studio.getCurrentLayerData();
  const onionFramesBefore = studio.getOnionFrames("before");
  const onionFramesAfter = studio.getOnionFrames("after");
  const compositeLayers = studio.getCompositeLayerData();
  const framesThumbs = studio.frames.map((f, i) => ({
    index: i,
    isEmpty: f.layers.every((l) => l.isEmpty),
    imageData: f.layers.find((l) => l.layerId === studio.activeLayer?.id)?.imageData,
  }));

  return (
    <div className="fixed inset-0 flex flex-col bg-[#0a0a0f] overflow-hidden select-none" style={{ touchAction: "none", overscrollBehavior: "none" }}>

      {/* ═══════════════════════════════════════════
           TOP BAR — Clean like FlipaClip
           [←]  Project Name           [⬆] [⋯]
         ═══════════════════════════════════════════ */}
      <div className="flex items-center justify-between px-2 py-1.5 bg-[#111118] border-b border-[#2a2a3a] shrink-0">
        {/* Left: Back + project name */}
        <div className="flex items-center gap-1.5">
          <button
            onClick={() => navigate("/studio")}
            className="w-8 h-8 rounded-lg flex items-center justify-center text-[#72728a] hover:text-white hover:bg-white/5 transition-colors"
          >
            <ArrowLeft size={18} />
          </button>
          <button onClick={() => setShowProjectSettings(true)} className="min-w-0 text-left group">
            <h1 className="text-sm font-bold text-white font-['Special_Elite'] leading-tight truncate group-hover:text-[#ff2d55] transition-colors">
              {projectName}
            </h1>
            <p className="text-[9px] text-[#555] leading-tight">
              {studio.fps} FPS · {studio.frames.length} frames · {studio.layers.length} layers
            </p>
          </button>
        </div>

        {/* Right: Share + 3-dot menu */}
        <div className="flex items-center gap-1">
          {/* Share/Export */}
          <button
            onClick={() => setShowExport(true)}
            className="w-8 h-8 rounded-lg flex items-center justify-center text-[#ff2d55] hover:bg-[#ff2d55]/10 transition-colors"
          >
            <Upload size={16} />
          </button>

          {/* 3-dot menu → opens bottom sheet */}
          <button
            onClick={() => setShowMenu(!showMenu)}
            className="w-8 h-8 rounded-lg flex items-center justify-center text-[#72728a] hover:text-white hover:bg-white/5 transition-colors"
          >
            <MoreHorizontal size={18} />
          </button>
        </div>
      </div>

      {/* ═══════════════════════════════════════════
           TOOLBAR — Floating pill with cursor + overflow
           [V][🖌][🧽][⭕][🪣][T][···]
         ═══════════════════════════════════════════ */}
      <StudioToolbar
        activeTool={studio.activeTool}
        onToolSelect={studio.setActiveTool}
      />

      {/* ═══════════════════════════════════════════
           CANVAS AREA — fills ALL remaining space
           + Tool settings + Spatter overlays
         ═══════════════════════════════════════════ */}
      <div className="flex-1 relative overflow-hidden">
        <StudioCanvas
          tool={studio.activeTool}
          color={studio.brushColor}
          brushSize={studio.brushSettings.size}
          brushOpacity={studio.brushSettings.opacity}
          brushStabilizer={studio.brushSettings.stabilizer}
          brushType={studio.brushSettings.brushType}
          eraserSettings={studio.eraserSettings}
          fillSettings={studio.fillSettings}
          rulerMode={studio.rulerMode}
          grid={studio.grid}
          onionSkin={studio.onionSkin}
          onionFramesBefore={onionFramesBefore}
          onionFramesAfter={onionFramesAfter}
          currentFrameData={currentLayerData}
          layersBelow={compositeLayers.below}
          layersAbove={compositeLayers.above}
          onStrokeStart={onStrokeStart}
          onStrokeEnd={onStrokeEnd}
          onCanvasReady={onCanvasReady}
          selection={studio.selection}
          onSelectionChange={studio.setSelection}
          onCanvasTap={handleCanvasTap}
          insertedImage={insertedImage}
          onInsertedImageChange={setInsertedImage}
          onCommitInsertedImage={handleCommitInsertedImage}
        />

        {/* Expanded settings overlay (floats above ToolOptionsBar) */}
        <div className="absolute left-0 right-0 bottom-0">
          <ToolSettingsOverlay
            activeTool={studio.activeTool}
            visible={studio.showToolSettings}
            onClose={() => { studio.setShowToolSettings(false); studio.setShowColorPicker(false); }}
            brushColor={studio.brushColor}
            previousColor={studio.previousColor}
            recentColors={studio.recentColors}
            brushSettings={studio.brushSettings}
            onColorChange={studio.setBrushColor}
            onBrushSettingsChange={studio.setBrushSettings}
            eraserSettings={studio.eraserSettings}
            onEraserSettingsChange={studio.setEraserSettings}
            fillSettings={studio.fillSettings}
            onFillSettingsChange={studio.setFillSettings}
            rulerMode={studio.rulerMode}
            onRulerModeChange={studio.setRulerMode}
            showColorPicker={studio.showColorPicker}
            setShowColorPicker={studio.setShowColorPicker}
          />
        </div>

        {/* Spatter AI Panel */}
        {showSpatter && (
          <div className="absolute right-0 top-0 bottom-0 z-30">
            <SpatterStudioPanel
              frameCount={studio.frames.length}
              currentFrameIndex={studio.currentFrameIndex}
              layerCount={studio.layers.length}
              fps={studio.fps}
              onClose={() => setShowSpatter(false)}
            />
          </div>
        )}
      </div>

      {/* ═══════════════════════════════════════════
           TOOL OPTIONS BAR — PERSISTENT strip
         ═══════════════════════════════════════════ */}
      <ToolOptionsBar
        activeTool={studio.activeTool}
        brushColor={studio.brushColor}
        brushSettings={studio.brushSettings}
        onColorSwatchTap={() => {
          studio.setShowColorPicker(!studio.showColorPicker);
          studio.setShowToolSettings(false);
        }}
        onBrushSizeChange={(size) => studio.setBrushSettings({ ...studio.brushSettings, size })}
        eraserSettings={studio.eraserSettings}
        onEraserSizeChange={(size) => studio.setEraserSettings({ ...studio.eraserSettings, size })}
        fillSettings={studio.fillSettings}
        onFillToleranceChange={(t) => studio.setFillSettings({ ...studio.fillSettings, tolerance: t })}
        onionEnabled={studio.onionSkin.enabled}
        onToggleOnion={() => studio.setOnionSkin({ ...studio.onionSkin, enabled: !studio.onionSkin.enabled })}
        rulerMode={studio.rulerMode}
        onToggleRuler={() => studio.setRulerMode(studio.rulerMode === "off" ? "line" : "off")}
        hasSelection={studio.selection !== null}
        onDeleteSelection={() => studio.setSelection(null)}
        onCopySelection={() => {}}
        onSelectAll={() => {}}
      />

      {/* ═══════════════════════════════════════════
           FRAME STRIP — transport + thumbnails
         ═══════════════════════════════════════════ */}
      <TimelinePanel
        frames={framesThumbs}
        currentFrameIndex={studio.currentFrameIndex}
        setCurrentFrameIndex={studio.setCurrentFrameIndex}
        onAddFrame={studio.addFrame}
        onDeleteFrame={studio.deleteFrame}
        onCopyFrame={handleCopyFrame}
        onPasteFrame={handlePasteFrame}
        hasCopiedFrame={copiedFrame !== null}
        isPlaying={studio.isPlaying}
        setIsPlaying={studio.setIsPlaying}
      />

      {/* ═══════════════════════════════════════════
           BOTTOM ACTION BAR (FlipaClip-exact)
           AUDIO | UNDO | REDO | COPY | PASTE | LAYER
         ═══════════════════════════════════════════ */}
      <BottomActionBar
        canUndo={studio.canUndo}
        canRedo={studio.canRedo}
        onUndo={handleUndo}
        onRedo={handleRedo}
        onCopy={handleCopy}
        onPaste={handlePaste}
        hasCopied={hasCopiedContent || copiedFrame !== null}
        onAudioTap={() => setShowSoundVault(true)}
        onLayerTap={() => setShowLayers(true)}
        layerCount={studio.layers.length}
      />

      {/* ═══════════════════════════════════════════
           OVERLAY SHEETS (z-index stacking)
         ═══════════════════════════════════════════ */}

      {/* Menu Bottom Sheet (3-dot menu) — ALL items wired */}
      <MenuBottomSheet
        visible={showMenu}
        onClose={() => setShowMenu(false)}
        onionEnabled={studio.onionSkin.enabled}
        onToggleOnion={() => studio.setOnionSkin({ ...studio.onionSkin, enabled: !studio.onionSkin.enabled })}
        onEditOnion={() => {
          setShowMenu(false);
          studio.setShowToolSettings(true);
        }}
        gridEnabled={studio.grid.enabled}
        onToggleGrid={() => studio.setGrid({ ...studio.grid, enabled: !studio.grid.enabled })}
        onEditGrid={() => {
          setShowMenu(false);
          studio.setShowToolSettings(true);
        }}
        onProjectSettings={() => {
          setShowMenu(false);
          setShowProjectSettings(true);
        }}
        onFramesViewer={() => {
          setShowMenu(false);
          setShowFramesViewer(true);
        }}
        onMagicCut={() => {
          setShowMenu(false);
          // Magic Cut: select all content on current layer (like cursor tool select-all)
          if (canvasRef.current && studio.activeLayer) {
            studio.setActiveTool("cursor");
          }
        }}
        onAddImage={() => { setShowMenu(false); setShowImageVault(true); }}
        onAddVideo={() => {
          setShowMenu(false);
          // TODO: Video import
          alert("Video import coming soon! For now, use Add Image to add frames.");
        }}
        onMakeMovie={() => { setShowMenu(false); setShowExport(true); }}
      />

      {/* Layers Bottom Sheet */}
      <LayersPanel
        visible={showLayers}
        onClose={() => setShowLayers(false)}
        layers={studio.layers}
        activeLayerIndex={studio.activeLayerIndex}
        onSelectLayer={(i) => { studio.setActiveLayerIndex(i); }}
        onAddLayer={studio.addLayer}
        onDeleteLayer={studio.deleteLayer}
        onToggleVisibility={studio.toggleLayerVisibility}
        onToggleLock={studio.toggleLayerLock}
        onOpacityChange={studio.setLayerOpacity}
        onReorder={studio.reorderLayer}
        onMergeDown={(i) => studio.mergeLayerDown(i)}
        onDuplicateLayer={(i) => studio.duplicateLayer?.(i)}
      />

      {/* Image Vault (full-screen overlay) */}
      <ImageVault
        visible={showImageVault}
        onClose={() => setShowImageVault(false)}
        onSelectImage={handleSelectImage}
      />

      {/* Sound Vault (full-screen overlay) */}
      <SoundVault
        visible={showSoundVault}
        onClose={() => setShowSoundVault(false)}
        onSelectSound={handleSelectSound}
      />

      {/* Export Dialog */}
      <ExportDialog
        open={showExport}
        onClose={() => setShowExport(false)}
        frames={studio.frames}
        layers={studio.layers}
        fps={studio.fps}
        canvasWidth={1080}
        canvasHeight={1920}
        projectName={projectName}
      />

      {/* Project Settings Dialog */}
      <ProjectSettingsDialog
        open={showProjectSettings}
        onClose={() => setShowProjectSettings(false)}
        projectName={projectName}
        fps={studio.fps}
        canvasWidth={1080}
        canvasHeight={1920}
        onSave={handleSaveProjectSettings}
      />

      {/* Frames Viewer (full-screen grid) */}
      <FramesViewer
        open={showFramesViewer}
        onClose={() => setShowFramesViewer(false)}
        frames={framesThumbs}
        currentFrameIndex={studio.currentFrameIndex}
        onSelectFrame={studio.setCurrentFrameIndex}
        onAddFrame={studio.addFrame}
        onDeleteFrame={studio.deleteFrame}
        onCopyFrame={handleCopyFrame}
        fps={studio.fps}
      />
    </div>
  );
}
