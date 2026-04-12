/**
 * StickDeath Infinity — Studio Canvas
 *
 * The main Skia canvas that renders stick figures, handles gestures,
 * and displays onion skinning, grid lines, and joint handles.
 *
 * Uses @shopify/react-native-skia for all rendering and
 * react-native-gesture-handler for touch input.
 */

import React, { useMemo } from 'react';
import { StyleSheet, View, useWindowDimensions } from 'react-native';
import {
  Canvas,
  Circle,
  Group,
  Line,
  LinearGradient,
  Paint,
  Path,
  Skia,
  vec,
  BlurMask,
  Rect as SkRect,
  DashPathEffect,
  RoundedRect,
} from '@shopify/react-native-skia';
import { GestureDetector } from 'react-native-gesture-handler';
import type { StickFigure, JointId, Point } from '../../models/StickFigure';
import { BONES, getJointPoint, styleToColor, styleToRGBA } from '../../models/StickFigure';
import type { FrameModel, CameraState } from '../../models/Frame';
import { worldToScreen } from '../../models/Frame';
import { getBackground, type BackgroundPreset } from '../../models/Project';
import type { ToolMode, StudioActions } from '../../hooks/useStudio';
import { useGestures } from '../../hooks/useGestures';
import { Colors } from '../../theme/colors';

// ─── Props ──────────────────────────────────────────────────────────

interface StudioCanvasProps {
  /** All frames for onion skinning */
  frames: FrameModel[];
  /** Current frame index */
  currentFrameIndex: number;
  /** Camera state */
  camera: CameraState;
  /** Background preset id */
  backgroundId: string;
  /** Onion skinning config */
  onion: { enabled: boolean; prev: number; next: number };
  /** Currently selected figure id */
  selectedFigureId: string | null;
  /** Currently selected joint id */
  selectedJointId: JointId | null;
  /** Active tool mode */
  toolMode: ToolMode;
  /** Whether playback is active */
  isPlaying: boolean;
  /** Show grid lines */
  showGrid?: boolean;
  /** Studio actions */
  actions: StudioActions;
}

// ─── Grid rendering ─────────────────────────────────────────────────

const GRID_SPACING = 50;

function GridLines({
  width,
  height,
  camera,
}: {
  width: number;
  height: number;
  camera: CameraState;
}) {
  const center = { x: width / 2, y: height / 2 };

  // Build grid paths
  const gridPath = useMemo(() => {
    const p = Skia.Path.Make();
    const range = Math.max(width, height) * 3;
    const step = GRID_SPACING;

    for (let i = -range; i <= range; i += step) {
      p.moveTo(i, -range);
      p.lineTo(i, range);
      p.moveTo(-range, i);
      p.lineTo(range, i);
    }
    return p;
  }, [width, height]);

  const majorGridPath = useMemo(() => {
    const p = Skia.Path.Make();
    const range = Math.max(width, height) * 3;
    const step = GRID_SPACING * 5;

    for (let i = -range; i <= range; i += step) {
      p.moveTo(i, -range);
      p.lineTo(i, range);
      p.moveTo(-range, i);
      p.lineTo(range, i);
    }
    return p;
  }, [width, height]);

  return (
    <Group
      transform={[
        { translateX: center.x + camera.panX },
        { translateY: center.y + camera.panY },
        { rotate: camera.rotationRadians },
        { scale: camera.zoom },
      ]}
    >
      <Path
        path={gridPath}
        color={Colors.canvasGrid}
        style="stroke"
        strokeWidth={0.5 / camera.zoom}
      />
      <Path
        path={majorGridPath}
        color={Colors.canvasGridMajor}
        style="stroke"
        strokeWidth={1 / camera.zoom}
      />
    </Group>
  );
}

// ─── Background rendering ───────────────────────────────────────────

