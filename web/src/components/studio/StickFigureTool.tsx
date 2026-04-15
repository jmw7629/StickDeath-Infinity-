import { useCallback, useRef, useState, useEffect } from "react";

// ─── Stick Figure Joint System ───
// The stick figure uses a simple skeleton with draggable joints.
// Head is a circle, body parts are lines connecting joints.
// User drags joints to pose, then "stamps" the figure onto the canvas.

export interface Joint {
  id: string;
  x: number;
  y: number;
  parentId: string | null;
  label: string;
}

export interface StickFigureState {
  joints: Joint[];
  headRadius: number;
  lineWidth: number;
  color: string;
}

// Default T-pose centered at (0,0) — will be offset to canvas position
const DEFAULT_JOINTS: Joint[] = [
  { id: "head",       x: 0,   y: -90,  parentId: null,          label: "Head" },
  { id: "neck",       x: 0,   y: -60,  parentId: "head",        label: "Neck" },
  { id: "torso",      x: 0,   y: 0,    parentId: "neck",        label: "Torso" },
  { id: "hip",        x: 0,   y: 40,   parentId: "torso",       label: "Hip" },
  // Arms
  { id: "l_shoulder", x: -25, y: -55,  parentId: "neck",        label: "L Shoulder" },
  { id: "l_elbow",    x: -50, y: -30,  parentId: "l_shoulder",  label: "L Elbow" },
  { id: "l_hand",     x: -70, y: -5,   parentId: "l_elbow",     label: "L Hand" },
  { id: "r_shoulder", x: 25,  y: -55,  parentId: "neck",        label: "R Shoulder" },
  { id: "r_elbow",    x: 50,  y: -30,  parentId: "r_shoulder",  label: "R Elbow" },
  { id: "r_hand",     x: 70,  y: -5,   parentId: "r_elbow",     label: "R Hand" },
  // Legs
  { id: "l_knee",     x: -20, y: 80,   parentId: "hip",         label: "L Knee" },
  { id: "l_foot",     x: -25, y: 120,  parentId: "l_knee",      label: "L Foot" },
  { id: "r_knee",     x: 20,  y: 80,   parentId: "hip",         label: "R Knee" },
  { id: "r_foot",     x: 25,  y: 120,  parentId: "r_knee",      label: "R Foot" },
];

interface Props {
  canvasWidth: number;
  canvasHeight: number;
  color: string;
  lineWidth: number;
  onStamp: (imageData: string) => void;
  visible: boolean;
}

