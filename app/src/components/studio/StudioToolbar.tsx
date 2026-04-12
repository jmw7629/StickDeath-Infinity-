/**
 * StickDeath Infinity — Studio Toolbar
 *
 * Floating bottom toolbar with glass effect. Houses tool buttons,
 * figure actions, undo/redo, playback controls, and panel toggles.
 *
 * Uses react-native-reanimated for entrance animation and
 * press feedback.
 */

import React, { useCallback } from 'react';
import { StyleSheet, View, Pressable, Text } from 'react-native';
import Animated, {
  FadeInDown,
  FadeOutDown,
  useAnimatedStyle,
  useSharedValue,
  withSpring,
  withTiming,
  interpolate,
} from 'react-native-reanimated';
import { BlurView } from 'expo-blur';
import { Colors, GlassPanel } from '../../theme/colors';
import type { ToolMode, PanelState, StudioActions } from '../../hooks/useStudio';

// ─── Icon map (SF Symbol names → emoji placeholders) ────────────────
// In production these would be custom SVG icons or an icon font.
// Using descriptive text labels that are clear and compact.

const TOOL_ICONS: Record<string, string> = {
  pose: '🦴',
  move: '✋',
  draw: '✏️',
  // Divider
  addFigure: '➕',
  duplicate: '📋',
  delete: '🗑️',
  // Divider
  undo: '↩️',
  redo: '↪️',
  // Divider
  play: '▶️',
  pause: '⏸️',
  // Divider
  layers: '📑',
  properties: '⚙️',
  timeline: '🎞️',
};

// ─── Tool Button ────────────────────────────────────────────────────

interface ToolButtonProps {
  icon: string;
  label: string;
  isActive?: boolean;
  isDisabled?: boolean;
  onPress: () => void;
}

const AnimatedPressable = Animated.createAnimatedComponent(Pressable);

const ToolButton: React.FC<ToolButtonProps> = ({
  icon,
  label,
  isActive = false,
  isDisabled = false,
  onPress,
}) => {
  const scale = useSharedValue(1);

  const animatedStyle = useAnimatedStyle(() => ({
    transform: [{ scale: scale.value }],
    backgroundColor: isActive
      ? Colors.accentDim
      : 'transparent',
    opacity: isDisabled ? 0.35 : 1,
  }));

  const handlePressIn = useCallback(() => {
    scale.value = withSpring(0.85, { damping: 15, stiffness: 300 });
  }, [scale]);

  const handlePressOut = useCallback(() => {
    scale.value = withSpring(1, { damping: 15, stiffness: 300 });
  }, [scale]);

  return (
    <AnimatedPressable
      style={[styles.toolButton, animatedStyle]}
      onPress={isDisabled ? undefined : onPress}
      onPressIn={handlePressIn}
      onPressOut={handlePressOut}
      disabled={isDisabled}
    >
      <Text style={styles.toolIcon}>{icon}</Text>
      <Text
        style={[
          styles.toolLabel,
          isActive && styles.toolLabelActive,
        ]}
        numberOfLines={1}
      >
        {label}
      </Text>
    </AnimatedPressable>
  );
};

// ─── Divider ────────────────────────────────────────────────────────

const ToolDivider: React.FC = () => <View style={styles.divider} />;

// ─── Props ──────────────────────────────────────────────────────────

interface StudioToolbarProps {
  toolMode: ToolMode;
  isPlaying: boolean;
  canUndo: boolean;
  canRedo: boolean;
  panels: PanelState;
  selectedFigureId: string | null;
  actions: StudioActions;
}

// ─── Component ──────────────────────────────────────────────────────