function CanvasBackground({
  width,
  height,
  preset,
}: {
  width: number;
  height: number;
  preset: BackgroundPreset;
}) {
  switch (preset.type) {
    case 'gradient':
      return (
        <SkRect x={0} y={0} width={width} height={height}>
          <LinearGradient
            start={vec(0, 0)}
            end={vec(0, height)}
            colors={[preset.color1, preset.color2 ?? preset.color1]}
          />
        </SkRect>
      );

    case 'horizon':
      return (
        <Group>
          <SkRect x={0} y={0} width={width} height={height / 2}>
            <LinearGradient
              start={vec(0, 0)}
              end={vec(0, height / 2)}
              colors={[preset.color1, preset.color2 ?? preset.color1]}
            />
          </SkRect>
          <SkRect
            x={0}
            y={height / 2}
            width={width}
            height={height / 2}
          >
            <LinearGradient
              start={vec(0, height / 2)}
              end={vec(0, height)}
              colors={[preset.color2 ?? '#333', '#111']}
            />
          </SkRect>
        </Group>
      );

    case 'grid': {
      const gridPath = Skia.Path.Make();
      const step = 40;
      for (let x = 0; x <= width; x += step) {
        gridPath.moveTo(x, 0);
        gridPath.lineTo(x, height);
      }
      for (let y = 0; y <= height; y += step) {
        gridPath.moveTo(0, y);
        gridPath.lineTo(width, y);
      }
      return (
        <Group>
          <SkRect x={0} y={0} width={width} height={height} color={preset.color1} />
          <Path
            path={gridPath}
            color={preset.color2 ?? '#333'}
            style="stroke"
            strokeWidth={0.5}
            opacity={0.4}
          />
        </Group>
      );
    }

    case 'dots': {
      const dotPath = Skia.Path.Make();
      const step = 30;
      for (let x = step; x < width; x += step) {
        for (let y = step; y < height; y += step) {
          dotPath.addCircle(x, y, 1.5);
        }
      }
      return (
        <Group>
          <SkRect x={0} y={0} width={width} height={height} color={preset.color1} />
          <Path path={dotPath} color={preset.color2 ?? '#444'} style="fill" opacity={0.5} />
        </Group>
      );
    }

    case 'speedLines': {
      const linePath = Skia.Path.Make();
      const cx = width / 2;
      const cy = height / 2;
      const count = 60;
      for (let i = 0; i < count; i++) {
        const angle = (i / count) * Math.PI * 2;
        const r1 = Math.min(width, height) * 0.15;
        const r2 = Math.max(width, height) * 0.8;
        linePath.moveTo(cx + Math.cos(angle) * r1, cy + Math.sin(angle) * r1);
        linePath.lineTo(cx + Math.cos(angle) * r2, cy + Math.sin(angle) * r2);
      }
      return (
        <Group>
          <SkRect x={0} y={0} width={width} height={height} color={preset.color1} />
          <Path
            path={linePath}
            color={preset.color2 ?? '#333'}
            style="stroke"
            strokeWidth={1.5}
            opacity={0.25}
          />
        </Group>
      );
    }

    default:
      return (
        <SkRect x={0} y={0} width={width} height={height} color={preset.color1} />
      );
  }
}

// ─── Figure rendering ───────────────────────────────────────────────

interface FigureRendererProps {
  figure: StickFigure;
  camera: CameraState;
  center: Point;
  /** Override color + opacity for onion skin */
  overrideColor?: string;
  overrideOpacity?: number;
  /** Whether to draw joint handles */
  showHandles?: boolean;
  /** Currently selected joint for highlight */
  selectedJointId?: JointId | null;
  isSelected?: boolean;
}

function FigureRenderer({
  figure,
  camera,
  center,
  overrideColor,
  overrideOpacity,
  showHandles = false,
  selectedJointId,
  isSelected = false,
}: FigureRendererProps) {
  if (!figure.isVisible) return null;

  const color = overrideColor ?? styleToColor(figure.style);
  const opacity = overrideOpacity ?? 1;
  const lineWidth = figure.style.lineWidth;
  const headRadius = figure.style.headRadius;

  // Transform joints to screen space
  const screenJoints = useMemo(() => {
    const map: Record<string, Point> = {};
    for (const j of figure.joints) {
      map[j.id] = worldToScreen({ x: j.x, y: j.y }, camera, center);
    }
    return map;
  }, [figure.joints, camera, center]);

  // Build bone paths
  const bonePath = useMemo(() => {
    const p = Skia.Path.Make();
    for (const [a, b] of BONES) {
      const pA = screenJoints[a];
      const pB = screenJoints[b];
      if (pA && pB) {
        p.moveTo(pA.x, pA.y);
        p.lineTo(pB.x, pB.y);
      }
    }
    return p;
  }, [screenJoints]);

  const headPos = screenJoints['head'];
  const scaledLineWidth = lineWidth * camera.zoom;
  const scaledHeadRadius = headRadius * camera.zoom;
  const handleRadius = Math.max(8, 12 * camera.zoom);

  return (
    <Group opacity={opacity}>
      {/* Bones */}
      <Path
        path={bonePath}
        color={color}
        style="stroke"
        strokeWidth={scaledLineWidth}
        strokeCap="round"
        strokeJoin="round"
      />

      {/* Head circle */}
      {headPos && (
        <Circle
          cx={headPos.x}
          cy={headPos.y}
          r={scaledHeadRadius}
          color={color}
          style="stroke"
          strokeWidth={scaledLineWidth}
        />
      )}

      {/* Selection glow */}
      {isSelected && !overrideColor && headPos && (
        <Circle
          cx={headPos.x}
          cy={headPos.y}
          r={scaledHeadRadius + 6}
          color={Colors.accent}
          style="stroke"
          strokeWidth={2}
          opacity={0.5}
        >
          <BlurMask blur={4} style="normal" />
        </Circle>
      )}

      {/* Joint handles (only in non-onion, non-playing mode) */}
      {showHandles &&
        figure.joints.map((j) => {
          const sp = screenJoints[j.id];
          if (!sp) return null;
          const isActive = selectedJointId === j.id;
          return (
            <Group key={j.id}>
              {/* Hover/active glow */}
              {isActive && (
                <Circle
                  cx={sp.x}
                  cy={sp.y}
                  r={handleRadius + 6}
                  color={Colors.jointHandleActive}
                  opacity={0.3}
                >
                  <BlurMask blur={6} style="normal" />
                </Circle>
              )}
              {/* Handle circle */}
              <Circle
                cx={sp.x}
                cy={sp.y}
                r={handleRadius}
                color={isActive ? Colors.jointHandleActive : Colors.jointHandle}
                style="fill"
              />
              <Circle
                cx={sp.x}
                cy={sp.y}
                r={handleRadius}
                color="rgba(255,255,255,0.3)"
                style="stroke"
                strokeWidth={1.5}
              />
            </Group>
          );
        })}
    </Group>
  );
}

