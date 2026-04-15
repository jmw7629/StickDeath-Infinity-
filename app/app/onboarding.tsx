/**
 * Onboarding Screen — First-time user walkthrough
 *
 * Shown after registration. Swipeable pages introducing
 * the app features, then CTA to start creating.
 */

import React, { useCallback, useRef, useState } from 'react';
import {
  Dimensions,
  FlatList,
  Pressable,
  StyleSheet,
  Text,
  View,
  type ViewToken,
} from 'react-native';
import { useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import * as Haptics from 'expo-haptics';
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withSpring,
  interpolateColor,
} from 'react-native-reanimated';
import { Button } from '../src/components/common/Button';
import { theme } from '../src/theme';
import { brandPink, brandCyan } from '../src/theme/colors';

const { width: SCREEN_WIDTH } = Dimensions.get('window');

interface OnboardingPage {
  id: string;
  emoji: string;
  title: string;
  description: string;
  color: string;
}

const PAGES: OnboardingPage[] = [
  {
    id: 'create',
    emoji: '🎨',
    title: 'Create Stick Animations',
    description:
      'Build frame-by-frame stick figure animations with an intuitive editor. Drag joints, add layers, and bring your ideas to life.',
    color: brandPink,
  },
  {
    id: 'share',
    emoji: '🚀',
    title: 'Share With the World',
    description:
      'Publish your animations to the community feed. Get likes, comments, and build your following.',
    color: brandCyan,
  },
  {
    id: 'compete',
    emoji: '🏆',
    title: 'Join Challenges',
    description:
      'Enter weekly animation challenges, compete with other creators, and win recognition for your work.',
    color: '#9254DE',
  },
  {
    id: 'pro',
    emoji: '⚡',
    title: 'Go Pro',
    description:
      'Unlock unlimited layers, HD export, custom stick figures, AI assist, social publishing, and zero watermarks.',
    color: '#FF7A45',
  },
];

export default function OnboardingScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const flatListRef = useRef<FlatList>(null);
  const [currentIndex, setCurrentIndex] = useState(0);
  const progress = useSharedValue(0);

  const onViewableItemsChanged = useCallback(
    ({ viewableItems }: { viewableItems: ViewToken[] }) => {
      if (viewableItems.length > 0 && viewableItems[0].index != null) {
        setCurrentIndex(viewableItems[0].index);
        progress.value = withSpring(viewableItems[0].index);
      }
    },
    [progress],
  );

  const viewabilityConfig = useRef({ viewAreaCoveragePercentThreshold: 50 }).current;

  const handleNext = () => {
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    if (currentIndex < PAGES.length - 1) {
      flatListRef.current?.scrollToIndex({ index: currentIndex + 1, animated: true });
    } else {
      router.replace('/(tabs)');
    }
  };

  const handleSkip = () => {
    router.replace('/(tabs)');
  };

  const isLastPage = currentIndex === PAGES.length - 1;

  return (
    <View style={[styles.container, { paddingTop: insets.top, paddingBottom: insets.bottom }]}>
      {/* Skip button */}
      {!isLastPage && (
        <Pressable style={styles.skipButton} onPress={handleSkip}>
          <Text style={styles.skipText}>Skip</Text>
        </Pressable>
      )}

      {/* Pages */}
      <FlatList
        ref={flatListRef}
        data={PAGES}
        keyExtractor={(item) => item.id}
        horizontal
        pagingEnabled
        showsHorizontalScrollIndicator={false}
        bounces={false}
        onViewableItemsChanged={onViewableItemsChanged}
        viewabilityConfig={viewabilityConfig}
        renderItem={({ item }) => (
          <View style={styles.page}>
            <Text style={styles.emoji}>{item.emoji}</Text>
            <Text style={[styles.title, { color: item.color }]}>{item.title}</Text>
            <Text style={styles.description}>{item.description}</Text>
          </View>
        )}
      />

      {/* Dots + CTA */}
      <View style={styles.footer}>
        <View style={styles.dots}>
          {PAGES.map((_, i) => (
            <View
              key={i}
              style={[
                styles.dot,
                {
                  backgroundColor:
                    i === currentIndex ? PAGES[currentIndex].color : theme.colors.gray[700],
                  width: i === currentIndex ? 24 : 8,
                },
              ]}
            />
          ))}
        </View>

        <Button
          title={isLastPage ? "Let's Go!" : 'Next'}
          variant="primary"
          size="lg"
          fullWidth
          onPress={handleNext}
          icon={
            isLastPage ? undefined : (
              <Ionicons name="arrow-forward" size={18} color={theme.colors.white} />
            )
          }
          iconPosition="right"
        />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
  skipButton: {
    position: 'absolute',
    top: 60,
    right: theme.spacing.xl,
    zIndex: 10,
    paddingVertical: theme.spacing.sm,
    paddingHorizontal: theme.spacing.lg,
  },
  skipText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.md,
    color: theme.colors.textMuted,
  },
  page: {
    width: SCREEN_WIDTH,
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: theme.spacing.xxl,
  },
  emoji: {
    fontSize: 80,
    marginBottom: theme.spacing.xxl,
  },
  title: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xxxl,
    textAlign: 'center',
    marginBottom: theme.spacing.lg,
  },
  description: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.lg,
    color: theme.colors.textSecondary,
    textAlign: 'center',
    lineHeight: theme.lineHeight.xl,
    paddingHorizontal: theme.spacing.lg,
  },
  footer: {
    paddingHorizontal: theme.spacing.xl,
    paddingBottom: theme.spacing.xxl,
    gap: theme.spacing.xl,
  },
  dots: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: theme.spacing.sm,
  },
  dot: {
    height: 8,
    borderRadius: 4,
  },
});
