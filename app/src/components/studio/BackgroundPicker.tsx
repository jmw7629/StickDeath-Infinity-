/**
 * StickDeath Infinity — Background Picker
 *
 * Modal overlay presenting background presets grouped by type
 * (solid, gradient, horizon, grid, dots, speed lines).
 * Tap a swatch to select; modal auto-closes.
 */

import React, { useMemo } from 'react';
import {
  StyleSheet,
  View,
  Text,
  Pressable,
  ScrollView,
  Modal,
} from 'react-native';
import Animated, {
  FadeIn,
  FadeOut,
  SlideInDown,
  SlideOutDown,
} from 'react-native-reanimated';
import { BlurView } from 'expo-blur';
import {
  Canvas,
  LinearGradient,
  Rect as SkRect,
  vec,
  Circle,
  Path,
  Skia,
  Group,
} from '@shopify/react-native-skia';
import {
  BACKGROUND_PRESETS,
  type BackgroundPreset,
  type BackgroundType,
} from '../../models/Project';
import type { StudioActions } from '../../hooks/useStudio';
import { Colors } from '../../theme/colors';

// ─── Constants ──────────────────────────────────────────────────────

const SWATCH_W = 90;
const SWATCH_H = 64;

const TYPE_LABELS: Record<BackgroundType, string> = {
  solid: '● Solid',
  gradient: '◐ Gradient',
  horizon: '☰ Horizon',
  grid: '⊞ Grid',
  dots: '⁘ Dots',
  speedLines: '⚡ Speed Lines',
};

const TYPE_ORDER: BackgroundType[] = [
  'solid',
  'gradient',
  'horizon',
  'grid',
  'dots',
  'speedLines',
];

// ─── Background Swatch (mini preview via Skia) ──────────────────────

const BgSwatch: React.FC<{
  preset: BackgroundPreset;
  isSelected: boolean;
  onPress: () => void;
}> = ({ preset, isSelected, onPress }) => {
  return (
    <Pressable
      style={[
        styles.swatch,
        isSelected && styles.swatchSelected,
      ]}
      onPress={onPress}
    >
      <Canvas style={styles.swatchCanvas}>
        <SwatchPreview preset={preset} />
      </Canvas>
      <Text style={styles.swatchLabel} numberOfLines={1}>
        {preset.name}
      </Text>
    </Pressable>
  );
};

/** Renders a tiny Skia preview matching the background type. */
const SwatchPreview: React.FC<{ preset: BackgroundPreset }> = ({ preset }) => {
  const w = SWATCH_W - 4;
  const h = SWATCH_H - 20;

  switch (preset.type) {
    case 'gradient':
      return (
        <SkRect x={0} y={0} width={w} height={h}>
          <LinearGradient
            start={vec(0, 0)}
            end={vec(0, h)}
            colors={[preset.color1, preset.color2 ?? preset.color1]}
          />
        </SkRect>
      );

    case 'horizon':
      return (
        <Group>
          <SkRect x={0} y={0} width={w} height={h / 2} color={preset.color1} />
          <SkRect
            x={0}
            y={h / 2}
            width={w}
            height={h / 2}
            color={preset.color2 ?? '#333'}
          />
        </Group>
      );

    case 'grid': {
      const gridPath = Skia.Path.Make();
      const step = 12;
      for (let x = 0; x <= w; x += step) {
        gridPath.moveTo(x, 0);
        gridPath.lineTo(x, h);
      }
      for (let y = 0; y <= h; y += step) {
        gridPath.moveTo(0, y);
        gridPath.lineTo(w, y);
      }
      return (
        <Group>
          <SkRect x={0} y={0} width={w} height={h} color={preset.color1} />
          <Path
            path={gridPath}
            color={preset.color2 ?? '#333'}
            style="stroke"
            strokeWidth={0.5}
            opacity={0.5}
          />
        </Group>
      );
    }

    case 'dots': {
      const dotPath = Skia.Path.Make();
      const step = 10;
      for (let x = step; x < w; x += step) {
        for (let y = step; y < h; y += step) {
          dotPath.addCircle(x, y, 1);
        }
      }
      return (
        <Group>
          <SkRect x={0} y={0} width={w} height={h} color={preset.color1} />
          <Path
            path={dotPath}
            color={preset.color2 ?? '#444'}
            style="fill"
            opacity={0.6}
          />
        </Group>
      );
    }

    case 'speedLines': {
      const linePath = Skia.Path.Make();
      const cx = w / 2;
      const cy = h / 2;
      const count = 20;
      for (let i = 0; i < count; i++) {
        const angle = (i / count) * Math.PI * 2;
        const r1 = 6;
        const r2 = Math.max(w, h);
        linePath.moveTo(cx + Math.cos(angle) * r1, cy + Math.sin(angle) * r1);
        linePath.lineTo(cx + Math.cos(angle) * r2, cy + Math.sin(angle) * r2);
      }
      return (
        <Group>
          <SkRect x={0} y={0} width={w} height={h} color={preset.color1} />
          <Path
            path={linePath}
            color={preset.color2 ?? '#444'}
            style="stroke"
            strokeWidth={1}
            opacity={0.3}
          />
        </Group>
      );
    }

    default:
      return (
        <SkRect x={0} y={0} width={w} height={h} color={preset.color1} />
      );
  }
};

