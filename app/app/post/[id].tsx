/**
 * Post Detail + Comments Screen
 *
 * Full view of a community post with comments, reactions, and sharing.
 */

import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Alert,
  FlatList,
  Image,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  Share,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import * as Haptics from 'expo-haptics';
import { supabase } from '../../src/lib/supabase';
import { useAuth } from '../../src/hooks/useAuth';
import { Avatar } from '../../src/components/common/Avatar';
import { LoadingScreen } from '../../src/components/common/LoadingScreen';
import { ReportModal } from '../../src/components/common/ReportModal';
import { theme } from '../../src/theme';
import { brandPink } from '../../src/theme/colors';
import type {
  CommunityPost,
  PostComment,
  Profile,
  ReactionType,
} from '../../src/types/database';

interface PostWithProfile extends CommunityPost {
  profiles: Pick<Profile, 'username' | 'display_name' | 'avatar_url' | 'is_verified'>;
}

interface CommentWithProfile extends PostComment {
  profiles: Pick<Profile, 'username' | 'display_name' | 'avatar_url'>;
}

const REACTIONS: ReactionType[] = ['🔥', '💀', '🤣', '👑', '💯'];

export default function PostDetailScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { user } = useAuth();
  const inputRef = useRef<TextInput>(null);

  const [post, setPost] = useState<PostWithProfile | null>(null);
  const [comments, setComments] = useState<CommentWithProfile[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [commentText, setCommentText] = useState('');
  const [sending, setSending] = useState(false);
  const [liked, setLiked] = useState(false);
  const [showReactions, setShowReactions] = useState(false);
  const [replyingTo, setReplyingTo] = useState<string | null>(null);
  const [showReportModal, setShowReportModal] = useState(false);

  const fetchPost = useCallback(async () => {
    if (!id) return;
    try {
      const { data, error } = await supabase
        .from('community_posts')
        .select(
          '*, profiles!community_posts_user_id_fkey(username, display_name, avatar_url, is_verified)'
        )
        .eq('id', id)
        .single();

      if (error) throw error;
      setPost(data as unknown as PostWithProfile);
    } catch (err) {
      console.error('[PostDetail] fetch post error:', err);
    }
  }, [id]);

  const fetchComments = useCallback(async () => {
    if (!id) return;
    try {
      const { data, error } = await supabase
        .from('post_comments')
        .select(
          '*, profiles!post_comments_user_id_fkey(username, display_name, avatar_url)'
        )
        .eq('post_id', id)
        .order('created_at', { ascending: true });

      if (error) throw error;
      setComments((data as unknown as CommentWithProfile[]) ?? []);
    } catch (err) {
      console.error('[PostDetail] fetch comments error:', err);
    }
  }, [id]);

  const checkIfLiked = useCallback(async () => {
    if (!user || !id) return;
    const { data } = await supabase
      .from('post_reactions')
      .select('id')
      .eq('post_id', id)
      .eq('user_id', user.id)
      .maybeSingle();

    setLiked(!!data);
  }, [user, id]);

  useEffect(() => {
    Promise.all([fetchPost(), fetchComments(), checkIfLiked()]).finally(() =>
      setIsLoading(false)
    );
  }, [fetchPost, fetchComments, checkIfLiked]);

  // Real-time comments
  useEffect(() => {
    if (!id) return;
    const channel = supabase
      .channel(`post_comments_${id}`)
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'public',
          table: 'post_comments',
          filter: `post_id=eq.${id}`,
        },
        () => fetchComments()
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [id, fetchComments]);

  const handleLike = async (reaction: ReactionType = '🔥') => {
    if (!user || !id) return;
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);

    const wasLiked = liked;
    setLiked(!wasLiked);
    setShowReactions(false);

    if (post) {
      setPost({
        ...post,
        like_count: post.like_count + (wasLiked ? -1 : 1),
      });
    }

    try {
      if (wasLiked) {
        await supabase
          .from('post_reactions')
          .delete()
          .eq('post_id', id)
          .eq('user_id', user.id);
      } else {
        await supabase
          .from('post_reactions')
          .insert({ post_id: id, user_id: user.id, reaction });
      }
    } catch {
      setLiked(wasLiked);
    }
  };

  const handleSendComment = async () => {
    if (!user || !id || !commentText.trim()) return;
    setSending(true);
    try {
      const { error } = await supabase.from('post_comments').insert({
        post_id: id,
        user_id: user.id,
        body: commentText.trim(),
        parent_comment_id: replyingTo,
      });

      if (error) throw error;
      setCommentText('');
      setReplyingTo(null);
      await fetchComments();
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to post comment';
      Alert.alert('Error', msg);
    } finally {
      setSending(false);
    }
  };

  const handleShare = async () => {
    if (!post) return;
    try {
      await Share.share({
        message: `Check out this animation by @${post.profiles.username} on STICKDEATH ∞! ${post.caption || ''}`,
        url: `https://stickdeath.app/post/${post.id}`,
      });
    } catch {
      // User cancelled
    }
  };

  const handleUserTap = (userId: string) => {
    router.push(`/user/${userId}`);
  };

  const formatTime = (iso: string): string => {
    const d = new Date(iso);
    const now = new Date();
    const diffMs = now.getTime() - d.getTime();
    const diffMin = Math.floor(diffMs / 60000);
    const diffHours = Math.floor(diffMs / 3600000);
    const diffDays = Math.floor(diffMs / 86400000);

    if (diffMin < 1) return 'Just now';
    if (diffMin < 60) return `${diffMin}m`;
    if (diffHours < 24) return `${diffHours}h`;
    if (diffDays < 7) return `${diffDays}d`;
    return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  };

  const formatCount = (n: number): string => {
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
    if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
    return String(n);
  };

  if (isLoading || !post) {
    return <LoadingScreen message="Loading post…" />;
  }

  const profile = post.profiles;

  return (
    <KeyboardAvoidingView
      style={[styles.container, { paddingTop: insets.top }]}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      keyboardVerticalOffset={0}
    >
      {/* Header */}
      <View style={styles.header}>
        <Pressable onPress={() => router.back()} style={styles.backButton}>
          <Ionicons name="chevron-back" size={24} color={theme.colors.text} />
        </Pressable>
        <Text style={styles.headerTitle}>Post</Text>
        <View style={{ flexDirection: 'row', gap: 8 }}>
          <Pressable onPress={handleShare} style={styles.backButton}>
            <Ionicons name="share-outline" size={22} color={theme.colors.text} />
          </Pressable>
          {post && post.user_id !== user?.id && (
            <Pressable onPress={() => setShowReportModal(true)} style={styles.backButton}>
              <Ionicons name="flag-outline" size={20} color={theme.colors.textMuted} />
            </Pressable>
          )}
        </View>
      </View>

      <FlatList
        data={comments}
        keyExtractor={(item) => item.id}
        showsVerticalScrollIndicator={false}
        contentContainerStyle={styles.listContent}
        ListHeaderComponent={
          <View>
            {/* Author row */}
            <Pressable
              style={styles.authorRow}
              onPress={() => handleUserTap(post.user_id)}
            >
              <Avatar
                uri={profile.avatar_url}
                name={profile.display_name || profile.username}
                size="md"
              />
              <View style={styles.authorInfo}>
                <View style={styles.authorNameRow}>
                  <Text style={styles.authorName}>
                    {profile.display_name || profile.username}
                  </Text>
                  {profile.is_verified && (
                    <Ionicons
                      name="checkmark-circle"
                      size={14}
                      color={brandPink}
                      style={{ marginLeft: 4 }}
                    />
                  )}
                </View>
                <Text style={styles.authorUsername}>
                  @{profile.username} · {formatTime(post.created_at)}
                </Text>
              </View>
            </Pressable>

            {/* Media */}
            <View style={styles.mediaContainer}>
              {post.thumbnail_url ? (
                <Image
                  source={{ uri: post.thumbnail_url }}
                  style={styles.media}
                  resizeMode="cover"
                />
              ) : (
                <View style={styles.mediaPlaceholder}>
                  <Ionicons
                    name="play-circle"
                    size={64}
                    color={theme.colors.textMuted}
                  />
                </View>
              )}
            </View>

            {/* Caption */}
            {post.caption && (
              <Text style={styles.caption}>{post.caption}</Text>
            )}

            {/* Tags */}
            {post.tags.length > 0 && (
              <View style={styles.tags}>
                {post.tags.map((tag) => (
                  <View key={tag} style={styles.tag}>
                    <Text style={styles.tagText}>#{tag}</Text>
                  </View>
                ))}
              </View>
            )}

            {/* Actions */}
            <View style={styles.actions}>
              <Pressable
                style={styles.actionButton}
                onPress={() => handleLike()}
                onLongPress={() => setShowReactions(true)}
              >
                <Ionicons
                  name={liked ? 'heart' : 'heart-outline'}
                  size={24}
                  color={liked ? brandPink : theme.colors.textSecondary}
                />
                <Text
                  style={[styles.actionCount, liked && { color: brandPink }]}
                >
                  {formatCount(post.like_count)}
                </Text>
              </Pressable>

              <Pressable
                style={styles.actionButton}
                onPress={() => inputRef.current?.focus()}
              >
                <Ionicons
                  name="chatbubble-outline"
                  size={22}
                  color={theme.colors.textSecondary}
                />
                <Text style={styles.actionCount}>
                  {formatCount(post.comment_count)}
                </Text>
              </Pressable>

              <Pressable style={styles.actionButton} onPress={handleShare}>
                <Ionicons
                  name="share-outline"
                  size={22}
                  color={theme.colors.textSecondary}
                />
                <Text style={styles.actionCount}>
                  {formatCount(post.share_count)}
                </Text>
              </Pressable>

              <View style={styles.actionButton}>
                <Ionicons
                  name="eye-outline"
                  size={22}
                  color={theme.colors.textSecondary}
                />
                <Text style={styles.actionCount}>
                  {formatCount(post.view_count)}
                </Text>
              </View>
            </View>

            {/* Reaction picker */}
            {showReactions && (
              <View style={styles.reactionPicker}>
                {REACTIONS.map((r) => (
                  <Pressable
                    key={r}
                    style={styles.reactionButton}
                    onPress={() => handleLike(r)}
                  >
                    <Text style={styles.reactionEmoji}>{r}</Text>
                  </Pressable>
                ))}
              </View>
            )}

            {/* Comments header */}
            <View style={styles.commentsHeader}>
              <Text style={styles.commentsTitle}>
                Comments ({comments.length})
              </Text>
            </View>
          </View>
        }
        renderItem={({ item }) => (
          <View style={styles.commentRow}>
            <Pressable onPress={() => handleUserTap(item.user_id)}>
              <Avatar
                uri={item.profiles.avatar_url}
                name={item.profiles.display_name || item.profiles.username}
                size="sm"
              />
            </Pressable>
            <View style={styles.commentContent}>
              <View style={styles.commentHeader}>
                <Text style={styles.commentAuthor}>
                  {item.profiles.display_name || item.profiles.username}
                </Text>
                <Text style={styles.commentTime}>
                  {formatTime(item.created_at)}
                </Text>
              </View>
              <Text style={styles.commentBody}>{item.body}</Text>
              <Pressable
                style={styles.replyButton}
                onPress={() => {
                  setReplyingTo(item.id);
                  inputRef.current?.focus();
                }}
              >
                <Text style={styles.replyText}>Reply</Text>
              </Pressable>
            </View>
          </View>
        )}
        ListEmptyComponent={
          <View style={styles.emptyComments}>
            <Text style={styles.emptyCommentsText}>
              No comments yet. Be the first!
            </Text>
          </View>
        }
      />

      {/* Comment input */}
      <View style={[styles.inputContainer, { paddingBottom: insets.bottom + 8 }]}>
        {replyingTo && (
          <View style={styles.replyingBanner}>
            <Text style={styles.replyingText}>Replying to comment</Text>
            <Pressable onPress={() => setReplyingTo(null)}>
              <Ionicons name="close" size={16} color={theme.colors.textMuted} />
            </Pressable>
          </View>
        )}
        <View style={styles.inputRow}>
          <TextInput
            ref={inputRef}
            style={styles.commentInput}
            value={commentText}
            onChangeText={setCommentText}
            placeholder="Add a comment…"
            placeholderTextColor={theme.colors.textMuted}
            multiline
            maxLength={500}
          />
          <Pressable
            style={[
              styles.sendButton,
              !commentText.trim() && styles.sendButtonDisabled,
            ]}
            onPress={handleSendComment}
            disabled={!commentText.trim() || sending}
          >
            <Ionicons
              name="send"
              size={20}
              color={commentText.trim() ? brandPink : theme.colors.textMuted}
            />
          </Pressable>
        </View>
      </View>
      {/* Report Modal */}
      <ReportModal
        visible={showReportModal}
        onClose={() => setShowReportModal(false)}
        entityType="post"
        entityId={postId!}
        entityLabel={post?.caption || 'Post'}
      />
    </KeyboardAvoidingView>
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
  listContent: {
    paddingHorizontal: theme.spacing.lg,
    paddingBottom: 20,
  },
  authorRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: theme.spacing.lg,
  },
  authorInfo: {
    marginLeft: theme.spacing.md,
    flex: 1,
  },
  authorNameRow: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  authorName: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
  },
  authorUsername: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textMuted,
  },
  mediaContainer: {
    borderRadius: theme.radii.lg,
    overflow: 'hidden',
    marginBottom: theme.spacing.lg,
  },
  media: {
    width: '100%',
    aspectRatio: 9 / 16,
  },
  mediaPlaceholder: {
    width: '100%',
    aspectRatio: 16 / 9,
    backgroundColor: theme.colors.surface,
    borderRadius: theme.radii.lg,
    alignItems: 'center',
    justifyContent: 'center',
  },
  caption: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
    lineHeight: theme.lineHeight.lg,
    marginBottom: theme.spacing.md,
  },
  tags: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: theme.spacing.sm,
    marginBottom: theme.spacing.lg,
  },
  tag: {
    backgroundColor: theme.colors.surface,
    paddingHorizontal: theme.spacing.sm,
    paddingVertical: theme.spacing.xxs,
    borderRadius: theme.radii.xs,
  },
  tagText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.xs,
    color: theme.colors.secondary,
  },
  actions: {
    flexDirection: 'row',
    justifyContent: 'space-around',
    paddingVertical: theme.spacing.md,
    borderTopWidth: 0.5,
    borderBottomWidth: 0.5,
    borderColor: theme.colors.border,
    marginBottom: theme.spacing.lg,
  },
  actionButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
  },
  actionCount: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textSecondary,
  },
  reactionPicker: {
    flexDirection: 'row',
    justifyContent: 'center',
    gap: theme.spacing.md,
    backgroundColor: theme.colors.card,
    borderRadius: theme.radii.xl,
    paddingVertical: theme.spacing.sm,
    paddingHorizontal: theme.spacing.lg,
    marginBottom: theme.spacing.lg,
    ...theme.shadows.md,
  },
  reactionButton: {
    padding: theme.spacing.xs,
  },
  reactionEmoji: {
    fontSize: 28,
  },
  commentsHeader: {
    marginBottom: theme.spacing.lg,
  },
  commentsTitle: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.lg,
    color: theme.colors.text,
  },
  commentRow: {
    flexDirection: 'row',
    marginBottom: theme.spacing.lg,
  },
  commentContent: {
    flex: 1,
    marginLeft: theme.spacing.md,
  },
  commentHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    marginBottom: theme.spacing.xxs,
  },
  commentAuthor: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.sm,
    color: theme.colors.text,
  },
  commentTime: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
  },
  commentBody: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
    lineHeight: theme.lineHeight.md,
  },
  replyButton: {
    marginTop: theme.spacing.xs,
  },
  replyText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
  },
  emptyComments: {
    alignItems: 'center',
    paddingVertical: theme.spacing.xxl,
  },
  emptyCommentsText: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textMuted,
  },
  inputContainer: {
    borderTopWidth: 0.5,
    borderTopColor: theme.colors.border,
    backgroundColor: theme.colors.surface,
    paddingHorizontal: theme.spacing.lg,
    paddingTop: theme.spacing.sm,
  },
  replyingBanner: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: theme.spacing.xs,
    paddingHorizontal: theme.spacing.sm,
    marginBottom: theme.spacing.xs,
  },
  replyingText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
  },
  inputRow: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    gap: theme.spacing.sm,
  },
  commentInput: {
    flex: 1,
    backgroundColor: theme.colors.card,
    borderRadius: theme.radii.xl,
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.md,
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
    maxHeight: 100,
  },
  sendButton: {
    width: 40,
    height: 40,
    alignItems: 'center',
    justifyContent: 'center',
  },
  sendButtonDisabled: {
    opacity: 0.5,
  },
});
