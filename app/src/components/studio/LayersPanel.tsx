/**
 * StickDeath Infinity — Layers Panel
 *
 * Slide-in panel from the left listing all figures in the current
 * frame. Each row shows: colour dot, name, visibility toggle (eye),
 * lock toggle. Tap to select, drag to reorder. Add/delete figure
 * buttons at the bottom.
 */

import React, { useCallback } from 'react';
import {
  StyleSheet,
  View,
  Text,
  Pressable,
  ScrollView,
} from 'react-native';
import Animated, {
  SlideInLeft,
  SlideOutLeft,
  useAnimatedStyle,
  useSharedValue,
  withSpring,
} from 'react-native-reanimated';
import { BlurView } from 'expo-blur';
import type { StickFigure } from '../../models/StickFigure';
import { styleToColor } from '../../models/StickFigure';
import type { FrameModel } from '../../models/Frame';
import type { StudioActions } from '../../hooks/useStudio';
import { Colors } from '../../theme/colors';

// ─── Constants ──────────────────────────────────────────────────────

const PANEL_WIDTH = 240;

// ─── Layer Row ──────────────────────────────────────────────────────

interface LayerRowProps {
  figure: StickFigure;
  isSelected: boolean;
  onSelect: () => void;
  onToggleVisibility: () => void;
  onToggleLock: () => void;
}

const AnimatedPressable = Animated.createAnimatedComponent(Pressable);

const LayerRow: React.FC<LayerRowProps> = ({
  figure,
  isSelected,
  onSelect,
  onToggleVisibility,
  onToggleLock,
}) => {
  const scale = useSharedValue(1);

  const animatedStyle = useAnimatedStyle(() => ({
    transform: [{ scale: scale.value }],
  }));

  const handlePressIn = useCallback(() => {
    scale.value = withSpring(0.97, { damping: 15, stiffness: 300 });
  }, [scale]);

  const handlePressOut = useCallback(() => {
    scale.value = withSpring(1, { damping: 15, stiffness: 300 });
  }, [scale]);

  const color = styleToColor(figure.style);
  const dimmed = !figure.isVisible || figure.isLocked;

  return (
    <AnimatedPressable
      onPress={onSelect}
      onPressIn={handlePressIn}
      onPressOut={handlePressOut}
      style={[
        styles.layerRow,
        isSelected && styles.layerRowSelected,
        animatedStyle,
      ]}
    >
      {/* Colour dot */}
      <View style={[styles.colorDot, { backgroundColor: color }]} />

      {/* Name */}
      <Text
        style={[
          styles.layerName,
          dimmed && styles.layerNameDimmed,
        ]}
        numberOfLines={1}
      >
        {figure.name}
      </Text>

      {/* Action buttons */}
      <View style={styles.layerActions}>
        {/* Visibility toggle */}
        <Pressable
          style={styles.layerActionBtn}
          onPress={onToggleVisibility}
          hitSlop={8}
        >
          <Text style={styles.layerActionIcon}>
            {figure.isVisible ? '👁' : '👁‍🗨'}
          </Text>
          {!figure.isVisible && <View style={styles.strikethrough} />}
        </Pressable>

        {/* Lock toggle */}
        <Pressable
          style={styles.layerActionBtn}
          onPress={onToggleLock}
          hitSlop={8}
        >
          <Text style={styles.layerActionIcon}>
            {figure.isLocked ? '🔒' : '🔓'}
          </Text>
        </Pressable>
      </View>
    </AnimatedPressable>
  );
};

// ─── Props ──────────────────────────────────────────────────────────

interface LayersPanelProps {
  visible: boolean;
  frame: FrameModel | undefined;
  selectedFigureId: string | null;
  actions: StudioActions;
}

// ─── Component ──────────────────────────────────────────────────────

