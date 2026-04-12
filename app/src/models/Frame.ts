/**
 * StickDeath Infinity — Frame model
 *
 * A single animation frame containing one or more posed StickFigures,
 * camera state, and per-frame timing.
 */

import { v4 as uuid } from 'uuid';
import type { StickFigure, Point } from './StickFigure';
import { cloneFigure } from './StickFigure';

// ─── Camera State ───────────────────────────────────────────────────

export interface CameraState {
  panX: number;
  panY: number;
  zoom: number;
  rotationRadians: number;
}

export const DEFAULT_CAMERA: CameraState = {
  panX: 0,
  panY: 0,
  zoom: 1.0,
  rotationRadians: 0,
};

// ─── Camera Transform Utilities ─────────────────────────────────────

/**
 * Convert a world-space point to screen-space given camera state
 * and the stage center (half the canvas dimensions).
 */
export function worldToScreen(
  p: Point,
  camera: CameraState,
  stageCenter: Point,
): Point {
  const cos = Math.cos(camera.rotationRadians);
  const sin = Math.sin(camera.rotationRadians);

  // Scale → Rotate → Translate
  const sx = p.x * camera.zoom;
  const sy = p.y * camera.zoom;
  const rx = sx * cos - sy * sin;
  const ry = sx * sin + sy * cos;

  return {
    x: rx + camera.panX + stageCenter.x,
    y: ry + camera.panY + stageCenter.y,
  };
}

/**
 * Convert a screen-space point to world-space (inverse of worldToScreen).
 */
export function screenToWorld(
  p: Point,
  camera: CameraState,
  stageCenter: Point,
): Point {
  const dx = p.x - camera.panX - stageCenter.x;
  const dy = p.y - camera.panY - stageCenter.y;

  const cos = Math.cos(-camera.rotationRadians);
  const sin = Math.sin(-camera.rotationRadians);
  const rx = dx * cos - dy * sin;
  const ry = dx * sin + dy * cos;

  const z = camera.zoom || 1;
  return { x: rx / z, y: ry / z };
}

// ─── Frame Model ────────────────────────────────────────────────────

export interface FrameModel {
  id: string;
  figures: StickFigure[];
  /** Per-frame duration override in seconds (0 = use project FPS). */
  duration: number;
}

/** Create a blank frame with a deep clone of provided figures. */
export function createFrame(figures: StickFigure[], duration = 0): FrameModel {
  return {
    id: uuid(),
    figures: figures.map((f) => cloneFigure(f, f.name)),
    duration,
  };
}

/** Deep-clone a frame (new id, deep-copied figures). */
export function cloneFrame(frame: FrameModel): FrameModel {
  return {
    id: uuid(),
    figures: frame.figures.map((f) => cloneFigure(f, f.name)),
    duration: frame.duration,
  };
}

/** Replace a figure inside a frame by id. */
export function updateFigureInFrame(
  frame: FrameModel,
  figureId: string,
  updater: (fig: StickFigure) => StickFigure,
): FrameModel {
  return {
    ...frame,
    figures: frame.figures.map((f) => (f.id === figureId ? updater(f) : f)),
  };
}

/** Remove a figure from a frame. Returns unchanged frame if only 1 figure. */
export function removeFigureFromFrame(
  frame: FrameModel,
  figureId: string,
): FrameModel {
  if (frame.figures.length <= 1) return frame;
  return {
    ...frame,
    figures: frame.figures.filter((f) => f.id !== figureId),
  };
}

/** Reorder figures in a frame (move from one index to another). */
export function reorderFigures(
  frame: FrameModel,
  fromIndex: number,
  toIndex: number,
): FrameModel {
  const figs = [...frame.figures];
  const [moved] = figs.splice(fromIndex, 1);
  figs.splice(toIndex, 0, moved);
  return { ...frame, figures: figs };
}
