/**
 * Studio Tab — Project Gallery
 *
 * Shows the user's animation projects in a grid.
 * Create new or open existing projects.
 */

import React, { useState } from 'react';
import {
  Alert,
  FlatList,
  Image,
  Pressable,
  RefreshControl,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useRouter } from 'expo-router';
import { Ionicons } from '@expo/vector-icons';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import * as Haptics from 'expo-haptics';
import { useProjects } from '../../src/hooks/useProjects';
import { useAuth } from '../../src/hooks/useAuth';
import { LoadingScreen } from '../../src/components/common/LoadingScreen';
import { theme } from '../../src/theme';
import { brandPink, brandCyan } from '../../src/theme/colors';
import type { StudioProject } from '../../src/types/database';

export default function StudioTab() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { profile } = useAuth();
  const { projects, isLoading, refresh, createProject, deleteProject } =
    useProjects();
  const [refreshing, setRefreshing] = useState(false);

  const handleRefresh = async () => {
    setRefreshing(true);
    await refresh();
    setRefreshing(false);
  };

  const handleCreateProject = async () => {
    try {
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
      const id = await createProject();
      router.push(`/studio/${id}`);
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to create project';
      Alert.alert('Error', msg);
    }
  };

  const handleOpenProject = (id: string) => {
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    router.push(`/studio/${id}`);
  };

  const handleDeleteProject = (project: StudioProject) => {
    Alert.alert(
      'Delete Project',
      `Are you sure you want to delete "${project.title}"? This cannot be undone.`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Delete',
          style: 'destructive',
          onPress: () => deleteProject(project.id),
        },
      ]
    );
  };

  const formatDate = (iso: string) => {
    const d = new Date(iso);
    const now = new Date();
    const diffMs = now.getTime() - d.getTime();
    const diffHours = diffMs / (1000 * 60 * 60);

    if (diffHours < 1) return 'Just now';
    if (diffHours < 24) return `${Math.floor(diffHours)}h ago`;
    if (diffHours < 48) return 'Yesterday';
    return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  };

  if (isLoading) {
    return <LoadingScreen message="Loading projects…" />;
  }

  return (
    <View style={[styles.container, { paddingTop: insets.top }]}>
      {/* Header */}
      <View style={styles.header}>
        <View>
          <Text style={styles.greeting}>
            Hey, {profile?.display_name || profile?.username || 'Creator'} 👋
          </Text>
          <Text style={styles.headerTitle}>Your Projects</Text>
        </View>
        <View style={styles.headerActions}>
          <Pressable
            style={styles.challengeButton}
            onPress={() => router.push('/challenges')}
          >
            <Ionicons name="trophy-outline" size={20} color={brandCyan} />
          </Pressable>
          <Pressable style={styles.createButton} onPress={handleCreateProject}>
            <Ionicons name="add" size={24} color={theme.colors.white} />
          </Pressable>
        </View>
      </View>

      {/* Project grid */}
      <FlatList
        data={projects}
        keyExtractor={(item) => item.id}
        numColumns={2}
        columnWrapperStyle={styles.row}
        contentContainerStyle={styles.listContent}
        showsVerticalScrollIndicator={false}
        refreshControl={
          <RefreshControl
            refreshing={refreshing}
            onRefresh={handleRefresh}
            tintColor={brandPink}
          />
        }
        ListEmptyComponent={
          <View style={styles.emptyState}>
            <Text style={styles.emptyEmoji}>🎬</Text>
            <Text style={styles.emptyTitle}>No projects yet</Text>
            <Text style={styles.emptySubtitle}>
              Tap the + button to create your first stick figure animation!
            </Text>
          </View>
        }
        renderItem={({ item }) => (
          <Pressable
            style={styles.projectCard}
            onPress={() => handleOpenProject(item.id)}
            onLongPress={() => handleDeleteProject(item)}
          >
            {/* Thumbnail */}
            <View style={styles.thumbnailContainer}>
              {item.thumbnail_url ? (
                <Image
                  source={{ uri: item.thumbnail_url }}
                  style={styles.thumbnail}
                  resizeMode="cover"
                />
              ) : (
                <View style={styles.thumbnailPlaceholder}>
                  <Ionicons
                    name="film-outline"
                    size={32}
                    color={theme.colors.textMuted}
                  />
                </View>
              )}
              {/* Frame count badge */}
              <View style={styles.frameBadge}>
                <Text style={styles.frameBadgeText}>
                  {item.frame_count} frames
                </Text>
              </View>
            </View>

            {/* Info */}
            <View style={styles.projectInfo}>
              <Text style={styles.projectTitle} numberOfLines={1}>
                {item.title}
              </Text>
              <Text style={styles.projectMeta}>
                {formatDate(item.updated_at)}
              </Text>
            </View>
          </Pressable>
        )}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
  header: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingHorizontal: theme.spacing.xl,
    paddingVertical: theme.spacing.lg,
  },
  greeting: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textSecondary,
    marginBottom: theme.spacing.xxs,
  },
  headerTitle: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xxl,
    color: theme.colors.text,
  },
  headerActions: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
  },
  challengeButton: {
    width: 40,
    height: 40,
    borderRadius: 20,
    backgroundColor: theme.colors.surface,
    borderWidth: 1,
    borderColor: theme.colors.border,
    alignItems: 'center',
    justifyContent: 'center',
  },
  createButton: {
    width: 48,
    height: 48,
    borderRadius: 24,
    backgroundColor: brandPink,
    alignItems: 'center',
    justifyContent: 'center',
    ...theme.shadows.md,
  },
  listContent: {
    paddingHorizontal: theme.spacing.lg,
    paddingBottom: theme.layout.tabBarHeight + 20,
  },
  row: {
    justifyContent: 'space-between',
    marginBottom: theme.spacing.lg,
  },
  projectCard: {
    width: '48%',
    backgroundColor: theme.colors.card,
    borderRadius: theme.radii.lg,
    overflow: 'hidden',
    ...theme.shadows.sm,
  },
  thumbnailContainer: {
    aspectRatio: 9 / 16,
    width: '100%',
    position: 'relative',
  },
  thumbnail: {
    width: '100%',
    height: '100%',
  },
  thumbnailPlaceholder: {
    width: '100%',
    height: '100%',
    backgroundColor: theme.colors.surface,
    alignItems: 'center',
    justifyContent: 'center',
  },
  frameBadge: {
    position: 'absolute',
    bottom: theme.spacing.sm,
    right: theme.spacing.sm,
    backgroundColor: 'rgba(0,0,0,0.7)',
    paddingHorizontal: theme.spacing.sm,
    paddingVertical: theme.spacing.xxs,
    borderRadius: theme.radii.xs,
  },
  frameBadgeText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.xs,
    color: theme.colors.text,
  },
  projectInfo: {
    padding: theme.spacing.md,
  },
  projectTitle: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.sm,
    color: theme.colors.text,
    marginBottom: theme.spacing.xxs,
  },
  projectMeta: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
  },
  emptyState: {
    alignItems: 'center',
    justifyContent: 'center',
    paddingTop: 120,
    paddingHorizontal: theme.spacing.xxl,
  },
  emptyEmoji: {
    fontSize: 64,
    marginBottom: theme.spacing.lg,
  },
  emptyTitle: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xl,
    color: theme.colors.text,
    marginBottom: theme.spacing.sm,
  },
  emptySubtitle: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textSecondary,
    textAlign: 'center',
    lineHeight: theme.lineHeight.lg,
  },
});
