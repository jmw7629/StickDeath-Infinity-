/**
 * VideoPlayer — Plays rendered animation videos with controls.
 *
 * Uses expo-av Video component. Shows play/pause overlay,
 * progress bar, and loop toggle.
 */

import React, { useCallback, useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { Video, ResizeMode, type AVPlaybackStatus } from 'expo-av';
import { Ionicons } from '@expo/vector-icons';
import { theme } from '../../theme';
import { brandPink } from '../../theme/colors';

interface VideoPlayerProps {
  uri: string;
  posterUri?: string | null;
  autoPlay?: boolean;
  loop?: boolean;
  style?: object;
  onEnd?: () => void;
}

export function VideoPlayer({
  uri,
  posterUri,
  autoPlay = false,
  loop = true,
  style,
  onEnd,
}: VideoPlayerProps) {
  const videoRef = useRef<Video>(null);
  const [isPlaying, setIsPlaying] = useState(autoPlay);
  const [isLoaded, setIsLoaded] = useState(false);
  const [progress, setProgress] = useState(0);
  const [duration, setDuration] = useState(0);
  const [showControls, setShowControls] = useState(!autoPlay);

  const handlePlaybackStatusUpdate = useCallback(
    (status: AVPlaybackStatus) => {
      if (!status.isLoaded) return;

      setIsLoaded(true);
      setIsPlaying(status.isPlaying);
      setProgress(status.positionMillis);
      setDuration(status.durationMillis ?? 0);

      if (status.didJustFinish && !loop) {
        onEnd?.();
      }
    },
    [loop, onEnd],
  );

  const togglePlayPause = async () => {
    if (!videoRef.current) return;
    if (isPlaying) {
      await videoRef.current.pauseAsync();
    } else {
      await videoRef.current.playAsync();
    }
    setShowControls(true);
    // Auto-hide controls after 2s
    setTimeout(() => setShowControls(false), 2000);
  };

  const handleTap = () => {
    setShowControls((prev) => !prev);
    if (!showControls) {
      setTimeout(() => setShowControls(false), 3000);
    }
  };

  const formatTime = (ms: number) => {
    const totalSecs = Math.floor(ms / 1000);
    const mins = Math.floor(totalSecs / 60);
    const secs = totalSecs % 60;
    return `${mins}:${secs.toString().padStart(2, '0')}`;
  };

  const progressPercent = duration > 0 ? (progress / duration) * 100 : 0;

  return (
    <View style={[styles.container, style]}>
      <Video
        ref={videoRef}
        source={{ uri }}
        posterSource={posterUri ? { uri: posterUri } : undefined}
        usePoster={!!posterUri}
        posterStyle={styles.poster}
        style={styles.video}
        resizeMode={ResizeMode.CONTAIN}
        shouldPlay={autoPlay}
        isLooping={loop}
        onPlaybackStatusUpdate={handlePlaybackStatusUpdate}
      />

      {/* Tap overlay */}
      <Pressable style={styles.overlay} onPress={handleTap}>
        {/* Play/Pause button */}
        {showControls && isLoaded && (
          <Pressable style={styles.playButton} onPress={togglePlayPause}>
            <Ionicons
              name={isPlaying ? 'pause' : 'play'}
              size={36}
              color={theme.colors.white}
            />
          </Pressable>
        )}
      </Pressable>

      {/* Progress bar */}
      {isLoaded && showControls && (
        <View style={styles.controls}>
          <Text style={styles.timeText}>{formatTime(progress)}</Text>
          <View style={styles.progressBar}>
            <View
              style={[styles.progressFill, { width: `${progressPercent}%` }]}
            />
          </View>
          <Text style={styles.timeText}>{formatTime(duration)}</Text>
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    width: '100%',
    aspectRatio: 9 / 16,
    backgroundColor: '#000',
    borderRadius: theme.radii.md,
    overflow: 'hidden',
    position: 'relative',
  },
  video: {
    width: '100%',
    height: '100%',
  },
  poster: {
    width: '100%',
    height: '100%',
    resizeMode: 'cover',
  },
  overlay: {
    ...StyleSheet.absoluteFillObject,
    alignItems: 'center',
    justifyContent: 'center',
  },
  playButton: {
    width: 64,
    height: 64,
    borderRadius: 32,
    backgroundColor: 'rgba(0,0,0,0.5)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  controls: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.sm,
    backgroundColor: 'rgba(0,0,0,0.5)',
    gap: theme.spacing.sm,
  },
  progressBar: {
    flex: 1,
    height: 3,
    backgroundColor: 'rgba(255,255,255,0.3)',
    borderRadius: 1.5,
    overflow: 'hidden',
  },
  progressFill: {
    height: '100%',
    backgroundColor: brandPink,
    borderRadius: 1.5,
  },
  timeText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: 10,
    color: theme.colors.white,
    minWidth: 32,
    textAlign: 'center',
  },
});

export default VideoPlayer;
