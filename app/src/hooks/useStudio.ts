/**
 * StickDeath Infinity — Main studio state hook
 *
 * Central orchestrator for the animation studio. Manages frames,
 * figures, tool modes, undo/redo, playback, and panel states.
 *
 * Faithfully ports EditorViewModel.swift to a React hook pattern.
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import { v4 as uuid } from 'uuid';
import type {
  StickFigure,
  FigureStyle,
  JointId,
  Point,
  Rect,
} from '../models/StickFigure';
import {
  createDefaultFigure,
  setJointPosition,
  enforceBoneConstraints,
  translateFigure,
  cloneFigure,
  STYLE_WHITE,
  STYLE_RED,
  STYLE_BLUE,
  DEFAULT_STYLE,
} from '../models/StickFigure';
import type { FrameModel, CameraState } from '../models/Frame';
import {
  createFrame,
  cloneFrame,
  updateFigureInFrame,
  removeFigureFromFrame,
  reorderFigures,
  DEFAULT_CAMERA,
} from '../models/Frame';
import type { ProjectModel, UndoSnapshot } from '../models/Project';
import { createBlankProject, DEFAULT_WORLD } from '../models/Project';

// ─── Tool Modes ─────────────────────────────────────────────────────

export type ToolMode = 'pose' | 'move' | 'draw' | 'eraser';

// ─── Panel State ────────────────────────────────────────────────────

export interface PanelState {
  timeline: boolean;
  layers: boolean;
  properties: boolean;
  backgroundPicker: boolean;
}

// ─── Studio State ───────────────────────────────────────────────────

export interface StudioState {
  project: ProjectModel;
  currentFrame: number;
  selectedFigureId: string | null;
  selectedJointId: JointId | null;
  toolMode: ToolMode;
  panels: PanelState;
  isPlaying: boolean;
  canUndo: boolean;
  canRedo: boolean;
}

// ─── Studio Actions ─────────────────────────────────────────────────

export interface StudioActions {
  // Frame management
  addFrame: () => void;
  duplicateFrame: () => void;
  deleteFrame: () => void;
  goToFrame: (idx: number) => void;
  nextFrame: () => void;
  prevFrame: () => void;
  reorderFrames: (from: number, to: number) => void;
  setFrameDuration: (frameIdx: number, duration: number) => void;

  // Figure management
  addFigure: () => void;
  deleteFigure: (id: string) => void;
  duplicateFigure: (id: string) => void;
  selectFigure: (id: string | null) => void;
  toggleFigureVisibility: (id: string) => void;
  toggleFigureLock: (id: string) => void;
  updateFigureStyle: (id: string, style: Partial<FigureStyle>) => void;
  renameFigure: (id: string, name: string) => void;
  reorderFiguresInFrame: (from: number, to: number) => void;

  // Joint manipulation
  updateJoint: (
    figureId: string,
    jointId: JointId,
    position: Point,
    pinned?: boolean,
  ) => void;
  moveFigure: (figureId: string, delta: { width: number; height: number }) => void;

  // Camera
  setCamera: (camera: Partial<CameraState>) => void;
  resetCamera: () => void;

  // Tools
  setTool: (mode: ToolMode) => void;

  // Undo/Redo
  pushUndo: () => void;
  undo: () => void;
  redo: () => void;

  // Playback
  play: () => void;
  pause: () => void;
  togglePlay: () => void;
  setFps: (fps: number) => void;
  setLoop: (loop: boolean) => void;

  // Panels
  togglePanel: (panel: keyof PanelState) => void;
  closeAllPanels: () => void;

  // Background
  setBackground: (id: string) => void;

  // Onion skinning
  setOnion: (enabled: boolean, prev?: number, next?: number) => void;

  // Project
  setProjectName: (name: string) => void;
  loadProject: (project: ProjectModel) => void;
  getProject: () => ProjectModel;
}

// ─── Constants ──────────────────────────────────────────────────────

const MAX_UNDO = 50;
const FIGURE_STYLES_CYCLE: FigureStyle[] = [STYLE_WHITE, STYLE_RED, STYLE_BLUE, DEFAULT_STYLE];

// ─── Hook ───────────────────────────────────────────────────────────

export function useStudio(
  initialProject?: ProjectModel,
): StudioState & StudioActions {
  // -- Core state --
  const [project, setProject] = useState<ProjectModel>(
    initialProject ?? createBlankProject(),
  );
  const [currentFrame, setCurrentFrame] = useState(0);
  const [selectedFigureId, setSelectedFigureId] = useState<string | null>(
    project.frames[0]?.figures[0]?.id ?? null,
  );
  const [selectedJointId, setSelectedJointId] = useState<JointId | null>(null);
  const [toolMode, setToolMode] = useState<ToolMode>('pose');
  const [isPlaying, setIsPlaying] = useState(false);
  const [panels, setPanels] = useState<PanelState>({
    timeline: false,
    layers: false,
    properties: false,
    backgroundPicker: false,
  });

  // -- Undo/Redo stacks (refs for performance) --
  const undoStack = useRef<UndoSnapshot[]>([]);
  const redoStack = useRef<UndoSnapshot[]>([]);
  const [canUndo, setCanUndo] = useState(false);
  const [canRedo, setCanRedo] = useState(false);

  // -- Playback timer --
  const playbackRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const frameCountRef = useRef(project.frames.length);
  frameCountRef.current = project.frames.length;

  // -- Derived values --
  const frame: FrameModel | undefined = project.frames[currentFrame];

  // ─── Undo System ────────────────────────────────────────────────

  const pushUndo = useCallback(() => {
    setProject((prev) => {
      undoStack.current.push({
        frames: JSON.parse(JSON.stringify(prev.frames)),
        currentFrame,
      });
      if (undoStack.current.length > MAX_UNDO) undoStack.current.shift();
      redoStack.current = [];
      setCanUndo(true);
      setCanRedo(false);
      return prev;
    });
  }, [currentFrame]);

  const undo = useCallback(() => {
    const snap = undoStack.current.pop();
    if (!snap) return;

    setProject((prev) => {
      redoStack.current.push({
        frames: JSON.parse(JSON.stringify(prev.frames)),
        currentFrame,
      });
      setCanUndo(undoStack.current.length > 0);
      setCanRedo(true);
      return {
        ...prev,
        frames: snap.frames,
        updatedAt: new Date().toISOString(),
      };
    });
    setCurrentFrame((prev) =>
      Math.min(snap!.currentFrame, (snap!.frames.length || 1) - 1),
    );
  }, [currentFrame]);

  const redo = useCallback(() => {
    const snap = redoStack.current.pop();
    if (!snap) return;

    setProject((prev) => {
      undoStack.current.push({
        frames: JSON.parse(JSON.stringify(prev.frames)),
        currentFrame,
      });
      setCanUndo(true);
      setCanRedo(redoStack.current.length > 0);
      return {
        ...prev,
        frames: snap.frames,
        updatedAt: new Date().toISOString(),
      };
    });
    setCurrentFrame((prev) =>
      Math.min(snap!.currentFrame, (snap!.frames.length || 1) - 1),
    );
  }, [currentFrame]);

  // ─── Frame Management ───────────────────────────────────────────

  const addFrame = useCallback(() => {
    pushUndo();
    setProject((prev) => {
      const cur = prev.frames[currentFrame];
      if (!cur) return prev;
      const newFrame = createFrame(cur.figures);
      const frames = [...prev.frames];
      frames.splice(currentFrame + 1, 0, newFrame);
      return { ...prev, frames, updatedAt: new Date().toISOString() };
    });
    setCurrentFrame((prev) => prev + 1);
  }, [currentFrame, pushUndo]);

  const duplicateFrame = useCallback(() => {
    pushUndo();
    setProject((prev) => {
      const cur = prev.frames[currentFrame];
      if (!cur) return prev;
      const dup = cloneFrame(cur);
      const frames = [...prev.frames];
      frames.splice(currentFrame + 1, 0, dup);
      return { ...prev, frames, updatedAt: new Date().toISOString() };
    });
    setCurrentFrame((prev) => prev + 1);
  }, [currentFrame, pushUndo]);

  const deleteFrame = useCallback(() => {
    setProject((prev) => {
      if (prev.frames.length <= 1) return prev;
      pushUndo();
      const frames = prev.frames.filter((_, i) => i !== currentFrame);
      return { ...prev, frames, updatedAt: new Date().toISOString() };
    });
    setCurrentFrame((prev) => Math.min(prev, project.frames.length - 2));
  }, [currentFrame, project.frames.length, pushUndo]);

  const goToFrame = useCallback(
    (idx: number) => {
      if (idx >= 0 && idx < project.frames.length) {
        setCurrentFrame(idx);
      }
    },
    [project.frames.length],
  );

  const nextFrame = useCallback(() => {
    setCurrentFrame((prev) => {
      if (prev < frameCountRef.current - 1) return prev + 1;
      return project.loopPlayback ? 0 : prev;
    });
  }, [project.loopPlayback]);

  const prevFrame = useCallback(() => {
    setCurrentFrame((prev) => {
      if (prev > 0) return prev - 1;
      return project.loopPlayback ? frameCountRef.current - 1 : prev;
    });
  }, [project.loopPlayback]);

  const reorderFramesAction = useCallback(
    (from: number, to: number) => {
      pushUndo();
      setProject((prev) => {
        const frames = [...prev.frames];
        const [moved] = frames.splice(from, 1);
        frames.splice(to, 0, moved);
        return { ...prev, frames, updatedAt: new Date().toISOString() };
      });
      setCurrentFrame(to);
    },
    [pushUndo],
  );

  const setFrameDuration = useCallback(
    (frameIdx: number, duration: number) => {
      setProject((prev) => {
        const frames = [...prev.frames];
        if (frames[frameIdx]) {
          frames[frameIdx] = { ...frames[frameIdx], duration };
        }
        return { ...prev, frames, updatedAt: new Date().toISOString() };
      });
    },
    [],
  );

  // ─── Figure Management ──────────────────────────────────────────

  const addFigure = useCallback(() => {
    pushUndo();
    setProject((prev) => {
      const f = prev.frames[currentFrame];
      if (!f) return prev;
      const style = FIGURE_STYLES_CYCLE[f.figures.length % FIGURE_STYLES_CYCLE.length];
      const fig = createDefaultFigure(
        `Stick ${f.figures.length + 1}`,
        prev.worldRect,
        style,
      );
      const frames = [...prev.frames];
      frames[currentFrame] = {
        ...f,
        figures: [...f.figures, fig],
      };
      setSelectedFigureId(fig.id);
      return { ...prev, frames, updatedAt: new Date().toISOString() };
    });
  }, [currentFrame, pushUndo]);

  const deleteFigure = useCallback(
    (id: string) => {
      setProject((prev) => {
        const f = prev.frames[currentFrame];
        if (!f || f.figures.length <= 1) return prev;
        pushUndo();
        const frames = [...prev.frames];
        frames[currentFrame] = removeFigureFromFrame(f, id);
        if (selectedFigureId === id) {
          setSelectedFigureId(frames[currentFrame].figures[0]?.id ?? null);
        }
        return { ...prev, frames, updatedAt: new Date().toISOString() };
      });
    },
    [currentFrame, selectedFigureId, pushUndo],
  );

  const duplicateFigure = useCallback(
    (id: string) => {
      pushUndo();
      setProject((prev) => {
        const f = prev.frames[currentFrame];
        if (!f) return prev;
        const fig = f.figures.find((fig) => fig.id === id);
        if (!fig) return prev;
        const dup = cloneFigure(fig);
        // Offset slightly so it's visible
        const offset = translateFigure(dup, { width: 30, height: 30 });
        const frames = [...prev.frames];
        frames[currentFrame] = {
          ...f,
          figures: [...f.figures, offset],
        };
        setSelectedFigureId(offset.id);
        return { ...prev, frames, updatedAt: new Date().toISOString() };
      });
    },
    [currentFrame, pushUndo],
  );

  const selectFigure = useCallback((id: string | null) => {
    setSelectedFigureId(id);
    setSelectedJointId(null);
  }, []);

  const toggleFigureVisibility = useCallback(
    (id: string) => {
      setProject((prev) => {
        const f = prev.frames[currentFrame];
        if (!f) return prev;
        const frames = [...prev.frames];
        frames[currentFrame] = updateFigureInFrame(f, id, (fig) => ({
          ...fig,
          isVisible: !fig.isVisible,
        }));
        return { ...prev, frames };
      });
    },
    [currentFrame],
  );

  const toggleFigureLock = useCallback(
    (id: string) => {
      setProject((prev) => {
        const f = prev.frames[currentFrame];
        if (!f) return prev;
        const frames = [...prev.frames];
        frames[currentFrame] = updateFigureInFrame(f, id, (fig) => ({
          ...fig,
          isLocked: !fig.isLocked,
        }));
        return { ...prev, frames };
      });
    },
    [currentFrame],
  );

  const updateFigureStyle = useCallback(
    (id: string, style: Partial<FigureStyle>) => {
      setProject((prev) => {
        const f = prev.frames[currentFrame];
        if (!f) return prev;
        const frames = [...prev.frames];
        frames[currentFrame] = updateFigureInFrame(f, id, (fig) => ({
          ...fig,
          style: { ...fig.style, ...style },
        }));
        return { ...prev, frames, updatedAt: new Date().toISOString() };
      });
    },
    [currentFrame],
  );

  const renameFigure = useCallback(
    (id: string, name: string) => {
      setProject((prev) => {
        const f = prev.frames[currentFrame];
        if (!f) return prev;
        const frames = [...prev.frames];
        frames[currentFrame] = updateFigureInFrame(f, id, (fig) => ({
          ...fig,
          name,
        }));
        return { ...prev, frames };
      });
    },
    [currentFrame],
  );

  const reorderFiguresInFrame = useCallback(
    (from: number, to: number) => {
      pushUndo();
      setProject((prev) => {
        const f = prev.frames[currentFrame];
        if (!f) return prev;
        const frames = [...prev.frames];
        frames[currentFrame] = reorderFigures(f, from, to);
        return { ...prev, frames, updatedAt: new Date().toISOString() };
      });
    },
    [currentFrame, pushUndo],
  );

  // ─── Joint Manipulation ─────────────────────────────────────────

  const updateJoint = useCallback(
    (
      figureId: string,
      jointId: JointId,
      position: Point,
      pinned = true,
    ) => {
      setSelectedFigureId(figureId);
      setSelectedJointId(jointId);

      setProject((prev) => {
        const f = prev.frames[currentFrame];
        if (!f) return prev;
        const frames = [...prev.frames];
        frames[currentFrame] = updateFigureInFrame(f, figureId, (fig) => {
          let updated = setJointPosition(fig, jointId, position);
          updated = enforceBoneConstraints(updated, pinned ? jointId : null, 10);
          return updated;
        });
        return { ...prev, frames };
      });
    },
    [currentFrame],
  );

  const moveFigure = useCallback(
    (figureId: string, delta: { width: number; height: number }) => {
      setProject((prev) => {
        const f = prev.frames[currentFrame];
        if (!f) return prev;
        const frames = [...prev.frames];
        frames[currentFrame] = updateFigureInFrame(f, figureId, (fig) =>
          translateFigure(fig, delta),
        );
        return { ...prev, frames };
      });
    },
    [currentFrame],
  );

  // ─── Camera ─────────────────────────────────────────────────────

  const setCameraAction = useCallback((camera: Partial<CameraState>) => {
    setProject((prev) => ({
      ...prev,
      camera: { ...prev.camera, ...camera },
    }));
  }, []);

  const resetCamera = useCallback(() => {
    setProject((prev) => ({
      ...prev,
      camera: DEFAULT_CAMERA,
    }));
  }, []);

  // ─── Tool ───────────────────────────────────────────────────────

  const setTool = useCallback((mode: ToolMode) => {
    setToolMode(mode);
    setSelectedJointId(null);
  }, []);

  // ─── Playback ───────────────────────────────────────────────────

  const play = useCallback(() => {
    setIsPlaying(true);
    setPanels({ timeline: false, layers: false, properties: false, backgroundPicker: false });
  }, []);

  const pause = useCallback(() => {
    setIsPlaying(false);
  }, []);

  const togglePlay = useCallback(() => {
    setIsPlaying((prev) => {
      if (!prev) {
        // Close panels on play
        setPanels({ timeline: false, layers: false, properties: false, backgroundPicker: false });
      }
      return !prev;
    });
  }, []);

  // Playback timer
  useEffect(() => {
    if (isPlaying) {
      const interval = 1000 / Math.max(project.fps, 1);
      playbackRef.current = setInterval(() => {
        setCurrentFrame((prev) => {
          if (prev >= frameCountRef.current - 1) {
            if (project.loopPlayback) return 0;
            setIsPlaying(false);
            return prev;
          }
          return prev + 1;
        });
      }, interval);
    } else if (playbackRef.current) {
      clearInterval(playbackRef.current);
      playbackRef.current = null;
    }
    return () => {
      if (playbackRef.current) clearInterval(playbackRef.current);
    };
  }, [isPlaying, project.fps, project.loopPlayback]);

  const setFps = useCallback((fps: number) => {
    setProject((prev) => ({
      ...prev,
      fps: Math.max(1, Math.min(60, fps)),
      updatedAt: new Date().toISOString(),
    }));
  }, []);

  const setLoop = useCallback((loop: boolean) => {
    setProject((prev) => ({ ...prev, loopPlayback: loop }));
  }, []);

  // ─── Panels ─────────────────────────────────────────────────────

  const togglePanel = useCallback((panel: keyof PanelState) => {
    setPanels((prev) => {
      const next = { ...prev, [panel]: !prev[panel] };
      // Properties and layers are mutually exclusive side panels
      if (panel === 'properties' && next.properties) next.layers = false;
      if (panel === 'layers' && next.layers) next.properties = false;
      return next;
    });
  }, []);

  const closeAllPanels = useCallback(() => {
    setPanels({ timeline: false, layers: false, properties: false, backgroundPicker: false });
  }, []);

  // ─── Background ─────────────────────────────────────────────────

  const setBackground = useCallback((id: string) => {
    setProject((prev) => ({
      ...prev,
      backgroundId: id,
      updatedAt: new Date().toISOString(),
    }));
  }, []);

  // ─── Onion Skinning ─────────────────────────────────────────────

  const setOnion = useCallback(
    (enabled: boolean, prev?: number, next?: number) => {
      setProject((p) => ({
        ...p,
        onionEnabled: enabled,
        onionPrev: prev ?? p.onionPrev,
        onionNext: next ?? p.onionNext,
      }));
    },
    [],
  );

  // ─── Project-level ──────────────────────────────────────────────

  const setProjectName = useCallback((name: string) => {
    setProject((prev) => ({ ...prev, name, updatedAt: new Date().toISOString() }));
  }, []);

  const loadProject = useCallback((proj: ProjectModel) => {
    setProject(proj);
    setCurrentFrame(0);
    setSelectedFigureId(proj.frames[0]?.figures[0]?.id ?? null);
    setSelectedJointId(null);
    undoStack.current = [];
    redoStack.current = [];
    setCanUndo(false);
    setCanRedo(false);
  }, []);

  const getProject = useCallback(() => project, [project]);

  // ─── Return ─────────────────────────────────────────────────────

  return {
    // State
    project,
    currentFrame,
    selectedFigureId,
    selectedJointId,
    toolMode,
    panels,
    isPlaying,
    canUndo,
    canRedo,

    // Actions
    addFrame,
    duplicateFrame,
    deleteFrame,
    goToFrame,
    nextFrame,
    prevFrame,
    reorderFrames: reorderFramesAction,
    setFrameDuration,

    addFigure,
    deleteFigure,
    duplicateFigure,
    selectFigure,
    toggleFigureVisibility,
    toggleFigureLock,
    updateFigureStyle,
    renameFigure,
    reorderFiguresInFrame,

    updateJoint,
    moveFigure,

    setCamera: setCameraAction,
    resetCamera,

    setTool,

    pushUndo,
    undo,
    redo,

    play,
    pause,
    togglePlay,
    setFps,
    setLoop,

    togglePanel,
    closeAllPanels,

    setBackground,
    setOnion,

    setProjectName,
    loadProject,
    getProject,
  };
}
