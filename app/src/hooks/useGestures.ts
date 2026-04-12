/**
 * StickDeath Infinity — Gesture processing hook
 *
 * Converts raw touch events from react-native-gesture-handler into
 * studio actions (drag joint, move figure, pinch zoom, pan, rotate).
 * Faithfully ports the Swift EditorViewModel gesture handlers.
 */

import { useCallback, useRef } from 'react';
import { Gesture } from 'react-native-gesture-handler';
import type { GestureUpdateEvent, PanGestureHandlerEventPayload, PinchGestureHandlerEventPayload } from 'react-native-gesture-handler';
import type { SharedValue } from 'react-native-reanimated';
import { runOnJS } from 'react-native-reanimated';
import type { Point } from '../models/StickFigure';
import { figureCenter } from '../models/StickFigure';
import type { CameraState, FrameModel } from '../models/Frame';
import { screenToWorld, worldToScreen } from '../models/Frame';
import type { StudioActions, ToolMode } from './useStudio';

// ─── Types ──────────────────────────────────────────────────────────

export interface JointHit {
  figureId: string;
  jointId: string;
  worldPoint: Point;
  screenDistance: number;
}

export interface GestureConfig {
  /** Current tool mode */
  toolMode: ToolMode;
  /** Current camera state */
  camera: CameraState;
  /** Current frame (for hit testing) */
  frame: FrameModel | undefined;
  /** Canvas dimensions */
  canvasSize: { width: number; height: number };
  /** Studio actions to dispatch into */
  actions: Pick<
    StudioActions,
    | 'updateJoint'
    | 'moveFigure'
    | 'selectFigure'
    | 'setCamera'
    | 'pushUndo'
  >;
  /** Selected figure id for move mode */
  selectedFigureId: string | null;
}

// ─── Hit testing ────────────────────────────────────────────────────

const JOINT_HIT_RADIUS = 34;
const FIGURE_HIT_RADIUS = 80;

function stageCenter(canvasSize: { width: number; height: number }): Point {
  return { x: canvasSize.width / 2, y: canvasSize.height / 2 };
}

function findNearestJoint(
  screenTouch: Point,
  frame: FrameModel,
  camera: CameraState,
  center: Point,
): JointHit | null {
  let best: JointHit | null = null;

  for (const fig of frame.figures) {
    if (!fig.isVisible || fig.isLocked) continue;
    for (const joint of fig.joints) {
      const sp = worldToScreen({ x: joint.x, y: joint.y }, camera, center);
      const d = Math.hypot(sp.x - screenTouch.x, sp.y - screenTouch.y);
      if (d <= JOINT_HIT_RADIUS && (!best || d < best.screenDistance)) {
        best = {
          figureId: fig.id,
          jointId: joint.id,
          worldPoint: { x: joint.x, y: joint.y },
          screenDistance: d,
        };
      }
    }
  }

  return best;
}

function findNearestFigure(
  screenTouch: Point,
  frame: FrameModel,
  camera: CameraState,
  center: Point,
): string | null {
  let bestDist = Infinity;
  let bestId: string | null = null;

  for (const fig of frame.figures) {
    if (!fig.isVisible || fig.isLocked) continue;
    const c = figureCenter(fig);
    const sp = worldToScreen(c, camera, center);
    const d = Math.hypot(sp.x - screenTouch.x, sp.y - screenTouch.y);
    if (d < bestDist) {
      bestDist = d;
      bestId = fig.id;
    }
  }

  return bestDist < FIGURE_HIT_RADIUS ? bestId : null;
}

// ─── Hook ───────────────────────────────────────────────────────────