export default function StickFigureTool({
  canvasWidth, canvasHeight, color, lineWidth, onStamp, visible,
}: Props) {
  const svgRef = useRef<SVGSVGElement>(null);
  const [joints, setJoints] = useState<Joint[]>(() =>
    DEFAULT_JOINTS.map((j) => ({
      ...j,
      x: j.x + canvasWidth / 2,
      y: j.y + canvasHeight / 2,
    })),
  );
  const [dragging, setDragging] = useState<string | null>(null);
  const [headRadius, setHeadRadius] = useState(20);

  // Reset position when canvas size changes
  useEffect(() => {
    setJoints(
      DEFAULT_JOINTS.map((j) => ({
        ...j,
        x: j.x + canvasWidth / 2,
        y: j.y + canvasHeight / 2,
      })),
    );
  }, [canvasWidth, canvasHeight]);

  const getJoint = (id: string) => joints.find((j) => j.id === id);

  const handlePointerDown = useCallback((e: React.PointerEvent, jointId: string) => {
    e.stopPropagation();
    e.preventDefault();
    setDragging(jointId);
    (e.target as HTMLElement).setPointerCapture(e.pointerId);
  }, []);

  const handlePointerMove = useCallback((e: React.PointerEvent) => {
    if (!dragging || !svgRef.current) return;
    const svg = svgRef.current;
    const rect = svg.getBoundingClientRect();
    const scaleX = canvasWidth / rect.width;
    const scaleY = canvasHeight / rect.height;
    const x = (e.clientX - rect.left) * scaleX;
    const y = (e.clientY - rect.top) * scaleY;

    setJoints((prev) =>
      prev.map((j) => (j.id === dragging ? { ...j, x, y } : j)),
    );
  }, [dragging, canvasWidth, canvasHeight]);

  const handlePointerUp = useCallback(() => {
    setDragging(null);
  }, []);

  // Stamp the stick figure onto the canvas
  const handleStamp = useCallback(() => {
    const canvas = document.createElement("canvas");
    canvas.width = canvasWidth;
    canvas.height = canvasHeight;
    const ctx = canvas.getContext("2d")!;

    ctx.strokeStyle = color;
    ctx.lineWidth = lineWidth;
    ctx.lineCap = "round";
    ctx.lineJoin = "round";

    // Draw body lines
    for (const joint of joints) {
      if (joint.parentId && joint.id !== "head") {
        const parent = getJoint(joint.parentId);
        if (parent) {
          ctx.beginPath();
          ctx.moveTo(parent.x, parent.y);
          ctx.lineTo(joint.x, joint.y);
          ctx.stroke();
        }
      }
    }

    // Draw head circle
    const head = getJoint("head");
    if (head) {
      ctx.beginPath();
      ctx.arc(head.x, head.y, headRadius, 0, Math.PI * 2);
      ctx.stroke();
    }

    onStamp(canvas.toDataURL());
  }, [joints, color, lineWidth, headRadius, canvasWidth, canvasHeight, onStamp]);

  if (!visible) return null;

  const head = getJoint("head");

  return (
    <div className="absolute inset-0 z-10" style={{ pointerEvents: "auto" }}>
      <svg
        ref={svgRef}
        viewBox={`0 0 ${canvasWidth} ${canvasHeight}`}
        className="w-full h-full"
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
        style={{ cursor: dragging ? "grabbing" : "default" }}
      >
        {/* Body lines */}
        {joints.map((joint) => {
          if (!joint.parentId || joint.id === "head") return null;
          const parent = getJoint(joint.parentId);
          if (!parent) return null;
          return (
            <line
              key={`line-${joint.id}`}
              x1={parent.x} y1={parent.y}
              x2={joint.x} y2={joint.y}
              stroke={color}
              strokeWidth={lineWidth}
              strokeLinecap="round"
            />
          );
        })}

        {/* Head circle */}
        {head && (
          <circle
            cx={head.x} cy={head.y} r={headRadius}
            fill="none"
            stroke={color}
            strokeWidth={lineWidth}
          />
        )}

        {/* Joint handles */}
        {joints.map((joint) => (
          <g key={joint.id}>
            {/* Invisible hit area */}
            <circle
              cx={joint.x} cy={joint.y} r={12}
              fill="transparent"
              className="cursor-grab"
              onPointerDown={(e) => handlePointerDown(e, joint.id)}
            />
            {/* Visible dot */}
            <circle
              cx={joint.x} cy={joint.y}
              r={joint.id === "head" ? 6 : 4}
              fill={dragging === joint.id ? "#dc2626" : "#ff6b6b"}
              stroke="white"
              strokeWidth={1.5}
              className="pointer-events-none"
            />
          </g>
        ))}
      </svg>

      {/* Controls overlay */}
      <div className="absolute top-3 left-1/2 -translate-x-1/2 flex items-center gap-2 bg-[#111118]/90 border border-[#2a2a3a] rounded-lg px-3 py-1.5 shadow-lg">
        <span className="text-xs text-[#9090a8]">Head Size</span>
        <input
          type="range" min={10} max={40} value={headRadius}
          onChange={(e) => setHeadRadius(+e.target.value)}
          className="w-20 accent-red-600"
        />
        <span className="text-xs text-white w-5 text-right">{headRadius}</span>

        <div className="w-px h-4 bg-[#2a2a3a] mx-1" />

        <button
          onClick={handleStamp}
          className="text-xs bg-red-600 hover:bg-red-700 text-white px-3 py-1 rounded transition-colors"
        >
          Stamp
        </button>

        <button
          onClick={() => setJoints(DEFAULT_JOINTS.map((j) => ({
            ...j, x: j.x + canvasWidth / 2, y: j.y + canvasHeight / 2,
          })))}
          className="text-xs text-[#72728a] hover:text-white px-2 py-1 rounded transition-colors"
        >
          Reset
        </button>
      </div>
    </div>
  );
}
