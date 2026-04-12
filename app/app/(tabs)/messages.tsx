/**
 * Messages Tab — DM List
 *
 * Shows all DM threads for the current user, sorted by last message.
 */

import React, { useCallback, useEffect, useState } from 'react';
import {
  FlatList,
  Pressable,
  RefreshControl,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import { supabase } from '../../src/lib/supabase';
import { useAuth } from '../../src/hooks/useAuth';
import { Avatar } from '../../src/components/common/Avatar';
import { LoadingScreen } from '../../src/components/common/LoadingScreen';
import { theme } from '../../src/theme';
import { brandPink } from '../../src/theme/colors';
import type { DmThread, Profile } from '../../src/types/database';

interface ThreadWithParticipants extends DmThread {
  other_user: Pick<Profile, 'username' | 'display_name' | 'avatar_url'> | null;
  unread_count: number;
}

export default function MessagesTab() {
  const insets = useSafeAreaInsets();
  const { user } = useAuth();

  const [threads, setThreads] = useState<ThreadWithParticipants[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const fetchThreads = useCallback(async () => {
    if (!user) return;

    try {
      // 1. Get all threads the user is a member of
      const { data: memberships, error: memberError } = await supabase
        .from('dm_thread_members')
        .select('thread_id, last_read_at')
        .eq('user_id', user.id);

      if (memberError) throw memberError;
      if (!memberships?.length) {
        setThreads([]);
        return;
      }

      const threadIds = memberships.map((m) => m.thread_id);
      const lastReadMap = new Map(
        memberships.map((m) => [m.thread_id, m.last_read_at])
      );

      // 2. Get the thread details
      const { data: threadData, error: threadError } = await supabase
        .from('dm_threads')
        .select('*')
        .in('id', threadIds)
        .order('last_message_at', { ascending: false });

      if (threadError) throw threadError;

      // 3. For each thread, get the other participant's profile
      const enriched = await Promise.all(
        (threadData ?? []).map(async (thread) => {
          let otherUser: ThreadWithParticipants['other_user'] = null;

          if (!thread.is_group) {
            // Find the other member
            const { data: members } = await supabase
              .from('dm_thread_members')
              .select('user_id')
              .eq('thread_id', thread.id)
              .neq('user_id', user.id)
              .limit(1);

            if (members?.[0]) {
              const { data: profile } = await supabase
                .from('profiles')
                .select('username, display_name, avatar_url')
                .eq('id', members[0].user_id)
                .single();

              otherUser = profile;
            }
          }

          // Count unread messages
          const lastRead = lastReadMap.get(thread.id);
          let unread_count = 0;

          if (lastRead) {
            const { count } = await supabase
              .from('dm_messages')
              .select('*', { count: 'exact', head: true })
              .eq('thread_id', thread.id)
              .neq('sender_id', user.id)
              .gt('created_at', lastRead);

            unread_count = count ?? 0;
          }

          return { ...thread, other_user: otherUser, unread_count } as ThreadWithParticipants;
        })
      );

      setThreads(enriched);
    } catch (err) {
      console.error('[Messages] fetch error:', err);
    } finally {
      setIsLoading(false);
      setRefreshing(false);
    }
  }, [user]);

  useEffect(() => {
    fetchThreads();
  }, [fetchThreads]);

  // Real-time subscription for new messages
  useEffect(() => {
    if (!user) return;

    const channel = supabase
      .channel('dm_messages_realtime')
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'dm_messages' },
        () => {
          fetchThreads(); // Re-fetch thread list on new message
        }
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [user, fetchThreads]);

  const handleRefresh = () => {
    setRefreshing(true);
    fetchThreads();
  };

  const formatTime = (iso: string | null): string => {
    if (!iso) return '';
    const d = new Date(iso);
    const now = new Date();
    const diffMs = now.getTime() - d.getTime();
    const diffHours = diffMs / (1000 * 60 * 60);

    if (diffHours < 1) return 'Now';
    if (diffHours < 24) {
      return d.toLocaleTimeString('en-US', {
        hour: 'numeric',
        minute: '2-digit',
      });
    }
    if (diffHours < 168) {
      return d.toLocaleDateString('en-US', { weekday: 'short' });
    }
    return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  };

  if (isLoading) {
    return <LoadingScreen message="Loading messages…" />;
  }

  return (
    <View style={[styles.container, { paddingTop: insets.top }]}>
      {/* Header */}
      <View style={styles.header}>
        <Text style={styles.headerTitle}>Messages</Text>
        <Pressable style={styles.newMessageButton}>
          <Ionicons name="create-outline" size={22} color={theme.colors.text} />
        </Pressable>
      </View>

      <FlatList
        data={threads}
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
            <Text style={styles.emptyEmoji}>💬</Text>
            <Text style={styles.emptyTitle}>No messages yet</Text>
            <Text style={styles.emptySubtitle}>
              Start a conversation with another creator!
            </Text>
          </View>
        }
        renderItem={({ item }) => {
          const displayName = item.is_group
            ? item.group_name ?? 'Group Chat'
            : item.other_user?.display_name ??
              item.other_user?.username ??
              'Unknown';
          const avatarUri = item.is_group
            ? item.group_avatar_url
            : item.other_user?.avatar_url;

          return (
            <Pressable style={styles.threadRow}>
              <Avatar uri={avatarUri} name={displayName} size="md" />

              <View style={styles.threadInfo}>
                <View style={styles.threadTopRow}>
                  <Text style={styles.threadName} numberOfLines={1}>
                    {displayName}
                  </Text>
                  <Text style={styles.threadTime}>
                    {formatTime(item.last_message_at)}
                  </Text>
                </View>
                <View style={styles.threadBottomRow}>
                  <Text
                    style={[
                      styles.threadPreview,
                      item.unread_count > 0 && styles.threadPreviewUnread,
                    ]}
                    numberOfLines={1}
                  >
                    {item.last_message_preview || 'No messages yet'}
                  </Text>
                  {item.unread_count > 0 && (
                    <View style={styles.unreadBadge}>
                      <Text style={styles.unreadBadgeText}>
                        {item.unread_count > 99 ? '99+' : item.unread_count}
                      </Text>
                    </View>
                  )}
                </View>
              </View>
            </Pressable>
          );
        }}
        ItemSeparatorComponent={() => <View style={styles.separator} />}
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
  newMessageButton: {
    width: 40,
    height: 40,
    alignItems: 'center',
    justifyContent: 'center',
  },
  listContent: {
    paddingHorizontal: theme.spacing.lg,
    paddingBottom: theme.layout.tabBarHeight + 20,
  },
  threadRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: theme.spacing.md,
    paddingHorizontal: theme.spacing.sm,
  },
  threadInfo: {
    flex: 1,
    marginLeft: theme.spacing.md,
  },
  threadTopRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: theme.spacing.xxs,
  },
  threadName: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
    flex: 1,
    marginRight: theme.spacing.sm,
  },
  threadTime: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
  },
  threadBottomRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  threadPreview: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textMuted,
    flex: 1,
    marginRight: theme.spacing.sm,
  },
  threadPreviewUnread: {
    color: theme.colors.textSecondary,
    fontFamily: theme.fontFamily.medium,
  },
  unreadBadge: {
    backgroundColor: brandPink,
    borderRadius: 10,
    minWidth: 20,
    height: 20,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 6,
  },
  unreadBadgeText: {
    fontFamily: theme.fontFamily.bold,
    fontSize: 10,
    color: theme.colors.white,
  },
  separator: {
    height: 0.5,
    backgroundColor: theme.colors.border,
    marginLeft: 60,
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
