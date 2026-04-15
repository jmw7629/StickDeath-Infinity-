import { useState, useCallback } from "react";
import { X, Download, Film, Image, Loader2, CheckCircle2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import type { FrameData } from "./types";
// @ts-expect-error gif.js has no types
import GIF from "gif.js";

interface Props {
  open: boolean;
  onClose: () => void;
  frames: FrameData[];
  layers: { id: string; visible: boolean; opacity: number }[];
  fps: number;
  canvasWidth: number;
  canvasHeight: number;
  projectName?: string;
}

type ExportState = "idle" | "rendering" | "done" | "error";

export default function ExportDialog({
  open,
  onClose,
  frames,
  layers,
  fps,
  canvasWidth,
  canvasHeight,
  projectName = "stickdeath-animation",
}: Props) {
  const [exportState, setExportState] = useState<ExportState>("idle");
  const [progress, setProgress] = useState(0);
  const [outputUrl, setOutputUrl] = useState<string | null>(null);
  const [exportFormat, setExportFormat] = useState<"gif" | "png" | "spritesheet">("gif");

  const renderFrameToCanvas = useCallback(
    (frame: FrameData, targetCanvas: HTMLCanvasElement) => {
      const ctx = targetCanvas.getContext("2d")!;
      ctx.clearRect(0, 0, canvasWidth, canvasHeight);

      // White background for export
      ctx.fillStyle = "#ffffff";
      ctx.fillRect(0, 0, canvasWidth, canvasHeight);

      // Composite visible layers in order
      const visibleLayers = layers.filter((l) => l.visible);

      for (const layer of visibleLayers) {
        const frameLayer = frame.layers.find((fl) => fl.layerId === layer.id);
        if (!frameLayer || frameLayer.isEmpty || !frameLayer.imageData) continue;

        // Draw layer with opacity
        const img = new window.Image();
        img.src = frameLayer.imageData;

        ctx.globalAlpha = layer.opacity;
        ctx.drawImage(img, 0, 0);
        ctx.globalAlpha = 1.0;
      }
    },
    [layers, canvasWidth, canvasHeight],
  );

  const exportGif = useCallback(async () => {
    setExportState("rendering");
    setProgress(0);

    try {
      const gif = new GIF({
        workers: 2,
        quality: 10,
        width: canvasWidth,
        height: canvasHeight,
        workerScript: "/gif.worker.js",
      });

      const tempCanvas = document.createElement("canvas");
      tempCanvas.width = canvasWidth;
      tempCanvas.height = canvasHeight;

      // Pre-load all images first
      const loadImage = (src: string): Promise<HTMLImageElement> =>
        new Promise((resolve, reject) => {
          const img = new window.Image();
          img.onload = () => resolve(img);
          img.onerror = reject;
          img.src = src;
        });

      for (let i = 0; i < frames.length; i++) {
        const frame = frames[i];
        const ctx = tempCanvas.getContext("2d")!;
        ctx.clearRect(0, 0, canvasWidth, canvasHeight);

        // White background
        ctx.fillStyle = "#ffffff";
        ctx.fillRect(0, 0, canvasWidth, canvasHeight);

        // Draw each visible layer
        const visibleLayers = layers.filter((l) => l.visible);
        for (const layer of visibleLayers) {
          const frameLayer = frame.layers.find((fl) => fl.layerId === layer.id);
          if (!frameLayer || frameLayer.isEmpty || !frameLayer.imageData) continue;

          const img = await loadImage(frameLayer.imageData);
          ctx.globalAlpha = layer.opacity;
          ctx.drawImage(img, 0, 0);
          ctx.globalAlpha = 1.0;
        }

        // Add frame to GIF
        const frameCanvas = document.createElement("canvas");
        frameCanvas.width = canvasWidth;
        frameCanvas.height = canvasHeight;
        const frameCtx = frameCanvas.getContext("2d")!;
        frameCtx.drawImage(tempCanvas, 0, 0);

        gif.addFrame(frameCtx, { delay: Math.round(1000 / fps), copy: true });
        setProgress(Math.round(((i + 1) / frames.length) * 80));
      }

      gif.on("progress", (p: number) => {
        setProgress(80 + Math.round(p * 20));
      });

      gif.on("finished", (blob: Blob) => {
        const url = URL.createObjectURL(blob);
        setOutputUrl(url);
        setExportState("done");
        setProgress(100);
      });

      gif.render();
    } catch (err) {
      console.error("GIF export failed:", err);
      setExportState("error");
    }
  }, [frames, layers, fps, canvasWidth, canvasHeight]);

  const exportPng = useCallback(() => {
    setExportState("rendering");
    setProgress(0);

    const tempCanvas = document.createElement("canvas");
    tempCanvas.width = canvasWidth;
    tempCanvas.height = canvasHeight;

    // Render current frame (frame 0 for now — could be currentFrameIndex)
    renderFrameToCanvas(frames[0], tempCanvas);

    const url = tempCanvas.toDataURL("image/png");
    setOutputUrl(url);
    setExportState("done");
    setProgress(100);
  }, [frames, canvasWidth, canvasHeight, renderFrameToCanvas]);

  const exportSpritesheet = useCallback(() => {
    setExportState("rendering");
    setProgress(0);

    const cols = Math.ceil(Math.sqrt(frames.length));
    const rows = Math.ceil(frames.length / cols);

    const sheetCanvas = document.createElement("canvas");
    sheetCanvas.width = canvasWidth * cols;
    sheetCanvas.height = canvasHeight * rows;
    const sheetCtx = sheetCanvas.getContext("2d")!;

    // White background
    sheetCtx.fillStyle = "#ffffff";
    sheetCtx.fillRect(0, 0, sheetCanvas.width, sheetCanvas.height);

    const tempCanvas = document.createElement("canvas");
    tempCanvas.width = canvasWidth;
    tempCanvas.height = canvasHeight;

    for (let i = 0; i < frames.length; i++) {
      renderFrameToCanvas(frames[i], tempCanvas);
      const col = i % cols;
      const row = Math.floor(i / cols);
      sheetCtx.drawImage(tempCanvas, col * canvasWidth, row * canvasHeight);
      setProgress(Math.round(((i + 1) / frames.length) * 100));
    }

    const url = sheetCanvas.toDataURL("image/png");
    setOutputUrl(url);
    setExportState("done");
    setProgress(100);
  }, [frames, canvasWidth, canvasHeight, renderFrameToCanvas]);

  const handleExport = () => {
    if (exportFormat === "gif") exportGif();
    else if (exportFormat === "png") exportPng();
    else if (exportFormat === "spritesheet") exportSpritesheet();
  };

  const handleDownload = () => {
    if (!outputUrl) return;
    const ext = exportFormat === "gif" ? "gif" : "png";
    const suffix = exportFormat === "spritesheet" ? "-spritesheet" : "";
    const a = document.createElement("a");
    a.href = outputUrl;
    a.download = `${projectName}${suffix}.${ext}`;
    a.click();
  };

  const handleClose = () => {
    if (outputUrl) URL.revokeObjectURL(outputUrl);
    setExportState("idle");
    setProgress(0);
    setOutputUrl(null);
    onClose();
  };

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm">
      <div className="bg-[#111118] border border-[#2a2a3a] rounded-2xl w-full max-w-md shadow-2xl">
        {/* Header */}
        <div className="flex items-center justify-between px-5 py-4 border-b border-[#2a2a3a]">
          <div className="flex items-center gap-2">
            <Download size={18} className="text-red-500" />
            <h2 className="text-base font-bold text-white">Export Animation</h2>
          </div>
          <button onClick={handleClose} className="text-[#72728a] hover:text-white transition-colors">
            <X size={18} />
          </button>
        </div>

        {/* Content */}
        <div className="px-5 py-4 space-y-4">
          {/* Format selection */}
          {exportState === "idle" && (
            <>
              <div className="space-y-2">
                <label className="text-xs font-medium text-[#9090a8]">Format</label>
                <div className="grid grid-cols-3 gap-2">
                  <button
                    onClick={() => setExportFormat("gif")}
                    className={`flex flex-col items-center gap-1.5 p-3 rounded-xl border transition-all ${
                      exportFormat === "gif"
                        ? "border-red-600 bg-red-600/10 text-white"
                        : "border-[#2a2a3a] text-[#72728a] hover:text-white hover:border-[#3a3a4a]"
                    }`}
                  >
                    <Film size={20} />
                    <span className="text-xs font-medium">GIF</span>
                    <span className="text-[9px] text-[#72728a]">Animated</span>
                  </button>
                  <button
                    onClick={() => setExportFormat("png")}
                    className={`flex flex-col items-center gap-1.5 p-3 rounded-xl border transition-all ${
                      exportFormat === "png"
                        ? "border-red-600 bg-red-600/10 text-white"
                        : "border-[#2a2a3a] text-[#72728a] hover:text-white hover:border-[#3a3a4a]"
                    }`}
                  >
                    <Image size={20} />
                    <span className="text-xs font-medium">PNG</span>
                    <span className="text-[9px] text-[#72728a]">Single frame</span>
                  </button>
                  <button
                    onClick={() => setExportFormat("spritesheet")}
                    className={`flex flex-col items-center gap-1.5 p-3 rounded-xl border transition-all ${
                      exportFormat === "spritesheet"
                        ? "border-red-600 bg-red-600/10 text-white"
                        : "border-[#2a2a3a] text-[#72728a] hover:text-white hover:border-[#3a3a4a]"
                    }`}
                  >
                    <Image size={20} />
                    <span className="text-xs font-medium">Sheet</span>
                    <span className="text-[9px] text-[#72728a]">Spritesheet</span>
                  </button>
                </div>
              </div>

              {/* Info */}
              <div className="bg-[#0a0a0f] border border-[#2a2a3a] rounded-lg p-3 space-y-1">
                <div className="flex justify-between text-xs">
                  <span className="text-[#72728a]">Frames</span>
                  <span className="text-white">{frames.length}</span>
                </div>
                <div className="flex justify-between text-xs">
                  <span className="text-[#72728a]">FPS</span>
                  <span className="text-white">{fps}</span>
                </div>
                <div className="flex justify-between text-xs">
                  <span className="text-[#72728a]">Resolution</span>
                  <span className="text-white">{canvasWidth}×{canvasHeight}</span>
                </div>
                <div className="flex justify-between text-xs">
                  <span className="text-[#72728a]">Duration</span>
                  <span className="text-white">{(frames.length / fps).toFixed(1)}s</span>
                </div>
              </div>

              <Button
                className="w-full bg-red-600 hover:bg-red-700 text-white font-bold"
                onClick={handleExport}
              >
                <Download size={16} className="mr-2" />
                Export {exportFormat === "gif" ? "GIF" : exportFormat === "png" ? "PNG" : "Spritesheet"}
              </Button>
            </>
          )}

          {/* Rendering progress */}
          {exportState === "rendering" && (
            <div className="text-center py-6">
              <Loader2 size={32} className="mx-auto mb-3 text-red-500 animate-spin" />
              <p className="text-sm font-medium text-white mb-2">
                Rendering{exportFormat === "gif" ? " GIF" : ""}...
              </p>
              <div className="w-full bg-[#0a0a0f] rounded-full h-2 border border-[#2a2a3a]">
                <div
                  className="bg-red-600 h-full rounded-full transition-all duration-300"
                  style={{ width: `${progress}%` }}
                />
              </div>
              <p className="text-xs text-[#72728a] mt-2">{progress}%</p>
            </div>
          )}

          {/* Done */}
          {exportState === "done" && outputUrl && (
            <div className="text-center py-4 space-y-4">
              <CheckCircle2 size={32} className="mx-auto text-green-500" />
              <p className="text-sm font-medium text-white">Export complete!</p>

              {/* Preview */}
              <div className="border border-[#2a2a3a] rounded-xl overflow-hidden bg-[#0a0a0f] max-h-48 flex items-center justify-center">
                {exportFormat === "gif" ? (
                  <img src={outputUrl} alt="Exported GIF" className="max-h-48 object-contain" />
                ) : (
                  <img src={outputUrl} alt="Exported PNG" className="max-h-48 object-contain" />
                )}
              </div>

              <div className="flex gap-2">
                <Button
                  className="flex-1 bg-red-600 hover:bg-red-700 text-white font-bold"
                  onClick={handleDownload}
                >
                  <Download size={16} className="mr-2" />
                  Download
                </Button>
                <Button
                  variant="outline"
                  className="border-[#2a2a3a] text-[#9090a8] hover:text-white"
                  onClick={() => {
                    setExportState("idle");
                    setProgress(0);
                    if (outputUrl) URL.revokeObjectURL(outputUrl);
                    setOutputUrl(null);
                  }}
                >
                  Back
                </Button>
              </div>
            </div>
          )}

          {/* Error */}
          {exportState === "error" && (
            <div className="text-center py-6">
              <p className="text-sm text-red-400 mb-3">Export failed. Try again.</p>
              <Button
                variant="outline"
                className="border-[#2a2a3a] text-white"
                onClick={() => {
                  setExportState("idle");
                  setProgress(0);
                }}
              >
                Retry
              </Button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