// ─── Crosshair at center ────────────────────────────────────────────

function CenterCrosshair({ x, y }: { x: number; y: number }) {
  const size = 12;
  return (
    <Group opacity={0.2}>
      <Line p1={vec(x - size, y)} p2={vec(x + size, y)} color="#fff" strokeWidth={1} />
      <Line p1={vec(x, y - size)} p2={vec(x, y + size)} color="#fff" strokeWidth={1} />
    </Group>
  );
}

// ─── Main Component ─────────────────────────────────────────────────

export const StudioCanvas: React.FC<StudioCanvasProps> = ({
  frames,
  currentFrameIndex,
  camera,
  backgroundId,
  onion,
  selectedFigureId,
  selectedJointId,
  toolMode,
  isPlaying,
  showGrid = true,
  actions,
}) => {
  const { width, height } = useWindowDimensions();
  const center: Point = { x: width / 2, y: height / 2 };
  const currentFrame = frames[currentFrameIndex];
  const bgPreset = getBackground(backgroundId);

  // Build gesture handler
  const { gesture } = useGestures({
    toolMode,
    camera,
    frame: currentFrame,
    canvasSize: { width, height },
    actions,
    selectedFigureId,
  });

  // ── Onion skin frames ──────────────────────────────────────────

  const onionFrames = useMemo(() => {
    if (!onion.enabled || isPlaying) return [];

    const result: { frame: FrameModel; color: string; opacity: number }[] = [];

    // Previous frames (blue tint)
    for (let i = 1; i <= onion.prev; i++) {
      const idx = currentFrameIndex - i;
      if (idx >= 0 && frames[idx]) {
        const fade = 1 - i / (onion.prev + 1);
        result.push({
          frame: frames[idx],
          color: 'rgba(70,130,255,0.8)',
          opacity: 0.35 * fade,
        });
      }
    }

    // Next frames (green tint)
    for (let i = 1; i <= onion.next; i++) {
      const idx = currentFrameIndex + i;
      if (idx < frames.length && frames[idx]) {
        const fade = 1 - i / (onion.next + 1);
        result.push({
          frame: frames[idx],
          color: 'rgba(70,220,120,0.8)',
          opacity: 0.35 * fade,
        });
      }
    }

    return result;
  }, [onion, currentFrameIndex, frames, isPlaying]);

  return (
    <GestureDetector gesture={gesture}>
      <View style={styles.container}>
        <Canvas style={styles.canvas}>
          {/* Background */}
          <CanvasBackground width={width} height={height} preset={bgPreset} />

          {/* Grid (behind figures) */}
          {showGrid && !isPlaying && (
            <GridLines width={width} height={height} camera={camera} />
          )}

          {/* Center crosshair */}
          {!isPlaying && (
            <CenterCrosshair
              x={center.x + camera.panX}
              y={center.y + camera.panY}
            />
          )}

          {/* Onion skin frames */}
          {onionFrames.map(({ frame: onionFrame, color, opacity }) =>
            onionFrame.figures.map((fig) => (
              <FigureRenderer
                key={`onion-${onionFrame.id}-${fig.id}`}
                figure={fig}
                camera={camera}
                center={center}
                overrideColor={color}
                overrideOpacity={opacity}
              />
            )),
          )}

          {/* Current frame figures */}
          {currentFrame?.figures.map((fig) => (
            <FigureRenderer
              key={fig.id}
              figure={fig}
              camera={camera}
              center={center}
              showHandles={
                !isPlaying &&
                (toolMode === 'pose' || toolMode === 'move') &&
                fig.id === selectedFigureId
              }
              selectedJointId={
                fig.id === selectedFigureId ? selectedJointId : null
              }
              isSelected={fig.id === selectedFigureId}
            />
          ))}
        </Canvas>
      </View>
    </GestureDetector>
  );
};

// ─── Styles ─────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: Colors.canvasBg,
  },
  canvas: {
    flex: 1,
  },
});
