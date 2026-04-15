/**
 * Profile Tab — User Profile + Settings
 *
 * Shows the current user's profile, stats, published posts,
 * and settings (sign out, subscription management, etc.).
 */

import React, { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Image,
  Linking,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import * as ImagePicker from 'expo-image-picker';
import { supabase } from '../../src/lib/supabase';
import { useAuth } from '../../src/hooks/useAuth';
import { Avatar } from '../../src/components/common/Avatar';
import { Button } from '../../src/components/common/Button';
import { LoadingScreen } from '../../src/components/common/LoadingScreen';
import { theme } from '../../src/theme';
import { brandPink, brandCyan } from '../../src/theme/colors';
import type { CommunityPost } from '../../src/types/database';

const SUPABASE_URL = process.env.EXPO_PUBLIC_SUPABASE_URL!;

export default function ProfileTab() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { user, profile, signOut, refreshProfile } = useAuth();

  const [posts, setPosts] = useState<CommunityPost[]>([]);
  const [isLoadingPosts, setIsLoadingPosts] = useState(true);

  const fetchUserPosts = useCallback(async () => {
    if (!user) return;
    try {
      const { data, error } = await supabase
        .from('community_posts')
        .select('*')
        .eq('user_id', user.id)
        .order('created_at', { ascending: false })
        .limit(20);

      if (error) throw error;
      setPosts((data as CommunityPost[]) ?? []);
    } catch (err) {
      console.error('[Profile] fetch posts error:', err);
    } finally {
      setIsLoadingPosts(false);
    }
  }, [user]);

  useEffect(() => {
    fetchUserPosts();
  }, [fetchUserPosts]);

  const [upgrading, setUpgrading] = useState(false);

  const handleUpgrade = async () => {
    if (!user) return;
    setUpgrading(true);
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) throw new Error('Not authenticated');

      const res = await fetch(`${SUPABASE_URL}/functions/v1/create-checkout`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${session.access_token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          return_url: 'stickdeath://subscription/success',
          cancel_url: 'stickdeath://subscription/cancel',
        }),
      });

      const json = await res.json();
      if (!res.ok) throw new Error(json.error || json.message || 'Checkout failed');
      if (json.checkout_url) {
        await Linking.openURL(json.checkout_url);
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to start checkout';
      Alert.alert('Error', msg);
    } finally {
      setUpgrading(false);
    }
  };

  const handleSignOut = () => {
    Alert.alert('Sign Out', 'Are you sure you want to sign out?', [
      { text: 'Cancel', style: 'cancel' },
      { text: 'Sign Out', style: 'destructive', onPress: signOut },
    ]);
  };

  const handleEditAvatar = async () => {
    try {
      const result = await ImagePicker.launchImageLibraryAsync({
        mediaTypes: ['images'],
        allowsEditing: true,
        aspect: [1, 1],
        quality: 0.8,
      });

      if (result.canceled || !result.assets[0]) return;
      if (!user) return;

      const asset = result.assets[0];
      const fileExt = asset.uri.split('.').pop()?.toLowerCase() || 'jpg';
      const filePath = `avatars/${user.id}.${fileExt}`;

      // Upload to Supabase Storage
      const response = await fetch(asset.uri);
      const blob = await response.blob();

      const { error: uploadError } = await supabase.storage
        .from('avatars')
        .upload(filePath, blob, { upsert: true, contentType: `image/${fileExt}` });

      if (uploadError) throw uploadError;

      // Get public URL
      const {
        data: { publicUrl },
      } = supabase.storage.from('avatars').getPublicUrl(filePath);

      // Update profile
      const { error: updateError } = await supabase
        .from('profiles')
        .update({ avatar_url: publicUrl })
        .eq('id', user.id);

      if (updateError) throw updateError;

      await refreshProfile();
      Alert.alert('Success', 'Avatar updated!');
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to update avatar';
      Alert.alert('Error', msg);
    }
  };

  const formatCount = (n: number): string => {
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
    if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
    return String(n);
  };

  if (!profile) {
    return <LoadingScreen message="Loading profile…" />;
  }

  return (
    <ScrollView
      style={[styles.container, { paddingTop: insets.top }]}
      contentContainerStyle={styles.scrollContent}
      showsVerticalScrollIndicator={false}
    >
      {/* Header */}
      <View style={styles.header}>
        <Text style={styles.headerTitle}>Profile</Text>
        <Pressable style={styles.settingsButton} onPress={() => router.push('/settings')}>
          <Ionicons name="settings-outline" size={22} color={theme.colors.text} />
        </Pressable>
      </View>

      {/* Profile card */}
      <View style={styles.profileCard}>
        <Pressable onPress={handleEditAvatar} style={styles.avatarContainer}>
          <Avatar
            uri={profile.avatar_url}
            name={profile.display_name || profile.username}
            size="xl"
          />
          <View style={styles.editAvatarBadge}>
            <Ionicons name="camera" size={14} color={theme.colors.white} />
          </View>
        </Pressable>

        <Text style={styles.displayName}>
          {profile.display_name || profile.username}
        </Text>
        <Text style={styles.username}>@{profile.username}</Text>

        {profile.bio && <Text style={styles.bio}>{profile.bio}</Text>}

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
      </View>

      {/* Posts grid */}
      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Published Animations</Text>

        {isLoadingPosts ? (
          <View style={styles.postLoadingContainer}>
            <Text style={styles.loadingText}>Loading…</Text>
          </View>
        ) : posts.length === 0 ? (
          <View style={styles.emptyPosts}>
            <Text style={styles.emptyText}>
              No published animations yet.{'\n'}Create and share your first one!
            </Text>
          </View>
        ) : (
          <View style={styles.postsGrid}>
            {posts.map((post) => (
              <Pressable key={post.id} style={styles.postThumbnail}>
                {post.thumbnail_url ? (
                  <Image
                    source={{ uri: post.thumbnail_url }}
                    style={styles.postImage}
                    resizeMode="cover"
                  />
                ) : (
                  <View style={styles.postPlaceholder}>
                    <Ionicons
                      name="film-outline"
                      size={24}
                      color={theme.colors.textMuted}
                    />
                  </View>
                )}
                <View style={styles.postOverlay}>
                  <Ionicons name="heart" size={12} color={theme.colors.white} />
                  <Text style={styles.postLikes}>
                    {formatCount(post.like_count)}
                  </Text>
                </View>
              </Pressable>
            ))}
          </View>
        )}
      </View>

      {/* Pro upgrade CTA (only for free users) */}
      {profile.subscription_tier === 'free' && (
        <View style={styles.proCard}>
          <View style={styles.proCardContent}>
            <Text style={styles.proCardTitle}>Go Pro ✨</Text>
            <Text style={styles.proCardDescription}>
              Unlimited layers, HD export, custom stick figures, no watermark,
              and more.
            </Text>
            <Button
              title="Upgrade — $4.99/mo"
              variant="primary"
              size="md"
              fullWidth
              loading={upgrading}
              onPress={handleUpgrade}
              style={styles.proButton}
            />
          </View>
        </View>
      )}

      {/* Sign out */}
      <Button
        title="Sign Out"
        variant="ghost"
        size="md"
        fullWidth
        onPress={handleSignOut}
        textStyle={{ color: theme.colors.error }}
        style={styles.signOutButton}
      />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
  scrollContent: {
    paddingBottom: theme.layout.tabBarHeight + 40,
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
  settingsButton: {
    width: 40,
    height: 40,
    alignItems: 'center',
    justifyContent: 'center',
  },
  profileCard: {
    alignItems: 'center',
    paddingHorizontal: theme.spacing.xl,
    paddingBottom: theme.spacing.xl,
  },
  avatarContainer: {
    position: 'relative',
    marginBottom: theme.spacing.lg,
  },
  editAvatarBadge: {
    position: 'absolute',
    bottom: 2,
    right: 2,
    width: 28,
    height: 28,
    borderRadius: 14,
    backgroundColor: brandPink,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 2,
    borderColor: theme.colors.background,
  },
  displayName: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xl,
    color: theme.colors.text,
    marginBottom: theme.spacing.xxs,
  },
  username: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textMuted,
    marginBottom: theme.spacing.md,
  },
  bio: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textSecondary,
    textAlign: 'center',
    lineHeight: theme.lineHeight.lg,
    marginBottom: theme.spacing.lg,
    paddingHorizontal: theme.spacing.xl,
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
  section: {
    paddingHorizontal: theme.spacing.xl,
    marginTop: theme.spacing.xxl,
  },
  sectionTitle: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.lg,
    color: theme.colors.text,
    marginBottom: theme.spacing.lg,
  },
  postLoadingContainer: {
    alignItems: 'center',
    paddingVertical: theme.spacing.xxl,
  },
  loadingText: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textMuted,
  },
  emptyPosts: {
    alignItems: 'center',
    paddingVertical: theme.spacing.xxl,
  },
  emptyText: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textMuted,
    textAlign: 'center',
    lineHeight: theme.lineHeight.lg,
  },
  postsGrid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 2,
  },
  postThumbnail: {
    width: '32.8%',
    aspectRatio: 9 / 16,
    borderRadius: theme.radii.sm,
    overflow: 'hidden',
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
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderRadius: theme.radii.xs,
  },
  postLikes: {
    fontFamily: theme.fontFamily.medium,
    fontSize: 10,
    color: theme.colors.white,
  },
  proCard: {
    marginHorizontal: theme.spacing.xl,
    marginTop: theme.spacing.xxl,
    borderRadius: theme.radii.lg,
    backgroundColor: theme.colors.card,
    borderWidth: 1,
    borderColor: brandPink,
    overflow: 'hidden',
  },
  proCardContent: {
    padding: theme.spacing.xl,
    alignItems: 'center',
  },
  proCardTitle: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xl,
    color: theme.colors.text,
    marginBottom: theme.spacing.sm,
  },
  proCardDescription: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textSecondary,
    textAlign: 'center',
    lineHeight: theme.lineHeight.md,
    marginBottom: theme.spacing.lg,
  },
  proButton: {
    marginTop: theme.spacing.sm,
  },
  signOutButton: {
    marginHorizontal: theme.spacing.xl,
    marginTop: theme.spacing.xxl,
  },
});
