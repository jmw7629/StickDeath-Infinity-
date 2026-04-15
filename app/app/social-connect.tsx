/**
 * Social Connect Screen
 *
 * Connect YouTube, TikTok, Instagram, Facebook accounts
 * for cross-posting animations. Uses the social-connect Edge Function.
 */

import React, { useCallback, useEffect, useState } from 'react';
import {
  Alert,
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
import * as WebBrowser from 'expo-web-browser';
import * as Haptics from 'expo-haptics';
import { supabase } from '../src/lib/supabase';
import { useAuth } from '../src/hooks/useAuth';
import { LoadingScreen } from '../src/components/common/LoadingScreen';
import { theme } from '../src/theme';
import { brandPink, brandCyan } from '../src/theme/colors';

const SUPABASE_URL = process.env.EXPO_PUBLIC_SUPABASE_URL!;

type Platform = 'youtube' | 'tiktok' | 'instagram' | 'facebook';

interface PlatformConnection {
  platform: Platform;
  connected: boolean;
  platform_username: string | null;
  connected_at: string | null;
}

const PLATFORM_CONFIG: Record<
  Platform,
  { label: string; icon: string; color: string; description: string }
> = {
  youtube: {
    label: 'YouTube',
    icon: 'logo-youtube',
    color: '#FF0000',
    description: 'Publish animations as YouTube Shorts',
  },
  tiktok: {
    label: 'TikTok',
    icon: 'logo-tiktok',
    color: '#00F2EA',
    description: 'Share directly to your TikTok profile',
  },
  instagram: {
    label: 'Instagram',
    icon: 'logo-instagram',
    color: '#E4405F',
    description: 'Post as Instagram Reels',
  },
  facebook: {
    label: 'Facebook',
    icon: 'logo-facebook',
    color: '#1877F2',
    description: 'Publish to your Facebook page',
  },
};

export default function SocialConnectScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { profile } = useAuth();

  const [connections, setConnections] = useState<PlatformConnection[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [connecting, setConnecting] = useState<Platform | null>(null);

  const fetchStatus = useCallback(async () => {
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) return;

      const res = await fetch(
        `${SUPABASE_URL}/functions/v1/social-connect?action=status`,
        {
          headers: { Authorization: `Bearer ${session.access_token}` },
        },
      );

      const json = await res.json();
      if (json.connections) {
        setConnections(json.connections);
      }
    } catch (err) {
      console.error('[SocialConnect] status error:', err);
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchStatus();
  }, [fetchStatus]);

  const handleConnect = async (platform: Platform) => {
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
    setConnecting(platform);

    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) throw new Error('Not authenticated');

      const res = await fetch(
        `${SUPABASE_URL}/functions/v1/social-connect?action=connect&platform=${platform}`,
        {
          headers: { Authorization: `Bearer ${session.access_token}` },
        },
      );

      const json = await res.json();
      if (!res.ok) throw new Error(json.error || 'Failed to get auth URL');

      if (json.auth_url) {
        await WebBrowser.openBrowserAsync(json.auth_url);
        // After redirect, refresh status
        await fetchStatus();
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Connection failed';
      Alert.alert('Error', msg);
    } finally {
      setConnecting(null);
    }
  };

  const handleDisconnect = async (platform: Platform) => {
    Alert.alert(
      `Disconnect ${PLATFORM_CONFIG[platform].label}?`,
      'You can reconnect any time.',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Disconnect',
          style: 'destructive',
          onPress: async () => {
            try {
              const { data: { session } } = await supabase.auth.getSession();
              if (!session) return;

              const res = await fetch(
                `${SUPABASE_URL}/functions/v1/social-connect?action=disconnect&platform=${platform}`,
                {
                  method: 'POST',
                  headers: { Authorization: `Bearer ${session.access_token}` },
                },
              );

              if (!res.ok) throw new Error('Disconnect failed');
              await fetchStatus();
              Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
            } catch (err) {
              Alert.alert('Error', 'Failed to disconnect. Try again.');
            }
          },
        },
      ],
    );
  };

  const isPro = profile?.subscription_tier === 'pro';

  if (isLoading) return <LoadingScreen message="Loading connections…" />;

  return (
    <ScrollView
      style={[styles.container, { paddingTop: insets.top }]}
      contentContainerStyle={styles.scrollContent}
    >
      {/* Header */}
      <View style={styles.header}>
        <Pressable onPress={() => router.back()} style={styles.backButton}>
          <Ionicons name="arrow-back" size={24} color={theme.colors.text} />
        </Pressable>
        <Text style={styles.headerTitle}>Connected Accounts</Text>
        <View style={{ width: 40 }} />
      </View>

      <Text style={styles.subtitle}>
        Connect your social accounts to publish animations directly from StickDeath.
      </Text>

      {!isPro && (
        <View style={styles.proBanner}>
          <Ionicons name="star" size={18} color={brandPink} />
          <Text style={styles.proBannerText}>
            Social publishing requires Pro. Upgrade to connect accounts.
          </Text>
        </View>
      )}

      {/* Platform cards */}
      {(['youtube', 'tiktok', 'instagram', 'facebook'] as Platform[]).map((platform) => {
        const config = PLATFORM_CONFIG[platform];
        const connection = connections.find((c) => c.platform === platform);
        const isConnected = connection?.connected ?? false;

        return (
          <View key={platform} style={styles.platformCard}>
            <View style={styles.platformLeft}>
              <View style={[styles.platformIcon, { backgroundColor: `${config.color}20` }]}>
                <Ionicons name={config.icon as any} size={24} color={config.color} />
              </View>
              <View style={styles.platformInfo}>
                <Text style={styles.platformName}>{config.label}</Text>
                {isConnected && connection?.platform_username ? (
                  <Text style={styles.connectedAs}>
                    Connected as {connection.platform_username}
                  </Text>
                ) : (
                  <Text style={styles.platformDesc}>{config.description}</Text>
                )}
              </View>
            </View>

            {isConnected ? (
              <Pressable
                style={styles.disconnectButton}
                onPress={() => handleDisconnect(platform)}
              >
                <Text style={styles.disconnectText}>Disconnect</Text>
              </Pressable>
            ) : (
              <Pressable
                style={[styles.connectButton, !isPro && styles.connectDisabled]}
                onPress={() => isPro && handleConnect(platform)}
                disabled={!isPro || connecting === platform}
              >
                <Text
                  style={[styles.connectText, !isPro && styles.connectTextDisabled]}
                >
                  {connecting === platform ? 'Connecting…' : 'Connect'}
                </Text>
              </Pressable>
            )}
          </View>
        );
      })}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
  scrollContent: {
    paddingBottom: 40,
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
  subtitle: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textSecondary,
    paddingHorizontal: theme.spacing.xl,
    marginBottom: theme.spacing.xl,
    lineHeight: theme.lineHeight.lg,
  },
  proBanner: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    marginHorizontal: theme.spacing.xl,
    marginBottom: theme.spacing.xl,
    padding: theme.spacing.lg,
    backgroundColor: `${brandPink}15`,
    borderRadius: theme.radii.md,
    borderWidth: 1,
    borderColor: `${brandPink}30`,
  },
  proBannerText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.sm,
    color: brandPink,
    flex: 1,
  },
  platformCard: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginHorizontal: theme.spacing.xl,
    marginBottom: theme.spacing.md,
    padding: theme.spacing.lg,
    backgroundColor: theme.colors.card,
    borderRadius: theme.radii.lg,
  },
  platformLeft: {
    flexDirection: 'row',
    alignItems: 'center',
    flex: 1,
    gap: theme.spacing.md,
  },
  platformIcon: {
    width: 44,
    height: 44,
    borderRadius: theme.radii.md,
    alignItems: 'center',
    justifyContent: 'center',
  },
  platformInfo: {
    flex: 1,
  },
  platformName: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
  },
  platformDesc: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
    marginTop: 2,
  },
  connectedAs: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: theme.colors.success,
    marginTop: 2,
  },
  connectButton: {
    paddingVertical: theme.spacing.sm,
    paddingHorizontal: theme.spacing.lg,
    borderRadius: theme.radii.md,
    backgroundColor: brandPink,
  },
  connectDisabled: {
    backgroundColor: theme.colors.gray[700],
  },
  connectText: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.sm,
    color: theme.colors.white,
  },
  connectTextDisabled: {
    color: theme.colors.textMuted,
  },
  disconnectButton: {
    paddingVertical: theme.spacing.sm,
    paddingHorizontal: theme.spacing.lg,
    borderRadius: theme.radii.md,
    borderWidth: 1,
    borderColor: theme.colors.error,
  },
  disconnectText: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.sm,
    color: theme.colors.error,
  },
});