export const StudioToolbar: React.FC<StudioToolbarProps> = ({
  toolMode,
  isPlaying,
  canUndo,
  canRedo,
  panels,
  selectedFigureId,
  actions,
}) => {
  // Don't show toolbar during playback
  if (isPlaying) {
    return (
      <Animated.View
        entering={FadeInDown.duration(200)}
        exiting={FadeOutDown.duration(200)}
        style={styles.playbackOverlay}
      >
        <Pressable
          style={styles.pauseButton}
          onPress={actions.pause}
        >
          <Text style={styles.pauseIcon}>⏸️</Text>
          <Text style={styles.pauseLabel}>Tap to pause</Text>
        </Pressable>
      </Animated.View>
    );
  }

  return (
    <Animated.View
      entering={FadeInDown.springify().damping(18).stiffness(200)}
      style={styles.container}
    >
      <BlurView intensity={40} tint="dark" style={styles.blurWrap}>
        <View style={styles.toolbar}>
          {/* ── Tool Mode Group ── */}
          <ToolButton
            icon={TOOL_ICONS.pose}
            label="Pose"
            isActive={toolMode === 'pose'}
            onPress={() => actions.setTool('pose')}
          />
          <ToolButton
            icon={TOOL_ICONS.move}
            label="Move"
            isActive={toolMode === 'move'}
            onPress={() => actions.setTool('move')}
          />
          <ToolButton
            icon={TOOL_ICONS.draw}
            label="Draw"
            isActive={toolMode === 'draw'}
            onPress={() => actions.setTool('draw')}
          />

          <ToolDivider />

          {/* ── Figure Actions ── */}
          <ToolButton
            icon={TOOL_ICONS.addFigure}
            label="Add"
            onPress={actions.addFigure}
          />
          <ToolButton
            icon={TOOL_ICONS.duplicate}
            label="Copy"
            isDisabled={!selectedFigureId}
            onPress={() =>
              selectedFigureId && actions.duplicateFigure(selectedFigureId)
            }
          />
          <ToolButton
            icon={TOOL_ICONS.delete}
            label="Del"
            isDisabled={!selectedFigureId}
            onPress={() =>
              selectedFigureId && actions.deleteFigure(selectedFigureId)
            }
          />

          <ToolDivider />

          {/* ── Undo / Redo ── */}
          <ToolButton
            icon={TOOL_ICONS.undo}
            label="Undo"
            isDisabled={!canUndo}
            onPress={actions.undo}
          />
          <ToolButton
            icon={TOOL_ICONS.redo}
            label="Redo"
            isDisabled={!canRedo}
            onPress={actions.redo}
          />

          <ToolDivider />

          {/* ── Playback ── */}
          <ToolButton
            icon={TOOL_ICONS.play}
            label="Play"
            onPress={actions.play}
          />

          <ToolDivider />

          {/* ── Panel Toggles ── */}
          <ToolButton
            icon={TOOL_ICONS.layers}
            label="Layers"
            isActive={panels.layers}
            onPress={() => actions.togglePanel('layers')}
          />
          <ToolButton
            icon={TOOL_ICONS.properties}
            label="Props"
            isActive={panels.properties}
            onPress={() => actions.togglePanel('properties')}
          />
          <ToolButton
            icon={TOOL_ICONS.timeline}
            label="Time"
            isActive={panels.timeline}
            onPress={() => actions.togglePanel('timeline')}
          />
        </View>
      </BlurView>
    </Animated.View>
  );
};

// ─── Styles ─────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: {
    position: 'absolute',
    bottom: 28,
    left: 12,
    right: 12,
    alignItems: 'center',
  },
  blurWrap: {
    borderRadius: 20,
    overflow: 'hidden',
    borderWidth: 1,
    borderColor: Colors.glassBorder,
  },
  toolbar: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 8,
    paddingVertical: 6,
    backgroundColor: Colors.glass,
  },
  toolButton: {
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 12,
    minWidth: 44,
  },
  toolIcon: {
    fontSize: 20,
    marginBottom: 2,
  },
  toolLabel: {
    fontSize: 9,
    fontWeight: '600',
    color: Colors.textMuted,
    letterSpacing: 0.3,
  },
  toolLabelActive: {
    color: Colors.accentLight,
  },
  divider: {
    width: 1,
    height: 32,
    backgroundColor: Colors.divider,
    marginHorizontal: 4,
  },

  // Playback overlay
  playbackOverlay: {
    position: 'absolute',
    bottom: 40,
    alignSelf: 'center',
  },
  pauseButton: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 20,
    paddingVertical: 10,
    borderRadius: 24,
    backgroundColor: 'rgba(0,0,0,0.6)',
    borderWidth: 1,
    borderColor: Colors.glassBorder,
  },
  pauseIcon: {
    fontSize: 18,
    marginRight: 8,
  },
  pauseLabel: {
    fontSize: 13,
    fontWeight: '600',
    color: Colors.textSecondary,
  },
});
