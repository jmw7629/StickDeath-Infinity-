/**
 * StickDeath Infinity — Properties Panel
 *
 * Slide-in panel from the right showing selected figure properties:
 * colour picker (presets + custom), line width slider, head size
 * slider, opacity. Also shows frame properties: duration, background.
 */

import React, { useCallback, useState } from 'react';
import {
  StyleSheet,
  View,
  Text,
  Pressable,
  ScrollView,
  TextInput,
} from 'react-native';
import Animated, {
  SlideInRight,
  SlideOutRight,
  useAnimatedStyle,
  useSharedValue,
  withSpring,
} from 'react-native-reanimated';
import { BlurView } from 'expo-blur';
import Slider from '@react-native-community/slider';
import type { FigureStyle, StickFigure } from '../../models/StickFigure';
import { styleToColor, STYLE_PRESETS } from '../../models/StickFigure';
import type { FrameModel } from '../../models/Frame';
import type { StudioActions } from '../../hooks/useStudio';
import { Colors } from '../../theme/colors';

// ─── Constants ──────────────────────────────────────────────────────

const PANEL_WIDTH = 260;

const COLOR_PRESETS = [
  { r: 1, g: 1, b: 1, hex: '#FFFFFF' },
  { r: 0, g: 0, b: 0, hex: '#000000' },
  { r: 0.95, g: 0.2, b: 0.2, hex: '#F23333' },
  { r: 0.2, g: 0.4, b: 1.0, hex: '#3366FF' },
  { r: 0.1, g: 0.8, b: 0.3, hex: '#19CC4D' },
  { r: 1.0, g: 0.6, b: 0.0, hex: '#FF9900' },
  { r: 0.6, g: 0.2, b: 0.9, hex: '#9933E6' },
  { r: 1.0, g: 0.85, b: 0.0, hex: '#FFD900' },
  { r: 0.0, g: 0.85, b: 0.85, hex: '#00D9D9' },
  { r: 1.0, g: 0.4, b: 0.7, hex: '#FF66B3' },
];

// ─── Section Header ─────────────────────────────────────────────────

const SectionHeader: React.FC<{ title: string }> = ({ title }) => (
  <Text style={styles.sectionTitle}>{title}</Text>
);

// ─── Colour Swatch ──────────────────────────────────────────────────

const ColorSwatch: React.FC<{
  hex: string;
  isSelected: boolean;
  onPress: () => void;
}> = ({ hex, isSelected, onPress }) => (
  <Pressable
    style={[
      styles.colorSwatch,
      { backgroundColor: hex },
      isSelected && styles.colorSwatchSelected,
    ]}
    onPress={onPress}
  />
);

// ─── Slider Row ─────────────────────────────────────────────────────

const SliderRow: React.FC<{
  label: string;
  value: number;
  min: number;
  max: number;
  step?: number;
  unit?: string;
  onValueChange: (v: number) => void;
}> = ({ label, value, min, max, step = 1, unit = '', onValueChange }) => (
  <View style={styles.sliderRow}>
    <View style={styles.sliderHeader}>
      <Text style={styles.sliderLabel}>{label}</Text>
      <Text style={styles.sliderValue}>
        {Math.round(value * 10) / 10}
        {unit}
      </Text>
    </View>
    <Slider
      style={styles.slider}
      minimumValue={min}
      maximumValue={max}
      step={step}
      value={value}
      onValueChange={onValueChange}
      minimumTrackTintColor={Colors.accent}
      maximumTrackTintColor="rgba(255,255,255,0.1)"
      thumbTintColor={Colors.accentLight}
    />
  </View>
);

// ─── Props ──────────────────────────────────────────────────────────

interface PropertiesPanelProps {
  visible: boolean;
  frame: FrameModel | undefined;
  selectedFigure: StickFigure | undefined;
  backgroundId: string;
  currentFrameIndex: number;
  actions: StudioActions;
}

// ─── Component ──────────────────────────────────────────────────────

