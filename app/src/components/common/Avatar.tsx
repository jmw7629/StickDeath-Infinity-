/**
 * Avatar — user avatar with fallback initials, optional online badge, and sizes.
 */

import React, { useMemo, useState } from 'react';
import { Image, StyleSheet, Text, View, type ViewStyle } from 'react-native';
import { theme } from '../../theme';
import { brandPink, brandCyan } from '../../theme/colors';

// ── Types ──────────────────────────────────────────────

export type AvatarSize = 'xs' | 'sm' | 'md' | 'lg' | 'xl';

export interface AvatarProps {
  uri?: string | null;
  name?: string | null;
  size?: AvatarSize;
  showOnline?: boolean;
  isOnline?: boolean;
  style?: ViewStyle;
}

// ── Sizes ──────────────────────────────────────────────

const sizeMap: Record<AvatarSize, number> = {
  xs: 28,
  sm: 36,
  md: 44,
  lg: 64,
  xl: 96,
};

const fontSizeMap: Record<AvatarSize, number> = {
  xs: 11,
  sm: 13,
  md: 16,
  lg: 24,
  xl: 36,
};

const badgeSizeMap: Record<AvatarSize, number> = {
  xs: 8,
  sm: 10,
  md: 12,
  lg: 16,
  xl: 20,
};

// ── Deterministic fallback color ───────────────────────

const fallbackColors = [
  brandPink,
  brandCyan,
  '#F759AB',
  '#36CFC9',
  '#9254DE',
  '#597EF7',
  '#FF7A45',
  '#73D13D',
];

function colorForName(name: string): string {
  let hash = 0;
  for (let i = 0; i < name.length; i++) {
    hash = name.charCodeAt(i) + ((hash << 5) - hash);
  }
  return fallbackColors[Math.abs(hash) % fallbackColors.length];
}

function initials(name: string): string {
  const parts = name.trim().split(/\s+/);
  if (parts.length >= 2) {
    return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
  }
  return name.slice(0, 2).toUpperCase();
}

// ── Component ──────────────────────────────────────────

export function Avatar({
  uri,
  name,
  size = 'md',
  showOnline = false,
  isOnline = false,
  style,
}: AvatarProps) {
  const [imageError, setImageError] = useState(false);
  const dim = sizeMap[size];
  const badgeDim = badgeSizeMap[size];
  const showFallback = !uri || imageError;

  const fallbackBg = useMemo(
    () => colorForName(name || 'U'),
    [name]
  );

  return (
    <View
      style={[
        {
          width: dim,
          height: dim,
          borderRadius: dim / 2,
          overflow: 'hidden',
        },
        style,
      ]}
    >
      {showFallback ? (
        <View
          style={[
            styles.fallback,
            {
              width: dim,
              height: dim,
              borderRadius: dim / 2,
              backgroundColor: fallbackBg,
            },
          ]}
        >
          <Text
            style={[
              styles.initials,
              { fontSize: fontSizeMap[size] },
            ]}
          >
            {initials(name || 'U')}
          </Text>
        </View>
      ) : (
        <Image
          source={{ uri }}
          style={{ width: dim, height: dim }}
          onError={() => setImageError(true)}
        />
      )}

      {showOnline && (
        <View
          style={[
            styles.badge,
            {
              width: badgeDim,
              height: badgeDim,
              borderRadius: badgeDim / 2,
              borderWidth: badgeDim > 10 ? 2 : 1.5,
              backgroundColor: isOnline
                ? theme.colors.success
                : theme.colors.gray[600],
            },
          ]}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  fallback: {
    alignItems: 'center',
    justifyContent: 'center',
  },
  initials: {
    color: theme.colors.white,
    fontFamily: theme.fontFamily.bold,
  },
  badge: {
    position: 'absolute',
    bottom: 0,
    right: 0,
    borderColor: theme.colors.background,
  },
});

export default Avatar;
