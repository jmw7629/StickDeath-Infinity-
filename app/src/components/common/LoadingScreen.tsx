/**
 * LoadingScreen — full-screen loading indicator with optional message.
 */

import React, { useEffect } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withRepeat,
  withTiming,
  Easing,
} from 'react-native-reanimated';
import { theme } from '../../theme';

export interface LoadingScreenProps {
  message?: string;
}

export function LoadingScreen({ message }: LoadingScreenProps) {
  const opacity = useSharedValue(0.4);

  useEffect(() => {
    opacity.value = withRepeat(
      withTiming(1, { duration: 800, easing: Easing.inOut(Easing.ease) }),
      -1,
      true
    );
  }, [opacity]);

  const animatedStyle = useAnimatedStyle(() => ({
    opacity: opacity.value,
  }));

  return (
    <View style={styles.container}>
      <Animated.View style={animatedStyle}>
        <Text style={styles.logo}>☠️</Text>
      </Animated.View>

      <ActivityIndicator
        size="large"
        color={theme.colors.primary}
        style={styles.spinner}
      />

      {message && <Text style={styles.message}>{message}</Text>}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: theme.colors.background,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: theme.spacing.xl,
  },
  logo: {
    fontSize: 48,
    marginBottom: theme.spacing.xl,
  },
  spinner: {
    marginBottom: theme.spacing.lg,
  },
  message: {
    color: theme.colors.textSecondary,
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.md,
    textAlign: 'center',
  },
});

export default LoadingScreen;
