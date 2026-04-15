// StickDeath ∞ — Canvas (FlipaClip-style rebuild)
// Full-space canvas, lasso selection with bounding box, ruler sub-tools, cursor tool
// No permanent sidebars — canvas takes all available space

import { useCallback, useEffect, useRef, useState } from "react";
import type {
  ToolType, RulerMode, StrokePoint, GridSettings, OnionSkinSettings,
  SelectionBox, EraserSettings, FillSettings, InsertedImage,
} from "./types";

interface CompositeLayer {
  imageData: string;
  opacity: number;
  blendMode: string;
}

interface Props {
  tool: ToolType;
  color: string;
  brushSize: number;
  brushOpacity: number;
  brushStabilizer: number;
  brushType: string;
  eraserSettings: EraserSettings;
  fillSettings: FillSettings;
  rulerMode: RulerMode;
  grid: GridSettings;
  onionSkin: OnionSkinSettings;
  onionFramesBefore: { imageData: string | null; opacity: number }[];
  onionFramesAfter: { imageData: string | null; opacity: number }[];
  currentFrameData: string | null;
  layersBelow?: CompositeLayer[];
  layersAbove?: CompositeLayer[];
  onStrokeStart: () => void;
  onStrokeEnd: (imageData: string) => void;
  onCanvasReady: (canvas: HTMLCanvasElement) => void;
  // Lasso selection
  selection: SelectionBox | null;
  onSelectionChange: (s: SelectionBox | null) => void;
  // Dismiss overlays on canvas tap
  onCanvasTap?: () => void;
  // Inserted image (from Image Vault)
  insertedImage: InsertedImage | null;
  onInsertedImageChange: (img: InsertedImage | null) => void;
  onCommitInsertedImage: () => void;
}

// Canvas logical size (drawing resolution)
const CANVAS_W = 1080;
const CANVAS_H = 1920;

// ─── Stabilizer: smooth points with moving average ───
function stabilizePoints(raw: StrokePoint[], strength: number): StrokePoint[] {
  if (strength === 0 || raw.length < 2) return raw;
  const windowSize = Math.max(2, Math.round(strength / 10));
  const result: StrokePoint[] = [raw[0]];
  for (let i = 1; i < raw.length; i++) {
    const start = Math.max(0, i - windowSize);
    let sumX = 0, sumY = 0, count = 0;
    for (let j = start; j <= i; j++) {
      sumX += raw[j].x; sumY += raw[j].y; count++;
    }
    result.push({ x: sumX / count, y: sumY / count, pressure: raw[i].pressure });
  }
  return result;
}

// ─── Catmull-Rom smooth curve ───
function drawSmoothLine(ctx: CanvasRenderingContext2D, points: StrokePoint[], tension = 0.5) {
  if (points.length < 2) return;
  if (points.length === 2) {
    ctx.beginPath();
    ctx.moveTo(points[0].x, points[0].y);
    ctx.lineTo(points[1].x, points[1].y);
    ctx.stroke();
    return;
  }
  ctx.beginPath();
  ctx.moveTo(points[0].x, points[0].y);
  for (let i = 0; i < points.length - 1; i++) {
    const p0 = points[Math.max(0, i - 1)];
    const p1 = points[i];
    const p2 = points[Math.min(points.length - 1, i + 1)];
    const p3 = points[Math.min(points.length - 1, i + 2)];
    const cp1x = p1.x + (p2.x - p0.x) * tension / 3;
    const cp1y = p1.y + (p2.y - p0.y) * tension / 3;
    const cp2x = p2.x - (p3.x - p1.x) * tension / 3;
    const cp2y = p2.y - (p3.y - p1.y) * tension / 3;
    ctx.bezierCurveTo(cp1x, cp1y, cp2x, cp2y, p2.x, p2.y);
  }
  ctx.stroke();
}

// ─── Compute bounding box from lasso path ───
function pathBounds(path: StrokePoint[]): { x: number; y: number; w: number; h: number } {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const p of path) {
    if (p.x < minX) minX = p.x; if (p.y < minY) minY = p.y;
    if (p.x > maxX) maxX = p.x; if (p.y > maxY) maxY = p.y;
  }
  return { x: minX, y: minY, w: maxX - minX, h: maxY - minY };
}

