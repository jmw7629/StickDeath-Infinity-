/**
 * Publish Screen
 *
 * Publish a rendered animation to:
 *   1. StickDeath official channels (YouTube, TikTok, Discord) — always watermarked
 *   2. User's own connected accounts — watermark removable for Pro
 *
 * Mirrors the iOS native PublishSheet.swift behavior.
 */

import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import * as Haptics from 'expo-haptics';
import { supabase } from '../src/lib/supabase';
import { useAuth } from '../src/hooks/useAuth';
import { theme } from '../src/theme';
import { brandPink, brandCyan } from '../src/theme/colors';

const SUPABASE_URL = process.env.EXPO_PUBLIC_SUPABASE_URL!;

// Official StickDeath channels — always receive watermarked videos
const OFFICIAL_CHANNELS = [
  {
    platform: 'youtube',
    handle: '@stickdeath.infinity',
    icon: 'logo-youtube' as const,
    color: '#FF0000',
    label: 'YouTube',
  },
  {
    platform: 'tiktok',
    handle: '@stickdeath.infinity',
    icon: 'logo-tiktok' as const,
    color: '#00F2EA',
    label: 'TikTok',
  },
  {
    platform: 'discord',
    handle: '#stickdeath_infinity',
    icon: 'logo-discord' as const,
    color: '#5865F2',
    label: 'Discord',
  },
];

type Step = 'form' | 'publishing' | 'done';