export function useGestures(config: GestureConfig) {
  const {
    toolMode,
    camera,
    frame,
    canvasSize,
    actions,
    selectedFigureId,
  } = config;

  // Refs for gesture state (to avoid closures)
  const dragStart = useRef<{
    jointWorldPoint: Point;
    touchWorldPoint: Point;
    figureId: string;
    jointId: string;
  } | null>(null);

  const moveStart = useRef<{
    figureId: string;
    worldTouch: Point;
  } | null>(null);

  const cameraStart = useRef<{
    panX: number;
    panY: number;
    zoom: number;
    rotation: number;
  } | null>(null);

  const center = stageCenter(canvasSize);

  // ─── JS callbacks (called from worklet via runOnJS) ─────────

  const onPoseDragBegin = useCallback(
    (x: number, y: number) => {
      if (!frame) return;
      const screenTouch = { x, y };
      const hit = findNearestJoint(screenTouch, frame, camera, center);

      if (hit) {
        const worldTouch = screenToWorld(screenTouch, camera, center);
        dragStart.current = {
          jointWorldPoint: hit.worldPoint,
          touchWorldPoint: worldTouch,
          figureId: hit.figureId,
          jointId: hit.jointId,
        };
        actions.selectFigure(hit.figureId);
        actions.pushUndo();
      } else {
        dragStart.current = null;
        actions.selectFigure(null);
      }
    },
    [frame, camera, center, actions],
  );

  const onPoseDragUpdate = useCallback(
    (x: number, y: number) => {
      if (!dragStart.current) return;
      const worldTouch = screenToWorld({ x, y }, camera, center);
      const { jointWorldPoint, touchWorldPoint, figureId, jointId } =
        dragStart.current;

      const dx = worldTouch.x - touchWorldPoint.x;
      const dy = worldTouch.y - touchWorldPoint.y;
      const newPos = {
        x: jointWorldPoint.x + dx,
        y: jointWorldPoint.y + dy,
      };

      actions.updateJoint(figureId, jointId as any, newPos, true);
    },
    [camera, center, actions],
  );

  const onPoseDragEnd = useCallback(() => {
    dragStart.current = null;
  }, []);

  const onMoveDragBegin = useCallback(
    (x: number, y: number) => {
      if (!frame) return;
      const screenTouch = { x, y };
      const figId = findNearestFigure(screenTouch, frame, camera, center);

      if (figId) {
        const worldTouch = screenToWorld(screenTouch, camera, center);
        moveStart.current = { figureId: figId, worldTouch };
        actions.selectFigure(figId);
        actions.pushUndo();
      } else {
        moveStart.current = null;
      }
    },
    [frame, camera, center, actions],
  );

  const onMoveDragUpdate = useCallback(
    (x: number, y: number) => {
      if (!moveStart.current) return;
      const worldTouch = screenToWorld({ x, y }, camera, center);
      const dx = worldTouch.x - moveStart.current.worldTouch.x;
      const dy = worldTouch.y - moveStart.current.worldTouch.y;

      actions.moveFigure(moveStart.current.figureId, {
        width: dx,
        height: dy,
      });
      moveStart.current.worldTouch = worldTouch;
    },
    [camera, center, actions],
  );

  const onMoveDragEnd = useCallback(() => {
    moveStart.current = null;
  }, []);

  const onCameraPanBegin = useCallback(() => {
    cameraStart.current = {
      panX: camera.panX,
      panY: camera.panY,
      zoom: camera.zoom,
      rotation: camera.rotationRadians,
    };
  }, [camera]);

  const onCameraPanUpdate = useCallback(
    (translationX: number, translationY: number) => {
      if (!cameraStart.current) return;
      actions.setCamera({
        panX: cameraStart.current.panX + translationX,
        panY: cameraStart.current.panY + translationY,
      });
    },
    [actions],
  );

  const onPinchUpdate = useCallback(
    (scale: number) => {
      if (!cameraStart.current) return;
      const newZoom = Math.max(0.25, Math.min(5, cameraStart.current.zoom * scale));
      actions.setCamera({ zoom: newZoom });
    },
    [actions],
  );

  const onRotateUpdate = useCallback(
    (rotation: number) => {
      if (!cameraStart.current) return;
      actions.setCamera({
        rotationRadians: cameraStart.current.rotation + rotation,
      });
    },
    [actions],
  );

  // ─── Composed Gestures ──────────────────────────────────────────

  /**
   * Single-finger pan gesture — behaviour depends on tool mode.
   */
  const panGesture = Gesture.Pan()
    .minPointers(1)
    .maxPointers(1)
    .onBegin((e) => {
      'worklet';
      if (toolMode === 'pose') {
        runOnJS(onPoseDragBegin)(e.absoluteX, e.absoluteY);
      } else if (toolMode === 'move') {
        runOnJS(onMoveDragBegin)(e.absoluteX, e.absoluteY);
      }
    })
    .onUpdate((e) => {
      'worklet';
      if (toolMode === 'pose') {
        runOnJS(onPoseDragUpdate)(e.absoluteX, e.absoluteY);
      } else if (toolMode === 'move') {
        runOnJS(onMoveDragUpdate)(e.absoluteX, e.absoluteY);
      }
    })
    .onEnd(() => {
      'worklet';
      if (toolMode === 'pose') {
        runOnJS(onPoseDragEnd)();
      } else if (toolMode === 'move') {
        runOnJS(onMoveDragEnd)();
      }
    });

  /**
   * Two-finger pan gesture — always camera pan.
   */
  const cameraPanGesture = Gesture.Pan()
    .minPointers(2)
    .maxPointers(2)
    .onBegin(() => {
      'worklet';
      runOnJS(onCameraPanBegin)();
    })
    .onUpdate((e) => {
      'worklet';
      runOnJS(onCameraPanUpdate)(e.translationX, e.translationY);
    });

  /**
   * Pinch gesture — camera zoom.
   */
  const pinchGesture = Gesture.Pinch()
    .onBegin(() => {
      'worklet';
      runOnJS(onCameraPanBegin)();
    })
    .onUpdate((e) => {
      'worklet';
      runOnJS(onPinchUpdate)(e.scale);
    });

  /**
   * Rotation gesture — camera rotate.
   */
  const rotationGesture = Gesture.Rotation()
    .onBegin(() => {
      'worklet';
      runOnJS(onCameraPanBegin)();
    })
    .onUpdate((e) => {
      'worklet';
      runOnJS(onRotateUpdate)(e.rotation);
    });

  /**
   * Composed gesture: single-finger tool + simultaneous two-finger camera.
   */
  const composedGesture = Gesture.Race(
    panGesture,
    Gesture.Simultaneous(cameraPanGesture, pinchGesture, rotationGesture),
  );

  return {
    gesture: composedGesture,
    panGesture,
    cameraPanGesture,
    pinchGesture,
    rotationGesture,
  };
}
