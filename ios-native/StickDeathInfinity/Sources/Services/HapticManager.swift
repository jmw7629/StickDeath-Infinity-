// HapticManager.swift
// Centralized haptic feedback — pre-warmed generators for zero-latency response
// Usage: HapticManager.shared.jointDrag()

import UIKit

final class HapticManager {
    static let shared = HapticManager()

    // Pre-allocated generators (zero-latency on first fire)
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let softImpact = UIImpactFeedbackGenerator(style: .soft)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let notificationFeedback = UINotificationFeedbackGenerator()

    private init() {
        // Pre-warm all generators so first trigger is instant
        lightImpact.prepare()
        softImpact.prepare()
        mediumImpact.prepare()
        rigidImpact.prepare()
        selectionFeedback.prepare()
        notificationFeedback.prepare()
    }

    // MARK: - Editor Haptics

    /// Light tap when dragging a joint on the canvas
    func jointDrag() {
        lightImpact.impactOccurred()
        lightImpact.prepare()
    }

    /// Soft bump when switching between frames in the timeline
    func frameSwitched() {
        softImpact.impactOccurred()
        softImpact.prepare()
    }

    /// Medium pulse when changing editor mode (pose / move / draw)
    func modeChanged() {
        mediumImpact.impactOccurred()
        mediumImpact.prepare()
    }

    /// Rigid thud when placing an object from the asset library
    func objectPlaced() {
        rigidImpact.impactOccurred()
        rigidImpact.prepare()
    }

    // MARK: - System Haptics

    /// Success notification when an animation is published
    func published() {
        notificationFeedback.notificationOccurred(.success)
        notificationFeedback.prepare()
    }

    /// Error notification on failures
    func error() {
        notificationFeedback.notificationOccurred(.error)
        notificationFeedback.prepare()
    }

    /// Subtle tick for standard button taps
    func buttonTap() {
        selectionFeedback.selectionChanged()
        selectionFeedback.prepare()
    }
}
