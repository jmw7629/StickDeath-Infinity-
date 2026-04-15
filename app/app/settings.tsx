/**
 * Settings Screen
 *
 * Account settings, subscription management, connected accounts,
 * and sign out. Accessible from Profile tab gear icon.
 */

import React, { useCallback, useState } from 'react';
import {
  Alert,
  Linking,
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import * as Haptics from 'expo-haptics';
import { supabase } from '../src/lib/supabase';
import { useAuth } from '../src/hooks/useAuth';
import { Avatar } from '../src/components/common/Avatar';
import { Button } from '../src/components/common/Button';
import { LoadingScreen } from '../src/components/common/LoadingScreen';
import { theme } from '../src/theme';
import { brandPink, brandCyan } from '../src/theme/colors';

const SUPABASE_URL = process.env.EXPO_PUBLIC_SUPABASE_URL!;

export default function SettingsScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { user, profile, signOut, refreshProfile } = useAuth();

  const [isEditing, setIsEditing] = useState(false);
  const [displayName, setDisplayName] = useState(profile?.display_name || '');
  const [bio, setBio] = useState(profile?.bio || '');
  const [website, setWebsite] = useState(profile?.website || '');
  const [saving, setSaving] = useState(false);
  const [managingSubscription, setManagingSubscription] = useState(false);

  // Notification preferences (local state — would be persisted to DB)
  const [pushEnabled, setPushEnabled] = useState(true);
  const [emailEnabled, setEmailEnabled] = useState(true);

  const handleBack = () => {
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    router.back();
  };

  const handleSaveProfile = useCallback(async () => {
    if (!user) return;
    setSaving(true);
    try {
      const { error } = await supabase
        .from('profiles')
        .update({
          display_name: displayName.trim() || null,
          bio: bio.trim() || null,
          website: website.trim() || null,
        })
        .eq('id', user.id);

      if (error) throw error;
      await refreshProfile();
      setIsEditing(false);
      Alert.alert('Saved', 'Your profile has been updated.');
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to save';
      Alert.alert('Error', msg);
    } finally {
      setSaving(false);
    }
  }, [user, displayName, bio, website, refreshProfile]);

  const handleManageSubscription = useCallback(async () => {
    if (!user?.id) return;
    setManagingSubscription(true);
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) throw new Error('Not authenticated');

      const res = await fetch(`${SUPABASE_URL}/functions/v1/manage-subscription`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${session.access_token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ action: 'portal' }),
      });

      const json = await res.json();
      if (!res.ok) throw new Error(json.error || 'Failed to open portal');
      if (json.url) {
        await Linking.openURL(json.url);
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to manage subscription';
      Alert.alert('Error', msg);
    } finally {
      setManagingSubscription(false);
    }
  }, [user]);

  const handleSignOut = () => {
    Alert.alert('Sign Out', 'Are you sure you want to sign out?', [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Sign Out',
        style: 'destructive',
        onPress: async () => {
          await signOut();
          router.replace('/(auth)/welcome');
        },
      },
    ]);
  };

  const handleDeleteAccount = () => {
    Alert.alert(
      'Delete Account',
      'This will permanently delete your account and all your data. This action cannot be undone.',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Delete Account',
          style: 'destructive',
          onPress: () => {
            Alert.alert(
              'Are you absolutely sure?',
              'Type DELETE to confirm.',
              [{ text: 'Cancel', style: 'cancel' }]
            );
          },
        },
      ]
    );
  };

  if (!profile) {
    return <LoadingScreen message="Loading settings…" />;
  }

  return (
    <View style={[styles.container, { paddingTop: insets.top }]}>
      {/* Header */}
      <View style={styles.header}>
        <Pressable onPress={handleBack} style={styles.backButton}>
          <Ionicons name="chevron-back" size={24} color={theme.colors.text} />
        </Pressable>
        <Text style={styles.headerTitle}>Settings</Text>
        <View style={styles.backButton} />
      </View>

      <ScrollView
        showsVerticalScrollIndicator={false}
        contentContainerStyle={styles.scrollContent}
      >
        {/* Profile Section */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Profile</Text>
          <View style={styles.card}>
            <View style={styles.profileRow}>
              <Avatar
                uri={profile.avatar_url}
                name={profile.display_name || profile.username}
                size="lg"
              />
              <View style={styles.profileInfo}>
                <Text style={styles.profileName}>
                  {profile.display_name || profile.username}
                </Text>
                <Text style={styles.profileUsername}>@{profile.username}</Text>
              </View>
            </View>

            {isEditing ? (
              <View style={styles.editForm}>
                <Text style={styles.inputLabel}>Display Name</Text>
                <TextInput
                  style={styles.input}
                  value={displayName}
                  onChangeText={setDisplayName}
                  placeholder="Display name"
                  placeholderTextColor={theme.colors.textMuted}
                  autoCapitalize="words"
                />

                <Text style={styles.inputLabel}>Bio</Text>
                <TextInput
                  style={[styles.input, styles.bioInput]}
                  value={bio}
                  onChangeText={setBio}
                  placeholder="Tell the world about yourself"
                  placeholderTextColor={theme.colors.textMuted}
                  multiline
                  maxLength={150}
                />

                <Text style={styles.inputLabel}>Website</Text>
                <TextInput
                  style={styles.input}
                  value={website}
                  onChangeText={setWebsite}
                  placeholder="https://your-website.com"
                  placeholderTextColor={theme.colors.textMuted}
                  autoCapitalize="none"
                  keyboardType="url"
                />

                <View style={styles.editActions}>
                  <Button
                    title="Cancel"
                    variant="ghost"
                    size="sm"
                    onPress={() => {
                      setIsEditing(false);
                      setDisplayName(profile.display_name || '');
                      setBio(profile.bio || '');
                      setWebsite(profile.website || '');
                    }}
                  />
                  <Button
                    title="Save"
                    variant="primary"
                    size="sm"
                    loading={saving}
                    onPress={handleSaveProfile}
                  />
                </View>
              </View>
            ) : (
              <Button
                title="Edit Profile"
                variant="outline"
                size="sm"
                fullWidth
                style={{ marginTop: theme.spacing.lg }}
                onPress={() => setIsEditing(true)}
              />
            )}
          </View>
        </View>

        {/* Subscription Section */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Subscription</Text>
          <View style={styles.card}>
            <View style={styles.row}>
              <View style={styles.rowLeft}>
                <Ionicons
                  name={profile.subscription_tier === 'pro' ? 'star' : 'star-outline'}
                  size={22}
                  color={profile.subscription_tier === 'pro' ? brandPink : theme.colors.textMuted}
                />
                <View style={styles.rowTextContainer}>
                  <Text style={styles.rowTitle}>
                    {profile.subscription_tier === 'pro' ? 'Pro Plan' : 'Free Plan'}
                  </Text>
                  <Text style={styles.rowSubtitle}>
                    {profile.subscription_tier === 'pro'
                      ? 'Unlimited layers, HD export, no watermark'
                      : 'Upgrade for unlimited features'}
                  </Text>
                </View>
              </View>
            </View>

            {profile.subscription_tier === 'pro' ? (
              <Button
                title="Manage Subscription"
                variant="outline"
                size="sm"
                fullWidth
                loading={managingSubscription}
                onPress={handleManageSubscription}
                style={{ marginTop: theme.spacing.md }}
              />
            ) : (
              <Button
                title="Upgrade to Pro — $4.99/mo"
                variant="primary"
                size="md"
                fullWidth
                onPress={() => router.push('/settings')} // Will be replaced by checkout
                style={{ marginTop: theme.spacing.md }}
                icon={<Ionicons name="star" size={16} color={theme.colors.text} />}
              />
            )}
          </View>
        </View>

        {/* Notifications */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Notifications</Text>
          <View style={styles.card}>
            <View style={styles.toggleRow}>
              <View style={styles.rowLeft}>
                <Ionicons name="notifications-outline" size={22} color={theme.colors.textSecondary} />
                <Text style={styles.rowTitle}>Push Notifications</Text>
              </View>
              <Switch
                value={pushEnabled}
                onValueChange={setPushEnabled}
                trackColor={{ false: theme.colors.border, true: `${brandPink}60` }}
                thumbColor={pushEnabled ? brandPink : theme.colors.textMuted}
              />
            </View>

            <View style={styles.divider} />

            <View style={styles.toggleRow}>
              <View style={styles.rowLeft}>
                <Ionicons name="mail-outline" size={22} color={theme.colors.textSecondary} />
                <Text style={styles.rowTitle}>Email Notifications</Text>
              </View>
              <Switch
                value={emailEnabled}
                onValueChange={setEmailEnabled}
                trackColor={{ false: theme.colors.border, true: `${brandPink}60` }}
                thumbColor={emailEnabled ? brandPink : theme.colors.textMuted}
              />
            </View>
          </View>
        </View>

        {/* Connected Accounts */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Connected Accounts</Text>
          <View style={styles.card}>
            <Pressable style={styles.row}>
              <View style={styles.rowLeft}>
                <Ionicons name="logo-apple" size={22} color={theme.colors.textSecondary} />
                <Text style={styles.rowTitle}>Apple</Text>
              </View>
              <Text style={styles.rowAction}>Connect</Text>
            </Pressable>

            <View style={styles.divider} />

            <Pressable style={styles.row}>
              <View style={styles.rowLeft}>
                <Ionicons name="logo-google" size={22} color={theme.colors.textSecondary} />
                <Text style={styles.rowTitle}>Google</Text>
              </View>
              <Text style={styles.rowAction}>Connect</Text>
            </Pressable>

            <View style={styles.divider} />

            <Pressable style={styles.row} onPress={() => router.push('/social-connect')}>
              <View style={styles.rowLeft}>
                <Ionicons name="share-social-outline" size={22} color={theme.colors.textSecondary} />
                <Text style={styles.rowTitle}>Social Publishing</Text>
              </View>
              <Ionicons name="chevron-forward" size={18} color={theme.colors.textMuted} />
            </Pressable>
          </View>
        </View>

        {/* About */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>About</Text>
          <View style={styles.card}>
            <Pressable style={styles.row}>
              <View style={styles.rowLeft}>
                <Ionicons name="document-text-outline" size={22} color={theme.colors.textSecondary} />
                <Text style={styles.rowTitle}>Terms of Service</Text>
              </View>
              <Ionicons name="chevron-forward" size={18} color={theme.colors.textMuted} />
            </Pressable>

            <View style={styles.divider} />

            <Pressable style={styles.row}>
              <View style={styles.rowLeft}>
                <Ionicons name="shield-outline" size={22} color={theme.colors.textSecondary} />
                <Text style={styles.rowTitle}>Privacy Policy</Text>
              </View>
              <Ionicons name="chevron-forward" size={18} color={theme.colors.textMuted} />
            </Pressable>

            <View style={styles.divider} />

            <View style={styles.row}>
              <View style={styles.rowLeft}>
                <Ionicons name="information-circle-outline" size={22} color={theme.colors.textSecondary} />
                <Text style={styles.rowTitle}>Version</Text>
              </View>
              <Text style={styles.rowValue}>1.0.0</Text>
            </View>
          </View>
        </View>

        {/* Sign Out */}
        <Button
          title="Sign Out"
          variant="ghost"
          size="md"
          fullWidth
          onPress={handleSignOut}
          textStyle={{ color: theme.colors.error }}
          style={styles.signOutButton}
        />

        {/* Delete Account */}
        <Pressable onPress={handleDeleteAccount} style={styles.deleteButton}>
          <Text style={styles.deleteText}>Delete Account</Text>
        </Pressable>
      </ScrollView>
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
  scrollContent: {
    paddingHorizontal: theme.spacing.lg,
    paddingBottom: 80,
  },
  section: {
    marginBottom: theme.spacing.xl,
  },
  sectionTitle: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textMuted,
    textTransform: 'uppercase',
    letterSpacing: 1,
    marginBottom: theme.spacing.md,
    marginLeft: theme.spacing.xs,
  },
  card: {
    backgroundColor: theme.colors.card,
    borderRadius: theme.radii.lg,
    padding: theme.spacing.lg,
    ...theme.shadows.sm,
  },
  profileRow: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  profileInfo: {
    marginLeft: theme.spacing.lg,
    flex: 1,
  },
  profileName: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.lg,
    color: theme.colors.text,
  },
  profileUsername: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textMuted,
    marginTop: theme.spacing.xxs,
  },
  editForm: {
    marginTop: theme.spacing.lg,
  },
  inputLabel: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textSecondary,
    marginBottom: theme.spacing.xs,
    marginTop: theme.spacing.md,
  },
  input: {
    backgroundColor: theme.colors.surface,
    borderRadius: theme.radii.md,
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.md,
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
    borderWidth: 1,
    borderColor: theme.colors.border,
  },
  bioInput: {
    height: 80,
    textAlignVertical: 'top',
    paddingTop: theme.spacing.md,
  },
  editActions: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: theme.spacing.md,
    marginTop: theme.spacing.lg,
  },
  row: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: theme.spacing.sm,
  },
  toggleRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: theme.spacing.xs,
  },
  rowLeft: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.md,
    flex: 1,
  },
  rowTextContainer: {
    flex: 1,
  },
  rowTitle: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
  },
  rowSubtitle: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textMuted,
    marginTop: theme.spacing.xxs,
  },
  rowAction: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.sm,
    color: brandPink,
  },
  rowValue: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textMuted,
  },
  divider: {
    height: 0.5,
    backgroundColor: theme.colors.border,
    marginVertical: theme.spacing.md,
  },
  signOutButton: {
    marginTop: theme.spacing.lg,
  },
  deleteButton: {
    alignItems: 'center',
    paddingVertical: theme.spacing.xl,
  },
  deleteText: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.sm,
    color: theme.colors.error,
    opacity: 0.7,
  },
});