export default function StudioCanvas({
  tool, color, brushSize, brushOpacity, brushStabilizer, brushType: _brushType,
  eraserSettings, fillSettings, rulerMode,
  grid, onionSkin,
  onionFramesBefore, onionFramesAfter,
  currentFrameData,
  layersBelow = [], layersAbove = [],
  onStrokeStart, onStrokeEnd, onCanvasReady,
  selection, onSelectionChange,
  onCanvasTap,
  insertedImage, onInsertedImageChange, onCommitInsertedImage,
}: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const onionCanvasRef = useRef<HTMLCanvasElement>(null);
  const gridCanvasRef = useRef<HTMLCanvasElement>(null);
  const belowCanvasRef = useRef<HTMLCanvasElement>(null);
  const aboveCanvasRef = useRef<HTMLCanvasElement>(null);
  const selectionCanvasRef = useRef<HTMLCanvasElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  // Drawing state
  const isDrawing = useRef(false);
  const rawPoints = useRef<StrokePoint[]>([]);
  const lastPoint = useRef<StrokePoint | null>(null);
  const shapeStart = useRef<StrokePoint | null>(null);
  const snapshotBeforeShape = useRef<ImageData | null>(null);
  const snapshotBeforeStroke = useRef<ImageData | null>(null);

  // Lasso state
  const lassoPath = useRef<StrokePoint[]>([]);
  const isLassoing = useRef(false);
  const isDraggingSelection = useRef(false);
  const dragStartPoint = useRef<StrokePoint | null>(null);

  // Cursor tool state
  const isCursorDragging = useRef(false);
  const cursorDragStart = useRef<StrokePoint | null>(null);

  // Inserted image drag state
  const isDraggingInserted = useRef(false);
  const insertedDragStart = useRef<{ x: number; y: number; imgX: number; imgY: number } | null>(null);
  const isResizingInserted = useRef<string | null>(null);

  // Zoom/pan
  const [zoom, setZoom] = useState(1);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const isPanning = useRef(false);
  const panStart = useRef({ x: 0, y: 0, panX: 0, panY: 0 });

  // Fit canvas into container
  const [containerSize, setContainerSize] = useState({ w: 0, h: 0 });

  // Measure container
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const obs = new ResizeObserver((entries) => {
      const entry = entries[0];
      if (entry) {
        setContainerSize({
          w: entry.contentRect.width,
          h: entry.contentRect.height,
        });
      }
    });
    obs.observe(el);
    return () => obs.disconnect();
  }, []);

  // Compute scale to fit canvas in container
  const baseScale = containerSize.w && containerSize.h
    ? Math.min(containerSize.w / CANVAS_W, containerSize.h / CANVAS_H) * 0.92
    : 0.5;
  const effectiveScale = baseScale * zoom;

  // Init canvas
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    canvas.width = CANVAS_W;
    canvas.height = CANVAS_H;
    onCanvasReady(canvas);
  }, [onCanvasReady]);

  // Load current frame data
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d")!;
    if (currentFrameData) {
      const img = new Image();
      img.onload = () => { ctx.clearRect(0, 0, CANVAS_W, CANVAS_H); ctx.drawImage(img, 0, 0); };
      img.src = currentFrameData;
    } else {
      ctx.clearRect(0, 0, CANVAS_W, CANVAS_H);
    }
  }, [currentFrameData]);

  // ─── Composite layers ───
  useEffect(() => {
    const canvas = belowCanvasRef.current;
    if (!canvas) return;
    canvas.width = CANVAS_W; canvas.height = CANVAS_H;
    const ctx = canvas.getContext("2d")!;
    ctx.clearRect(0, 0, CANVAS_W, CANVAS_H);
    if (layersBelow.length === 0) return;
    (async () => {
      for (const layer of layersBelow) {
        await new Promise<void>((resolve) => {
          const img = new Image();
          img.onload = () => {
            ctx.globalAlpha = layer.opacity;
            ctx.globalCompositeOperation = (layer.blendMode as GlobalCompositeOperation) || "source-over";
            ctx.drawImage(img, 0, 0);
            ctx.globalAlpha = 1; ctx.globalCompositeOperation = "source-over";
            resolve();
          };
          img.onerror = () => resolve();
          img.src = layer.imageData;
        });
      }
    })();
  }, [layersBelow]);

  useEffect(() => {
    const canvas = aboveCanvasRef.current;
    if (!canvas) return;
    canvas.width = CANVAS_W; canvas.height = CANVAS_H;
    const ctx = canvas.getContext("2d")!;
    ctx.clearRect(0, 0, CANVAS_W, CANVAS_H);
    if (layersAbove.length === 0) return;
    (async () => {
      for (const layer of layersAbove) {
        await new Promise<void>((resolve) => {
          const img = new Image();
          img.onload = () => {
            ctx.globalAlpha = layer.opacity;
            ctx.globalCompositeOperation = (layer.blendMode as GlobalCompositeOperation) || "source-over";
            ctx.drawImage(img, 0, 0);
            ctx.globalAlpha = 1; ctx.globalCompositeOperation = "source-over";
            resolve();
          };
          img.onerror = () => resolve();
          img.src = layer.imageData;
        });
      }
    })();
  }, [layersAbove]);

  // ─── Onion skins ───
  useEffect(() => {
    const oc = onionCanvasRef.current;
    if (!oc) return;
    oc.width = CANVAS_W; oc.height = CANVAS_H;
    const ctx = oc.getContext("2d")!;
    ctx.clearRect(0, 0, CANVAS_W, CANVAS_H);
    if (!onionSkin.enabled) return;
    const drawGhost = (data: string | null, opacity: number, tint: string) => {
      if (!data || opacity <= 0) return Promise.resolve();
      return new Promise<void>((resolve) => {
        const img = new Image();
        img.onload = () => {
          ctx.globalAlpha = opacity; ctx.globalCompositeOperation = "source-over";
          ctx.drawImage(img, 0, 0);
          if (onionSkin.colored) {
            ctx.globalCompositeOperation = "source-atop";
            ctx.fillStyle = tint; ctx.globalAlpha = 0.35;
            ctx.fillRect(0, 0, CANVAS_W, CANVAS_H);
          }
          ctx.globalCompositeOperation = "source-over"; ctx.globalAlpha = 1;
          resolve();
        };
        img.onerror = () => resolve();
        img.src = data;
      });
    };
    (async () => {
      for (const f of onionFramesBefore) await drawGhost(f.imageData, f.opacity, "rgba(220,38,38,0.5)");
      for (const f of onionFramesAfter) await drawGhost(f.imageData, f.opacity, "rgba(34,197,94,0.4)");
    })();
  }, [onionSkin, onionFramesBefore, onionFramesAfter]);

  // ─── Grid ───
  useEffect(() => {
    const gc = gridCanvasRef.current;
    if (!gc) return;
    gc.width = CANVAS_W; gc.height = CANVAS_H;
    const ctx = gc.getContext("2d")!;
    ctx.clearRect(0, 0, CANVAS_W, CANVAS_H);
    if (!grid.enabled) return;
    ctx.strokeStyle = `rgba(180,180,200,${grid.opacity})`;
    ctx.lineWidth = 0.5;
    for (let x = grid.verticalSpacing; x < CANVAS_W; x += grid.verticalSpacing) {
      ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, CANVAS_H); ctx.stroke();
    }
    for (let y = grid.horizontalSpacing; y < CANVAS_H; y += grid.horizontalSpacing) {
      ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(CANVAS_W, y); ctx.stroke();
    }
    ctx.strokeStyle = `rgba(180,180,200,${Math.min(1, grid.opacity * 2)})`; ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(CANVAS_W / 2, 0); ctx.lineTo(CANVAS_W / 2, CANVAS_H);
    ctx.moveTo(0, CANVAS_H / 2); ctx.lineTo(CANVAS_W, CANVAS_H / 2);
    ctx.stroke();
  }, [grid]);

  // ─── Draw selection overlay (lasso box) ───
  useEffect(() => {
    const sc = selectionCanvasRef.current;
    if (!sc) return;
    sc.width = CANVAS_W; sc.height = CANVAS_H;
    const ctx = sc.getContext("2d")!;
    ctx.clearRect(0, 0, CANVAS_W, CANVAS_H);

    // Active lasso path (while drawing)
    if (isLassoing.current && lassoPath.current.length > 1) {
      ctx.setLineDash([6, 4]);
      ctx.strokeStyle = "#dc2626";
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(lassoPath.current[0].x, lassoPath.current[0].y);
      for (const p of lassoPath.current) ctx.lineTo(p.x, p.y);
      ctx.stroke();
      ctx.setLineDash([]);
    }

    // Selection bounding box
    if (selection) {
      const { x, y, width: w, height: h } = selection;
      ctx.save();
      ctx.setLineDash([8, 4]);
      ctx.strokeStyle = "#dc2626";
      ctx.lineWidth = 2;
      ctx.strokeRect(x, y, w, h);
      ctx.setLineDash([]);

      const handleSize = 8;
      ctx.fillStyle = "#fff";
      ctx.strokeStyle = "#dc2626";
      ctx.lineWidth = 1.5;
      const corners = [
        [x, y], [x + w, y], [x, y + h], [x + w, y + h],
        [x + w / 2, y], [x + w, y + h / 2], [x + w / 2, y + h], [x, y + h / 2],
      ];
      for (const [cx, cy] of corners) {
        ctx.fillRect(cx - handleSize / 2, cy - handleSize / 2, handleSize, handleSize);
        ctx.strokeRect(cx - handleSize / 2, cy - handleSize / 2, handleSize, handleSize);
      }

      const rX = x + w / 2, rY = y - 24;
      ctx.beginPath();
      ctx.moveTo(x + w / 2, y); ctx.lineTo(rX, rY);
      ctx.strokeStyle = "#dc2626"; ctx.lineWidth = 1;
      ctx.stroke();
      ctx.beginPath();
      ctx.arc(rX, rY, 6, 0, Math.PI * 2);
      ctx.fillStyle = "#dc2626"; ctx.fill();
      ctx.strokeStyle = "#fff"; ctx.lineWidth = 1.5;
      ctx.stroke();

      if (selection.imageData) {
        const img = new Image();
        img.onload = () => {
          ctx.globalAlpha = 0.85;
          ctx.drawImage(img, x, y, w, h);
          ctx.globalAlpha = 1;
        };
        img.src = selection.imageData;
      }
      ctx.restore();
    }
  }, [selection]);

  // ─── Pointer → canvas coordinates ───
  const getCanvasPoint = useCallback((e: React.PointerEvent): StrokePoint => {
    const canvas = canvasRef.current!;
    const rect = canvas.getBoundingClientRect();
    const scaleX = CANVAS_W / rect.width;
    const scaleY = CANVAS_H / rect.height;
    let x = (e.clientX - rect.left) * scaleX;
    let y = (e.clientY - rect.top) * scaleY;
    if (grid.snap && grid.enabled) {
      x = Math.round(x / grid.verticalSpacing) * grid.verticalSpacing;
      y = Math.round(y / grid.horizontalSpacing) * grid.horizontalSpacing;
    }
    return { x, y, pressure: e.pressure, timestamp: Date.now() };
  }, [grid]);

  // ─── Setup drawing context — FIXED: sets both strokeStyle AND fillStyle ───
  const setupCtx = useCallback((ctx: CanvasRenderingContext2D) => {
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    if (tool === "eraser") {
      ctx.globalCompositeOperation = "destination-out";
      ctx.lineWidth = eraserSettings.size;
      ctx.strokeStyle = "rgba(0,0,0,1)";
      ctx.fillStyle = "rgba(0,0,0,1)";
      ctx.globalAlpha = eraserSettings.opacity;
    } else {
      ctx.globalCompositeOperation = "source-over";
      ctx.lineWidth = brushSize;
      ctx.strokeStyle = color;
      ctx.fillStyle = color;
      ctx.globalAlpha = brushOpacity;
    }
  }, [tool, color, brushSize, brushOpacity, eraserSettings]);

  // ─── Check if point is inside selection box ───
  const isInsideSelection = useCallback((p: StrokePoint): boolean => {
    if (!selection) return false;
    return p.x >= selection.x && p.x <= selection.x + selection.width &&
           p.y >= selection.y && p.y <= selection.y + selection.height;
  }, [selection]);

  // ─── Check if point is inside inserted image ───
  const isInsideInsertedImage = useCallback((p: StrokePoint): boolean => {
    if (!insertedImage) return false;
    return p.x >= insertedImage.x && p.x <= insertedImage.x + insertedImage.width &&
           p.y >= insertedImage.y && p.y <= insertedImage.y + insertedImage.height;
  }, [insertedImage]);

  // ─── Get resize handle at point for inserted image ───
  const getInsertedResizeHandle = useCallback((p: StrokePoint): string | null => {
    if (!insertedImage) return null;
    const { x, y, width: w, height: h } = insertedImage;
    const hs = 20; // handle hit area
    if (Math.abs(p.x - (x + w)) < hs && Math.abs(p.y - (y + h)) < hs) return "br";
    if (Math.abs(p.x - x) < hs && Math.abs(p.y - y) < hs) return "tl";
    if (Math.abs(p.x - (x + w)) < hs && Math.abs(p.y - y) < hs) return "tr";
    if (Math.abs(p.x - x) < hs && Math.abs(p.y - (y + h)) < hs) return "bl";
    return null;
  }, [insertedImage]);

  // ─── POINTER DOWN ───
  const handlePointerDown = useCallback((e: React.PointerEvent) => {
    onCanvasTap?.();

    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d")!;
    const point = getCanvasPoint(e);

    // Two-finger pan
    if (e.pointerType === "touch" && e.isPrimary === false) {
      isPanning.current = true;
      panStart.current = { x: e.clientX, y: e.clientY, panX: pan.x, panY: pan.y };
      return;
    }

    // ─── INSERTED IMAGE HANDLING (any tool — takes priority) ───
    if (insertedImage && !insertedImage.committed) {
      const handle = getInsertedResizeHandle(point);
      if (handle) {
        isResizingInserted.current = handle;
        insertedDragStart.current = { x: point.x, y: point.y, imgX: insertedImage.x, imgY: insertedImage.y };
        canvas.setPointerCapture(e.pointerId);
        return;
      }
      if (isInsideInsertedImage(point)) {
        isDraggingInserted.current = true;
        insertedDragStart.current = { x: point.x, y: point.y, imgX: insertedImage.x, imgY: insertedImage.y };
        canvas.setPointerCapture(e.pointerId);
        return;
      }
      // Clicked outside inserted image → commit it
      onCommitInsertedImage();
    }

    // ─── CURSOR TOOL (select all + move) ───
    if (tool === "cursor") {
      if (selection && isInsideSelection(point)) {
        isDraggingSelection.current = true;
        dragStartPoint.current = point;
        canvas.setPointerCapture(e.pointerId);
        return;
      }
      if (selection) {
        // Click outside selection → commit
        commitSelection(ctx);
        return;
      }
      // No selection → select all content on current layer
      const hasContent = !isCanvasEmpty(canvas);
      if (hasContent) {
        onStrokeStart();
        onSelectionChange({
          x: 0, y: 0, width: CANVAS_W, height: CANVAS_H,
          rotation: 0, pivotX: CANVAS_W / 2, pivotY: CANVAS_H / 2,
          imageData: canvas.toDataURL(),
          maskPath: [
            { x: 0, y: 0 }, { x: CANVAS_W, y: 0 },
            { x: CANVAS_W, y: CANVAS_H }, { x: 0, y: CANVAS_H },
          ],
        });
        ctx.clearRect(0, 0, CANVAS_W, CANVAS_H);
      }
      return;
    }

    // ─── LASSO TOOL ───
    if (tool === "lasso") {
      if (selection && isInsideSelection(point)) {
        isDraggingSelection.current = true;
        dragStartPoint.current = point;
        canvas.setPointerCapture(e.pointerId);
        return;
      }
      if (selection) {
        commitSelection(ctx);
        return;
      }
      isLassoing.current = true;
      lassoPath.current = [point];
      canvas.setPointerCapture(e.pointerId);
      return;
    }

    // ─── FILL TOOL ───
    if (tool === "fill") {
      onStrokeStart();
      floodFill(ctx, Math.round(point.x), Math.round(point.y), color, CANVAS_W, CANVAS_H, fillSettings.tolerance);
      onStrokeEnd(canvas.toDataURL());
      return;
    }

    // ─── TEXT TOOL ───
    if (tool === "text") {
      const text = prompt("Enter text:");
      if (!text) return;
      onStrokeStart();
      ctx.globalCompositeOperation = "source-over";
      ctx.font = "bold 48px 'Special Elite', monospace";
      ctx.fillStyle = color;
      ctx.globalAlpha = brushOpacity;
      ctx.fillText(text, point.x, point.y);
      ctx.globalAlpha = 1;
      onStrokeEnd(canvas.toDataURL());
      return;
    }

    // ─── BRUSH / ERASER (with ruler modes) ───
    isDrawing.current = true;
    lastPoint.current = point;
    rawPoints.current = [point];
    onStrokeStart();
    canvas.setPointerCapture(e.pointerId);

    // Ruler shape tools
    if (rulerMode !== "off" && tool === "brush") {
      shapeStart.current = point;
      snapshotBeforeShape.current = ctx.getImageData(0, 0, CANVAS_W, CANVAS_H);
      snapshotBeforeStroke.current = snapshotBeforeShape.current;
      return;
    }

    // Save for stabilized redraw
    snapshotBeforeStroke.current = ctx.getImageData(0, 0, CANVAS_W, CANVAS_H);

    // Draw dot at start position
    setupCtx(ctx);
    ctx.beginPath();
    ctx.arc(point.x, point.y, ctx.lineWidth / 2, 0, Math.PI * 2);
    ctx.fill();
  }, [getCanvasPoint, tool, color, brushOpacity, rulerMode, selection, isInsideSelection, fillSettings, onStrokeStart, onStrokeEnd, setupCtx, onCanvasTap, pan, insertedImage, isInsideInsertedImage, getInsertedResizeHandle, onCommitInsertedImage, onSelectionChange]);

  // ─── POINTER MOVE ───
  const handlePointerMove = useCallback((e: React.PointerEvent) => {
    // Panning
    if (isPanning.current) {
      setPan({
        x: panStart.current.panX + (e.clientX - panStart.current.x),
        y: panStart.current.panY + (e.clientY - panStart.current.y),
      });
      return;
    }

    const point = getCanvasPoint(e);

    // Dragging inserted image
    if (isDraggingInserted.current && insertedImage && insertedDragStart.current) {
      const dx = point.x - insertedDragStart.current.x;
      const dy = point.y - insertedDragStart.current.y;
      onInsertedImageChange({
        ...insertedImage,
        x: insertedDragStart.current.imgX + dx,
        y: insertedDragStart.current.imgY + dy,
      });
      return;
    }

    // Resizing inserted image
    if (isResizingInserted.current && insertedImage && insertedDragStart.current) {
      const handle = isResizingInserted.current;
      const dx = point.x - insertedDragStart.current.x;
      const dy = point.y - insertedDragStart.current.y;
      let { x, y, width: w, height: h } = insertedImage;
      const origX = insertedDragStart.current.imgX;
      const origY = insertedDragStart.current.imgY;
      const origW = insertedImage.width;
      const origH = insertedImage.height;
      const aspect = origW / origH;

      if (handle === "br") {
        w = Math.max(40, origW + dx);
        h = w / aspect;
      } else if (handle === "tl") {
        w = Math.max(40, origW - dx);
        h = w / aspect;
        x = origX + (origW - w);
        y = origY + (origH - h);
      } else if (handle === "tr") {
        w = Math.max(40, origW + dx);
        h = w / aspect;
        y = origY + (origH - h);
      } else if (handle === "bl") {
        w = Math.max(40, origW - dx);
        h = w / aspect;
        x = origX + (origW - w);
      }
      onInsertedImageChange({ ...insertedImage, x, y, width: w, height: h });
      return;
    }

    // Lasso drawing
    if (isLassoing.current) {
      lassoPath.current.push(point);
      const sc = selectionCanvasRef.current;
      if (sc) {
        const sctx = sc.getContext("2d")!;
        sctx.clearRect(0, 0, CANVAS_W, CANVAS_H);
        sctx.setLineDash([6, 4]);
        sctx.strokeStyle = "#dc2626";
        sctx.lineWidth = 2;
        sctx.beginPath();
        sctx.moveTo(lassoPath.current[0].x, lassoPath.current[0].y);
        for (const p of lassoPath.current) sctx.lineTo(p.x, p.y);
        sctx.stroke();
        sctx.setLineDash([]);
      }
      return;
    }

    // Dragging selection (lasso or cursor tool)
    if (isDraggingSelection.current && selection && dragStartPoint.current) {
      const dx = point.x - dragStartPoint.current.x;
      const dy = point.y - dragStartPoint.current.y;
      onSelectionChange({
        ...selection,
        x: selection.x + dx,
        y: selection.y + dy,
      });
      dragStartPoint.current = point;
      return;
    }

    // Normal drawing
    if (!isDrawing.current) return;
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d")!;

    // Ruler shape preview
    if (rulerMode !== "off" && tool === "brush") {
      if (snapshotBeforeShape.current) {
        ctx.putImageData(snapshotBeforeShape.current, 0, 0);
      }
      setupCtx(ctx);
      ctx.globalCompositeOperation = "source-over";
      const start = shapeStart.current!;

      if (rulerMode === "line") {
        ctx.beginPath();
        ctx.moveTo(start.x, start.y);
        ctx.lineTo(point.x, point.y);
        ctx.stroke();
      } else if (rulerMode === "rect") {
        ctx.beginPath();
        ctx.strokeRect(start.x, start.y, point.x - start.x, point.y - start.y);
      } else if (rulerMode === "circle") {
        const rx = Math.abs(point.x - start.x) / 2;
        const ry = Math.abs(point.y - start.y) / 2;
        const cx = start.x + (point.x - start.x) / 2;
        const cy = start.y + (point.y - start.y) / 2;
        ctx.beginPath();
        ctx.ellipse(cx, cy, Math.max(1, rx), Math.max(1, ry), 0, 0, Math.PI * 2);
        ctx.stroke();
      } else if (rulerMode === "mirror") {
        ctx.beginPath();
        ctx.moveTo(start.x, start.y);
        ctx.lineTo(point.x, point.y);
        ctx.stroke();
        ctx.beginPath();
        ctx.moveTo(CANVAS_W - start.x, start.y);
        ctx.lineTo(CANVAS_W - point.x, point.y);
        ctx.stroke();
      }
      return;
    }

    // Brush/Eraser stroke
    rawPoints.current.push(point);
    if (brushStabilizer > 20 && snapshotBeforeStroke.current) {
      ctx.putImageData(snapshotBeforeStroke.current, 0, 0);
      setupCtx(ctx);
      const smoothed = stabilizePoints(rawPoints.current, brushStabilizer);
      drawSmoothLine(ctx, smoothed);
    } else {
      setupCtx(ctx);
      if (lastPoint.current) {
        ctx.beginPath();
        ctx.moveTo(lastPoint.current.x, lastPoint.current.y);
        ctx.lineTo(point.x, point.y);
        ctx.stroke();
      }
    }
    lastPoint.current = point;
  }, [getCanvasPoint, tool, rulerMode, selection, brushStabilizer, setupCtx, onSelectionChange, insertedImage, onInsertedImageChange]);

  // ─── POINTER UP ───
  const handlePointerUp = useCallback((_e: React.PointerEvent) => {
    isPanning.current = false;

    // Finish inserted image drag/resize
    if (isDraggingInserted.current || isResizingInserted.current) {
      isDraggingInserted.current = false;
      isResizingInserted.current = null;
      insertedDragStart.current = null;
      return;
    }

    // Finish lasso
    if (isLassoing.current) {
      isLassoing.current = false;
      const path = lassoPath.current;
      if (path.length > 5) {
        const bounds = pathBounds(path);
        if (bounds.w > 5 && bounds.h > 5) {
          const canvas = canvasRef.current;
          if (canvas) {
            const ctx = canvas.getContext("2d")!;
            const offscreen = document.createElement("canvas");
            offscreen.width = CANVAS_W;
            offscreen.height = CANVAS_H;
            const offCtx = offscreen.getContext("2d")!;
            offCtx.beginPath();
            offCtx.moveTo(path[0].x, path[0].y);
            for (const p of path) offCtx.lineTo(p.x, p.y);
            offCtx.closePath();
            offCtx.clip();
            offCtx.drawImage(canvas, 0, 0);

            const selCanvas = document.createElement("canvas");
            selCanvas.width = Math.ceil(bounds.w);
            selCanvas.height = Math.ceil(bounds.h);
            const selCtx = selCanvas.getContext("2d")!;
            selCtx.drawImage(offscreen, bounds.x, bounds.y, bounds.w, bounds.h, 0, 0, bounds.w, bounds.h);

            ctx.save();
            ctx.beginPath();
            ctx.moveTo(path[0].x, path[0].y);
            for (const p of path) ctx.lineTo(p.x, p.y);
            ctx.closePath();
            ctx.clip();
            ctx.clearRect(bounds.x, bounds.y, bounds.w, bounds.h);
            ctx.restore();

            onSelectionChange({
              x: bounds.x,
              y: bounds.y,
              width: bounds.w,
              height: bounds.h,
              rotation: 0,
              pivotX: bounds.x + bounds.w / 2,
              pivotY: bounds.y + bounds.h / 2,
              imageData: selCanvas.toDataURL(),
              maskPath: [...path],
            });
          }
        }
      }
      lassoPath.current = [];
      return;
    }

    // Finish selection drag
    if (isDraggingSelection.current) {
      isDraggingSelection.current = false;
      dragStartPoint.current = null;
      return;
    }

    // Finish cursor drag
    if (isCursorDragging.current) {
      isCursorDragging.current = false;
      cursorDragStart.current = null;
      return;
    }

    // Finish drawing
    if (!isDrawing.current) return;

    // Final stabilized redraw
    if (brushStabilizer > 20 && snapshotBeforeStroke.current &&
        rawPoints.current.length > 2 && rulerMode === "off") {
      const canvas = canvasRef.current;
      if (canvas) {
        const ctx = canvas.getContext("2d")!;
        ctx.putImageData(snapshotBeforeStroke.current, 0, 0);
        setupCtx(ctx);
        const smoothed = stabilizePoints(rawPoints.current, brushStabilizer);
        drawSmoothLine(ctx, smoothed);
      }
    }

    isDrawing.current = false;
    lastPoint.current = null;
    shapeStart.current = null;
    snapshotBeforeShape.current = null;
    snapshotBeforeStroke.current = null;
    rawPoints.current = [];

    const canvas = canvasRef.current;
    if (canvas) onStrokeEnd(canvas.toDataURL());
  }, [onStrokeEnd, brushStabilizer, rulerMode, setupCtx, onSelectionChange]);

  // ─── Commit selection (paste back onto canvas) ───
  const commitSelection = useCallback((ctx: CanvasRenderingContext2D) => {
    if (!selection) return;
    const img = new Image();
    img.onload = () => {
      ctx.drawImage(img, selection.x, selection.y, selection.width, selection.height);
      onSelectionChange(null);
      const canvas = canvasRef.current;
      if (canvas) onStrokeEnd(canvas.toDataURL());
    };
    img.src = selection.imageData;
  }, [selection, onSelectionChange, onStrokeEnd]);

  // ─── Check if canvas has any content ───
  const isCanvasEmpty = useCallback((canvas: HTMLCanvasElement): boolean => {
    const ctx = canvas.getContext("2d")!;
    const data = ctx.getImageData(0, 0, CANVAS_W, CANVAS_H).data;
    for (let i = 3; i < data.length; i += 4) {
      if (data[i] > 0) return false;
    }
    return true;
  }, []);

  // ─── Double-tap = select all on layer ───
  const handleDoubleClick = useCallback(() => {
    if (tool !== "lasso" && tool !== "cursor") return;
    const canvas = canvasRef.current;
    if (!canvas) return;
    onStrokeStart();
    onSelectionChange({
      x: 0, y: 0, width: CANVAS_W, height: CANVAS_H,
      rotation: 0, pivotX: CANVAS_W / 2, pivotY: CANVAS_H / 2,
      imageData: canvas.toDataURL(),
      maskPath: [
        { x: 0, y: 0 }, { x: CANVAS_W, y: 0 },
        { x: CANVAS_W, y: CANVAS_H }, { x: 0, y: CANVAS_H },
      ],
    });
    const ctx = canvas.getContext("2d")!;
    ctx.clearRect(0, 0, CANVAS_W, CANVAS_H);
  }, [tool, onSelectionChange, onStrokeStart]);

  // Zoom
  const handleWheel = useCallback((e: React.WheelEvent) => {
    if (e.ctrlKey || e.metaKey) {
      e.preventDefault();
      const delta = e.deltaY > 0 ? 0.9 : 1.1;
      setZoom((prev) => Math.min(5, Math.max(0.25, prev * delta)));
    }
  }, []);

  // Reset view
  const resetView = useCallback(() => {
    setZoom(1);
    setPan({ x: 0, y: 0 });
  }, []);

  const cursorClass =
    tool === "cursor" ? (selection ? "cursor-move" : "cursor-default")
    : tool === "lasso" ? (selection ? "cursor-move" : "cursor-crosshair")
    : tool === "eraser" ? "cursor-crosshair"
    : tool === "fill" ? "cursor-crosshair"
    : tool === "text" ? "cursor-text"
    : "cursor-crosshair";

  return (
    <div
      ref={containerRef}
      className="relative flex-1 flex items-center justify-center bg-[#1a1a24] overflow-hidden touch-none"
      style={{ touchAction: "none", overscrollBehavior: "none" }}
      onWheel={handleWheel}
    >
      {/* Canvas stack with zoom/pan */}
      <div
        className="relative"
        style={{
          width: CANVAS_W,
          height: CANVAS_H,
          transform: `translate(${pan.x}px, ${pan.y}px) scale(${effectiveScale})`,
          transformOrigin: "center center",
          transition: isPanning.current ? "none" : "transform 0.08s ease-out",
        }}
      >
        {/* White canvas background */}
        <div
          className="absolute inset-0 rounded-sm bg-white shadow-lg shadow-black/30"
          style={{ width: CANVAS_W, height: CANVAS_H }}
        />

        {/* Onion skin */}
        <canvas ref={onionCanvasRef} className="absolute inset-0 pointer-events-none"
          style={{ width: CANVAS_W, height: CANVAS_H }} />

        {/* Layers below */}
        <canvas ref={belowCanvasRef} className="absolute inset-0 pointer-events-none"
          style={{ width: CANVAS_W, height: CANVAS_H }} />

        {/* Main drawing canvas */}
        <canvas
          ref={canvasRef}
          className={`absolute inset-0 touch-none ${cursorClass}`}
          style={{ width: CANVAS_W, height: CANVAS_H }}
          onPointerDown={handlePointerDown}
          onPointerMove={handlePointerMove}
          onPointerUp={handlePointerUp}
          onPointerLeave={handlePointerUp}
          onDoubleClick={handleDoubleClick}
        />

        {/* Selection overlay */}
        <canvas ref={selectionCanvasRef} className="absolute inset-0 pointer-events-none"
          style={{ width: CANVAS_W, height: CANVAS_H }} />

        {/* Layers above */}
        <canvas ref={aboveCanvasRef} className="absolute inset-0 pointer-events-none"
          style={{ width: CANVAS_W, height: CANVAS_H }} />

        {/* Grid */}
        <canvas ref={gridCanvasRef} className="absolute inset-0 pointer-events-none"
          style={{ width: CANVAS_W, height: CANVAS_H }} />

        {/* ─── Inserted Image Overlay (moveable/resizable) ─── */}
        {insertedImage && !insertedImage.committed && (
          <div
            className="absolute pointer-events-none"
            style={{
              left: insertedImage.x,
              top: insertedImage.y,
              width: insertedImage.width,
              height: insertedImage.height,
            }}
          >
            <img
              src={insertedImage.url}
              alt={insertedImage.name}
              className="w-full h-full object-contain"
              draggable={false}
            />
            {/* Selection border */}
            <div className="absolute inset-0 border-2 border-dashed border-[#ff2d55] rounded-sm" />
            {/* Corner handles */}
            <div className="absolute -top-2 -left-2 w-4 h-4 bg-white border-2 border-[#ff2d55] rounded-sm" />
            <div className="absolute -top-2 -right-2 w-4 h-4 bg-white border-2 border-[#ff2d55] rounded-sm" />
            <div className="absolute -bottom-2 -left-2 w-4 h-4 bg-white border-2 border-[#ff2d55] rounded-sm" />
            <div className="absolute -bottom-2 -right-2 w-4 h-4 bg-white border-2 border-[#ff2d55] rounded-sm" />
            {/* Move icon center */}
            <div className="absolute inset-0 flex items-center justify-center">
              <div className="bg-black/40 text-white text-xs px-2 py-1 rounded-md backdrop-blur-sm">
                Drag to move · Corners to resize
              </div>
            </div>
          </div>
        )}
      </div>

      {/* Inserted image action buttons */}
      {insertedImage && !insertedImage.committed && (
        <div className="absolute bottom-3 left-1/2 -translate-x-1/2 flex gap-2 z-10">
          <button
            onClick={onCommitInsertedImage}
            className="bg-[#ff2d55] text-white text-xs font-bold px-4 py-2 rounded-xl shadow-lg shadow-[#ff2d55]/30 hover:bg-[#ff1a47] transition-colors"
          >
            ✓ Place Image
          </button>
          <button
            onClick={() => onInsertedImageChange(null)}
            className="bg-[#333] text-white text-xs font-bold px-4 py-2 rounded-xl shadow-lg hover:bg-[#444] transition-colors"
          >
            ✕ Cancel
          </button>
        </div>
      )}

      {/* Zoom indicator + reset */}
      {zoom !== 1 && (
        <button
          onClick={resetView}
          className="absolute bottom-2 right-2 bg-black/60 text-white text-xs px-2.5 py-1 rounded-md hover:bg-black/80 transition-colors"
        >
          {Math.round(zoom * 100)}% — reset
        </button>
      )}
    </div>
  );
}

