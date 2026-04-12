/**
 * StickDeath Infinity — Stick Figure rig model
 *
 * Faithful port of the Swift `StickFigure` struct including the iterative
 * constraint solver for bone-length enforcement.
 */

import { v4 as uuid } from 'uuid';

// ─── Geometry helpers ───────────────────────────────────────────────

export interface Point {
  x: number;
  y: number;
}

export interface Size {
  width: number;
  height: number;
}

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

function dist(a: Point, b: Point): number {
  return Math.hypot(b.x - a.x, b.y - a.y);
}

function clamp(val: number, lo: number, hi: number): number {
  return Math.min(Math.max(val, lo), hi);
}

// ─── Joint ──────────────────────────────────────────────────────────

export interface Joint {
  id: JointId;
  x: number;
  y: number;
}

/** All recognised joint identifiers — order matters for default figure. */
export const JOINT_IDS = [
  'head',
  'neck',
  'hip',
  'l_shoulder',
  'l_elbow',
  'l_hand',
  'r_shoulder',
  'r_elbow',
  'r_hand',
  'l_knee',
  'l_foot',
  'r_knee',
  'r_foot',
] as const;

export type JointId = (typeof JOINT_IDS)[number];

// ─── Bones ──────────────────────────────────────────────────────────

/** A bone connects two joints. Order matches Swift `StickFigure.bones`. */
export type Bone = [JointId, JointId];

export const BONES: Bone[] = [
  ['head', 'neck'],
  ['neck', 'l_shoulder'],
  ['l_shoulder', 'l_elbow'],
  ['l_elbow', 'l_hand'],
  ['neck', 'r_shoulder'],
  ['r_shoulder', 'r_elbow'],
  ['r_elbow', 'r_hand'],
  ['neck', 'hip'],
  ['hip', 'l_knee'],
  ['l_knee', 'l_foot'],
  ['hip', 'r_knee'],
  ['r_knee', 'r_foot'],
];

// ─── Figure Style ───────────────────────────────────────────────────

export interface FigureStyle {
  strokeR: number;
  strokeG: number;
  strokeB: number;
  lineWidth: number;
  headRadius: number;
}

function rgbToHex(r: number, g: number, b: number): string {
  const to = (v: number) =>
    Math.round(clamp(v, 0, 1) * 255)
      .toString(16)
      .padStart(2, '0');
  return `#${to(r)}${to(g)}${to(b)}`;
}

export function styleToColor(s: FigureStyle): string {
  return rgbToHex(s.strokeR, s.strokeG, s.strokeB);
}

export function styleToRGBA(s: FigureStyle, alpha = 1): string {
  const r = Math.round(clamp(s.strokeR, 0, 1) * 255);
  const g = Math.round(clamp(s.strokeG, 0, 1) * 255);
  const b = Math.round(clamp(s.strokeB, 0, 1) * 255);
  return `rgba(${r},${g},${b},${alpha})`;
}

export const DEFAULT_STYLE: FigureStyle = {
  strokeR: 0,
  strokeG: 0,
  strokeB: 0,
  lineWidth: 6,
  headRadius: 12,
};

export const STYLE_WHITE: FigureStyle = {
  strokeR: 1,
  strokeG: 1,
  strokeB: 1,
  lineWidth: 6,
  headRadius: 12,
};

export const STYLE_RED: FigureStyle = {
  strokeR: 0.95,
  strokeG: 0.2,
  strokeB: 0.2,
  lineWidth: 6,
  headRadius: 12,
};

export const STYLE_BLUE: FigureStyle = {
  strokeR: 0.2,
  strokeG: 0.4,
  strokeB: 1.0,
  lineWidth: 6,
  headRadius: 12,
};

export const STYLE_PRESETS: FigureStyle[] = [
  DEFAULT_STYLE,
  STYLE_WHITE,
  STYLE_RED,
  STYLE_BLUE,
  { strokeR: 0.1, strokeG: 0.8, strokeB: 0.3, lineWidth: 6, headRadius: 12 },
  { strokeR: 1.0, strokeG: 0.6, strokeB: 0.0, lineWidth: 6, headRadius: 12 },
  { strokeR: 0.6, strokeG: 0.2, strokeB: 0.9, lineWidth: 6, headRadius: 12 },
];

// ─── Stick Figure ───────────────────────────────────────────────────

export interface StickFigure {
  id: string;
  name: string;
  joints: Joint[];
  /** Maps "a->b" to rest length for constraint solving */
  restLengths: Record<string, number>;
  style: FigureStyle;
  isVisible: boolean;
  isLocked: boolean;
}

// -- Joint accessors --

export function getJoint(fig: StickFigure, id: JointId): Joint | undefined {
  return fig.joints.find((j) => j.id === id);
}

export function getJointPoint(fig: StickFigure, id: JointId): Point | undefined {
  const j = getJoint(fig, id);
  return j ? { x: j.x, y: j.y } : undefined;
}

export function setJointPosition(fig: StickFigure, jid: JointId, p: Point): StickFigure {
  return {
    ...fig,
    joints: fig.joints.map((j) => (j.id === jid ? { ...j, x: p.x, y: p.y } : j)),
  };
}

// -- Rest length key (matches Swift) --

function restKey(a: string, b: string): string {
  return `${a}->${b}`;
}

// -- Build rest lengths from current pose --

