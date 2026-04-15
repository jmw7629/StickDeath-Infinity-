/**
 * TipModal — Send a tip to a creator via Stripe PaymentIntent.
 *
 * Shows preset amounts ($1, $3, $5, $10) or custom.
 * Calls create-tip Edge Function → returns Stripe client secret.
 * Opens Stripe payment sheet or web checkout.
 */

import React, { useState } from 'react';
import {
  Alert,
  Linking,
  Modal,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import * as Haptics from 'expo-haptics';
import { supabase } from '../../lib/supabase';
import { Button } from './Button';
import { Avatar } from './Avatar';
import { theme } from '../../theme';
import { brandPink, brandCyan } from '../../theme/colors';

const SUPABASE_URL = process.env.EXPO_PUBLIC_SUPABASE_URL!;
const PRESET_AMOUNTS = [100, 300, 500, 1000]; // cents

interface TipModalProps {
  visible: boolean;
  onClose: () => void;
  recipientId: string;
  recipientName: string;
  recipientAvatar?: string | null;
  postId?: string;
}

export function TipModal({
  visible,
  onClose,
  recipientId,
  recipientName,
  recipientAvatar,
  postId,
}: TipModalProps) {
  const [selectedAmount, setSelectedAmount] = useState(300); // default $3
  const [customAmount, setCustomAmount] = useState('');
  const [isCustom, setIsCustom] = useState(false);
  const [sending, setSending] = useState(false);

  const amountCents = isCustom
    ? Math.round(parseFloat(customAmount || '0') * 100)
    : selectedAmount;

  const handleSelectPreset = (cents: number) => {
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    setIsCustom(false);
    setSelectedAmount(cents);
  };

  const handleCustom = () => {
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    setIsCustom(true);
  };

  const handleSendTip = async () => {
    if (amountCents < 100) {
      Alert.alert('Minimum Tip', 'Minimum tip is $1.00');
      return;
    }
    if (amountCents > 50000) {
      Alert.alert('Maximum Tip', 'Maximum tip is $500.00');
      return;
    }

    setSending(true);
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) throw new Error('Not authenticated');

      const res = await fetch(`${SUPABASE_URL}/functions/v1/create-tip`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${session.access_token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          toUserId: recipientId,
          amountCents,
          postId: postId ?? null,
        }),
      });

      const json = await res.json();
      if (!res.ok) throw new Error(json.error || 'Failed to create tip');

      // For now, show a success message — in production you'd use
      // Stripe's React Native SDK payment sheet with the clientSecret
      Alert.alert(
        'Tip Created! 🎉',
        `Your $${(amountCents / 100).toFixed(2)} tip to ${recipientName} is being processed.`,
      );
      onClose();
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Tip failed';
      Alert.alert('Error', msg);
    } finally {
      setSending(false);
    }
  };

  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={onClose}>
      <View style={styles.overlay}>
        <View style={styles.sheet}>
          {/* Handle bar */}
          <View style={styles.handleBar} />

          {/* Header */}
          <View style={styles.header}>
            <Avatar uri={recipientAvatar} name={recipientName} size="lg" />
            <Text style={styles.headerTitle}>
              Tip {recipientName}
            </Text>
            <Text style={styles.headerSubtitle}>
              Show your appreciation for their work
            </Text>
          </View>

          {/* Amount presets */}
          <View style={styles.presets}>
            {PRESET_AMOUNTS.map((cents) => (
              <Pressable
                key={cents}
                style={[
                  styles.presetButton,
                  !isCustom && selectedAmount === cents && styles.presetSelected,
                ]}
                onPress={() => handleSelectPreset(cents)}
              >
                <Text
                  style={[
                    styles.presetText,
                    !isCustom && selectedAmount === cents && styles.presetTextSelected,
                  ]}
                >
                  ${(cents / 100).toFixed(0)}
                </Text>
              </Pressable>
            ))}
            <Pressable
              style={[styles.presetButton, isCustom && styles.presetSelected]}
              onPress={handleCustom}
            >
              <Text style={[styles.presetText, isCustom && styles.presetTextSelected]}>
                Custom
              </Text>
            </Pressable>
          </View>

          {/* Custom amount input */}
          {isCustom && (
            <View style={styles.customRow}>
              <Text style={styles.dollarSign}>$</Text>
              <TextInput
                style={styles.customInput}
                value={customAmount}
                onChangeText={setCustomAmount}
                placeholder="0.00"
                placeholderTextColor={theme.colors.textMuted}
                keyboardType="decimal-pad"
                autoFocus
                maxLength={6}
              />
            </View>
          )}

          {/* Total display */}
          <View style={styles.totalRow}>
            <Ionicons name="heart" size={16} color={brandPink} />
            <Text style={styles.totalText}>
              ${(amountCents / 100).toFixed(2)}
            </Text>
          </View>

          {/* Actions */}
          <Button
            title={`Send $${(amountCents / 100).toFixed(2)} Tip`}
            variant="primary"
            size="lg"
            fullWidth
            loading={sending}
            disabled={amountCents < 100}
            onPress={handleSendTip}
          />

          <Pressable style={styles.cancelButton} onPress={onClose}>
            <Text style={styles.cancelText}>Cancel</Text>
          </Pressable>
        </View>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  overlay: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.6)',
    justifyContent: 'flex-end',
  },
  sheet: {
    backgroundColor: theme.colors.card,
    borderTopLeftRadius: theme.radii.xl,
    borderTopRightRadius: theme.radii.xl,
    paddingHorizontal: theme.spacing.xl,
    paddingBottom: theme.spacing.xxxl,
  },
  handleBar: {
    width: 40,
    height: 4,
    backgroundColor: theme.colors.gray[600],
    borderRadius: 2,
    alignSelf: 'center',
    marginTop: theme.spacing.md,
    marginBottom: theme.spacing.xl,
  },
  header: {
    alignItems: 'center',
    marginBottom: theme.spacing.xl,
  },
  headerTitle: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xl,
    color: theme.colors.text,
    marginTop: theme.spacing.md,
  },
  headerSubtitle: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textMuted,
    marginTop: theme.spacing.xs,
  },
  presets: {
    flexDirection: 'row',
    gap: theme.spacing.sm,
    marginBottom: theme.spacing.lg,
  },
  presetButton: {
    flex: 1,
    paddingVertical: theme.spacing.md,
    borderRadius: theme.radii.md,
    backgroundColor: theme.colors.surface,
    borderWidth: 1,
    borderColor: theme.colors.border,
    alignItems: 'center',
  },
  presetSelected: {
    borderColor: brandPink,
    backgroundColor: `${brandPink}20`,
  },
  presetText: {
    fontFamily: theme.fontFamily.semibold,
    fontSize: theme.fontSize.md,
    color: theme.colors.textSecondary,
  },
  presetTextSelected: {
    color: brandPink,
  },
  customRow: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: theme.colors.surface,
    borderRadius: theme.radii.md,
    borderWidth: 1,
    borderColor: brandPink,
    paddingHorizontal: theme.spacing.lg,
    marginBottom: theme.spacing.lg,
  },
  dollarSign: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xxl,
    color: brandPink,
  },
  customInput: {
    flex: 1,
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xxl,
    color: theme.colors.text,
    paddingVertical: theme.spacing.md,
    marginLeft: theme.spacing.sm,
  },
  totalRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: theme.spacing.sm,
    marginBottom: theme.spacing.xl,
  },
  totalText: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xxxl,
    color: theme.colors.text,
  },
  cancelButton: {
    alignItems: 'center',
    paddingVertical: theme.spacing.md,
    marginTop: theme.spacing.md,
  },
  cancelText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.md,
    color: theme.colors.textMuted,
  },
});

export default TipModal;
