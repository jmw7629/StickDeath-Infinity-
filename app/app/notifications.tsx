/**
 * Notifications Screen
 *
 * Shows all user notifications: likes, comments, follows, mentions.
 * Grouped by time, with read/unread state.
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
import { useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import { supabase } from '../src/lib/supabase';
import { useAuth } from '../src/hooks/useAuth';
import { Avatar } from '../src/components/common/Avatar';
import { LoadingScreen } from '../src/components/common/LoadingScreen';
import { theme } from '../src/theme';
import { brandPink, brandCyan } from '../src/theme/colors';
import type { Notification, Profile } from '../src/types/database';

interface NotificationWithActor extends Notification {
  actor_profile?: Pick<Profile, 'username' | 'display_name' | 'avatar_url'> | null;
}

const NOTIFICATION_ICONS: Record<
  string,
  { name: keyof typeof Ionicons.glyphMap; color: string }
> = {
  like: { name: 'heart', color: brandPink },
  comment: { name: 'chatbubble', color: brandCyan },
  follow: { name: 'person-add', color: '#6C5CE7' },
  mention: { name: 'at', color: '#FFB800' },
  system: { name: 'megaphone', color: '#4DABF7' },
};

export default function NotificationsScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { user } = useAuth();

  const [notifications, setNotifications] = useState<NotificationWithActor[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const fetchNotifications = useCallback(async () => {
    if (!user) return;
    try {
      const { data, error } = await supabase
        .from('notifications')
        .select('*')
        .eq('user_id', user.id)
        .order('created_at', { ascending: false })
        .limit(50);

      if (error) throw error;
      const notifs = (data as Notification[]) ?? [];

      // Fetch actor profiles
      const actorIds = [...new Set(notifs.filter((n) => n.actor_id).map((n) => n.actor_id!))];
      let actorMap = new Map<string, Pick<Profile, 'username' | 'display_name' | 'avatar_url'>>();

      if (actorIds.length > 0) {
        const { data: profiles } = await supabase
          .from('profiles')
          .select('id, username, display_name, avatar_url')
          .in('id', actorIds);

        if (profiles) {
          actorMap = new Map(profiles.map((p) => [p.id, p]));
        }
      }

      setNotifications(
        notifs.map((n) => ({
          ...n,
          actor_profile: n.actor_id ? actorMap.get(n.actor_id) ?? null : null,
        }))
      );
    } catch (err) {
      console.error('[Notifications] fetch error:', err);
    } finally {
      setIsLoading(false);
      setRefreshing(false);
    }
  }, [user]);

  useEffect(() => {
    fetchNotifications();
  }, [fetchNotifications]);

  // Real-time notifications
  useEffect(() => {
    if (!user) return;
    const channel = supabase
      .channel('notifications_realtime')
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'public',
          table: 'notifications',
          filter: `user_id=eq.${user.id}`,
        },
        () => fetchNotifications()
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [user, fetchNotifications]);

  const handleRefresh = () => {
    setRefreshing(true);
    fetchNotifications();
  };

  const markAsRead = useCallback(
    async (notifId: string) => {
      await supabase
        .from('notifications')
        .update({ is_read: true })
        .eq('id', notifId);
    },
    []
  );

  const markAllAsRead = useCallback(async () => {
    if (!user) return;
    await supabase
      .from('notifications')
      .update({ is_read: true })
      .eq('user_id', user.id)
      .eq('is_read', false);

    setNotifications((prev) => prev.map((n) => ({ ...n, is_read: true })));
  }, [user]);

  const handleNotificationTap = (notification: NotificationWithActor) => {
    // Mark as read
    if (!notification.is_read) {
      markAsRead(notification.id);
      setNotifications((prev) =>
        prev.map((n) => (n.id === notification.id ? { ...n, is_read: true } : n))
      );
    }

    // Navigate based on type
    switch (notification.type) {
      case 'like':
      case 'comment':
      case 'mention':
        if (notification.entity_type === 'post' && notification.entity_id) {
          router.push(`/post/${notification.entity_id}`);
        }
        break;
      case 'follow':
        if (notification.actor_id) {
          router.push(`/user/${notification.actor_id}`);
        }
        break;
    }
  };

  const formatTime = (iso: string): string => {
    const d = new Date(iso);
    const now = new Date();
    const diffMs = now.getTime() - d.getTime();
    const diffMin = Math.floor(diffMs / 60000);
    const diffHours = Math.floor(diffMs / 3600000);
    const diffDays = Math.floor(diffMs / 86400000);

    if (diffMin < 1) return 'Just now';
    if (diffMin < 60) return `${diffMin}m ago`;
    if (diffHours < 24) return `${diffHours}h ago`;
    if (diffDays < 7) return `${diffDays}d ago`;
    return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  };

  const unreadCount = notifications.filter((n) => !n.is_read).length;

  if (isLoading) {
    return <LoadingScreen message="Loading notifications…" />;
  }

  return (
    <View style={[styles.container, { paddingTop: insets.top }]}>
      {/* Header */}
      <View style={styles.header}>
        <Pressable onPress={() => router.back()} style={styles.backButton}>
          <Ionicons name="chevron-back" size={24} color={theme.colors.text} />
        </Pressable>
        <Text style={styles.headerTitle}>Notifications</Text>
        {unreadCount > 0 ? (
          <Pressable onPress={markAllAsRead} style={styles.markReadButton}>
            <Text style={styles.markReadText}>Read all</Text>
          </Pressable>
        ) : (
          <View style={styles.backButton} />
        )}
      </View>

      <FlatList
        data={notifications}
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
            <Text style={styles.emptyEmoji}>🔔</Text>
            <Text style={styles.emptyTitle}>No notifications</Text>
            <Text style={styles.emptySubtitle}>
              When someone likes, comments, or follows you, it'll show up here.
            </Text>
          </View>
        }
        renderItem={({ item }) => {
          const iconConfig = NOTIFICATION_ICONS[item.type] || NOTIFICATION_ICONS.system;
          const actorName =
            item.actor_profile?.display_name ||
            item.actor_profile?.username ||
            null;

          return (
            <Pressable
              style={[
                styles.notifRow,
                !item.is_read && styles.notifRowUnread,
              ]}
              onPress={() => handleNotificationTap(item)}
            >
              {/* Avatar or icon */}
              {item.actor_profile ? (
                <View style={styles.avatarContainer}>
                  <Avatar
                    uri={item.actor_profile.avatar_url}
                    name={actorName || 'U'}
                    size="md"
                  />
                  <View
                    style={[
                      styles.typeIcon,
                      { backgroundColor: iconConfig.color },
                    ]}
                  >
                    <Ionicons
                      name={iconConfig.name}
                      size={10}
                      color="#fff"
                    />
                  </View>
                </View>
              ) : (
                <View
                  style={[
                    styles.systemIcon,
                    { backgroundColor: `${iconConfig.color}20` },
                  ]}
                >
                  <Ionicons
                    name={iconConfig.name}
                    size={22}
                    color={iconConfig.color}
                  />
                </View>
              )}

              {/* Content */}
              <View style={styles.notifContent}>
                <Text style={styles.notifTitle} numberOfLines={2}>
                  {item.title}
                </Text>
                {item.body && (
                  <Text style={styles.notifBody} numberOfLines={1}>
                    {item.body}
                  </Text>
                )}
                <Text style={styles.notifTime}>{formatTime(item.created_at)}</Text>
              </View>

              {/* Unread dot */}
              {!item.is_read && <View style={styles.unreadDot} />}
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
  },
  markReadButton: {
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.sm,
  },
  markReadText: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.sm,
    color: brandPink,
  },
  listContent: {
    paddingHorizontal: theme.spacing.lg,
    paddingBottom: 40,
  },
  notifRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: theme.spacing.md,
    paddingHorizontal: theme.spacing.sm,
    borderRadius: theme.radii.md,
  },
  notifRowUnread: {
    backgroundColor: `${brandPink}08`,
  },
  avatarContainer: {
    position: 'relative',
  },
  typeIcon: {
    position: 'absolute',
    bottom: -2,
    right: -2,
    width: 20,
    height: 20,
    borderRadius: 10,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 2,
    borderColor: theme.colors.background,
  },
  systemIcon: {
    width: 44,
    height: 44,
    borderRadius: 22,
    alignItems: 'center',
    justifyContent: 'center',
  },
  notifContent: {
    flex: 1,
    marginLeft: theme.spacing.md,
  },
  notifTitle: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
    lineHeight: theme.lineHeight.md,
  },
  notifBody: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textSecondary,
    marginTop: theme.spacing.xxs,
  },
  notifTime: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
    marginTop: theme.spacing.xs,
  },
  unreadDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: brandPink,
    marginLeft: theme.spacing.sm,
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
    lineHeight: theme.lineHeight.lg,
  },
});
