/**
 * Register Screen
 *
 * Create account with email, username, password + OAuth options.
 */

import React, { useState } from 'react';
import {
  Alert,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useRouter } from 'expo-router';
import { Ionicons } from '@expo/vector-icons';
import { useAuth } from '../../src/hooks/useAuth';
import { Button } from '../../src/components/common/Button';
import { theme } from '../../src/theme';

const USERNAME_REGEX = /^[a-z0-9_]{3,20}$/;

export default function RegisterScreen() {
  const router = useRouter();
  const { signUpWithEmail, signInWithOAuth } = useAuth();

  const [username, setUsername] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [oauthLoading, setOauthLoading] = useState<string | null>(null);

  const usernameClean = username.trim().toLowerCase();
  const isUsernameValid = USERNAME_REGEX.test(usernameClean);
  const isPasswordValid = password.length >= 8;

  const handleRegister = async () => {
    if (!usernameClean) {
      Alert.alert('Missing Username', 'Pick a unique username.');
      return;
    }
    if (!isUsernameValid) {
      Alert.alert(
        'Invalid Username',
        'Usernames must be 3–20 characters: lowercase letters, numbers, and underscores only.'
      );
      return;
    }
    if (!email.trim()) {
      Alert.alert('Missing Email', 'Enter your email address.');
      return;
    }
    if (!isPasswordValid) {
      Alert.alert(
        'Weak Password',
        'Password must be at least 8 characters.'
      );
      return;
    }

    setIsLoading(true);
    try {
      await signUpWithEmail(email, password, usernameClean);
      // Auth listener will auto-redirect to (tabs)
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Registration failed';
      Alert.alert('Sign Up Error', message);
    } finally {
      setIsLoading(false);
    }
  };

  const handleOAuth = async (provider: 'apple' | 'google') => {
    setOauthLoading(provider);
    try {
      await signInWithOAuth(provider);
    } finally {
      setOauthLoading(null);
    }
  };

  return (
    <KeyboardAvoidingView
      style={styles.flex}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
    >
      <ScrollView
        contentContainerStyle={styles.container}
        keyboardShouldPersistTaps="handled"
      >
        {/* Header */}
        <View style={styles.header}>
          <Pressable onPress={() => router.back()} style={styles.backButton}>
            <Ionicons name="arrow-back" size={24} color={theme.colors.text} />
          </Pressable>
          <Text style={styles.title}>Create Account</Text>
          <Text style={styles.subtitle}>
            Start making stick figure masterpieces
          </Text>
        </View>

        {/* OAuth buttons */}
        <View style={styles.oauthSection}>
          {Platform.OS === 'ios' && (
            <Pressable
              style={[styles.oauthButton, styles.appleButton]}
              onPress={() => handleOAuth('apple')}
              disabled={!!oauthLoading}
            >
              <Ionicons name="logo-apple" size={20} color="#FFFFFF" />
              <Text style={[styles.oauthText, { color: '#FFFFFF' }]}>
                {oauthLoading === 'apple' ? 'Signing up…' : 'Sign up with Apple'}
              </Text>
            </Pressable>
          )}

          <Pressable
            style={[styles.oauthButton, styles.googleButton]}
            onPress={() => handleOAuth('google')}
            disabled={!!oauthLoading}
          >
            <Ionicons name="logo-google" size={20} color={theme.colors.text} />
            <Text style={styles.oauthText}>
              {oauthLoading === 'google' ? 'Signing up…' : 'Sign up with Google'}
            </Text>
          </Pressable>
        </View>

        {/* Divider */}
        <View style={styles.divider}>
          <View style={styles.dividerLine} />
          <Text style={styles.dividerText}>or</Text>
          <View style={styles.dividerLine} />
        </View>

        {/* Email form */}
        <View style={styles.form}>
          <View style={styles.inputGroup}>
            <Text style={styles.label}>Username</Text>
            <TextInput
              style={[
                styles.input,
                usernameClean.length > 0 && !isUsernameValid && styles.inputError,
              ]}
              value={username}
              onChangeText={setUsername}
              placeholder="stick_master_99"
              placeholderTextColor={theme.colors.textMuted}
              autoCapitalize="none"
              autoComplete="username"
              autoCorrect={false}
              maxLength={20}
            />
            {usernameClean.length > 0 && !isUsernameValid && (
              <Text style={styles.errorHint}>
                3–20 chars: lowercase letters, numbers, underscores
              </Text>
            )}
          </View>

          <View style={styles.inputGroup}>
            <Text style={styles.label}>Email</Text>
            <TextInput
              style={styles.input}
              value={email}
              onChangeText={setEmail}
              placeholder="you@example.com"
              placeholderTextColor={theme.colors.textMuted}
              keyboardType="email-address"
              autoCapitalize="none"
              autoComplete="email"
              autoCorrect={false}
            />
          </View>

          <View style={styles.inputGroup}>
            <Text style={styles.label}>Password</Text>
            <View style={styles.passwordContainer}>
              <TextInput
                style={[
                  styles.input,
                  styles.passwordInput,
                  password.length > 0 && !isPasswordValid && styles.inputError,
                ]}
                value={password}
                onChangeText={setPassword}
                placeholder="Min 8 characters"
                placeholderTextColor={theme.colors.textMuted}
                secureTextEntry={!showPassword}
                autoCapitalize="none"
                autoComplete="new-password"
              />
              <Pressable
                onPress={() => setShowPassword(!showPassword)}
                style={styles.eyeButton}
              >
                <Ionicons
                  name={showPassword ? 'eye-off' : 'eye'}
                  size={20}
                  color={theme.colors.textMuted}
                />
              </Pressable>
            </View>
            {password.length > 0 && !isPasswordValid && (
              <Text style={styles.errorHint}>
                Must be at least 8 characters
              </Text>
            )}
          </View>

          <Button
            title="Create Account"
            variant="primary"
            size="lg"
            fullWidth
            loading={isLoading}
            disabled={!isUsernameValid || !email.trim() || !isPasswordValid}
            onPress={handleRegister}
            style={styles.registerButton}
          />
        </View>

        {/* Login link */}
        <View style={styles.footer}>
          <Text style={styles.footerText}>Already have an account? </Text>
          <Pressable onPress={() => router.replace('/(auth)/login')}>
            <Text style={styles.footerLink}>Sign In</Text>
          </Pressable>
        </View>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1, backgroundColor: theme.colors.background },
  container: {
    flexGrow: 1,
    paddingHorizontal: theme.spacing.xl,
    paddingTop: 60,
    paddingBottom: 40,
  },
  header: {
    marginBottom: theme.spacing.xxl,
  },
  backButton: {
    marginBottom: theme.spacing.xl,
    width: 40,
    height: 40,
    alignItems: 'center',
    justifyContent: 'center',
  },
  title: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xxxl,
    color: theme.colors.text,
    marginBottom: theme.spacing.sm,
  },
  subtitle: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textSecondary,
  },
  oauthSection: {
    gap: theme.spacing.md,
    marginBottom: theme.spacing.xl,
  },
  oauthButton: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: theme.spacing.md,
    borderRadius: theme.radii.md,
    gap: theme.spacing.sm,
  },
  appleButton: {
    backgroundColor: '#000000',
    borderWidth: 1,
    borderColor: theme.colors.gray[600],
  },
  googleButton: {
    backgroundColor: theme.colors.gray[800],
    borderWidth: 1,
    borderColor: theme.colors.border,
  },
  oauthText: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
  },
  divider: {
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: theme.spacing.xl,
  },
  dividerLine: {
    flex: 1,
    height: 1,
    backgroundColor: theme.colors.border,
  },
  dividerText: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textMuted,
    marginHorizontal: theme.spacing.lg,
  },
  form: {
    gap: theme.spacing.lg,
  },
  inputGroup: {
    gap: theme.spacing.sm,
  },
  label: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textSecondary,
  },
  input: {
    backgroundColor: theme.colors.surface,
    borderWidth: 1,
    borderColor: theme.colors.border,
    borderRadius: theme.radii.md,
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.md,
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
  },
  inputError: {
    borderColor: theme.colors.error,
  },
  passwordContainer: {
    position: 'relative',
  },
  passwordInput: {
    paddingRight: 48,
  },
  eyeButton: {
    position: 'absolute',
    right: theme.spacing.lg,
    top: 0,
    bottom: 0,
    justifyContent: 'center',
  },
  errorHint: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: theme.colors.error,
  },
  registerButton: {
    marginTop: theme.spacing.sm,
  },
  footer: {
    flexDirection: 'row',
    justifyContent: 'center',
    marginTop: theme.spacing.xxl,
  },
  footerText: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textSecondary,
  },
  footerLink: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.md,
    color: theme.colors.primary,
  },
});
