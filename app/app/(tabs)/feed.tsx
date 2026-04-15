/**
 * Feed Tab — Community Feed
 *
 * Scrollable feed of published animations from the community.
 * TikTok-style vertical cards with like / comment / share actions.
 */

import React, { useCallback, useEffect, useState } from 'react';
import {
  FlatList,
  Image,
  Pressable,
  RefreshControl,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import * as Haptics from 'expo-haptics';
import { supabase } from '../../src/lib/supabase';
import { useAuth } from '../../src/hooks/useAuth';
import { Avatar } from '../../src/components/common/Avatar';
import { LoadingScreen } from '../../src/components/common/LoadingScreen';
import { theme } from '../../src/theme';
import { brandPink } from '../../src/theme/colors';
import type { CommunityPost, Profile } from '../../src/types/database';

interface FeedPost extends CommunityPost {
  profiles: Pick<Profile, 'username' | 'display_name' | 'avatar_url' | 'is_verified'>;
}

const PAGE_SIZE = 20;

export default function FeedTab() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { user } = useAuth();

  const [posts, setPosts] = useState<FeedPost[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [likedPosts, setLikedPosts] = useState<Set<string>>(new Set());

  const fetchPosts = useCallback(async (isRefresh = false) => {
    try {
      const { data, error } = await supabase
        .from('community_posts')
        .select(
          `*, profiles!community_posts_user_id_fkey(username, display_name, avatar_url, is_verified)`
        )
        .order('created_at', { ascending: false })
        .limit(PAGE_SIZE);

      if (error) throw error;
      setPosts((data as unknown as FeedPost[]) ?? []);
    } catch (err) {
      console.error('[Feed] fetch error:', err);
    } finally {
      setIsLoading(false);
      if (isRefresh) setRefreshing(false);
    }
  }, []);

  // Fetch which posts the user has liked
  const fetchLikedPosts = useCallback(async () => {
    if (!user) return;
    try {
      const { data } = await supabase
        .from('post_reactions')
        .select('post_id')
        .eq('user_id', user.id);

      if (data) {
        setLikedPosts(new Set(data.map((r) => r.post_id)));
      }
    } catch (err) {
      console.error('[Feed] fetch liked error:', err);
    }
  }, [user]);

  useEffect(() => {
    fetchPosts();
    fetchLikedPosts();
  }, [fetchPosts, fetchLikedPosts]);

  const handleRefresh = () => {
    setRefreshing(true);
    fetchPosts(true);
    fetchLikedPosts();
  };

  const handleLike = async (postId: string) => {
    if (!user) return;

    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    const isLiked = likedPosts.has(postId);

    // Optimistic update
    setLikedPosts((prev) => {
      const next = new Set(prev);
      if (isLiked) next.delete(postId);
      else next.add(postId);
      return next;
    });

    setPosts((prev) =>
      prev.map((p) =>
        p.id === postId
          ? { ...p, like_count: p.like_count + (isLiked ? -1 : 1) }
          : p
      )
    );

    try {
      if (isLiked) {
        await supabase
          .from('post_reactions')
          .delete()
          .eq('post_id', postId)
          .eq('user_id', user.id);
      } else {
        await supabase
          .from('post_reactions')
          .insert({ post_id: postId, user_id: user.id, reaction: '🔥' });
      }
    } catch (err) {
      console.error('[Feed] like error:', err);
      // Revert optimistic update
      setLikedPosts((prev) => {
        const next = new Set(prev);
        if (isLiked) next.add(postId);
        else next.delete(postId);
        return next;
      });
    }
  };

  const formatCount = (n: number): string => {
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
    if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
    return String(n);
  };

  if (isLoading) {
    return <LoadingScreen message="Loading feed…" />;
  }

  return (
    <View style={[styles.container, { paddingTop: insets.top }]}>
      {/* Header */}
      <View style={styles.header}>
        <Text style={styles.headerTitle}>Feed</Text>
        <View style={styles.headerActions}>
          <Pressable onPress={() => router.push('/search')}>
            <Ionicons name="search" size={22} color={theme.colors.text} />
          </Pressable>
          <Pressable onPress={() => router.push('/notifications')}>
            <Ionicons name="notifications-outline" size={22} color={theme.colors.text} />
          </Pressable>
        </View>
      </View>

      <FlatList
        data={posts}
        keyExtractor={(item) => item.id}
        showsVerticalScrollIndicator={false}
        contentContainerStyle={styles.listContent}
        refreshControl={
          <RefreshControl
            refreshing={refreshing}
            onRefresh={handleRefresh}
            tintColor={brandPink}
          />
        }
        ListEmptyComponent={
          <View style={styles.emptyState}>
            <Text style={styles.emptyEmoji}>🔥</Text>
            <Text style={styles.emptyTitle}>No posts yet</Text>
            <Text style={styles.emptySubtitle}>
              Be the first to share an animation!
            </Text>
          </View>
        }
        renderItem={({ item }) => {
          const isLiked = likedPosts.has(item.id);
          const profile = item.profiles;

          return (
            <View style={styles.postCard}>
              {/* Author row */}
              <View style={styles.authorRow}>
                <Avatar
                  uri={profile.avatar_url}
                  name={profile.display_name || profile.username}
                  size="sm"
                />
                <View style={styles.authorInfo}>
                  <View style={styles.authorNameRow}>
                    <Text style={styles.authorName}>
                      {profile.display_name || profile.username}
                    </Text>
                    {profile.is_verified && (
                      <Ionicons
                        name="checkmark-circle"
                        size={14}
                        color={brandPink}
                        style={{ marginLeft: 4 }}
                      />
                    )}
                  </View>
                  <Text style={styles.authorUsername}>
                    @{profile.username}
                  </Text>
                </View>
              </View>

              {/* Media */}
              <Pressable style={styles.mediaContainer} onPress={() => router.push(`/post/${item.id}`)}>
                {item.thumbnail_url ? (
                  <Image
                    source={{ uri: item.thumbnail_url }}
                    style={styles.media}
                    resizeMode="cover"
                  />
                ) : (
                  <View style={styles.mediaPlaceholder}>
                    <Ionicons
                      name="play-circle"
                      size={48}
                      color={theme.colors.textMuted}
                    />
                  </View>
                )}
              </Pressable>

              {/* Caption */}
              {item.caption && (
                <Text style={styles.caption} numberOfLines={3}>
                  {item.caption}
                </Text>
              )}

              {/* Actions */}
              <View style={styles.actions}>
                <Pressable
                  style={styles.actionButton}
                  onPress={() => handleLike(item.id)}
                >
                  <Ionicons
                    name={isLiked ? 'heart' : 'heart-outline'}
                    size={22}
                    color={isLiked ? brandPink : theme.colors.textSecondary}
                  />
                  <Text
                    style={[
                      styles.actionCount,
                      isLiked && { color: brandPink },
                    ]}
                  >
                    {formatCount(item.like_count)}
                  </Text>
                </Pressable>

                <Pressable style={styles.actionButton}>
                  <Ionicons
                    name="chatbubble-outline"
                    size={20}
                    color={theme.colors.textSecondary}
                  />
                  <Text style={styles.actionCount}>
                    {formatCount(item.comment_count)}
                  </Text>
                </Pressable>

                <Pressable style={styles.actionButton}>
                  <Ionicons
                    name="share-outline"
                    size={20}
                    color={theme.colors.textSecondary}
                  />
                  <Text style={styles.actionCount}>
                    {formatCount(item.share_count)}
                  </Text>
                </Pressable>
              </View>

              {/* Tags */}
              {item.tags.length > 0 && (
                <View style={styles.tags}>
                  {item.tags.slice(0, 4).map((tag) => (
                    <View key={tag} style={styles.tag}>
                      <Text style={styles.tagText}>#{tag}</Text>
                    </View>
                  ))}
                </View>
              )}
            </View>
          );
        }}
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
  headerTitle: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xxl,
    color: theme.colors.text,
  },
  headerActions: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 16,
  },
  listContent: {
    paddingHorizontal: theme.spacing.lg,
    paddingBottom: theme.layout.tabBarHeight + 20,
  },
  postCard: {
    backgroundColor: theme.colors.card,
    borderRadius: theme.radii.lg,
    padding: theme.spacing.lg,
    marginBottom: theme.spacing.lg,
    ...theme.shadows.sm,
  },
  authorRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: theme.spacing.md,
  },
  authorInfo: {
    marginLeft: theme.spacing.md,
    flex: 1,
  },
  authorNameRow: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  authorName: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
  },
  authorUsername: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textMuted,
  },
  mediaContainer: {
    borderRadius: theme.radii.md,
    overflow: 'hidden',
    marginBottom: theme.spacing.md,
  },
  media: {
    width: '100%',
    aspectRatio: 9 / 16,
    borderRadius: theme.radii.md,
  },
  mediaPlaceholder: {
    width: '100%',
    aspectRatio: 16 / 9,
    backgroundColor: theme.colors.surface,
    borderRadius: theme.radii.md,
    alignItems: 'center',
    justifyContent: 'center',
  },
  caption: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
    lineHeight: theme.lineHeight.lg,
    marginBottom: theme.spacing.md,
  },
  actions: {
    flexDirection: 'row',
    gap: theme.spacing.xl,
  },
  actionButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
  },
  actionCount: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textSecondary,
  },
  tags: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: theme.spacing.sm,
    marginTop: theme.spacing.md,
  },
  tag: {
    backgroundColor: theme.colors.surface,
    paddingHorizontal: theme.spacing.sm,
    paddingVertical: theme.spacing.xxs,
    borderRadius: theme.radii.xs,
  },
  tagText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.xs,
    color: theme.colors.secondary,
  },
  emptyState: {
    alignItems: 'center',
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
  },
});