// ─── Props ──────────────────────────────────────────────────────────

interface BackgroundPickerProps {
  visible: boolean;
  currentBgId: string;
  actions: StudioActions;
}

// ─── Component ──────────────────────────────────────────────────────

export const BackgroundPicker: React.FC<BackgroundPickerProps> = ({
  visible,
  currentBgId,
  actions,
}) => {
  // Group presets by type
  const grouped = useMemo(() => {
    const map = new Map<BackgroundType, BackgroundPreset[]>();
    for (const preset of BACKGROUND_PRESETS) {
      const list = map.get(preset.type) ?? [];
      list.push(preset);
      map.set(preset.type, list);
    }
    return map;
  }, []);

  const handleSelect = (id: string) => {
    actions.setBackground(id);
    actions.togglePanel('backgroundPicker');
  };

  if (!visible) return null;

  return (
    <Modal transparent animationType="none" visible={visible}>
      <Animated.View
        entering={FadeIn.duration(200)}
        exiting={FadeOut.duration(150)}
        style={styles.overlay}
      >
        <Pressable
          style={styles.overlayBg}
          onPress={() => actions.togglePanel('backgroundPicker')}
        />

        <Animated.View
          entering={SlideInDown.springify().damping(20).stiffness(180)}
          exiting={SlideOutDown.duration(200)}
          style={styles.modal}
        >
          <BlurView intensity={60} tint="dark" style={styles.blurWrap}>
            <View style={styles.modalInner}>
              {/* Handle */}
              <View style={styles.handle} />

              {/* Title */}
              <Text style={styles.title}>Background</Text>

              <ScrollView
                showsVerticalScrollIndicator={false}
                contentContainerStyle={styles.scrollContent}
              >
                {TYPE_ORDER.map((type) => {
                  const presets = grouped.get(type);
                  if (!presets?.length) return null;

                  return (
                    <View key={type} style={styles.section}>
                      <Text style={styles.sectionTitle}>
                        {TYPE_LABELS[type]}
                      </Text>
                      <ScrollView
                        horizontal
                        showsHorizontalScrollIndicator={false}
                        contentContainerStyle={styles.swatchRow}
                      >
                        {presets.map((preset) => (
                          <BgSwatch
                            key={preset.id}
                            preset={preset}
                            isSelected={preset.id === currentBgId}
                            onPress={() => handleSelect(preset.id)}
                          />
                        ))}
                      </ScrollView>
                    </View>
                  );
                })}
              </ScrollView>
            </View>
          </BlurView>
        </Animated.View>
      </Animated.View>
    </Modal>
  );
};

// ─── Styles ─────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  overlay: {
    flex: 1,
    justifyContent: 'flex-end',
  },
  overlayBg: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'rgba(0,0,0,0.5)',
  },
  modal: {
    maxHeight: '70%',
    borderTopLeftRadius: 24,
    borderTopRightRadius: 24,
    overflow: 'hidden',
  },
  blurWrap: {
    borderTopLeftRadius: 24,
    borderTopRightRadius: 24,
    overflow: 'hidden',
    borderWidth: 1,
    borderBottomWidth: 0,
    borderColor: Colors.glassBorder,
  },
  modalInner: {
    backgroundColor: Colors.glass,
    paddingBottom: 30,
  },

  // Handle
  handle: {
    width: 36,
    height: 4,
    borderRadius: 2,
    backgroundColor: 'rgba(255,255,255,0.2)',
    alignSelf: 'center',
    marginTop: 10,
    marginBottom: 12,
  },

  // Title
  title: {
    fontSize: 18,
    fontWeight: '800',
    color: Colors.textPrimary,
    textAlign: 'center',
    marginBottom: 16,
    letterSpacing: 0.3,
  },

  scrollContent: {
    paddingHorizontal: 16,
    paddingBottom: 16,
  },

  // Section
  section: {
    marginBottom: 18,
  },
  sectionTitle: {
    fontSize: 12,
    fontWeight: '700',
    color: Colors.textMuted,
    textTransform: 'uppercase',
    letterSpacing: 1,
    marginBottom: 8,
  },
  swatchRow: {
    flexDirection: 'row',
    gap: 10,
  },

  // Swatch
  swatch: {
    width: SWATCH_W,
    borderRadius: 12,
    overflow: 'hidden',
    borderWidth: 2,
    borderColor: 'transparent',
    backgroundColor: 'rgba(0,0,0,0.3)',
  },
  swatchSelected: {
    borderColor: Colors.accent,
    shadowColor: Colors.accent,
    shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.5,
    shadowRadius: 8,
  },
  swatchCanvas: {
    width: SWATCH_W - 4,
    height: SWATCH_H - 20,
    margin: 2,
    borderRadius: 8,
    overflow: 'hidden',
  },
  swatchLabel: {
    fontSize: 9,
    fontWeight: '600',
    color: Colors.textSecondary,
    textAlign: 'center',
    paddingVertical: 3,
  },
});