// ─── Flood Fill ───
function floodFill(
  ctx: CanvasRenderingContext2D,
  startX: number, startY: number,
  fillColor: string,
  width: number, height: number,
  tolerance: number,
) {
  const imageData = ctx.getImageData(0, 0, width, height);
  const data = imageData.data;
  const tempCanvas = document.createElement("canvas");
  tempCanvas.width = 1; tempCanvas.height = 1;
  const tempCtx = tempCanvas.getContext("2d")!;
  tempCtx.fillStyle = fillColor;
  tempCtx.fillRect(0, 0, 1, 1);
  const fc = tempCtx.getImageData(0, 0, 1, 1).data;

  const idx = (startY * width + startX) * 4;
  const tR = data[idx], tG = data[idx + 1], tB = data[idx + 2], tA = data[idx + 3];
  if (tR === fc[0] && tG === fc[1] && tB === fc[2] && tA === fc[3]) return;

  const matches = (i: number) =>
    Math.abs(data[i] - tR) <= tolerance &&
    Math.abs(data[i + 1] - tG) <= tolerance &&
    Math.abs(data[i + 2] - tB) <= tolerance &&
    Math.abs(data[i + 3] - tA) <= tolerance;

  const stack: [number, number][] = [[startX, startY]];
  const visited = new Set<number>();
  while (stack.length > 0) {
    const [x, y] = stack.pop()!;
    const key = y * width + x;
    if (visited.has(key) || x < 0 || x >= width || y < 0 || y >= height) continue;
    const i = key * 4;
    if (!matches(i)) continue;
    visited.add(key);
    data[i] = fc[0]; data[i + 1] = fc[1]; data[i + 2] = fc[2]; data[i + 3] = fc[3];
    stack.push([x + 1, y], [x - 1, y], [x, y + 1], [x, y - 1]);
  }
  ctx.putImageData(imageData, 0, 0);
}
