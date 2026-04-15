/**
 * User Profile Screen
 *
 * View another user's profile, their published animations,
 * and follow/unfollow them.
 */

import React, { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  FlatList,
  Image,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import * as Haptics from 'expo-haptics';
import { supabase } from '../../src/lib/supabase';
import { useAuth } from '../../src/hooks/useAuth';
import { Avatar } from '../../src/components/common/Avatar';
import { Button } from '../../src/components/common/Button';
import { LoadingScreen } from '../../src/components/common/LoadingScreen';
import { theme } from '../../src/theme';
import { brandPink } from '../../src/theme/colors';
import type { Profile, CommunityPost } from '../../src/types/database';

export default function UserProfileScreen() {
  const { id: userId } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { user } = useAuth();

  const [profile, setProfile] = useState<Profile | null>(null);
  const [posts, setPosts] = useState<CommunityPost[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [isFollowing, setIsFollowing] = useState(false);
  const [followLoading, setFollowLoading] = useState(false);

  const isOwnProfile = user?.id === userId;

  const fetchProfile = useCallback(async () => {
    if (!userId) return;
    try {
      const { data, error } = await supabase
        .from('profiles')
        .select('*')
        .eq('id', userId)
        .single();

      if (error) throw error;
      setProfile(data as Profile);
    } catch (err) {
      console.error('[UserProfile] fetch error:', err);
    }
  }, [userId]);

  const fetchPosts = useCallback(async () => {
    if (!userId) return;
    try {
      const { data, error } = await supabase
        .from('community_posts')
        .select('*')
        .eq('user_id', userId)
        .order('created_at', { ascending: false })
        .limit(30);

      if (error) throw error;
      setPosts((data as CommunityPost[]) ?? []);
    } catch (err) {
      console.error('[UserProfile] fetch posts error:', err);
    }
  }, [userId]);

  const checkFollowing = useCallback(async () => {
    if (!user || !userId || isOwnProfile) return;
    try {
      const { data } = await supabase
        .from('follows')
        .select('id')
        .eq('follower_id', user.id)
        .eq('following_id', userId)
        .maybeSingle();

      setIsFollowing(!!data);
    } catch (err) {
      console.error('[UserProfile] check follow error:', err);
    }
  }, [user, userId, isOwnProfile]);

  useEffect(() => {
    Promise.all([fetchProfile(), fetchPosts(), checkFollowing()]).finally(() =>
      setIsLoading(false)
    );
  }, [fetchProfile, fetchPosts, checkFollowing]);

  const handleFollow = async () => {
    if (!user || !userId) return;
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
    setFollowLoading(true);

    const wasFollowing = isFollowing;
    setIsFollowing(!wasFollowing);

    // Optimistic count update
    if (profile) {
      setProfile({
        ...profile,
        follower_count: profile.follower_count + (wasFollowing ? -1 : 1),
      });
    }

    try {
      if (wasFollowing) {
        await supabase
          .from('follows')
          .delete()
          .eq('follower_id', user.id)
          .eq('following_id', userId);
      } else {
        await supabase
          .from('follows')
          .insert({ follower_id: user.id, following_id: userId });
      }
    } catch (err) {
      // Revert
      setIsFollowing(wasFollowing);
      if (profile) {
        setProfile({
          ...profile,
          follower_count: profile.follower_count + (wasFollowing ? 0 : -1),
        });
      }
      const msg = err instanceof Error ? err.message : 'Failed';
      Alert.alert('Error', msg);
    } finally {
      setFollowLoading(false);
    }
  };

  const handleMessage = async () => {
    if (!user || !userId) return;
    // Check if thread exists, otherwise create one
    try {
      const { data: existingMembers } = await supabase
        .from('dm_thread_members')
        .select('thread_id')
        .eq('user_id', user.id);

      if (existingMembers?.length) {
        for (const m of existingMembers) {
          const { data: otherMember } = await supabase
            .from('dm_thread_members')
            .select('user_id')
            .eq('thread_id', m.thread_id)
            .eq('user_id', userId)
            .maybeSingle();

          if (otherMember) {
            router.push(`/messages/${m.thread_id}`);
            return;
          }
        }
      }

      // Create new thread
      const { data: thread, error: threadErr } = await supabase
        .from('dm_threads')
        .insert({ created_by: user.id })
        .select()
        .single();

      if (threadErr) throw threadErr;

      // Add both members
      await supabase.from('dm_thread_members').insert([
        { thread_id: thread.id, user_id: user.id },
        { thread_id: thread.id, user_id: userId },
      ]);

      router.push(`/messages/${thread.id}`);
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to start conversation';
      Alert.alert('Error', msg);
    }
  };

  const formatCount = (n: number): string => {
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
    if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
    return String(n);
  };

  if (isLoading || !profile) {
    return <LoadingScreen message="Loading profile…" />;
  }

  return (
    <View style={[styles.container, { paddingTop: insets.top }]}>
      {/* Header */}
      <View style={styles.header}>
        <Pressable onPress={() => router.back()} style={styles.backButton}>
          <Ionicons name="chevron-back" size={24} color={theme.colors.text} />
        </Pressable>
        <Text style={styles.headerTitle} numberOfLines={1}>
          @{profile.username}
        </Text>
        <View style={styles.backButton} />
      </View>

      <FlatList
        data={posts}
        keyExtractor={(item) => item.id}
        numColumns={3}
        showsVerticalScrollIndicator={false}
        contentContainerStyle={styles.listContent}
        ListHeaderComponent={
          <View>
            {/* Profile info */}
            <View style={styles.profileSection}>
              <Avatar
                uri={profile.avatar_url}
                name={profile.display_name || profile.username}
                size="xl"
              />

              <Text style={styles.displayName}>
                {profile.display_name || profile.username}
              </Text>

              <View style={styles.usernameRow}>
                <Text style={styles.username}>@{profile.username}</Text>
                {profile.is_verified && (
                  <Ionicons
                    name="checkmark-circle"
                    size={16}
                    color={brandPink}
                    style={{ marginLeft: 4 }}
                  />
                )}
              </View>

              {profile.bio && <Text style={styles.bio}>{profile.bio}</Text>}

              {profile.website && (
                <Text style={styles.website}>{profile.website}</Text>
              )}

              {/* Subscription badge */}
              {profile.subscription_tier === 'pro' && (
                <View style={styles.proBadge}>
                  <Ionicons name="star" size={14} color={brandPink} />
                  <Text style={styles.proBadgeText}>PRO</Text>
                </View>
              )}

              {/* Stats */}
              <View style={styles.statsRow}>
                <View style={styles.stat}>
                  <Text style={styles.statValue}>
                    {formatCount(profile.follower_count)}
                  </Text>
                  <Text style={styles.statLabel}>Followers</Text>
                </View>
                <View style={styles.statDivider} />
                <View style={styles.stat}>
                  <Text style={styles.statValue}>
                    {formatCount(profile.following_count)}
                  </Text>
                  <Text style={styles.statLabel}>Following</Text>
                </View>
                <View style={styles.statDivider} />
                <View style={styles.stat}>
                  <Text style={styles.statValue}>
                    {formatCount(profile.total_likes)}
                  </Text>
                  <Text style={styles.statLabel}>Likes</Text>
                </View>
              </View>

              {/* Action buttons */}
              {!isOwnProfile && (
                <View style={styles.actionButtons}>
                  <Button
                    title={isFollowing ? 'Following' : 'Follow'}
                    variant={isFollowing ? 'outline' : 'primary'}
                    size="md"
                    loading={followLoading}
                    onPress={handleFollow}
                    style={styles.followButton}
                  />
                  <Button
                    title="Message"
                    variant="outline"
                    size="md"
                    onPress={handleMessage}
                    icon={
                      <Ionicons
                        name="chatbubble-outline"
                        size={16}
                        color={theme.colors.primary}
                      />
                    }
                    style={styles.messageButton}
                  />
                </View>
              )}
            </View>

            {/* Posts header */}
            <View style={styles.postsHeader}>
              <Ionicons
                name="grid-outline"
                size={18}
                color={theme.colors.text}
              />
              <Text style={styles.postsHeaderText}>
                Animations ({posts.length})
              </Text>
            </View>
          </View>
        }
        columnWrapperStyle={styles.gridRow}
        renderItem={({ item }) => (
          <Pressable
            style={styles.postThumbnail}
            onPress={() => router.push(`/post/${item.id}`)}
          >
            {item.thumbnail_url ? (
              <Image
                source={{ uri: item.thumbnail_url }}
                style={styles.postImage}
                resizeMode="cover"
              />
            ) : (
              <View style={styles.postPlaceholder}>
                <Ionicons
                  name="film-outline"
                  size={20}
                  color={theme.colors.textMuted}
                />
              </View>
            )}
            <View style={styles.postOverlay}>
              <Ionicons name="heart" size={10} color="#fff" />
              <Text style={styles.postLikes}>
                {formatCount(item.like_count)}
              </Text>
            </View>
          </Pressable>
        )}
        ListEmptyComponent={
          <View style={styles.emptyPosts}>
            <Text style={styles.emptyText}>No animations yet</Text>
          </View>
        }
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
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.md,
  },
  backButton: {
    width: 40,
    height: 40,
    alignItems: 'center',
    justifyContent: 'center',
  },
  headerTitle: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.lg,
    color: theme.colors.text,
    flex: 1,
    textAlign: 'center',
  },
  listContent: {
    paddingBottom: 40,
  },
  profileSection: {
    alignItems: 'center',
    paddingHorizontal: theme.spacing.xl,
    paddingBottom: theme.spacing.xl,
  },
  displayName: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xl,
    color: theme.colors.text,
    marginTop: theme.spacing.lg,
    marginBottom: theme.spacing.xxs,
  },
  usernameRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: theme.spacing.md,
  },
  username: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textMuted,
  },
  bio: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textSecondary,
    textAlign: 'center',
    lineHeight: theme.lineHeight.lg,
    marginBottom: theme.spacing.sm,
    paddingHorizontal: theme.spacing.xl,
  },
  website: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.sm,
    color: theme.colors.secondary,
    marginBottom: theme.spacing.md,
  },
  proBadge: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: `${brandPink}20`,
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.xs,
    borderRadius: theme.radii.full,
    marginBottom: theme.spacing.lg,
    gap: theme.spacing.xs,
  },
  proBadgeText: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xs,
    color: brandPink,
    letterSpacing: 1,
  },
  statsRow: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: theme.colors.card,
    borderRadius: theme.radii.lg,
    paddingVertical: theme.spacing.lg,
    paddingHorizontal: theme.spacing.xl,
    width: '100%',
  },
  stat: {
    flex: 1,
    alignItems: 'center',
  },
  statValue: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xl,
    color: theme.colors.text,
    marginBottom: theme.spacing.xxs,
  },
  statLabel: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
  },
  statDivider: {
    width: 1,
    height: 32,
    backgroundColor: theme.colors.border,
  },
  actionButtons: {
    flexDirection: 'row',
    gap: theme.spacing.md,
    marginTop: theme.spacing.lg,
    width: '100%',
  },
  followButton: {
    flex: 1,
  },
  messageButton: {
    flex: 1,
  },
  postsHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    paddingHorizontal: theme.spacing.xl,
    paddingVertical: theme.spacing.lg,
    borderTopWidth: 0.5,
    borderTopColor: theme.colors.border,
  },
  postsHeaderText: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
  },
  gridRow: {
    gap: 2,
    paddingHorizontal: 2,
  },
  postThumbnail: {
    flex: 1,
    aspectRatio: 1,
    maxWidth: '33.33%',
    position: 'relative',
  },
  postImage: {
    width: '100%',
    height: '100%',
  },
  postPlaceholder: {
    width: '100%',
    height: '100%',
    backgroundColor: theme.colors.surface,
    alignItems: 'center',
    justifyContent: 'center',
  },
  postOverlay: {
    position: 'absolute',
    bottom: 4,
    left: 4,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 2,
    backgroundColor: 'rgba(0,0,0,0.6)',
    paddingHorizontal: 5,
    paddingVertical: 2,
    borderRadius: theme.radii.xs,
  },
  postLikes: {
    fontFamily: theme.fontFamily.medium,
    fontSize: 9,
    color: '#fff',
  },
  emptyPosts: {
    alignItems: 'center',
    paddingVertical: theme.spacing.xxxl,
  },
  emptyText: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textMuted,
  },
});