export function rebuildRestLengths(fig: StickFigure): StickFigure {
  const rl: Record<string, number> = {};
  for (const [a, b] of BONES) {
    const pA = getJointPoint(fig, a);
    const pB = getJointPoint(fig, b);
    if (pA && pB) {
      rl[restKey(a, b)] = dist(pA, pB);
    }
  }
  return { ...fig, restLengths: rl };
}

// -- Constraint solver (faithful port from Swift) --

/**
 * Iteratively enforces bone-length constraints. The pinned joint (being
 * dragged) is immovable; all other joints relax toward rest lengths.
 *
 * Mutates a *copy* so callers get a new object (immutable pattern).
 */
export function enforceBoneConstraints(
  fig: StickFigure,
  pinnedJointId: JointId | null,
  iterations = 10,
): StickFigure {
  if (Object.keys(fig.restLengths).length === 0) return fig;

  // Work with a mutable array internally for perf
  const joints: Joint[] = fig.joints.map((j) => ({ ...j }));

  const getJ = (id: string) => joints.find((j) => j.id === id);
  const setJ = (id: string, p: Point) => {
    const j = joints.find((j) => j.id === id);
    if (j) {
      j.x = p.x;
      j.y = p.y;
    }
  };

  for (let iter = 0; iter < iterations; iter++) {
    for (const [a, b] of BONES) {
      const jA = getJ(a);
      const jB = getJ(b);
      const L = fig.restLengths[restKey(a, b)];
      if (!jA || !jB || L === undefined) continue;

      const dx = jB.x - jA.x;
      const dy = jB.y - jA.y;
      const d = Math.max(0.0001, Math.hypot(dx, dy));
      const diff = (d - L) / d;

      const pinA = pinnedJointId === a;
      const pinB = pinnedJointId === b;

      if (pinA && pinB) continue;

      if (pinA) {
        setJ(b, { x: jB.x - dx * diff, y: jB.y - dy * diff });
      } else if (pinB) {
        setJ(a, { x: jA.x + dx * diff, y: jA.y + dy * diff });
      } else {
        const h = diff * 0.5;
        setJ(a, { x: jA.x + dx * h, y: jA.y + dy * h });
        setJ(b, { x: jB.x - dx * h, y: jB.y - dy * h });
      }
    }
  }

  return { ...fig, joints };
}

// -- Translation --

export function translateFigure(fig: StickFigure, delta: Size): StickFigure {
  return {
    ...fig,
    joints: fig.joints.map((j) => ({
      ...j,
      x: j.x + delta.width,
      y: j.y + delta.height,
    })),
  };
}

// -- Center --

export function figureCenter(fig: StickFigure): Point {
  if (fig.joints.length === 0) return { x: 0, y: 0 };
  const sx = fig.joints.reduce((s, j) => s + j.x, 0);
  const sy = fig.joints.reduce((s, j) => s + j.y, 0);
  return { x: sx / fig.joints.length, y: sy / fig.joints.length };
}

// -- Bounding box --

export function figureBounds(fig: StickFigure): Rect {
  if (fig.joints.length === 0) return { x: 0, y: 0, width: 0, height: 0 };
  let minX = Infinity,
    minY = Infinity,
    maxX = -Infinity,
    maxY = -Infinity;
  for (const j of fig.joints) {
    if (j.x < minX) minX = j.x;
    if (j.y < minY) minY = j.y;
    if (j.x > maxX) maxX = j.x;
    if (j.y > maxY) maxY = j.y;
  }
  const pad = fig.style.headRadius + fig.style.lineWidth;
  return {
    x: minX - pad,
    y: minY - pad,
    width: maxX - minX + pad * 2,
    height: maxY - minY + pad * 2,
  };
}

// -- Clone / serialize --

export function cloneFigure(fig: StickFigure, newName?: string): StickFigure {
  return {
    ...fig,
    id: uuid(),
    name: newName ?? `${fig.name} copy`,
    joints: fig.joints.map((j) => ({ ...j })),
    restLengths: { ...fig.restLengths },
    style: { ...fig.style },
  };
}

/** Create the default T-pose figure (matches Swift defaultFigure). */
export function createDefaultFigure(
  name: string,
  worldRect: Rect = { x: -640, y: -360, width: 1280, height: 720 },
  style: FigureStyle = STYLE_WHITE,
): StickFigure {
  const cx = worldRect.x + worldRect.width / 2;
  const cy = worldRect.y + worldRect.height / 2;

  const J = (id: JointId, dx: number, dy: number): Joint => ({
    id,
    x: cx + dx,
    y: cy + dy,
  });

  const fig: StickFigure = {
    id: uuid(),
    name,
    joints: [
      J('head', 0, -160),
      J('neck', 0, -120),
      J('hip', 0, -40),
      J('l_shoulder', -45, -115),
      J('l_elbow', -85, -80),
      J('l_hand', -110, -45),
      J('r_shoulder', 45, -115),
      J('r_elbow', 85, -80),
      J('r_hand', 110, -45),
      J('l_knee', -35, 40),
      J('l_foot', -45, 120),
      J('r_knee', 35, 40),
      J('r_foot', 45, 120),
    ],
    restLengths: {},
    style,
    isVisible: true,
    isLocked: false,
  };

  return rebuildRestLengths(fig);
}
