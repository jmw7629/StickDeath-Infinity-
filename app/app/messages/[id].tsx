/**
 * DM Chat Thread Screen
 *
 * Real-time message conversation with send functionality.
 * Supports text messages and shared animation links.
 */

import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Alert,
  FlatList,
  KeyboardAvoidingView,
  Platform,
  Pressable,
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
import { theme } from '../../src/theme';
import { brandPink } from '../../src/theme/colors';
import type { DmMessage, Profile } from '../../src/types/database';

interface MessageWithSender extends DmMessage {
  profiles?: Pick<Profile, 'username' | 'display_name' | 'avatar_url'>;
}

export default function ChatScreen() {
  const { id: threadId } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { user } = useAuth();
  const flatListRef = useRef<FlatList>(null);

  const [messages, setMessages] = useState<MessageWithSender[]>([]);
  const [otherUser, setOtherUser] = useState<Pick<
    Profile,
    'username' | 'display_name' | 'avatar_url'
  > | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [messageText, setMessageText] = useState('');
  const [sending, setSending] = useState(false);

  const fetchMessages = useCallback(async () => {
    if (!threadId) return;
    try {
      const { data, error } = await supabase
        .from('dm_messages')
        .select('*')
        .eq('thread_id', threadId)
        .order('created_at', { ascending: true });

      if (error) throw error;
      setMessages((data as DmMessage[]) ?? []);
    } catch (err) {
      console.error('[Chat] fetch messages error:', err);
    }
  }, [threadId]);

  const fetchOtherUser = useCallback(async () => {
    if (!threadId || !user) return;
    try {
      const { data: members } = await supabase
        .from('dm_thread_members')
        .select('user_id')
        .eq('thread_id', threadId)
        .neq('user_id', user.id)
        .limit(1);

      if (members?.[0]) {
        const { data: profile } = await supabase
          .from('profiles')
          .select('username, display_name, avatar_url')
          .eq('id', members[0].user_id)
          .single();

        setOtherUser(profile);
      }
    } catch (err) {
      console.error('[Chat] fetch other user error:', err);
    }
  }, [threadId, user]);

  // Mark messages as read
  const markAsRead = useCallback(async () => {
    if (!threadId || !user) return;
    try {
      await supabase
        .from('dm_thread_members')
        .update({ last_read_at: new Date().toISOString() })
        .eq('thread_id', threadId)
        .eq('user_id', user.id);
    } catch (err) {
      console.error('[Chat] mark read error:', err);
    }
  }, [threadId, user]);

  useEffect(() => {
    Promise.all([fetchMessages(), fetchOtherUser()]).finally(() => {
      setIsLoading(false);
      markAsRead();
    });
  }, [fetchMessages, fetchOtherUser, markAsRead]);

  // Real-time messages
  useEffect(() => {
    if (!threadId) return;

    const channel = supabase
      .channel(`dm_messages_${threadId}`)
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'public',
          table: 'dm_messages',
          filter: `thread_id=eq.${threadId}`,
        },
        (payload) => {
          const newMsg = payload.new as DmMessage;
          setMessages((prev) => [...prev, newMsg]);
          markAsRead();
          // Scroll to bottom on new message
          setTimeout(() => {
            flatListRef.current?.scrollToEnd({ animated: true });
          }, 100);
        }
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [threadId, markAsRead]);

  const handleSend = async () => {
    if (!user || !threadId || !messageText.trim()) return;
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);

    const text = messageText.trim();
    setMessageText('');
    setSending(true);

    try {
      const { error } = await supabase.from('dm_messages').insert({
        thread_id: threadId,
        sender_id: user.id,
        body: text,
        status: 'sent',
      });

      if (error) throw error;

      // Update thread preview
      await supabase
        .from('dm_threads')
        .update({
          last_message_at: new Date().toISOString(),
          last_message_preview: text.substring(0, 100),
        })
        .eq('id', threadId);
    } catch (err) {
      setMessageText(text); // Restore text on error
      const msg = err instanceof Error ? err.message : 'Failed to send';
      Alert.alert('Error', msg);
    } finally {
      setSending(false);
    }
  };

  const formatTime = (iso: string): string => {
    const d = new Date(iso);
    return d.toLocaleTimeString('en-US', {
      hour: 'numeric',
      minute: '2-digit',
    });
  };

  const formatDateHeader = (iso: string): string => {
    const d = new Date(iso);
    const now = new Date();
    const diffMs = now.getTime() - d.getTime();
    const diffDays = Math.floor(diffMs / 86400000);

    if (diffDays === 0) return 'Today';
    if (diffDays === 1) return 'Yesterday';
    if (diffDays < 7) return d.toLocaleDateString('en-US', { weekday: 'long' });
    return d.toLocaleDateString('en-US', {
      month: 'short',
      day: 'numeric',
      year: d.getFullYear() !== now.getFullYear() ? 'numeric' : undefined,
    });
  };

  const shouldShowDateHeader = (index: number): boolean => {
    if (index === 0) return true;
    const curr = new Date(messages[index].created_at).toDateString();
    const prev = new Date(messages[index - 1].created_at).toDateString();
    return curr !== prev;
  };

  const displayName = otherUser?.display_name || otherUser?.username || 'Chat';

  if (isLoading) {
    return <LoadingScreen message="Loading messages…" />;
  }

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

        <Pressable
          style={styles.headerProfile}
          onPress={() => {
            // Navigate to other user's profile if we know their ID
          }}
        >
          <Avatar uri={otherUser?.avatar_url} name={displayName} size="sm" />
          <Text style={styles.headerName} numberOfLines={1}>
            {displayName}
          </Text>
        </Pressable>

        <Pressable style={styles.backButton}>
          <Ionicons
            name="ellipsis-vertical"
            size={20}
            color={theme.colors.text}
          />
        </Pressable>
      </View>

      {/* Messages */}
      <FlatList
        ref={flatListRef}
        data={messages}
        keyExtractor={(item) => item.id}
        showsVerticalScrollIndicator={false}
        contentContainerStyle={styles.messageList}
        onContentSizeChange={() =>
          flatListRef.current?.scrollToEnd({ animated: false })
        }
        onLayout={() =>
          flatListRef.current?.scrollToEnd({ animated: false })
        }
        ListEmptyComponent={
          <View style={styles.emptyState}>
            <Avatar uri={otherUser?.avatar_url} name={displayName} size="xl" />
            <Text style={styles.emptyTitle}>{displayName}</Text>
            <Text style={styles.emptySubtitle}>
              Send a message to start the conversation!
            </Text>
          </View>
        }
        renderItem={({ item, index }) => {
          const isMe = item.sender_id === user?.id;
          const showDate = shouldShowDateHeader(index);

          // Show avatar for consecutive messages from same non-self sender
          const showAvatar =
            !isMe &&
            (index === messages.length - 1 ||
              messages[index + 1]?.sender_id !== item.sender_id);

          return (
            <View>
              {showDate && (
                <View style={styles.dateHeader}>
                  <Text style={styles.dateHeaderText}>
                    {formatDateHeader(item.created_at)}
                  </Text>
                </View>
              )}

              <View
                style={[
                  styles.messageRow,
                  isMe ? styles.messageRowRight : styles.messageRowLeft,
                ]}
              >
                {!isMe && (
                  <View style={styles.avatarSpace}>
                    {showAvatar && (
                      <Avatar
                        uri={otherUser?.avatar_url}
                        name={displayName}
                        size="xs"
                      />
                    )}
                  </View>
                )}

                <View
                  style={[
                    styles.messageBubble,
                    isMe ? styles.myBubble : styles.theirBubble,
                  ]}
                >
                  <Text
                    style={[
                      styles.messageText,
                      isMe ? styles.myText : styles.theirText,
                    ]}
                  >
                    {item.body}
                  </Text>
                  <Text
                    style={[
                      styles.messageTime,
                      isMe ? styles.myTimeText : styles.theirTimeText,
                    ]}
                  >
                    {formatTime(item.created_at)}
                    {isMe && item.status === 'read' && ' ✓✓'}
                  </Text>
                </View>
              </View>
            </View>
          );
        }}
      />

      {/* Input */}
      <View style={[styles.inputContainer, { paddingBottom: insets.bottom + 8 }]}>
        <View style={styles.inputRow}>
          <Pressable style={styles.attachButton}>
            <Ionicons
              name="add-circle-outline"
              size={28}
              color={theme.colors.textSecondary}
            />
          </Pressable>

          <TextInput
            style={styles.messageInput}
            value={messageText}
            onChangeText={setMessageText}
            placeholder="Message…"
            placeholderTextColor={theme.colors.textMuted}
            multiline
            maxLength={2000}
          />

          <Pressable
            style={[
              styles.sendButton,
              !messageText.trim() && styles.sendButtonDisabled,
            ]}
            onPress={handleSend}
            disabled={!messageText.trim() || sending}
          >
            <Ionicons
              name="send"
              size={22}
              color={messageText.trim() ? brandPink : theme.colors.textMuted}
            />
          </Pressable>
        </View>
      </View>
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
    alignItems: 'center',
    paddingHorizontal: theme.spacing.sm,
    paddingVertical: theme.spacing.md,
    borderBottomWidth: 0.5,
    borderBottomColor: theme.colors.border,
  },
  backButton: {
    width: 40,
    height: 40,
    alignItems: 'center',
    justifyContent: 'center',
  },
  headerProfile: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.md,
    paddingHorizontal: theme.spacing.sm,
  },
  headerName: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.lg,
    color: theme.colors.text,
    flex: 1,
  },
  messageList: {
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.lg,
    flexGrow: 1,
    justifyContent: 'flex-end',
  },
  emptyState: {
    alignItems: 'center',
    paddingTop: 80,
  },
  emptyTitle: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xl,
    color: theme.colors.text,
    marginTop: theme.spacing.lg,
    marginBottom: theme.spacing.sm,
  },
  emptySubtitle: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.textMuted,
  },
  dateHeader: {
    alignItems: 'center',
    paddingVertical: theme.spacing.lg,
  },
  dateHeaderText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.xs,
    color: theme.colors.textMuted,
    backgroundColor: theme.colors.surface,
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.xs,
    borderRadius: theme.radii.full,
    overflow: 'hidden',
  },
  messageRow: {
    flexDirection: 'row',
    marginBottom: theme.spacing.xs,
    maxWidth: '80%',
  },
  messageRowRight: {
    alignSelf: 'flex-end',
  },
  messageRowLeft: {
    alignSelf: 'flex-start',
  },
  avatarSpace: {
    width: 28,
    marginRight: theme.spacing.sm,
    justifyContent: 'flex-end',
  },
  messageBubble: {
    borderRadius: theme.radii.lg,
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.md,
    maxWidth: '100%',
  },
  myBubble: {
    backgroundColor: brandPink,
    borderBottomRightRadius: theme.radii.xs,
  },
  theirBubble: {
    backgroundColor: theme.colors.card,
    borderBottomLeftRadius: theme.radii.xs,
  },
  messageText: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    lineHeight: theme.lineHeight.lg,
  },
  myText: {
    color: '#FFFFFF',
  },
  theirText: {
    color: theme.colors.text,
  },
  messageTime: {
    fontFamily: theme.fontFamily.regular,
    fontSize: 10,
    marginTop: theme.spacing.xxs,
    alignSelf: 'flex-end',
  },
  myTimeText: {
    color: 'rgba(255,255,255,0.7)',
  },
  theirTimeText: {
    color: theme.colors.textMuted,
  },
  inputContainer: {
    borderTopWidth: 0.5,
    borderTopColor: theme.colors.border,
    backgroundColor: theme.colors.surface,
    paddingHorizontal: theme.spacing.sm,
    paddingTop: theme.spacing.sm,
  },
  inputRow: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    gap: theme.spacing.xs,
  },
  attachButton: {
    width: 40,
    height: 40,
    alignItems: 'center',
    justifyContent: 'center',
  },
  messageInput: {
    flex: 1,
    backgroundColor: theme.colors.card,
    borderRadius: theme.radii.xl,
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.md,
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
    maxHeight: 120,
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