export const PropertiesPanel: React.FC<PropertiesPanelProps> = ({
  visible,
  frame,
  selectedFigure,
  backgroundId,
  currentFrameIndex,
  actions,
}) => {
  const [editingName, setEditingName] = useState(false);
  const [nameInput, setNameInput] = useState('');

  if (!visible) return null;

  const figColor = selectedFigure ? styleToColor(selectedFigure.style) : '#FFF';

  const handleColorSelect = useCallback(
    (preset: (typeof COLOR_PRESETS)[0]) => {
      if (!selectedFigure) return;
      actions.updateFigureStyle(selectedFigure.id, {
        strokeR: preset.r,
        strokeG: preset.g,
        strokeB: preset.b,
      });
    },
    [selectedFigure, actions],
  );

  const handleStartRename = useCallback(() => {
    if (!selectedFigure) return;
    setNameInput(selectedFigure.name);
    setEditingName(true);
  }, [selectedFigure]);

  const handleFinishRename = useCallback(() => {
    if (selectedFigure && nameInput.trim()) {
      actions.renameFigure(selectedFigure.id, nameInput.trim());
    }
    setEditingName(false);
  }, [selectedFigure, nameInput, actions]);

  return (
    <Animated.View
      entering={SlideInRight.springify().damping(20).stiffness(180)}
      exiting={SlideOutRight.duration(200)}
      style={styles.panel}
    >
      <BlurView intensity={50} tint="dark" style={styles.blurWrap}>
        <ScrollView
          style={styles.panelInner}
          contentContainerStyle={styles.panelContent}
          showsVerticalScrollIndicator={false}
        >
          {/* ── Figure Properties ── */}
          {selectedFigure ? (
            <>
              <View style={styles.header}>
                <Text style={styles.headerTitle}>Figure</Text>
              </View>

              {/* Name */}
              <View style={styles.nameRow}>
                {editingName ? (
                  <TextInput
                    style={styles.nameInput}
                    value={nameInput}
                    onChangeText={setNameInput}
                    onSubmitEditing={handleFinishRename}
                    onBlur={handleFinishRename}
                    autoFocus
                    selectTextOnFocus
                    returnKeyType="done"
                    maxLength={24}
                  />
                ) : (
                  <Pressable onPress={handleStartRename} style={styles.nameDisplay}>
                    <View
                      style={[
                        styles.nameDot,
                        { backgroundColor: figColor },
                      ]}
                    />
                    <Text style={styles.nameText} numberOfLines={1}>
                      {selectedFigure.name}
                    </Text>
                    <Text style={styles.nameEditHint}>✏️</Text>
                  </Pressable>
                )}
              </View>

              {/* Colour */}
              <SectionHeader title="Colour" />
              <View style={styles.colorGrid}>
                {COLOR_PRESETS.map((preset) => {
                  const isSelected =
                    Math.abs(preset.r - selectedFigure.style.strokeR) < 0.02 &&
                    Math.abs(preset.g - selectedFigure.style.strokeG) < 0.02 &&
                    Math.abs(preset.b - selectedFigure.style.strokeB) < 0.02;
                  return (
                    <ColorSwatch
                      key={preset.hex}
                      hex={preset.hex}
                      isSelected={isSelected}
                      onPress={() => handleColorSelect(preset)}
                    />
                  );
                })}
              </View>

              {/* Line Width */}
              <SectionHeader title="Stroke" />
              <SliderRow
                label="Line Width"
                value={selectedFigure.style.lineWidth}
                min={1}
                max={20}
                step={0.5}
                unit="px"
                onValueChange={(v) =>
                  actions.updateFigureStyle(selectedFigure.id, {
                    lineWidth: v,
                  })
                }
              />

              {/* Head Size */}
              <SliderRow
                label="Head Radius"
                value={selectedFigure.style.headRadius}
                min={4}
                max={40}
                step={1}
                unit="px"
                onValueChange={(v) =>
                  actions.updateFigureStyle(selectedFigure.id, {
                    headRadius: v,
                  })
                }
              />

              {/* Separator */}
              <View style={styles.separator} />
            </>
          ) : (
            <View style={styles.emptyState}>
              <Text style={styles.emptyIcon}>👆</Text>
              <Text style={styles.emptyText}>Select a figure to edit</Text>
            </View>
          )}

          {/* ── Frame Properties ── */}
          <View style={styles.header}>
            <Text style={styles.headerTitle}>Frame</Text>
          </View>

          {frame && (
            <>
              <SliderRow
                label="Duration Override"
                value={frame.duration}
                min={0}
                max={2}
                step={0.05}
                unit="s"
                onValueChange={(v) =>
                  actions.setFrameDuration(currentFrameIndex, v)
                }
              />
              <Text style={styles.durationHint}>
                {frame.duration === 0 ? 'Using project FPS' : 'Custom hold'}
              </Text>
            </>
          )}

          {/* Background */}
          <Pressable
            style={styles.bgButton}
            onPress={() => actions.togglePanel('backgroundPicker')}
          >
            <Text style={styles.bgButtonText}>🎨  Change Background</Text>
          </Pressable>
        </ScrollView>
      </BlurView>
    </Animated.View>
  );
};

