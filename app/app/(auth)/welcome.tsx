/**
 * Welcome Screen
 *
 * Landing page with animated logo, tagline, and sign-in / sign-up CTAs.
 */

import React, { useEffect } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { useRouter } from 'expo-router';
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withTiming,
  withDelay,
  withSpring,
  Easing,
} from 'react-native-reanimated';
import { Button } from '../../src/components/common/Button';
import { theme } from '../../src/theme';
import { brandCyan, brandPink } from '../../src/theme/colors';

export default function WelcomeScreen() {
  const router = useRouter();

  // ── Entrance animations ────────────────────────────
  const logoScale = useSharedValue(0.5);
  const logoOpacity = useSharedValue(0);
  const taglineOpacity = useSharedValue(0);
  const taglineTranslateY = useSharedValue(20);
  const buttonsOpacity = useSharedValue(0);
  const buttonsTranslateY = useSharedValue(30);

  useEffect(() => {
    logoScale.value = withSpring(1, { damping: 12, stiffness: 100 });
    logoOpacity.value = withTiming(1, { duration: 600 });

    taglineOpacity.value = withDelay(
      400,
      withTiming(1, { duration: 500, easing: Easing.out(Easing.ease) })
    );
    taglineTranslateY.value = withDelay(
      400,
      withTiming(0, { duration: 500, easing: Easing.out(Easing.ease) })
    );

    buttonsOpacity.value = withDelay(
      700,
      withTiming(1, { duration: 500, easing: Easing.out(Easing.ease) })
    );
    buttonsTranslateY.value = withDelay(
      700,
      withTiming(0, { duration: 500, easing: Easing.out(Easing.ease) })
    );
  }, []);

  const logoStyle = useAnimatedStyle(() => ({
    transform: [{ scale: logoScale.value }],
    opacity: logoOpacity.value,
  }));

  const taglineStyle = useAnimatedStyle(() => ({
    opacity: taglineOpacity.value,
    transform: [{ translateY: taglineTranslateY.value }],
  }));

  const buttonsStyle = useAnimatedStyle(() => ({
    opacity: buttonsOpacity.value,
    transform: [{ translateY: buttonsTranslateY.value }],
  }));

  return (
    <View style={styles.container}>
      {/* Logo area */}
      <View style={styles.topSection}>
        <Animated.View style={[styles.logoContainer, logoStyle]}>
          <Text style={styles.logoEmoji}>☠️</Text>
          <Text style={styles.logoText}>
            Stick<Text style={styles.logoPink}>Death</Text>
          </Text>
          <Text style={styles.logoSubtext}>INFINITY</Text>
        </Animated.View>

        <Animated.View style={taglineStyle}>
          <Text style={styles.tagline}>
            Create epic stick figure animations.{'\n'}Share with the world.
          </Text>
        </Animated.View>
      </View>

      {/* CTA buttons */}
      <Animated.View style={[styles.bottomSection, buttonsStyle]}>
        <Button
          title="Get Started"
          variant="primary"
          size="lg"
          fullWidth
          onPress={() => router.push('/(auth)/register')}
        />

        <Button
          title="I Already Have an Account"
          variant="ghost"
          size="lg"
          fullWidth
          onPress={() => router.push('/(auth)/login')}
          style={styles.secondaryButton}
        />

        <Text style={styles.terms}>
          By continuing, you agree to our{' '}
          <Text style={styles.link}>Terms of Service</Text> and{' '}
          <Text style={styles.link}>Privacy Policy</Text>
        </Text>
      </Animated.View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: theme.colors.background,
    justifyContent: 'space-between',
    paddingHorizontal: theme.spacing.xl,
    paddingTop: 120,
    paddingBottom: 48,
  },
  topSection: {
    alignItems: 'center',
  },
  logoContainer: {
    alignItems: 'center',
    marginBottom: theme.spacing.xxl,
  },
  logoEmoji: {
    fontSize: 72,
    marginBottom: theme.spacing.md,
  },
  logoText: {
    fontFamily: theme.fontFamily.black,
    fontSize: theme.fontSize.display,
    color: theme.colors.text,
    letterSpacing: -1,
  },
  logoPink: {
    color: brandPink,
  },
  logoSubtext: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.lg,
    color: brandCyan,
    letterSpacing: 8,
    marginTop: theme.spacing.xs,
  },
  tagline: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.lg,
    color: theme.colors.textSecondary,
    textAlign: 'center',
    lineHeight: theme.lineHeight.xl,
  },
  bottomSection: {
    alignItems: 'center',
  },
  secondaryButton: {
    marginTop: theme.spacing.md,
  },
  terms: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
    textAlign: 'center',
    marginTop: theme.spacing.xl,
    lineHeight: theme.lineHeight.sm,
  },
  link: {
    color: theme.colors.primary,
  },
});
