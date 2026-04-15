import { useCallback, useRef, useState } from "react";
import type {
  ToolType,
  RulerMode,
  FrameData,
  LayerData,
  OnionSkinSettings,
  GridSettings,
  BrushSettings,
  EraserSettings,
  FillSettings,
  SelectionBox,
} from "./types";

const MAX_UNDO = 50;

function createDefaultLayer(id: string, name: string): LayerData {
  return { id, name, visible: true, opacity: 1, locked: false, blendMode: "normal" };
}

function createEmptyFrame(index: number, layerIds: string[]): FrameData {
  return {
    index,
    layers: layerIds.map((lid) => ({ layerId: lid, imageData: null, isEmpty: true })),
  };
}

export function useStudioState() {
  // ─── Tool State (5 main tools) ───
  const [activeTool, setActiveTool] = useState<ToolType>("brush");
  const [brushColor, setBrushColor] = useState("#000000");
  const [previousColor, setPreviousColor] = useState("#000000");
  const [brushSettings, setBrushSettings] = useState<BrushSettings>({
    size: 4, opacity: 1, stabilizer: 30, brushType: "pen",
  });
  const [eraserSettings, setEraserSettings] = useState<EraserSettings>({
    size: 20, opacity: 1, feather: 0,
  });
  const [fillSettings, setFillSettings] = useState<FillSettings>({
    tolerance: 10,
  });
  const [rulerMode, setRulerMode] = useState<RulerMode>("off");

  // ─── Selection State (Lasso) ───
  const [selection, setSelection] = useState<SelectionBox | null>(null);

  // ─── Tool Settings Overlay ───
  const [showToolSettings, setShowToolSettings] = useState(false);
  const [showColorPicker, setShowColorPicker] = useState(false);

  // ─── Onion Skin ───
  const [onionSkin, setOnionSkin] = useState<OnionSkinSettings>({
    enabled: true,
    framesBefore: 2,
    framesAfter: 1,
    opacityBefore: 0.25,
    opacityAfter: 0.15,
    colored: true,
    loop: false,
  });

  // ─── Grid ───
  const [grid, setGrid] = useState<GridSettings>({
    enabled: false,
    horizontalSpacing: 40,
    verticalSpacing: 40,
    opacity: 0.2,
    snap: false,
  });

  // ─── Layers ───
  const [layers, setLayers] = useState<LayerData[]>([
    createDefaultLayer("layer-1", "Layer 1"),
  ]);
  const [activeLayerIndex, setActiveLayerIndex] = useState(0);

  // ─── Frames ───
  const [frames, setFrames] = useState<FrameData[]>([
    createEmptyFrame(0, ["layer-1"]),
  ]);
  const [currentFrameIndex, setCurrentFrameIndex] = useState(0);

  // ─── Playback ───
  const [isPlaying, setIsPlaying] = useState(false);
  const [fps, setFps] = useState(12);

  // ─── Recent Colors ───
  const [recentColors, setRecentColors] = useState<string[]>([
    "#000000", "#ffffff", "#dc2626", "#f97316", "#eab308",
    "#22c55e", "#3b82f6", "#a855f7",
  ]);

  // ─── Undo/Redo (per-layer, per-frame) ───
  const undoStackRef = useRef<Map<string, string[]>>(new Map());
  const redoStackRef = useRef<Map<string, string[]>>(new Map());

  const getUndoKey = (frameIdx: number, layerId: string) => `${frameIdx}-${layerId}`;

  const pushUndo = useCallback((frameIdx: number, layerId: string, imageData: string) => {
    const key = getUndoKey(frameIdx, layerId);
    const stack = undoStackRef.current.get(key) || [];
    stack.push(imageData);
    if (stack.length > MAX_UNDO) stack.shift();
    undoStackRef.current.set(key, stack);
    redoStackRef.current.set(key, []);
  }, []);

  const undo = useCallback((frameIdx: number, layerId: string, currentData: string): string | null => {
    const key = getUndoKey(frameIdx, layerId);
    const undoStack = undoStackRef.current.get(key) || [];
    if (undoStack.length === 0) return null;
    const previous = undoStack.pop()!;
    undoStackRef.current.set(key, undoStack);
    const redoStack = redoStackRef.current.get(key) || [];
    redoStack.push(currentData);
    redoStackRef.current.set(key, redoStack);
    return previous;
  }, []);

  const redo = useCallback((frameIdx: number, layerId: string, currentData: string): string | null => {
    const key = getUndoKey(frameIdx, layerId);
    const redoStack = redoStackRef.current.get(key) || [];
    if (redoStack.length === 0) return null;
    const next = redoStack.pop()!;
    redoStackRef.current.set(key, redoStack);
    const undoStack = undoStackRef.current.get(key) || [];
    undoStack.push(currentData);
    undoStackRef.current.set(key, undoStack);
    return next;
  }, []);

  // ─── Color Management ───
  const setColor = useCallback((color: string) => {
    setPreviousColor(brushColor);
    setBrushColor(color);
    setRecentColors((prev) => {
      const filtered = prev.filter((c) => c !== color);
      return [color, ...filtered].slice(0, 16);
    });
  }, [brushColor]);

  // ─── Tool Selection (FlipaClip: tap again = settings) ───
  const handleToolSelect = useCallback((tool: ToolType) => {
    if (tool === activeTool) {
      // Tap active tool again → toggle settings overlay
      setShowToolSettings((v) => !v);
    } else {
      setActiveTool(tool);
      setShowToolSettings(false);
      setShowColorPicker(false);
    }
  }, [activeTool]);

  // ─── Layer Operations ───
  const addLayer = useCallback(() => {
    const newId = `layer-${Date.now()}`;
    const newLayer = createDefaultLayer(newId, `Layer ${layers.length + 1}`);
    setLayers((prev) => {
      const updated = [...prev];
      updated.splice(activeLayerIndex + 1, 0, newLayer);
      return updated;
    });
    setFrames((prev) =>
      prev.map((f) => ({
        ...f,
        layers: [
          ...f.layers.slice(0, activeLayerIndex + 1),
          { layerId: newId, imageData: null, isEmpty: true },
          ...f.layers.slice(activeLayerIndex + 1),
        ],
      })),
    );
    setActiveLayerIndex(activeLayerIndex + 1);
  }, [layers.length, activeLayerIndex]);

  const deleteLayer = useCallback((index: number) => {
    if (layers.length <= 1) return;
    const layerId = layers[index].id;
    setLayers((prev) => prev.filter((_, i) => i !== index));
    setFrames((prev) =>
      prev.map((f) => ({
        ...f,
        layers: f.layers.filter((l) => l.layerId !== layerId),
      })),
    );
    setActiveLayerIndex(Math.max(0, Math.min(activeLayerIndex, layers.length - 2)));
  }, [layers, activeLayerIndex]);

  const mergeLayerDown = useCallback((index: number) => {
    if (index <= 0 || index >= layers.length) return;
    const targetId = layers[index - 1].id;
    const sourceId = layers[index].id;
    setLayers((prev) => prev.filter((_, i) => i !== index));
    setActiveLayerIndex(Math.max(0, index - 1));
    return { targetId, sourceId };
  }, [layers]);

  const duplicateLayer = useCallback((index: number) => {
    if (index < 0 || index >= layers.length) return;
    const source = layers[index];
    const newId = `layer-${Date.now()}`;
    const newLayer = { ...source, id: newId, name: `${source.name} Copy` };
    setLayers((prev) => {
      const updated = [...prev];
      updated.splice(index + 1, 0, newLayer);
      return updated;
    });
    setFrames((prev) =>
      prev.map((f) => {
        const sourceLayerData = f.layers.find((l) => l.layerId === source.id);
        const newLayerData = {
          layerId: newId,
          imageData: sourceLayerData?.imageData ?? null,
          isEmpty: sourceLayerData?.isEmpty ?? true,
        };
        const updatedLayers = [...f.layers];
        updatedLayers.splice(index + 1, 0, newLayerData);
        return { ...f, layers: updatedLayers };
      }),
    );
    setActiveLayerIndex(index + 1);
  }, [layers]);

  const reorderLayer = useCallback((fromIndex: number, toIndex: number) => {
    setLayers((prev) => {
      const updated = [...prev];
      const [moved] = updated.splice(fromIndex, 1);
      updated.splice(toIndex, 0, moved);
      return updated;
    });
    setFrames((prev) =>
      prev.map((f) => {
        const updatedLayers = [...f.layers];
        const [moved] = updatedLayers.splice(fromIndex, 1);
        updatedLayers.splice(toIndex, 0, moved);
        return { ...f, layers: updatedLayers };
      }),
    );
    if (activeLayerIndex === fromIndex) setActiveLayerIndex(toIndex);
  }, [activeLayerIndex]);

  const toggleLayerVisibility = useCallback((index: number) => {
    setLayers((prev) => prev.map((l, i) => i === index ? { ...l, visible: !l.visible } : l));
  }, []);

  const toggleLayerLock = useCallback((index: number) => {
    setLayers((prev) => prev.map((l, i) => i === index ? { ...l, locked: !l.locked } : l));
  }, []);

  const setLayerOpacity = useCallback((index: number, opacity: number) => {
    setLayers((prev) => prev.map((l, i) => i === index ? { ...l, opacity } : l));
  }, []);

  const setLayerBlendMode = useCallback((index: number, blendMode: LayerData["blendMode"]) => {
    setLayers((prev) => prev.map((l, i) => i === index ? { ...l, blendMode } : l));
  }, []);

  // ─── Frame Operations ───
  const addFrame = useCallback((afterIndex: number, duplicate = false) => {
    const layerIds = layers.map((l) => l.id);
    setFrames((prev) => {
      const newFrame: FrameData = duplicate
        ? { index: afterIndex + 1, layers: prev[afterIndex].layers.map((l) => ({ ...l })) }
        : createEmptyFrame(afterIndex + 1, layerIds);
      const updated = [...prev];
      updated.splice(afterIndex + 1, 0, newFrame);
      return updated.map((f, i) => ({ ...f, index: i }));
    });
    setCurrentFrameIndex(afterIndex + 1);
  }, [layers]);

  const deleteFrame = useCallback((index: number) => {
    setFrames((prev) => {
      if (prev.length <= 1) return prev;
      const updated = prev.filter((_, i) => i !== index);
      return updated.map((f, i) => ({ ...f, index: i }));
    });
    setCurrentFrameIndex((prev) => Math.max(0, Math.min(prev, frames.length - 2)));
  }, [frames.length]);

  const updateFrameLayer = useCallback((frameIdx: number, layerId: string, imageData: string) => {
    setFrames((prev) =>
      prev.map((f, fi) =>
        fi === frameIdx
          ? {
              ...f,
              layers: f.layers.map((l) =>
                l.layerId === layerId ? { ...l, imageData, isEmpty: false } : l,
              ),
            }
          : f,
      ),
    );
  }, []);

  const copyFrame = useCallback((index: number) => {
    return frames[index] ? JSON.parse(JSON.stringify(frames[index])) : null;
  }, [frames]);

  const pasteFrame = useCallback((frameData: FrameData, afterIndex: number) => {
    setFrames((prev) => {
      const updated = [...prev];
      const newFrame = { ...frameData, index: afterIndex + 1 };
      updated.splice(afterIndex + 1, 0, newFrame);
      return updated.map((f, i) => ({ ...f, index: i }));
    });
    setCurrentFrameIndex(afterIndex + 1);
  }, []);

  // ─── Derived State ───
  const activeLayer = layers[activeLayerIndex];
  const activeLayerKey = getUndoKey(currentFrameIndex, activeLayer?.id ?? "");
  const canUndo = (undoStackRef.current.get(activeLayerKey)?.length ?? 0) > 0;
  const canRedo = (redoStackRef.current.get(activeLayerKey)?.length ?? 0) > 0;

  const getCurrentLayerData = useCallback((): string | null => {
    const frame = frames[currentFrameIndex];
    if (!frame) return null;
    const layerData = frame.layers.find((l) => l.layerId === activeLayer?.id);
    return layerData?.imageData ?? null;
  }, [frames, currentFrameIndex, activeLayer]);

  const getCompositeLayerData = useCallback((): {
    below: { imageData: string; opacity: number; blendMode: string }[];
    above: { imageData: string; opacity: number; blendMode: string }[];
  } => {
    const frame = frames[currentFrameIndex];
    if (!frame) return { below: [], above: [] };

    const below: { imageData: string; opacity: number; blendMode: string }[] = [];
    const above: { imageData: string; opacity: number; blendMode: string }[] = [];
    let passedActive = false;

    for (const layer of layers) {
      if (layer.id === activeLayer?.id) { passedActive = true; continue; }
      if (!layer.visible) continue;
      const frameLayer = frame.layers.find((fl) => fl.layerId === layer.id);
      if (!frameLayer?.imageData || frameLayer.isEmpty) continue;
      const entry = { imageData: frameLayer.imageData, opacity: layer.opacity, blendMode: layer.blendMode };
      if (passedActive) above.push(entry); else below.push(entry);
    }
    return { below, above };
  }, [frames, currentFrameIndex, layers, activeLayer]);

  const getOnionFrames = useCallback((direction: "before" | "after"): { imageData: string | null; opacity: number }[] => {
    if (!onionSkin.enabled) return [];
    const count = direction === "before" ? onionSkin.framesBefore : onionSkin.framesAfter;
    const baseOpacity = direction === "before" ? onionSkin.opacityBefore : onionSkin.opacityAfter;
    const result: { imageData: string | null; opacity: number }[] = [];

    for (let i = 1; i <= count; i++) {
      let frameIdx = direction === "before" ? currentFrameIndex - i : currentFrameIndex + i;
      if (onionSkin.loop) frameIdx = ((frameIdx % frames.length) + frames.length) % frames.length;
      if (frameIdx < 0 || frameIdx >= frames.length) continue;
      const frame = frames[frameIdx];
      const layerData = frame?.layers.find((l) => l.layerId === activeLayer?.id);
      const opacity = baseOpacity * (1 - (i - 1) / count);
      result.push({ imageData: layerData?.imageData ?? null, opacity });
    }
    return result;
  }, [onionSkin, currentFrameIndex, frames, activeLayer]);

  return {
    // Tools (5 main)
    activeTool, setActiveTool: handleToolSelect, setActiveToolDirect: setActiveTool,
    brushColor, setBrushColor: setColor,
    previousColor,
    brushSettings, setBrushSettings,
    eraserSettings, setEraserSettings,
    fillSettings, setFillSettings,
    rulerMode, setRulerMode,
    // Selection
    selection, setSelection,
    // Tool settings overlay
    showToolSettings, setShowToolSettings,
    showColorPicker, setShowColorPicker,
    // Onion skin
    onionSkin, setOnionSkin,
    // Grid
    grid, setGrid,
    // Layers
    layers, activeLayerIndex, setActiveLayerIndex, activeLayer,
    addLayer, deleteLayer, duplicateLayer, mergeLayerDown, reorderLayer,
    toggleLayerVisibility, toggleLayerLock,
    setLayerOpacity, setLayerBlendMode,
    // Frames
    frames, currentFrameIndex, setCurrentFrameIndex,
    addFrame, deleteFrame, updateFrameLayer,
    copyFrame, pasteFrame,
    // Playback
    isPlaying, setIsPlaying,
    fps, setFps,
    // Colors
    recentColors,
    // Undo/redo
    pushUndo, undo, redo, canUndo, canRedo,
    // Derived
    getCurrentLayerData, getOnionFrames, getCompositeLayerData,
  };
}
