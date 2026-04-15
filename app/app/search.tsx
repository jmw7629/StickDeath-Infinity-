/**
 * Search / Discover Screen
 *
 * Search for users and posts. Shows trending posts and
 * suggested users when search is empty.
 */

import React, { useCallback, useRef, useState } from 'react';
import {
  FlatList,
  Image,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import { supabase } from '../src/lib/supabase';
import { Avatar } from '../src/components/common/Avatar';
import { Button } from '../src/components/common/Button';
import { theme } from '../src/theme';
import { brandPink, brandCyan } from '../src/theme/colors';
import type { Profile, CommunityPost } from '../src/types/database';

type SearchTab = 'users' | 'posts';

export default function SearchScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const inputRef = useRef<TextInput>(null);

  const [query, setQuery] = useState('');
  const [activeTab, setActiveTab] = useState<SearchTab>('users');
  const [users, setUsers] = useState<Profile[]>([]);
  const [posts, setPosts] = useState<(CommunityPost & { profiles: Pick<Profile, 'username' | 'display_name' | 'avatar_url'> })[]>([]);
  const [searching, setSearching] = useState(false);
  const [hasSearched, setHasSearched] = useState(false);

  const searchUsers = useCallback(async (q: string) => {
    const { data } = await supabase
      .from('profiles')
      .select('*')
      .or(`username.ilike.%${q}%,display_name.ilike.%${q}%`)
      .order('follower_count', { ascending: false })
      .limit(20);

    setUsers((data as Profile[]) ?? []);
  }, []);

  const searchPosts = useCallback(async (q: string) => {
    const { data } = await supabase
      .from('community_posts')
      .select(
        '*, profiles!community_posts_user_id_fkey(username, display_name, avatar_url)'
      )
      .or(`caption.ilike.%${q}%,tags.cs.{${q.toLowerCase()}}`)
      .order('like_count', { ascending: false })
      .limit(20);

    setPosts((data as any) ?? []);
  }, []);

  const handleSearch = useCallback(async () => {
    const q = query.trim();
    if (!q) return;

    setSearching(true);
    setHasSearched(true);
    try {
      await Promise.all([searchUsers(q), searchPosts(q)]);
    } catch (err) {
      console.error('[Search] error:', err);
    } finally {
      setSearching(false);
    }
  }, [query, searchUsers, searchPosts]);

  const handleClear = () => {
    setQuery('');
    setUsers([]);
    setPosts([]);
    setHasSearched(false);
    inputRef.current?.focus();
  };

  const formatCount = (n: number): string => {
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
    if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
    return String(n);
  };

  return (
    <View style={[styles.container, { paddingTop: insets.top }]}>
      {/* Header */}
      <View style={styles.header}>
        <Pressable onPress={() => router.back()} style={styles.backButton}>
          <Ionicons name="chevron-back" size={24} color={theme.colors.text} />
        </Pressable>
        <View style={styles.searchBar}>
          <Ionicons
            name="search"
            size={18}
            color={theme.colors.textMuted}
            style={styles.searchIcon}
          />
          <TextInput
            ref={inputRef}
            style={styles.searchInput}
            value={query}
            onChangeText={setQuery}
            placeholder="Search users, animations, tags…"
            placeholderTextColor={theme.colors.textMuted}
            autoFocus
            autoCapitalize="none"
            autoCorrect={false}
            returnKeyType="search"
            onSubmitEditing={handleSearch}
          />
          {query.length > 0 && (
            <Pressable onPress={handleClear} style={styles.clearButton}>
              <Ionicons
                name="close-circle"
                size={18}
                color={theme.colors.textMuted}
              />
            </Pressable>
          )}
        </View>
      </View>

      {/* Tabs */}
      {hasSearched && (
        <View style={styles.tabs}>
          <Pressable
            style={[styles.tab, activeTab === 'users' && styles.tabActive]}
            onPress={() => setActiveTab('users')}
          >
            <Text
              style={[
                styles.tabText,
                activeTab === 'users' && styles.tabTextActive,
              ]}
            >
              Users ({users.length})
            </Text>
          </Pressable>
          <Pressable
            style={[styles.tab, activeTab === 'posts' && styles.tabActive]}
            onPress={() => setActiveTab('posts')}
          >
            <Text
              style={[
                styles.tabText,
                activeTab === 'posts' && styles.tabTextActive,
              ]}
            >
              Posts ({posts.length})
            </Text>
          </Pressable>
        </View>
      )}

      {/* Results */}
      {!hasSearched ? (
        <View style={styles.emptyState}>
          <Ionicons
            name="search"
            size={64}
            color={theme.colors.textMuted}
            style={{ opacity: 0.3 }}
          />
          <Text style={styles.emptyTitle}>Discover</Text>
          <Text style={styles.emptySubtitle}>
            Search for creators, animations, and tags
          </Text>
        </View>
      ) : activeTab === 'users' ? (
        <FlatList
          data={users}
          keyExtractor={(item) => item.id}
          showsVerticalScrollIndicator={false}
          contentContainerStyle={styles.listContent}
          ListEmptyComponent={
            <View style={styles.noResults}>
              <Text style={styles.noResultsText}>No users found</Text>
            </View>
          }
          renderItem={({ item }) => (
            <Pressable
              style={styles.userRow}
              onPress={() => router.push(`/user/${item.id}`)}
            >
              <Avatar
                uri={item.avatar_url}
                name={item.display_name || item.username}
                size="md"
              />
              <View style={styles.userInfo}>
                <View style={styles.userNameRow}>
                  <Text style={styles.userDisplayName} numberOfLines={1}>
                    {item.display_name || item.username}
                  </Text>
                  {item.is_verified && (
                    <Ionicons
                      name="checkmark-circle"
                      size={14}
                      color={brandPink}
                      style={{ marginLeft: 4 }}
                    />
                  )}
                  {item.subscription_tier === 'pro' && (
                    <View style={styles.proBadgeMini}>
                      <Text style={styles.proBadgeMiniText}>PRO</Text>
                    </View>
                  )}
                </View>
                <Text style={styles.userUsername}>@{item.username}</Text>
                {item.bio && (
                  <Text style={styles.userBio} numberOfLines={1}>
                    {item.bio}
                  </Text>
                )}
              </View>
              <Text style={styles.followerCount}>
                {formatCount(item.follower_count)}
              </Text>
            </Pressable>
          )}
          ItemSeparatorComponent={() => <View style={styles.separator} />}
        />
      ) : (
        <FlatList
          data={posts}
          keyExtractor={(item) => item.id}
          numColumns={2}
          showsVerticalScrollIndicator={false}
          contentContainerStyle={styles.listContent}
          columnWrapperStyle={styles.postsRow}
          ListEmptyComponent={
            <View style={styles.noResults}>
              <Text style={styles.noResultsText}>No posts found</Text>
            </View>
          }
          renderItem={({ item }) => (
            <Pressable
              style={styles.postCard}
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
                    size={28}
                    color={theme.colors.textMuted}
                  />
                </View>
              )}
              <View style={styles.postInfo}>
                <Text style={styles.postCaption} numberOfLines={2}>
                  {item.caption || 'Untitled'}
                </Text>
                <View style={styles.postMeta}>
                  <Text style={styles.postAuthor}>
                    @{item.profiles?.username}
                  </Text>
                  <View style={styles.postLikes}>
                    <Ionicons name="heart" size={10} color={brandPink} />
                    <Text style={styles.postLikesText}>
                      {formatCount(item.like_count)}
                    </Text>
                  </View>
                </View>
              </View>
            </Pressable>
          )}
        />
      )}
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
    alignItems: 'center',
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.md,
    gap: theme.spacing.sm,
  },
  backButton: {
    width: 36,
    height: 36,
    alignItems: 'center',
    justifyContent: 'center',
  },
  searchBar: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: theme.colors.card,
    borderRadius: theme.radii.xl,
    paddingHorizontal: theme.spacing.md,
    height: 44,
  },
  searchIcon: {
    marginRight: theme.spacing.sm,
  },
  searchInput: {
    flex: 1,
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
    paddingVertical: 0,
  },
  clearButton: {
    padding: theme.spacing.xs,
  },
  tabs: {
    flexDirection: 'row',
    paddingHorizontal: theme.spacing.lg,
    borderBottomWidth: 0.5,
    borderBottomColor: theme.colors.border,
  },
  tab: {
    flex: 1,
    alignItems: 'center',
    paddingVertical: theme.spacing.md,
    borderBottomWidth: 2,
    borderBottomColor: 'transparent',
  },
  tabActive: {
    borderBottomColor: brandPink,
  },
  tabText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.md,
    color: theme.colors.textMuted,
  },
  tabTextActive: {
    color: theme.colors.text,
    fontFamily: theme.fontFamily.semibold,
  },
  listContent: {
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.lg,
    paddingBottom: 40,
  },
  emptyState: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: theme.spacing.xxl,
    marginTop: -80,
  },
  emptyTitle: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xxl,
    color: theme.colors.text,
    marginTop: theme.spacing.lg,
    marginBottom: theme.spacing.sm,
  },
  emptySubtitle: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textMuted,
    textAlign: 'center',
  },
  noResults: {
    alignItems: 'center',
    paddingVertical: theme.spacing.xxxl,
  },
  noResultsText: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textMuted,
  },
  userRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: theme.spacing.md,
  },
  userInfo: {
    flex: 1,
    marginLeft: theme.spacing.md,
  },
  userNameRow: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  userDisplayName: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
  },
  userUsername: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textMuted,
    marginTop: theme.spacing.xxs,
  },
  userBio: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textSecondary,
    marginTop: theme.spacing.xxs,
  },
  proBadgeMini: {
    backgroundColor: `${brandPink}20`,
    paddingHorizontal: 6,
    paddingVertical: 1,
    borderRadius: theme.radii.xs,
    marginLeft: 6,
  },
  proBadgeMiniText: {
    fontFamily: theme.fontFamily.bold,
    fontSize: 9,
    color: brandPink,
  },
  followerCount: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textMuted,
  },
  separator: {
    height: 0.5,
    backgroundColor: theme.colors.border,
    marginLeft: 60,
  },
  postsRow: {
    gap: theme.spacing.md,
    marginBottom: theme.spacing.md,
  },
  postCard: {
    flex: 1,
    backgroundColor: theme.colors.card,
    borderRadius: theme.radii.lg,
    overflow: 'hidden',
  },
  postImage: {
    width: '100%',
    aspectRatio: 9 / 16,
  },
  postPlaceholder: {
    width: '100%',
    aspectRatio: 1,
    backgroundColor: theme.colors.surface,
    alignItems: 'center',
    justifyContent: 'center',
  },
  postInfo: {
    padding: theme.spacing.md,
  },
  postCaption: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.sm,
    color: theme.colors.text,
    marginBottom: theme.spacing.xs,
  },
  postMeta: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  postAuthor: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
  },
  postLikes: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 2,
  },
  postLikesText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
  },
});
