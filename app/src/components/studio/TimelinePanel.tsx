/**
 * StickDeath Infinity — Timeline Panel
 *
 * Slide-up panel from bottom showing frame thumbnails in a horizontal
 * scroll. Supports tap-to-select, long-press context menu, add frame,
 * FPS control, and onion skin toggle.
 *
 * Uses react-native-reanimated for slide animation and
 * react-native-gesture-handler for drag-to-reorder.
 */

import React, { useCallback, useRef, useMemo } from 'react';
import {
  StyleSheet,
  View,
  Text,
  Pressable,
  ScrollView,
  Alert,
} from 'react-native';
import Animated, {
  useAnimatedStyle,
  useSharedValue,
  withSpring,
  SlideInDown,
  SlideOutDown,
} from 'react-native-reanimated';
import { BlurView } from 'expo-blur';
import {
  Canvas,
  Circle,
  Group,
  Path,
  Skia,
  vec,
} from '@shopify/react-native-skia';
import type { FrameModel } from '../../models/Frame';
import type { StickFigure, Point } from '../../models/StickFigure';
import { BONES, getJointPoint, styleToColor } from '../../models/StickFigure';
import type { StudioActions } from '../../hooks/useStudio';
import { Colors, GlassPanel } from '../../theme/colors';

// ─── Constants ──────────────────────────────────────────────────────

const THUMB_W = 80;
const THUMB_H = 56;
const PANEL_HEIGHT = 170;

// ─── Thumbnail renderer ─────────────────────────────────────────────

/**
 * Renders a tiny preview of a frame's stick figures using Skia.
 * Normalizes all figures into the thumbnail viewport.
 */
const FrameThumbnail: React.FC<{
  frame: FrameModel;
  index: number;
  isSelected: boolean;
  onPress: () => void;
  onLongPress: () => void;
}> = ({ frame, index, isSelected, onPress, onLongPress }) => {
  // Compute bounding box of all joints
  const { figures } = frame;

  const thumbnailData = useMemo(() => {
    let minX = Infinity,
      minY = Infinity,
      maxX = -Infinity,
      maxY = -Infinity;

    for (const fig of figures) {
      if (!fig.isVisible) continue;
      for (const j of fig.joints) {
        if (j.x < minX) minX = j.x;
        if (j.y < minY) minY = j.y;
        if (j.x > maxX) maxX = j.x;
        if (j.y > maxY) maxY = j.y;
      }
    }

    if (!isFinite(minX)) return null;

    const w = maxX - minX || 1;
    const h = maxY - minY || 1;
    const padding = 8;
    const scaleX = (THUMB_W - padding * 2) / w;
    const scaleY = (THUMB_H - padding * 2) / h;
    const scale = Math.min(scaleX, scaleY, 1.5);
    const offsetX = (THUMB_W - w * scale) / 2 - minX * scale;
    const offsetY = (THUMB_H - h * scale) / 2 - minY * scale;

    return { scale, offsetX, offsetY };
  }, [figures]);

  return (
    <Pressable
      onPress={onPress}
      onLongPress={onLongPress}
      style={[
        styles.thumbContainer,
        isSelected && styles.thumbSelected,
      ]}
    >
      <Canvas style={styles.thumbCanvas}>
        {/* Dark bg */}
        <Group>
          {thumbnailData &&
            figures.map((fig) => {
              if (!fig.isVisible) return null;
              const { scale, offsetX, offsetY } = thumbnailData;

              const bonePath = Skia.Path.Make();
              for (const [a, b] of BONES) {
                const pA = getJointPoint(fig, a);
                const pB = getJointPoint(fig, b);
                if (pA && pB) {
                  bonePath.moveTo(
                    pA.x * scale + offsetX,
                    pA.y * scale + offsetY,
                  );
                  bonePath.lineTo(
                    pB.x * scale + offsetX,
                    pB.y * scale + offsetY,
                  );
                }
              }

              const head = getJointPoint(fig, 'head');
              const color = styleToColor(fig.style);

              return (
                <Group key={fig.id}>
                  <Path
                    path={bonePath}
                    color={color}
                    style="stroke"
                    strokeWidth={Math.max(1, fig.style.lineWidth * scale * 0.5)}
                    strokeCap="round"
                  />
                  {head && (
                    <Circle
                      cx={head.x * scale + offsetX}
                      cy={head.y * scale + offsetY}
                      r={Math.max(2, fig.style.headRadius * scale * 0.5)}
                      color={color}
                      style="stroke"
                      strokeWidth={Math.max(1, fig.style.lineWidth * scale * 0.4)}
                    />
                  )}
                </Group>
              );
            })}
        </Group>
      </Canvas>

      {/* Frame number badge */}
      <View style={styles.frameBadge}>
        <Text style={styles.frameBadgeText}>{index + 1}</Text>
      </View>
    </Pressable>
  );
};

