/**
 * Studio Editor Screen
 *
 * Full-screen animation editor. This is the core product screen.
 * Loads a project by ID and provides the Skia canvas, timeline,
 * toolbar, and layer management.
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  Alert,
  Pressable,
  StyleSheet,
  Text,
  View,
  Dimensions,
  Platform,
} from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import { GestureDetector, Gesture } from 'react-native-gesture-handler';
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withTiming,
  runOnJS,
} from 'react-native-reanimated';
import * as Haptics from 'expo-haptics';
import { useProjects } from '../../src/hooks/useProjects';
import { LoadingScreen } from '../../src/components/common/LoadingScreen';
import { theme } from '../../src/theme';
import { brandPink, brandCyan } from '../../src/theme/colors';
import type {
  StudioProject,
  ProjectData,
  Frame,
  Layer,
  StickElement,
  Point,
} from '../../src/types/database';

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

// ── Tool types ─────────────────────────────────────────
type StudioTool = 'select' | 'stickfigure' | 'draw' | 'shape' | 'text' | 'eraser';

// ── Autosave interval (ms) ─────────────────────────────
const AUTOSAVE_INTERVAL = 15_000;

export default function StudioEditorScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { getProject, updateProject } = useProjects();

  // ── State ──────────────────────────────────────────
  const [project, setProject] = useState<StudioProject | null>(null);
  const [projectData, setProjectData] = useState<ProjectData | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [activeTool, setActiveTool] = useState<StudioTool>('select');
  const [activeLayerIndex, setActiveLayerIndex] = useState(0);
  const [activeFrameIndex, setActiveFrameIndex] = useState(0);
  const [isPlaying, setIsPlaying] = useState(false);
  const [showTimeline, setShowTimeline] = useState(true);
  const [isDirty, setIsDirty] = useState(false);

  const playIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const autosaveRef = useRef<ReturnType<typeof setInterval> | null>(null);

  // ── Drawing state (shared values for gesture performance) ──
  const drawPath = useSharedValue<Point[]>([]);
  const toolbarHeight = useAnimatedStyle(() => ({
    height: withTiming(showTimeline ? 180 : 0, { duration: 200 }),
  }));

  // ── Load project ───────────────────────────────────
  useEffect(() => {
    if (!id) return;

    (async () => {
      const p = await getProject(id);
      if (!p) {
        Alert.alert('Error', 'Project not found', [
          { text: 'OK', onPress: () => router.back() },
        ]);
        return;
      }
      setProject(p);
      setProjectData(p.project_data);
      setIsLoading(false);
    })();
  }, [id, getProject, router]);

  // ── Autosave ───────────────────────────────────────
  useEffect(() => {
    autosaveRef.current = setInterval(() => {
      if (isDirty && project && projectData) {
        handleSave(false);
      }
    }, AUTOSAVE_INTERVAL);

    return () => {
      if (autosaveRef.current) clearInterval(autosaveRef.current);
    };
  }, [isDirty, project, projectData]);

  // ── Playback ───────────────────────────────────────
  useEffect(() => {
    if (!isPlaying || !projectData) return;

    const layer = projectData.layers[activeLayerIndex];
    if (!layer || layer.frames.length <= 1) {
      setIsPlaying(false);
      return;
    }

    const fps = project?.fps ?? 12;
    const frameDuration = 1000 / fps;

    playIntervalRef.current = setInterval(() => {
      setActiveFrameIndex((prev) => {
        const nextFrame = prev + 1;
        if (nextFrame >= layer.frames.length) {
          return 0; // loop
        }
        return nextFrame;
      });
    }, frameDuration);

    return () => {
      if (playIntervalRef.current) clearInterval(playIntervalRef.current);
    };
  }, [isPlaying, projectData, activeLayerIndex, project?.fps]);

  // ── Derived state ──────────────────────────────────
  const activeLayer: Layer | undefined = projectData?.layers[activeLayerIndex];
  const activeFrame: Frame | undefined = activeLayer?.frames[activeFrameIndex];
  const totalFrames = activeLayer?.frames.length ?? 0;

  // ── Mutations ──────────────────────────────────────
  const updateData = useCallback(
    (updater: (data: ProjectData) => ProjectData) => {
      setProjectData((prev) => {
        if (!prev) return prev;
        const next = updater(prev);
        setIsDirty(true);
        return next;
      });
    },
    []
  );

  const addFrame = useCallback(() => {
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    updateData((data) => {
      const layers = [...data.layers];
      const layer = { ...layers[activeLayerIndex] };
      const newFrame: Frame = {
        id: `frame-${Date.now()}`,
        index: layer.frames.length,
        duration_ms: Math.round(1000 / (project?.fps ?? 12)),
        elements: [],
      };
      layer.frames = [...layer.frames, newFrame];
      layers[activeLayerIndex] = layer;
      return { ...data, layers };
    });
    setActiveFrameIndex(totalFrames); // go to new frame
  }, [activeLayerIndex, totalFrames, project?.fps, updateData]);

  const deleteFrame = useCallback(() => {
    if (totalFrames <= 1) {
      Alert.alert('Cannot Delete', 'A project must have at least one frame.');
      return;
    }

    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
    updateData((data) => {
      const layers = [...data.layers];
      const layer = { ...layers[activeLayerIndex] };
      layer.frames = layer.frames.filter((_, i) => i !== activeFrameIndex);
      // Re-index
      layer.frames = layer.frames.map((f, i) => ({ ...f, index: i }));
      layers[activeLayerIndex] = layer;
      return { ...data, layers };
    });

    setActiveFrameIndex((prev) => Math.max(0, prev - 1));
  }, [activeLayerIndex, activeFrameIndex, totalFrames, updateData]);

  const handleSave = useCallback(
    async (showAlert = true) => {
      if (!project || !projectData) return;

      try {
        const frameCount = projectData.layers.reduce(
          (max, l) => Math.max(max, l.frames.length),
          0
        );
        const fps = project.fps || 12;
        const durationMs = Math.round((frameCount / fps) * 1000);

        await updateProject(project.id, {
          project_data: projectData,
          frame_count: frameCount,
          duration_ms: durationMs,
        });

        setIsDirty(false);
        if (showAlert) {
          Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message : 'Failed to save';
        if (showAlert) Alert.alert('Save Error', msg);
      }
    },
    [project, projectData, updateProject]
  );

  const handleBack = useCallback(() => {
    if (isDirty) {
      Alert.alert('Unsaved Changes', 'Save before leaving?', [
        { text: 'Discard', style: 'destructive', onPress: () => router.back() },
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Save',
          onPress: async () => {
            await handleSave(false);
            router.back();
          },
        },
      ]);
    } else {
      router.back();
    }
  }, [isDirty, handleSave, router]);

  // ── Drawing gesture ────────────────────────────────
  const panGesture = Gesture.Pan()
    .onStart((e) => {
      if (activeTool === 'draw') {
        drawPath.value = [{ x: e.x, y: e.y }];
      }
    })
    .onUpdate((e) => {
      if (activeTool === 'draw') {
        drawPath.value = [...drawPath.value, { x: e.x, y: e.y }];
      }
    })
    .onEnd(() => {
      if (activeTool === 'draw' && drawPath.value.length > 1) {
        const points = [...drawPath.value];
        runOnJS(addFreehandElement)(points);
      }
      drawPath.value = [];
    });

  const addFreehandElement = useCallback(
    (points: Point[]) => {
      updateData((data) => {
        const layers = [...data.layers];
        const layer = { ...layers[activeLayerIndex] };
        const frames = [...layer.frames];
        const frame = { ...frames[activeFrameIndex] };

        frame.elements = [
          ...frame.elements,
          {
            type: 'freehand' as const,
            id: `freehand-${Date.now()}`,
            points,
            color: '#FFFFFF',
            stroke_width: 3,
          },
        ];

        frames[activeFrameIndex] = frame;
        layer.frames = frames;
        layers[activeLayerIndex] = layer;
        return { ...data, layers };
      });
    },
    [activeLayerIndex, activeFrameIndex, updateData]
  );

  // ── Tools config ───────────────────────────────────
  const tools: { id: StudioTool; icon: string; label: string }[] = [
    { id: 'select', icon: 'move-outline', label: 'Select' },
    { id: 'stickfigure', icon: 'body-outline', label: 'Stick' },
    { id: 'draw', icon: 'brush-outline', label: 'Draw' },
    { id: 'shape', icon: 'shapes-outline', label: 'Shape' },
    { id: 'text', icon: 'text-outline', label: 'Text' },
    { id: 'eraser', icon: 'remove-circle-outline', label: 'Eraser' },
  ];

  // ── Loading state ──────────────────────────────────
  if (isLoading || !projectData) {
    return <LoadingScreen message="Opening studio…" />;
  }

  return (
    <View style={[styles.container, { paddingTop: insets.top }]}>
      {/* ── Top bar ─────────────────────────────────── */}
      <View style={styles.topBar}>
        <Pressable onPress={handleBack} style={styles.topBarButton}>
          <Ionicons name="arrow-back" size={22} color={theme.colors.text} />
        </Pressable>

        <Pressable style={styles.titleContainer}>
          <Text style={styles.projectTitle} numberOfLines={1}>
            {project?.title ?? 'Untitled'}
          </Text>
          {isDirty && <View style={styles.dirtyDot} />}
        </Pressable>

        <View style={styles.topBarActions}>
          <Pressable onPress={() => handleSave(true)} style={styles.topBarButton}>
            <Ionicons name="save-outline" size={20} color={theme.colors.text} />
          </Pressable>
          <Pressable style={styles.topBarButton}>
            <Ionicons
              name="share-outline"
              size={20}
              color={theme.colors.text}
            />
          </Pressable>
        </View>
      </View>

      {/* ── Canvas area ─────────────────────────────── */}
      <GestureDetector gesture={panGesture}>
        <View style={styles.canvas}>
          {/* Grid background */}
          {projectData.settings.grid_enabled && (
            <View style={styles.gridOverlay} pointerEvents="none" />
          )}

          {/* Render elements for current frame */}
          {activeFrame?.elements.map((element) => (
            <View key={element.id} style={styles.elementPlaceholder}>
              {element.type === 'stickfigure' && (
                <Ionicons name="body" size={48} color={element.color} />
              )}
              {element.type === 'freehand' && (
                <View
                  style={[
                    styles.freehandPreview,
                    { borderColor: element.color },
                  ]}
                />
              )}
              {element.type === 'text' && (
                <Text style={[styles.textElement, { color: element.color }]}>
                  {element.text}
                </Text>
              )}
            </View>
          ))}

          {/* Empty frame indicator */}
          {(!activeFrame || activeFrame.elements.length === 0) && (
            <View style={styles.emptyCanvas}>
              <Text style={styles.emptyCanvasText}>
                {activeTool === 'draw'
                  ? 'Draw on the canvas'
                  : 'Select a tool to start creating'}
              </Text>
            </View>
          )}

          {/* Frame counter */}
          <View style={styles.frameCounter}>
            <Text style={styles.frameCounterText}>
              {activeFrameIndex + 1} / {totalFrames}
            </Text>
          </View>
        </View>
      </GestureDetector>

      {/* ── Tool bar ────────────────────────────────── */}
      <View style={styles.toolbar}>
        {tools.map((tool) => (
          <Pressable
            key={tool.id}
            style={[
              styles.toolButton,
              activeTool === tool.id && styles.toolButtonActive,
            ]}
            onPress={() => {
              Haptics.selectionAsync();
              setActiveTool(tool.id);
            }}
          >
            <Ionicons
              name={tool.icon as any}
              size={22}
              color={
                activeTool === tool.id
                  ? brandPink
                  : theme.colors.textSecondary
              }
            />
            <Text
              style={[
                styles.toolLabel,
                activeTool === tool.id && styles.toolLabelActive,
              ]}
            >
              {tool.label}
            </Text>
          </Pressable>
        ))}
      </View>

      {/* ── Timeline ────────────────────────────────── */}
      <Animated.View style={[styles.timeline, toolbarHeight]}>
        {/* Playback controls */}
        <View style={styles.playbackRow}>
          <Pressable
            style={styles.playbackButton}
            onPress={() => setActiveFrameIndex(0)}
          >
            <Ionicons
              name="play-skip-back"
              size={18}
              color={theme.colors.text}
            />
          </Pressable>

          <Pressable
            style={styles.playbackButton}
            onPress={() =>
              setActiveFrameIndex((p) => Math.max(0, p - 1))
            }
          >
            <Ionicons
              name="play-back"
              size={18}
              color={theme.colors.text}
            />
          </Pressable>

          <Pressable
            style={[styles.playButton, isPlaying && styles.playButtonActive]}
            onPress={() => {
              Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
              setIsPlaying(!isPlaying);
            }}
          >
            <Ionicons
              name={isPlaying ? 'pause' : 'play'}
              size={22}
              color={theme.colors.white}
            />
          </Pressable>

          <Pressable
            style={styles.playbackButton}
            onPress={() =>
              setActiveFrameIndex((p) =>
                Math.min(totalFrames - 1, p + 1)
              )
            }
          >
            <Ionicons
              name="play-forward"
              size={18}
              color={theme.colors.text}
            />
          </Pressable>

          <Pressable style={styles.playbackButton} onPress={addFrame}>
            <Ionicons
              name="add-circle-outline"
              size={18}
              color={brandCyan}
            />
          </Pressable>

          <Pressable style={styles.playbackButton} onPress={deleteFrame}>
            <Ionicons
              name="trash-outline"
              size={18}
              color={theme.colors.error}
            />
          </Pressable>
        </View>

        {/* Frame scrubber */}
        <View style={styles.frameScrubber}>
          {activeLayer?.frames.map((frame, index) => (
            <Pressable
              key={frame.id}
              style={[
                styles.frameThumb,
                index === activeFrameIndex && styles.frameThumbActive,
              ]}
              onPress={() => {
                Haptics.selectionAsync();
                setActiveFrameIndex(index);
              }}
            >
              <Text style={styles.frameThumbText}>{index + 1}</Text>
              {frame.elements.length > 0 && (
                <View style={styles.frameThumbDot} />
              )}
            </Pressable>
          ))}
        </View>

        {/* Layer indicator */}
        <View style={styles.layerRow}>
          <Ionicons
            name="layers-outline"
            size={16}
            color={theme.colors.textMuted}
          />
          <Text style={styles.layerText}>
            {activeLayer?.name ?? 'Layer 1'} ({projectData.layers.length}{' '}
            {projectData.layers.length === 1 ? 'layer' : 'layers'})
          </Text>
        </View>
      </Animated.View>

      {/* ── Timeline toggle ─────────────────────────── */}
      <Pressable
        style={styles.timelineToggle}
        onPress={() => setShowTimeline(!showTimeline)}
      >
        <Ionicons
          name={showTimeline ? 'chevron-down' : 'chevron-up'}
          size={20}
          color={theme.colors.textMuted}
        />
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
  // Top bar
  topBar: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: theme.spacing.md,
    height: theme.layout.headerHeight,
    backgroundColor: theme.colors.surface,
    borderBottomWidth: 0.5,
    borderBottomColor: theme.colors.border,
  },
  topBarButton: {
    width: 40,
    height: 40,
    alignItems: 'center',
    justifyContent: 'center',
  },
  titleContainer: {
    flexDirection: 'row',
    alignItems: 'center',
    flex: 1,
    justifyContent: 'center',
  },
  projectTitle: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
  },
  dirtyDot: {
    width: 6,
    height: 6,
    borderRadius: 3,
    backgroundColor: theme.colors.warning,
    marginLeft: theme.spacing.sm,
  },
  topBarActions: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  // Canvas
  canvas: {
    flex: 1,
    backgroundColor: '#0A0A0F',
    position: 'relative',
  },
  gridOverlay: {
    ...StyleSheet.absoluteFillObject,
    opacity: 0.1,
    borderWidth: 1,
    borderColor: theme.colors.gray[700],
  },
  elementPlaceholder: {
    position: 'absolute',
  },
  freehandPreview: {
    width: 40,
    height: 2,
    borderWidth: 1,
  },
  textElement: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.lg,
  },
  emptyCanvas: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  emptyCanvasText: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textMuted,
  },
  frameCounter: {
    position: 'absolute',
    top: theme.spacing.md,
    right: theme.spacing.md,
    backgroundColor: 'rgba(0,0,0,0.7)',
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.xs,
    borderRadius: theme.radii.sm,
  },
  frameCounterText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.sm,
    color: theme.colors.text,
  },
  // Toolbar
  toolbar: {
    flexDirection: 'row',
    justifyContent: 'space-around',
    backgroundColor: theme.colors.surface,
    paddingVertical: theme.spacing.sm,
    borderTopWidth: 0.5,
    borderTopColor: theme.colors.border,
  },
  toolButton: {
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: theme.spacing.xs,
    paddingHorizontal: theme.spacing.sm,
    borderRadius: theme.radii.sm,
    minWidth: 50,
  },
  toolButtonActive: {
    backgroundColor: `${brandPink}15`,
  },
  toolLabel: {
    fontFamily: theme.fontFamily.medium,
    fontSize: 9,
    color: theme.colors.textMuted,
    marginTop: 2,
  },
  toolLabelActive: {
    color: brandPink,
  },
  // Timeline
  timeline: {
    backgroundColor: theme.colors.surface,
    borderTopWidth: 0.5,
    borderTopColor: theme.colors.border,
    overflow: 'hidden',
    paddingHorizontal: theme.spacing.md,
  },
  playbackRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: theme.spacing.sm,
    gap: theme.spacing.md,
  },
  playbackButton: {
    width: 36,
    height: 36,
    alignItems: 'center',
    justifyContent: 'center',
  },
  playButton: {
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: brandPink,
    alignItems: 'center',
    justifyContent: 'center',
  },
  playButtonActive: {
    backgroundColor: brandCyan,
  },
  frameScrubber: {
    flexDirection: 'row',
    gap: theme.spacing.sm,
    paddingVertical: theme.spacing.sm,
    flexWrap: 'wrap',
  },
  frameThumb: {
    width: 40,
    height: 40,
    borderRadius: theme.radii.sm,
    backgroundColor: theme.colors.card,
    borderWidth: 1.5,
    borderColor: 'transparent',
    alignItems: 'center',
    justifyContent: 'center',
    position: 'relative',
  },
  frameThumbActive: {
    borderColor: brandPink,
    backgroundColor: `${brandPink}20`,
  },
  frameThumbText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.xs,
    color: theme.colors.text,
  },
  frameThumbDot: {
    position: 'absolute',
    bottom: 3,
    width: 4,
    height: 4,
    borderRadius: 2,
    backgroundColor: brandCyan,
  },
  layerRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    paddingVertical: theme.spacing.sm,
  },
  layerText: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
  },
  timelineToggle: {
    alignItems: 'center',
    paddingVertical: theme.spacing.xs,
    backgroundColor: theme.colors.surface,
    borderTopWidth: 0.5,
    borderTopColor: theme.colors.border,
    paddingBottom: Platform.OS === 'ios' ? 20 : theme.spacing.sm,
  },
});