export const LayersPanel: React.FC<LayersPanelProps> = ({
  visible,
  frame,
  selectedFigureId,
  actions,
}) => {
  if (!visible || !frame) return null;

  const figures = frame.figures;

  return (
    <Animated.View
      entering={SlideInLeft.springify().damping(20).stiffness(180)}
      exiting={SlideOutLeft.duration(200)}
      style={styles.panel}
    >
      <BlurView intensity={50} tint="dark" style={styles.blurWrap}>
        <View style={styles.panelInner}>
          {/* Header */}
          <View style={styles.header}>
            <Text style={styles.headerTitle}>Layers</Text>
            <Text style={styles.headerCount}>
              {figures.length} figure{figures.length !== 1 ? 's' : ''}
            </Text>
          </View>

          {/* Figure list (reversed so top = front) */}
          <ScrollView
            style={styles.list}
            contentContainerStyle={styles.listContent}
            showsVerticalScrollIndicator={false}
          >
            {[...figures].reverse().map((fig, revIdx) => {
              const realIdx = figures.length - 1 - revIdx;
              return (
                <LayerRow
                  key={fig.id}
                  figure={fig}
                  isSelected={fig.id === selectedFigureId}
                  onSelect={() => actions.selectFigure(fig.id)}
                  onToggleVisibility={() =>
                    actions.toggleFigureVisibility(fig.id)
                  }
                  onToggleLock={() => actions.toggleFigureLock(fig.id)}
                />
              );
            })}
          </ScrollView>

          {/* Bottom actions */}
          <View style={styles.bottomActions}>
            <Pressable
              style={styles.bottomBtn}
              onPress={actions.addFigure}
            >
              <Text style={styles.bottomBtnIcon}>➕</Text>
              <Text style={styles.bottomBtnText}>Add Figure</Text>
            </Pressable>

            <Pressable
              style={[
                styles.bottomBtn,
                styles.bottomBtnDanger,
                !selectedFigureId && styles.bottomBtnDisabled,
              ]}
              onPress={() =>
                selectedFigureId && actions.deleteFigure(selectedFigureId)
              }
              disabled={!selectedFigureId || figures.length <= 1}
            >
              <Text style={styles.bottomBtnIcon}>🗑️</Text>
              <Text style={styles.bottomBtnText}>Delete</Text>
            </Pressable>
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
    left: 0,
    top: 60,
    bottom: 100,
    width: PANEL_WIDTH,
  },
  blurWrap: {
    flex: 1,
    borderTopRightRadius: 20,
    borderBottomRightRadius: 20,
    overflow: 'hidden',
    borderWidth: 1,
    borderLeftWidth: 0,
    borderColor: Colors.glassBorder,
  },
  panelInner: {
    flex: 1,
    backgroundColor: Colors.glass,
    paddingTop: 14,
    paddingBottom: 10,
  },

  // Header
  header: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingHorizontal: 16,
    marginBottom: 12,
  },
  headerTitle: {
    fontSize: 14,
    fontWeight: '700',
    color: Colors.textPrimary,
    letterSpacing: 0.5,
  },
  headerCount: {
    fontSize: 11,
    fontWeight: '500',
    color: Colors.textMuted,
  },

  // List
  list: {
    flex: 1,
  },
  listContent: {
    paddingHorizontal: 8,
    gap: 4,
  },

  // Layer row
  layerRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 10,
    paddingVertical: 10,
    borderRadius: 10,
    backgroundColor: 'transparent',
  },
  layerRowSelected: {
    backgroundColor: Colors.accentDim,
  },
  colorDot: {
    width: 14,
    height: 14,
    borderRadius: 7,
    marginRight: 10,
    borderWidth: 1.5,
    borderColor: 'rgba(255,255,255,0.15)',
  },
  layerName: {
    flex: 1,
    fontSize: 13,
    fontWeight: '600',
    color: Colors.textPrimary,
  },
  layerNameDimmed: {
    color: Colors.textMuted,
  },
  layerActions: {
    flexDirection: 'row',
    gap: 6,
  },
  layerActionBtn: {
    width: 30,
    height: 30,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 8,
  },
  layerActionIcon: {
    fontSize: 15,
  },
  strikethrough: {
    position: 'absolute',
    width: 20,
    height: 2,
    backgroundColor: Colors.error,
    transform: [{ rotate: '-45deg' }],
    opacity: 0.7,
  },

  // Bottom actions
  bottomActions: {
    flexDirection: 'row',
    paddingHorizontal: 10,
    paddingTop: 10,
    gap: 8,
    borderTopWidth: 1,
    borderTopColor: Colors.divider,
  },
  bottomBtn: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: 8,
    borderRadius: 10,
    backgroundColor: 'rgba(255,255,255,0.05)',
    gap: 6,
  },
  bottomBtnDanger: {
    backgroundColor: 'rgba(255,71,87,0.1)',
  },
  bottomBtnDisabled: {
    opacity: 0.3,
  },
  bottomBtnIcon: {
    fontSize: 14,
  },
  bottomBtnText: {
    fontSize: 11,
    fontWeight: '600',
    color: Colors.textSecondary,
  },
});