// ─── FPS Control ────────────────────────────────────────────────────

const FPSControl: React.FC<{
  fps: number;
  onDecrease: () => void;
  onIncrease: () => void;
}> = ({ fps, onDecrease, onIncrease }) => (
  <View style={styles.fpsControl}>
    <Pressable style={styles.fpsBtn} onPress={onDecrease}>
      <Text style={styles.fpsBtnText}>−</Text>
    </Pressable>
    <Text style={styles.fpsValue}>{fps} fps</Text>
    <Pressable style={styles.fpsBtn} onPress={onIncrease}>
      <Text style={styles.fpsBtnText}>+</Text>
    </Pressable>
  </View>
);

// ─── Props ──────────────────────────────────────────────────────────

interface TimelinePanelProps {
  visible: boolean;
  frames: FrameModel[];
  currentFrame: number;
  fps: number;
  onionEnabled: boolean;
  actions: StudioActions;
}

// ─── Component ──────────────────────────────────────────────────────

export const TimelinePanel: React.FC<TimelinePanelProps> = ({
  visible,
  frames,
  currentFrame,
  fps,
  onionEnabled,
  actions,
}) => {
  const scrollRef = useRef<ScrollView>(null);

  const handleFramePress = useCallback(
    (idx: number) => {
      actions.goToFrame(idx);
    },
    [actions],
  );

  const handleFrameLongPress = useCallback(
    (idx: number) => {
      Alert.alert(`Frame ${idx + 1}`, 'Choose action', [
        {
          text: 'Duplicate',
          onPress: () => {
            actions.goToFrame(idx);
            actions.duplicateFrame();
          },
        },
        {
          text: 'Delete',
          style: 'destructive',
          onPress: () => {
            actions.goToFrame(idx);
            actions.deleteFrame();
          },
        },
        { text: 'Cancel', style: 'cancel' },
      ]);
    },
    [actions],
  );

  const handleAddFrame = useCallback(() => {
    actions.addFrame();
    // Scroll to end after a tick
    setTimeout(() => {
      scrollRef.current?.scrollToEnd({ animated: true });
    }, 100);
  }, [actions]);

  if (!visible) return null;

  return (
    <Animated.View
      entering={SlideInDown.springify().damping(20).stiffness(180)}
      exiting={SlideOutDown.duration(200)}
      style={styles.panel}
    >
      <BlurView intensity={50} tint="dark" style={styles.blurWrap}>
        <View style={styles.panelInner}>
          {/* Header */}
          <View style={styles.header}>
            <Text style={styles.headerTitle}>Timeline</Text>
            <View style={styles.headerActions}>
              {/* Onion toggle */}
              <Pressable
                style={[
                  styles.headerBtn,
                  onionEnabled && styles.headerBtnActive,
                ]}
                onPress={() => actions.setOnion(!onionEnabled)}
              >
                <Text style={styles.headerBtnText}>
                  🧅 {onionEnabled ? 'On' : 'Off'}
                </Text>
              </Pressable>

              <FPSControl
                fps={fps}
                onDecrease={() => actions.setFps(fps - 1)}
                onIncrease={() => actions.setFps(fps + 1)}
              />
            </View>
          </View>

          {/* Frame thumbnails */}
          <ScrollView
            ref={scrollRef}
            horizontal
            showsHorizontalScrollIndicator={false}
            contentContainerStyle={styles.thumbScroll}
          >
            {frames.map((frame, idx) => (
              <FrameThumbnail
                key={frame.id}
                frame={frame}
                index={idx}
                isSelected={idx === currentFrame}
                onPress={() => handleFramePress(idx)}
                onLongPress={() => handleFrameLongPress(idx)}
              />
            ))}

            {/* Add frame button */}
            <Pressable
              style={styles.addFrameBtn}
              onPress={handleAddFrame}
            >
              <Text style={styles.addFrameIcon}>＋</Text>
              <Text style={styles.addFrameLabel}>Add</Text>
            </Pressable>
          </ScrollView>

          {/* Scrubber bar */}
          <View style={styles.scrubber}>
            <View style={styles.scrubberTrack}>
              <View
                style={[
                  styles.scrubberFill,
                  {
                    width:
                      frames.length > 1
                        ? `${(currentFrame / (frames.length - 1)) * 100}%`
                        : '0%',
                  },
                ]}
              />
            </View>
            <Text style={styles.scrubberText}>
              {currentFrame + 1} / {frames.length}
            </Text>
          </View>
        </View>
      </BlurView>
    </Animated.View>
  );
};

