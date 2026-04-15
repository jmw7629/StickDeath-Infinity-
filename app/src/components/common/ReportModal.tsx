/**
 * ReportModal — Report a user, post, or comment.
 *
 * Inserts into a `reports` table and shows confirmation.
 */

import React, { useState } from 'react';
import {
  Alert,
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
import { theme } from '../../theme';
import { brandPink } from '../../theme/colors';

type ReportEntityType = 'user' | 'post' | 'comment';

const REPORT_REASONS = [
  'Spam or scam',
  'Harassment or bullying',
  'Hate speech',
  'Violence or dangerous content',
  'Nudity or sexual content',
  'Copyright infringement',
  'Impersonation',
  'Other',
] as const;

interface ReportModalProps {
  visible: boolean;
  onClose: () => void;
  entityType: ReportEntityType;
  entityId: string;
  entityLabel?: string; // e.g. username or post title
}

export function ReportModal({
  visible,
  onClose,
  entityType,
  entityId,
  entityLabel,
}: ReportModalProps) {
  const [selectedReason, setSelectedReason] = useState<string | null>(null);
  const [details, setDetails] = useState('');
  const [submitting, setSubmitting] = useState(false);

  const handleSubmit = async () => {
    if (!selectedReason) {
      Alert.alert('Select a Reason', 'Please select why you are reporting this content.');
      return;
    }

    Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning);
    setSubmitting(true);

    try {
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) throw new Error('Not authenticated');

      const { error } = await supabase.from('reports').insert({
        reporter_id: user.id,
        entity_type: entityType,
        entity_id: entityId,
        reason: selectedReason,
        details: details.trim() || null,
      });

      if (error) throw error;

      Alert.alert(
        'Report Submitted',
        'Thank you. Our team will review this report within 24 hours.',
      );
      onClose();
      setSelectedReason(null);
      setDetails('');
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to submit report';
      Alert.alert('Error', msg);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={onClose}>
      <View style={styles.overlay}>
        <View style={styles.sheet}>
          <View style={styles.handleBar} />

          <View style={styles.header}>
            <Ionicons name="flag" size={28} color={theme.colors.error} />
            <Text style={styles.title}>
              Report {entityType === 'user' ? 'User' : entityType === 'post' ? 'Post' : 'Comment'}
            </Text>
            {entityLabel && (
              <Text style={styles.subtitle} numberOfLines={1}>
                {entityLabel}
              </Text>
            )}
          </View>

          {/* Reasons */}
          <View style={styles.reasons}>
            {REPORT_REASONS.map((reason) => (
              <Pressable
                key={reason}
                style={[
                  styles.reasonRow,
                  selectedReason === reason && styles.reasonSelected,
                ]}
                onPress={() => setSelectedReason(reason)}
              >
                <View
                  style={[
                    styles.radio,
                    selectedReason === reason && styles.radioSelected,
                  ]}
                >
                  {selectedReason === reason && <View style={styles.radioInner} />}
                </View>
                <Text style={styles.reasonText}>{reason}</Text>
              </Pressable>
            ))}
          </View>

          {/* Details */}
          <TextInput
            style={styles.detailsInput}
            value={details}
            onChangeText={setDetails}
            placeholder="Additional details (optional)"
            placeholderTextColor={theme.colors.textMuted}
            multiline
            numberOfLines={3}
            maxLength={500}
            textAlignVertical="top"
          />

          <Button
            title="Submit Report"
            variant="danger"
            size="lg"
            fullWidth
            loading={submitting}
            disabled={!selectedReason}
            onPress={handleSubmit}
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
    maxHeight: '85%',
  },
  handleBar: {
    width: 40,
    height: 4,
    backgroundColor: theme.colors.gray[600],
    borderRadius: 2,
    alignSelf: 'center',
    marginTop: theme.spacing.md,
    marginBottom: theme.spacing.lg,
  },
  header: {
    alignItems: 'center',
    marginBottom: theme.spacing.xl,
  },
  title: {
    fontFamily: theme.fontFamily.bold,
    fontSize: theme.fontSize.xl,
    color: theme.colors.text,
    marginTop: theme.spacing.sm,
  },
  subtitle: {
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.sm,
    color: theme.colors.textMuted,
    marginTop: theme.spacing.xs,
  },
  reasons: {
    gap: theme.spacing.sm,
    marginBottom: theme.spacing.lg,
  },
  reasonRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: theme.spacing.md,
    paddingHorizontal: theme.spacing.lg,
    borderRadius: theme.radii.md,
    backgroundColor: theme.colors.surface,
    gap: theme.spacing.md,
  },
  reasonSelected: {
    borderWidth: 1,
    borderColor: theme.colors.error,
    backgroundColor: `${theme.colors.error}15`,
  },
  radio: {
    width: 20,
    height: 20,
    borderRadius: 10,
    borderWidth: 2,
    borderColor: theme.colors.gray[600],
    alignItems: 'center',
    justifyContent: 'center',
  },
  radioSelected: {
    borderColor: theme.colors.error,
  },
  radioInner: {
    width: 10,
    height: 10,
    borderRadius: 5,
    backgroundColor: theme.colors.error,
  },
  reasonText: {
    fontFamily: theme.fontFamily.medium,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
  },
  detailsInput: {
    backgroundColor: theme.colors.surface,
    borderWidth: 1,
    borderColor: theme.colors.border,
    borderRadius: theme.radii.md,
    paddingHorizontal: theme.spacing.lg,
    paddingTop: theme.spacing.md,
    paddingBottom: theme.spacing.md,
    fontFamily: theme.fontFamily.regular,
    fontSize: theme.fontSize.md,
    color: theme.colors.text,
    minHeight: 80,
    marginBottom: theme.spacing.xl,
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

export default ReportModal;
