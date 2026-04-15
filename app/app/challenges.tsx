/**
 * Challenge Browser Screen
 *
 * Browse active community challenges, view details,
 * and enter with an animation.
 */

import React, { useCallback, useEffect, useState } from 'react';
import {
  Alert,
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
import * as Haptics from 'expo-haptics';
import { supabase } from '../src/lib/supabase';
import { useAuth } from '../src/hooks/useAuth';
import { Button } from '../src/components/common/Button';
import { LoadingScreen } from '../src/components/common/LoadingScreen';
import { theme } from '../src/theme';
import { brandPink, brandCyan } from '../src/theme/colors';

interface Challenge {
  id: number;
  title: string;
  description: string | null;
  theme: string;
  tag: string;
  rules: string | null;
  start_date: string;
  end_date: string;
  active: boolean;
  created_at: string;
  entry_count?: number;
}

type ChallengeFilter = 'active' | 'upcoming' | 'ended';

export default function ChallengesScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { user } = useAuth();

  const [challenges, setChallenges] = useState<Challenge[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [filter, setFilter] = useState<ChallengeFilter>('active');
  const [expandedId, setExpandedId] = useState<number | null>(null);

  const fetchChallenges = useCallback(async () => {
    try {
      const now = new Date().toISOString();

      let query = supabase
        .from('challenges')
        .select('*')
        .order('start_date', { ascending: false });

      if (filter === 'active') {
        query = query.eq('active', true).lte('start_date', now).gte('end_date', now);
      } else if (filter === 'upcoming') {
        query = query.gt('start_date', now);
      } else {
        query = query.lt('end_date', now);
      }

      const { data, error } = await query.limit(30);
      if (error) throw error;

      // Get entry counts via community_posts tagged with challenge tag
      const enriched = await Promise.all(
        (data ?? []).map(async (c: any) => {
          const { count } = await supabase
            .from('community_posts')
            .select('*', { count: 'exact', head: true })
            .contains('tags', [c.tag]);

          return { ...c, entry_count: count ?? 0 } as Challenge;
        })
      );

      setChallenges(enriched);
    } catch (err) {
      console.error('[Challenges] fetch error:', err);
    } finally {
      setIsLoading(false);
      setRefreshing(false);
    }
  }, [filter]);

  useEffect(() => {
    setIsLoading(true);
    fetchChallenges();
  }, [fetchChallenges]);

  const handleRefresh = () => {
    setRefreshing(true);
    fetchChallenges();
  };

  const handleEnterChallenge = (challenge: Challenge) => {
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
    Alert.alert(
      'Enter Challenge',
      `Create an animation tagged #${challenge.tag} and publish it to enter "${challenge.title}"!`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Open Studio',
          onPress: () => router.push('/(tabs)'),
        },
      ]
    );
  };

  const formatDateRange = (start: string, end: string): string => {
    const s = new Date(start);
    const e = new Date(end);
    const opts: Intl.DateTimeFormatOptions = { month: 'short', day: 'numeric' };
    return `${s.toLocaleDateString('en-US', opts)} — ${e.toLocaleDateString('en-US', opts)}`;
  };

  const getTimeRemaining = (endDate: string): string => {
    const now = new Date();
    const end = new Date(endDate);
    const diffMs = end.getTime() - now.getTime();

    if (diffMs <= 0) return 'Ended';

    const days = Math.floor(diffMs / 86400000);
    const hours = Math.floor((diffMs % 86400000) / 3600000);

    if (days > 0) return `${days}d ${hours}h left`;
    return `${hours}h left`;
  };

  const getStatusColor = (challenge: Challenge): string => {
    const now = new Date();
    const start = new Date(challenge.start_date);
    const end = new Date(challenge.end_date);

    if (now < start) return brandCyan; // upcoming
    if (now > end) return theme.colors.textMuted; // ended
    return theme.colors.success; // active
  };

  if (isLoading) {
    return <LoadingScreen message="Loading challenges…" />;
  }

  return (
    <View style={[styles.container, { paddingTop: insets.top }]}>
      {/* Header */}
      <View style={styles.header}>
        <Pressable onPress={() => router.back()} style={styles.backButton}>
          <Ionicons name="chevron-back" size={24} color={theme.colors.text} />
        </Pressable>
        <Text style={styles.headerTitle}>Challenges</Text>
        <View style={styles.backButton} />
      </View>

      {/* Filter tabs */}
      <View style={styles.filterRow}>
        {(['active', 'upcoming', 'ended'] as ChallengeFilter[]).map((f) => (
          <Pressable
            key={f}
            style={[styles.filterChip, filter === f && styles.filterChipActive]}
            onPress={() => setFilter(f)}
          >
            <Text
              style={[
                styles.filterChipText,
                filter === f && styles.filterChipTextActive,
              ]}
            >
              {f.charAt(0).toUpperCase() + f.slice(1)}
            </Text>
          </Pressable>
        ))}
      </View>

      <FlatList
        data={challenges}
        keyExtractor={(item) => String(item.id)}
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
            <Text style={styles.emptyEmoji}>🏆</Text>
            <Text style={styles.emptyTitle}>No {filter} challenges</Text>
            <Text style={styles.emptySubtitle}>
              {filter === 'active'
                ? 'Check back soon for new community challenges!'
                : filter === 'upcoming'
                ? 'No upcoming challenges scheduled yet.'
                : 'Past challenges will appear here.'}
            </Text>
          </View>
        }
        renderItem={({ item }) => {
          const isExpanded = expandedId === item.id;
          const statusColor = getStatusColor(item);
          const now = new Date();
          const isActive =
            new Date(item.start_date) <= now && new Date(item.end_date) >= now;

          return (
            <Pressable
              style={styles.challengeCard}
              onPress={() => setExpandedId(isExpanded ? null : item.id)}
            >
              {/* Header */}
              <View style={styles.cardHeader}>
                <View style={styles.cardHeaderLeft}>
                  <View
                    style={[styles.statusDot, { backgroundColor: statusColor }]}
                  />
                  <View style={styles.cardTitleContainer}>
                    <Text style={styles.cardTitle}>{item.title}</Text>
                    <Text style={styles.cardDates}>
                      {formatDateRange(item.start_date, item.end_date)}
                    </Text>
                  </View>
                </View>
                <Ionicons
                  name={isExpanded ? 'chevron-up' : 'chevron-down'}
                  size={18}
                  color={theme.colors.textMuted}
                />
              </View>

              {/* Theme tag */}
              <View style={styles.cardTags}>
                <View style={styles.themeTag}>
                  <Ionicons name="color-palette" size={12} color={brandCyan} />
                  <Text style={styles.themeTagText}>{item.theme}</Text>
                </View>
                <View style={styles.hashTag}>
                  <Text style={styles.hashTagText}>#{item.tag}</Text>
                </View>
              </View>

              {/* Stats */}
              <View style={styles.cardStats}>
                <View style={styles.cardStat}>
                  <Ionicons
                    name="film-outline"
                    size={14}
                    color={theme.colors.textMuted}
                  />
                  <Text style={styles.cardStatText}>
                    {item.entry_count ?? 0} entries
                  </Text>
                </View>
                {isActive && (
                  <View style={styles.cardStat}>
                    <Ionicons
                      name="time-outline"
                      size={14}
                      color={theme.colors.success}
                    />
                    <Text style={[styles.cardStatText, { color: theme.colors.success }]}>
                      {getTimeRemaining(item.end_date)}
                    </Text>
                  </View>
                )}
              </View>

              {/* Expanded content */}
              {isExpanded && (
                <View style={styles.cardExpanded}>
                  {item.description && (
                    <Text style={styles.description}>{item.description}</Text>
                  )}
                  {item.rules && (
                    <View style={styles.rulesBox}>
                      <Text style={styles.rulesLabel}>Rules</Text>
                      <Text style={styles.rulesText}>{item.rules}</Text>
                    </View>
                  )}
                  {isActive && (
                    <Button
                      title="Enter Challenge"
                      variant="primary"
                      size="md"
                      fullWidth
                      onPress={() => handleEnterChallenge(item)}
                      icon={
                        <Ionicons name="trophy" size={16} color={theme.colors.text} />
                      }
                      style={{ marginTop: theme.spacing.lg }}
                    />
                  )}
                </View>
              )}
            </Pressable>
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
  filterRow: {
    flexDirection: 'row',
    paddingHorizontal: theme.spacing.lg,
    gap: theme.spacing.sm,
    marginBottom: theme.spacing.lg,
  },
  filterChip: {
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.sm,
    borderRadius: theme.radii.full,
    backgroundColor: theme.colors.card,
  },
  filterChipActive: {
    backgroundColor: brandPink,
  },
  filterChipText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textSecondary,
  },
  filterChipTextActive: {
    color: '#FFFFFF',
  },
  listContent: {
    paddingHorizontal: theme.spacing.lg,
    paddingBottom: 40,
  },
  challengeCard: {
    backgroundColor: theme.colors.card,
    borderRadius: theme.radii.lg,
    padding: theme.spacing.lg,
    marginBottom: theme.spacing.md,
    ...theme.shadows.sm,
  },
  cardHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: theme.spacing.md,
  },
  cardHeaderLeft: {
    flexDirection: 'row',
    alignItems: 'center',
    flex: 1,
  },
  statusDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    marginRight: theme.spacing.md,
  },
  cardTitleContainer: {
    flex: 1,
  },
  cardTitle: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.lg,
    color: theme.colors.text,
  },
  cardDates: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
    marginTop: theme.spacing.xxs,
  },
  cardTags: {
    flexDirection: 'row',
    gap: theme.spacing.sm,
    marginBottom: theme.spacing.md,
  },
  themeTag: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
    backgroundColor: `${brandCyan}15`,
    paddingHorizontal: theme.spacing.sm,
    paddingVertical: theme.spacing.xxs,
    borderRadius: theme.radii.xs,
  },
  themeTagText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.xs,
    color: brandCyan,
  },
  hashTag: {
    backgroundColor: theme.colors.surface,
    paddingHorizontal: theme.spacing.sm,
    paddingVertical: theme.spacing.xxs,
    borderRadius: theme.radii.xs,
  },
  hashTagText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textSecondary,
  },
  cardStats: {
    flexDirection: 'row',
    gap: theme.spacing.xl,
  },
  cardStat: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
  },
  cardStatText: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
  },
  cardExpanded: {
    marginTop: theme.spacing.lg,
    paddingTop: theme.spacing.lg,
    borderTopWidth: 0.5,
    borderTopColor: theme.colors.border,
  },
  description: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textSecondary,
    lineHeight: theme.lineHeight.lg,
    marginBottom: theme.spacing.md,
  },
  rulesBox: {
    backgroundColor: theme.colors.surface,
    borderRadius: theme.radii.md,
    padding: theme.spacing.lg,
  },
  rulesLabel: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.sm,
    color: theme.colors.text,
    marginBottom: theme.spacing.sm,
  },
  rulesText: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textSecondary,
    lineHeight: theme.lineHeight.md,
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
