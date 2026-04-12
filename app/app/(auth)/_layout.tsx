/**
 * Auth Stack Layout
 *
 * Contains welcome, login, and register screens.
 * If the user is already authenticated, redirect to tabs.
 */

import React from 'react';
import { Redirect, Stack } from 'expo-router';
import { useAuth } from '../../src/hooks/useAuth';
import { LoadingScreen } from '../../src/components/common/LoadingScreen';
import { theme } from '../../src/theme';

export default function AuthLayout() {
  const { session, isLoading } = useAuth();

  if (isLoading) {
    return <LoadingScreen message="Loading…" />;
  }

  // Already signed in → go to main app
  if (session) {
    return <Redirect href="/(tabs)" />;
  }

  return (
    <Stack
      screenOptions={{
        headerShown: false,
        contentStyle: { backgroundColor: theme.colors.background },
        animation: 'slide_from_right',
      }}
    >
      <Stack.Screen name="welcome" />
      <Stack.Screen name="login" />
      <Stack.Screen name="register" />
    </Stack>
  );
}