// ─── Styles ─────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  panel: {
    position: 'absolute',
    right: 0,
    top: 60,
    bottom: 100,
    width: PANEL_WIDTH,
  },
  blurWrap: {
    flex: 1,
    borderTopLeftRadius: 20,
    borderBottomLeftRadius: 20,
    overflow: 'hidden',
    borderWidth: 1,
    borderRightWidth: 0,
    borderColor: Colors.glassBorder,
  },
  panelInner: {
    flex: 1,
    backgroundColor: Colors.glass,
  },
  panelContent: {
    paddingVertical: 14,
    paddingHorizontal: 16,
  },

  // Header
  header: {
    marginBottom: 10,
  },
  headerTitle: {
    fontSize: 14,
    fontWeight: '700',
    color: Colors.textPrimary,
    letterSpacing: 0.5,
  },

  // Name
  nameRow: {
    marginBottom: 14,
  },
  nameDisplay: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 8,
    paddingHorizontal: 10,
    borderRadius: 10,
    backgroundColor: 'rgba(255,255,255,0.04)',
  },
  nameDot: {
    width: 12,
    height: 12,
    borderRadius: 6,
    marginRight: 8,
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.15)',
  },
  nameText: {
    flex: 1,
    fontSize: 14,
    fontWeight: '600',
    color: Colors.textPrimary,
  },
  nameEditHint: {
    fontSize: 12,
    marginLeft: 6,
  },
  nameInput: {
    fontSize: 14,
    fontWeight: '600',
    color: Colors.textPrimary,
    paddingVertical: 8,
    paddingHorizontal: 10,
    borderRadius: 10,
    backgroundColor: 'rgba(255,255,255,0.08)',
    borderWidth: 1,
    borderColor: Colors.accent,
  },

  // Section
  sectionTitle: {
    fontSize: 11,
    fontWeight: '700',
    color: Colors.textMuted,
    textTransform: 'uppercase',
    letterSpacing: 1,
    marginBottom: 8,
    marginTop: 4,
  },

  // Colour grid
  colorGrid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
    marginBottom: 16,
  },
  colorSwatch: {
    width: 32,
    height: 32,
    borderRadius: 16,
    borderWidth: 2,
    borderColor: 'transparent',
  },
  colorSwatchSelected: {
    borderColor: Colors.accentLight,
    shadowColor: Colors.accent,
    shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.6,
    shadowRadius: 6,
  },

  // Sliders
  sliderRow: {
    marginBottom: 12,
  },
  sliderHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 4,
  },
  sliderLabel: {
    fontSize: 12,
    fontWeight: '600',
    color: Colors.textSecondary,
  },
  sliderValue: {
    fontSize: 12,
    fontWeight: '700',
    color: Colors.textPrimary,
    minWidth: 44,
    textAlign: 'right',
  },
  slider: {
    height: 28,
  },

  // Duration hint
  durationHint: {
    fontSize: 10,
    color: Colors.textMuted,
    marginTop: -6,
    marginBottom: 12,
  },

  // Separator
  separator: {
    height: 1,
    backgroundColor: Colors.divider,
    marginVertical: 16,
  },

  // Empty state
  emptyState: {
    alignItems: 'center',
    paddingVertical: 24,
  },
  emptyIcon: {
    fontSize: 28,
    marginBottom: 8,
  },
  emptyText: {
    fontSize: 13,
    color: Colors.textMuted,
    fontWeight: '500',
  },

  // Background button
  bgButton: {
    marginTop: 12,
    paddingVertical: 12,
    borderRadius: 12,
    backgroundColor: 'rgba(255,255,255,0.05)',
    alignItems: 'center',
  },
  bgButtonText: {
    fontSize: 13,
    fontWeight: '600',
    color: Colors.textSecondary,
  },
});
