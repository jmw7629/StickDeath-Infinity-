/**
 * StickDeath Infinity — Project model
 *
 * Top-level container for an animation project with full
 * serialize/deserialize support for Supabase storage.
 */

import { v4 as uuid } from 'uuid';
import type { Rect } from './StickFigure';
import { createDefaultFigure, STYLE_WHITE } from './StickFigure';
import type { FrameModel, CameraState } from './Frame';
import { createFrame, DEFAULT_CAMERA } from './Frame';

// ─── Audio Clip (for future SFX timeline) ───────────────────────────

export interface AudioClip {
  id: string;
  assetName: string;
  startFrame: number;
  durationFrames: number;
  volume: number;
}

// ─── Background Preset ──────────────────────────────────────────────

export type BackgroundType =
  | 'solid'
  | 'gradient'
  | 'horizon'
  | 'grid'
  | 'dots'
  | 'speedLines';

export interface BackgroundPreset {
  id: string;
  name: string;
  type: BackgroundType;
  /** Primary colour (hex) */
  color1: string;
  /** Secondary colour (hex, for gradients/horizon) */
  color2?: string;
  /** Optional thumbnail key */
  thumbnail?: string;
}

export const BACKGROUND_PRESETS: BackgroundPreset[] = [
  // Solid
  { id: 'solid_black', name: 'Black', type: 'solid', color1: '#000000' },
  { id: 'solid_white', name: 'White', type: 'solid', color1: '#FFFFFF' },
  { id: 'solid_dark', name: 'Dark Grey', type: 'solid', color1: '#1A1A2E' },
  { id: 'solid_midnight', name: 'Midnight', type: 'solid', color1: '#0D0D1A' },
  { id: 'solid_navy', name: 'Navy', type: 'solid', color1: '#0A1628' },
  { id: 'solid_charcoal', name: 'Charcoal', type: 'solid', color1: '#2C2C3A' },

  // Gradient
  { id: 'grad_sunset', name: 'Sunset', type: 'gradient', color1: '#FF6B6B', color2: '#4834D4' },
  { id: 'grad_ocean', name: 'Ocean', type: 'gradient', color1: '#0652DD', color2: '#1B1464' },
  { id: 'grad_neon', name: 'Neon', type: 'gradient', color1: '#6C5CE7', color2: '#FD79A8' },
  { id: 'grad_forest', name: 'Forest', type: 'gradient', color1: '#00B894', color2: '#006266' },
  { id: 'grad_fire', name: 'Fire', type: 'gradient', color1: '#F97F51', color2: '#B33939' },
  { id: 'grad_ice', name: 'Ice', type: 'gradient', color1: '#74B9FF', color2: '#0984E3' },

  // Horizon (two-tone sky/ground)
  { id: 'horizon_day', name: 'Day', type: 'horizon', color1: '#74B9FF', color2: '#55A76A' },
  { id: 'horizon_night', name: 'Night', type: 'horizon', color1: '#0D0D2B', color2: '#1A1A3E' },
  { id: 'horizon_dusk', name: 'Dusk', type: 'horizon', color1: '#E17055', color2: '#2D3436' },

  // Grid
  { id: 'grid_dark', name: 'Dark Grid', type: 'grid', color1: '#111118', color2: '#222233' },
  { id: 'grid_light', name: 'Light Grid', type: 'grid', color1: '#F0F0F5', color2: '#DDDDE8' },
  { id: 'grid_neon', name: 'Neon Grid', type: 'grid', color1: '#0A0A1A', color2: '#6C5CE7' },

  // Dots
  { id: 'dots_dark', name: 'Dark Dots', type: 'dots', color1: '#111118', color2: '#333344' },
  { id: 'dots_paper', name: 'Paper Dots', type: 'dots', color1: '#F5F5EA', color2: '#CCCCBB' },

  // Speed lines
  { id: 'speed_radial', name: 'Radial Speed', type: 'speedLines', color1: '#111118', color2: '#333355' },
  { id: 'speed_horizontal', name: 'Horizontal Speed', type: 'speedLines', color1: '#0A0A1A', color2: '#444466' },
];

export function getBackground(id: string): BackgroundPreset {
  return BACKGROUND_PRESETS.find((b) => b.id === id) ?? BACKGROUND_PRESETS[0];
}

// ─── Project Model ──────────────────────────────────────────────────

export interface ProjectModel {
  id: string;
  name: string;
  frames: FrameModel[];
  fps: number;
  worldRect: Rect;
  camera: CameraState;
  backgroundId: string;
  onionEnabled: boolean;
  onionPrev: number;
  onionNext: number;
  audioClips: AudioClip[];
  loopPlayback: boolean;
  createdAt: string; // ISO date string
  updatedAt: string;
}

// ─── Default World ──────────────────────────────────────────────────

export const DEFAULT_WORLD: Rect = {
  x: -640,
  y: -360,
  width: 1280,
  height: 720,
};

// ─── Factory ────────────────────────────────────────────────────────

export function createBlankProject(name = 'Untitled'): ProjectModel {
  const fig = createDefaultFigure('Stick 1', DEFAULT_WORLD, STYLE_WHITE);
  const now = new Date().toISOString();

  return {
    id: uuid(),
    name,
    frames: [createFrame([fig])],
    fps: 12,
    worldRect: DEFAULT_WORLD,
    camera: DEFAULT_CAMERA,
    backgroundId: 'solid_black',
    onionEnabled: true,
    onionPrev: 1,
    onionNext: 0,
    audioClips: [],
    loopPlayback: true,
    createdAt: now,
    updatedAt: now,
  };
}

// ─── Serialization (for Supabase JSON column) ───────────────────────

/**
 * Serialize a project to a plain JSON-safe object.
 * This is what gets stored in `projects.data` JSONB column.
 */
export function serializeProject(project: ProjectModel): Record<string, unknown> {
  return JSON.parse(JSON.stringify(project));
}

/**
 * Deserialize a raw Supabase row back into a typed ProjectModel.
 * Applies defaults for any missing fields (forward compatibility).
 */
export function deserializeProject(raw: Record<string, unknown>): ProjectModel {
  const p = raw as unknown as ProjectModel;

  return {
    id: p.id ?? uuid(),
    name: p.name ?? 'Untitled',
    frames: Array.isArray(p.frames) ? p.frames : [],
    fps: typeof p.fps === 'number' ? p.fps : 12,
    worldRect: p.worldRect ?? DEFAULT_WORLD,
    camera: p.camera ?? DEFAULT_CAMERA,
    backgroundId: p.backgroundId ?? 'solid_black',
    onionEnabled: p.onionEnabled ?? true,
    onionPrev: typeof p.onionPrev === 'number' ? p.onionPrev : 1,
    onionNext: typeof p.onionNext === 'number' ? p.onionNext : 0,
    audioClips: Array.isArray(p.audioClips) ? p.audioClips : [],
    loopPlayback: p.loopPlayback ?? true,
    createdAt: p.createdAt ?? new Date().toISOString(),
    updatedAt: p.updatedAt ?? new Date().toISOString(),
  };
}

// ─── Undo snapshot ──────────────────────────────────────────────────

export interface UndoSnapshot {
  frames: FrameModel[];
  currentFrame: number;
}