// ─── Styles ─────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  panel: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    height: PANEL_HEIGHT,
  },
  blurWrap: {
    flex: 1,
    borderTopLeftRadius: 20,
    borderTopRightRadius: 20,
    overflow: 'hidden',
    borderWidth: 1,
    borderBottomWidth: 0,
    borderColor: Colors.glassBorder,
  },
  panelInner: {
    flex: 1,
    backgroundColor: Colors.glass,
    paddingTop: 10,
  },

  // Header
  header: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingHorizontal: 16,
    marginBottom: 8,
  },
  headerTitle: {
    fontSize: 14,
    fontWeight: '700',
    color: Colors.textPrimary,
    letterSpacing: 0.5,
  },
  headerActions: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
  },
  headerBtn: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 8,
    backgroundColor: 'rgba(255,255,255,0.05)',
  },
  headerBtnActive: {
    backgroundColor: Colors.accentDim,
  },
  headerBtnText: {
    fontSize: 11,
    fontWeight: '600',
    color: Colors.textSecondary,
  },

  // Thumbnails
  thumbScroll: {
    paddingHorizontal: 12,
    gap: 8,
    flexDirection: 'row',
    alignItems: 'center',
  },
  thumbContainer: {
    width: THUMB_W,
    height: THUMB_H,
    borderRadius: 10,
    backgroundColor: 'rgba(0,0,0,0.4)',
    borderWidth: 2,
    borderColor: 'transparent',
    overflow: 'hidden',
    marginRight: 8,
  },
  thumbSelected: {
    borderColor: Colors.accent,
    shadowColor: Colors.accent,
    shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.4,
    shadowRadius: 6,
  },
  thumbCanvas: {
    width: THUMB_W - 4,
    height: THUMB_H - 4,
    margin: 2,
  },
  frameBadge: {
    position: 'absolute',
    bottom: 2,
    right: 4,
    backgroundColor: 'rgba(0,0,0,0.6)',
    borderRadius: 4,
    paddingHorizontal: 4,
    paddingVertical: 1,
  },
  frameBadgeText: {
    fontSize: 8,
    fontWeight: '700',
    color: Colors.textSecondary,
  },

  // Add frame
  addFrameBtn: {
    width: THUMB_W,
    height: THUMB_H,
    borderRadius: 10,
    borderWidth: 2,
    borderColor: Colors.divider,
    borderStyle: 'dashed',
    alignItems: 'center',
    justifyContent: 'center',
  },
  addFrameIcon: {
    fontSize: 20,
    color: Colors.textMuted,
  },
  addFrameLabel: {
    fontSize: 9,
    fontWeight: '600',
    color: Colors.textMuted,
    marginTop: 2,
  },

  // FPS control
  fpsControl: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: 'rgba(255,255,255,0.05)',
    borderRadius: 8,
    paddingHorizontal: 4,
  },
  fpsBtn: {
    width: 28,
    height: 28,
    alignItems: 'center',
    justifyContent: 'center',
  },
  fpsBtnText: {
    fontSize: 16,
    fontWeight: '700',
    color: Colors.textSecondary,
  },
  fpsValue: {
    fontSize: 11,
    fontWeight: '700',
    color: Colors.textPrimary,
    minWidth: 40,
    textAlign: 'center',
  },

  // Scrubber
  scrubber: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 16,
    marginTop: 10,
    gap: 10,
  },
  scrubberTrack: {
    flex: 1,
    height: 3,
    borderRadius: 1.5,
    backgroundColor: 'rgba(255,255,255,0.08)',
    overflow: 'hidden',
  },
  scrubberFill: {
    height: '100%',
    backgroundColor: Colors.accent,
    borderRadius: 1.5,
  },
  scrubberText: {
    fontSize: 10,
    fontWeight: '600',
    color: Colors.textMuted,
    minWidth: 50,
    textAlign: 'right',
  },
});