export default function PublishScreen() {
  const { projectId, renderJobId } = useLocalSearchParams<{
    projectId: string;
    renderJobId: string;
  }>();
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { profile } = useAuth();

  const isPro = profile?.subscription_tier === 'pro';

  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [publishToOwn, setPublishToOwn] = useState(false);
  const [removeWatermark, setRemoveWatermark] = useState(false);
  const [selectedUserPlatforms, setSelectedUserPlatforms] = useState<string[]>([]);
  const [userAccounts, setUserAccounts] = useState<
    Array<{ platform: string; platform_username: string }>
  >([]);

  const [step, setStep] = useState<Step>('form');
  const [progressText, setProgressText] = useState('');
  const [publishError, setPublishError] = useState<string | null>(null);
  const [publishResults, setPublishResults] = useState<{
    official: number;
    user: number;
  } | null>(null);

  // Fetch user's connected social accounts
  useEffect(() => {
    (async () => {
      try {
        const { data: { session } } = await supabase.auth.getSession();
        if (!session) return;

        const res = await fetch(
          `${SUPABASE_URL}/functions/v1/social-connect?action=status`,
          { headers: { Authorization: `Bearer ${session.access_token}` } },
        );
        const json = await res.json();
        if (json.connections) {
          setUserAccounts(
            json.connections.filter((c: any) => c.connected),
          );
        }
      } catch {}
    })();
  }, []);

  const toggleUserPlatform = (platform: string) => {
    setSelectedUserPlatforms((prev) =>
      prev.includes(platform)
        ? prev.filter((p) => p !== platform)
        : [...prev, platform],
    );
  };

  const handlePublish = async () => {
    if (!title.trim()) {
      Alert.alert('Title required', 'Give your animation a name.');
      return;
    }

    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Heavy);
    setStep('publishing');
    setPublishError(null);

    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) throw new Error('Not authenticated');

      setProgressText('Publishing to official channels…');

      const res = await fetch(`${SUPABASE_URL}/functions/v1/publish-video`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${session.access_token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          render_job_id: renderJobId,
          title: title.trim(),
          description: description.trim(),
          account_type:
            publishToOwn && selectedUserPlatforms.length > 0 ? 'both' : 'official',
          platforms: publishToOwn ? selectedUserPlatforms : undefined,
          publish_to_own_channels: publishToOwn,
          watermark: !(isPro && removeWatermark),
        }),
      });

      const json = await res.json();
      if (!res.ok) throw new Error(json.error || 'Publish failed');

      const officialOk = (json.official_results || []).filter(
        (r: any) => r.status === 'published',
      ).length;
      const userOk = (json.user_results || []).filter(
        (r: any) => r.status === 'published',
      ).length;

      setPublishResults({ official: officialOk, user: userOk });
      setStep('done');
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
    } catch (err) {
      setPublishError(
        err instanceof Error ? err.message : 'Something went wrong',
      );
      setStep('form');
    }
  };

  // ── Success screen ──
  if (step === 'done') {
    return (
      <View style={[styles.container, { paddingTop: insets.top }]}>
        <View style={styles.successContainer}>
          <Ionicons name="checkmark-circle" size={72} color="#34C759" />
          <Text style={styles.successTitle}>Published! 🎉</Text>
          <Text style={styles.successSubtitle}>
            Your animation is being uploaded to all official channels.
          </Text>

          <View style={styles.successChannels}>
            <Text style={styles.successLabel}>Uploading to:</Text>
            {OFFICIAL_CHANNELS.map((ch) => (
              <View key={ch.platform} style={styles.successRow}>
                <Ionicons name={ch.icon} size={18} color={ch.color} />
                <Text style={styles.successChannelText}>
                  {ch.label} — {ch.handle}
                </Text>
                <Ionicons name="checkmark" size={14} color="#34C759" />
              </View>
            ))}
          </View>

          {publishResults && publishResults.user > 0 && (
            <Text style={styles.successExtra}>
              + {publishResults.user} of your own channels
            </Text>
          )}

          <Pressable
            style={styles.doneButton}
            onPress={() => router.back()}
          >
            <Text style={styles.doneButtonText}>Done</Text>
          </Pressable>
        </View>
      </View>
    );
  }

  // ── Publishing spinner ──
  if (step === 'publishing') {
    return (
      <View style={[styles.container, { paddingTop: insets.top }]}>
        <View style={styles.publishingContainer}>
          <ActivityIndicator size="large" color={brandPink} />
          <Text style={styles.publishingText}>{progressText}</Text>
        </View>
      </View>
    );
  }

  // ── Form ──
  return (
    <ScrollView
      style={[styles.container, { paddingTop: insets.top }]}
      contentContainerStyle={styles.scrollContent}
      keyboardShouldPersistTaps="handled"
    >
      {/* Header */}
      <View style={styles.header}>
        <Pressable onPress={() => router.back()} style={styles.backButton}>
          <Ionicons name="close" size={24} color={theme.colors.text} />
        </Pressable>
        <Text style={styles.headerTitle}>Publish</Text>
        <View style={{ width: 40 }} />
      </View>

      {/* Title & Description */}
      <View style={styles.section}>
        <Text style={styles.label}>Title</Text>
        <TextInput
          style={styles.input}
          placeholder="My Awesome Animation"
          placeholderTextColor={theme.colors.textMuted}
          value={title}
          onChangeText={setTitle}
          maxLength={100}
        />

        <Text style={[styles.label, { marginTop: 16 }]}>Description</Text>
        <TextInput
          style={[styles.input, styles.textArea]}
          placeholder="What's this animation about?"
          placeholderTextColor={theme.colors.textMuted}
          value={description}
          onChangeText={setDescription}
          multiline
          numberOfLines={3}
          maxLength={500}
        />
      </View>

      {/* Official Channels (always on) */}
      <View style={styles.section}>
        <View style={styles.sectionHeader}>
          <Ionicons name="megaphone" size={18} color={brandPink} />
          <Text style={styles.sectionTitle}>StickDeath Official Channels</Text>
        </View>
        <Text style={styles.sectionDesc}>
          Your video will be published to all official channels — this builds the
          community and generates reach for everyone.
        </Text>

        {OFFICIAL_CHANNELS.map((ch) => (
          <View key={ch.platform} style={styles.channelRow}>
            <Ionicons name={ch.icon} size={22} color={ch.color} />
            <View style={{ flex: 1 }}>
              <Text style={styles.channelName}>{ch.label}</Text>
              <Text style={styles.channelHandle}>{ch.handle}</Text>
            </View>
            <Ionicons name="checkmark-circle" size={20} color="#34C759" />
          </View>
        ))}
      </View>

      {/* Watermark */}
      <View style={styles.section}>
        <View style={styles.sectionHeader}>
          <Ionicons name="shield-checkmark" size={18} color={brandPink} />
          <Text style={styles.sectionTitle}>Video Branding</Text>
        </View>

        <View style={styles.watermarkCard}>
          <View style={{ flex: 1 }}>
            <Text style={styles.watermarkTitle}>"StickDeath ∞" watermark</Text>
            <Text style={styles.watermarkDesc}>
              Appears on all videos posted to official channels
            </Text>
          </View>
          <Ionicons name="checkmark-circle" size={20} color={brandPink} />
        </View>

        {isPro ? (
          <View style={styles.watermarkToggle}>
            <View style={{ flex: 1 }}>
              <Text style={styles.watermarkToggleTitle}>
                Remove watermark on personal export
              </Text>
              <Text style={styles.watermarkToggleDesc}>
                Only for copies sent to your own accounts
              </Text>
            </View>
            <Switch
              value={removeWatermark}
              onValueChange={setRemoveWatermark}
              trackColor={{ false: theme.colors.gray[700], true: brandPink }}
              thumbColor="#fff"
            />
          </View>
        ) : (
          <View style={styles.proBadge}>
            <Ionicons name="star" size={14} color={brandPink} />
            <Text style={styles.proBadgeText}>
              Upgrade to Pro to remove watermark on personal exports
            </Text>
          </View>
        )}
      </View>

      {/* User's Own Channels (optional) */}
      <View style={styles.section}>
        <View style={styles.toggleRow}>
          <View style={{ flex: 1 }}>
            <Text style={styles.sectionTitle}>Also publish to my channels</Text>
            <Text style={styles.sectionDesc}>
              Upload to your connected social accounts too
            </Text>
          </View>
          <Switch
            value={publishToOwn}
            onValueChange={setPublishToOwn}
            trackColor={{ false: theme.colors.gray[700], true: brandPink }}
            thumbColor="#fff"
          />
        </View>

        {publishToOwn && (
          <>
            {userAccounts.length === 0 ? (
              <Pressable
                style={styles.connectButton}
                onPress={() => router.push('/social-connect')}
              >
                <Ionicons name="link" size={18} color={brandPink} />
                <Text style={styles.connectButtonText}>Connect Accounts</Text>
              </Pressable>
            ) : (
              <>
                {userAccounts.map((acc) => {
                  const isSelected = selectedUserPlatforms.includes(acc.platform);
                  return (
                    <Pressable
                      key={acc.platform}
                      style={styles.channelRow}
                      onPress={() => toggleUserPlatform(acc.platform)}
                    >
                      <Ionicons
                        name={`logo-${acc.platform}` as any}
                        size={22}
                        color={theme.colors.text}
                      />
                      <View style={{ flex: 1 }}>
                        <Text style={styles.channelName}>
                          {acc.platform.charAt(0).toUpperCase() + acc.platform.slice(1)}
                        </Text>
                        <Text style={styles.channelHandle}>
                          {acc.platform_username}
                        </Text>
                      </View>
                      <Ionicons
                        name={isSelected ? 'checkmark-circle' : 'ellipse-outline'}
                        size={20}
                        color={isSelected ? brandCyan : theme.colors.textMuted}
                      />
                    </Pressable>
                  );
                })}
                <Pressable
                  style={styles.addMore}
                  onPress={() => router.push('/social-connect')}
                >
                  <Ionicons name="add-circle-outline" size={16} color={brandPink} />
                  <Text style={styles.addMoreText}>Connect more platforms</Text>
                </Pressable>
              </>
            )}
          </>
        )}
      </View>

      {/* Error */}
      {publishError && (
        <View style={styles.errorBanner}>
          <Ionicons name="warning" size={16} color={brandPink} />
          <Text style={styles.errorText}>{publishError}</Text>
        </View>
      )}

      {/* Publish Button */}
      <Pressable
        style={[styles.publishButton, !title.trim() && styles.publishDisabled]}
        onPress={handlePublish}
        disabled={!title.trim()}
      >
        <Ionicons name="paper-plane" size={20} color="#000" />
        <Text style={styles.publishButtonText}>Publish Animation</Text>
      </Pressable>

      {/* Terms */}
      <Text style={styles.terms}>
        By publishing, you agree that your video will be uploaded to StickDeath
        official channels. Videos may appear on YouTube, TikTok, Discord, and
        other platforms to build community reach.
      </Text>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
  scrollContent: {
    paddingBottom: 60,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: theme.spacing.xl,
    paddingVertical: theme.spacing.lg,
  },
  backButton: {
    width: 40,
    height: 40,
    alignItems: 'center',
    justifyContent: 'center',
  },
  headerTitle: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xl,
    color: theme.colors.text,
  },

  // Sections
  section: {
    marginHorizontal: theme.spacing.xl,
    marginBottom: theme.spacing.xl,
  },
  sectionHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    marginBottom: theme.spacing.sm,
  },
  sectionTitle: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
  },
  sectionDesc: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
    marginBottom: theme.spacing.md,
    lineHeight: 18,
  },

  // Inputs
  label: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.sm,
    color: theme.colors.text,
    marginBottom: 6,
  },
  input: {
    backgroundColor: theme.colors.card,
    borderRadius: theme.radii.md,
    padding: theme.spacing.lg,
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
  },
  textArea: {
    minHeight: 80,
    textAlignVertical: 'top',
  },

  // Channel rows
  channelRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.md,
    padding: theme.spacing.md,
    backgroundColor: theme.colors.card,
    borderRadius: theme.radii.md,
    marginBottom: theme.spacing.sm,
  },
  channelName: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.sm,
    color: theme.colors.text,
  },
  channelHandle: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
  },

  // Watermark
  watermarkCard: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: theme.spacing.lg,
    backgroundColor: theme.colors.card,
    borderRadius: theme.radii.md,
    marginBottom: theme.spacing.sm,
  },
  watermarkTitle: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.sm,
    color: theme.colors.text,
  },
  watermarkDesc: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
    marginTop: 2,
  },
  watermarkToggle: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.sm,
  },
  watermarkToggleTitle: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.xs,
    color: theme.colors.text,
  },
  watermarkToggleDesc: {
    fontFamily: theme.fontFamily.regular,
    fontSize: 11,
    color: theme.colors.textMuted,
    marginTop: 1,
  },
  proBadge: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    padding: theme.spacing.md,
    backgroundColor: `${brandPink}12`,
    borderRadius: theme.radii.md,
  },
  proBadgeText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.xs,
    color: brandPink,
    flex: 1,
  },

  // Toggle row
  toggleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: theme.spacing.md,
  },

  // Connect accounts
  connectButton: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: theme.spacing.sm,
    padding: theme.spacing.lg,
    backgroundColor: `${brandPink}12`,
    borderRadius: theme.radii.md,
    borderWidth: 1,
    borderColor: `${brandPink}30`,
    borderStyle: 'dashed',
  },
  connectButtonText: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.sm,
    color: brandPink,
  },
  addMore: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
    paddingTop: theme.spacing.sm,
  },
  addMoreText: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: brandPink,
  },

  // Error
  errorBanner: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    marginHorizontal: theme.spacing.xl,
    marginBottom: theme.spacing.lg,
    padding: theme.spacing.md,
    backgroundColor: `${brandPink}12`,
    borderRadius: theme.radii.md,
  },
  errorText: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: brandPink,
    flex: 1,
  },

  // Publish button
  publishButton: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: theme.spacing.sm,
    marginHorizontal: theme.spacing.xl,
    marginBottom: theme.spacing.md,
    paddingVertical: 16,
    backgroundColor: brandPink,
    borderRadius: theme.radii.lg,
  },
  publishDisabled: {
    backgroundColor: theme.colors.gray[700],
  },
  publishButtonText: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.lg,
    color: '#000',
  },

  // Terms
  terms: {
    fontFamily: theme.fontFamily.regular,
    fontSize: 10,
    color: theme.colors.textMuted,
    textAlign: 'center',
    paddingHorizontal: theme.spacing.xl * 2,
    marginBottom: theme.spacing.xl,
    lineHeight: 14,
  },

  // Success
  successContainer: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: theme.spacing.xl * 2,
  },
  successTitle: {
    fontFamily: theme.fontFamily.bold,
    fontSize: 28,
    color: theme.colors.text,
    marginTop: theme.spacing.lg,
  },
  successSubtitle: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textMuted,
    textAlign: 'center',
    marginTop: theme.spacing.sm,
    marginBottom: theme.spacing.xl,
  },
  successChannels: {
    width: '100%',
    padding: theme.spacing.lg,
    backgroundColor: theme.colors.card,
    borderRadius: theme.radii.lg,
    marginBottom: theme.spacing.lg,
  },
  successLabel: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
    marginBottom: theme.spacing.md,
  },
  successRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    paddingVertical: 6,
  },
  successChannelText: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textSecondary,
    flex: 1,
  },
  successExtra: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.sm,
    color: brandCyan,
    marginBottom: theme.spacing.xl,
  },
  doneButton: {
    width: '100%',
    paddingVertical: 16,
    backgroundColor: '#34C759',
    borderRadius: theme.radii.lg,
    alignItems: 'center',
  },
  doneButtonText: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.lg,
    color: '#000',
  },

  // Publishing
  publishingContainer: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: theme.spacing.lg,
  },
  publishingText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.md,
    color: theme.colors.textMuted,
  },
});
