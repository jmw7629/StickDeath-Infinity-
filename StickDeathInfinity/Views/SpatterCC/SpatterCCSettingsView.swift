// ═══════════════════════════════════════════════════════════════════
// SpatterCCSettingsView — Command Center global settings
// Matches: spatter-admin /settings exactly
// - AI Engine config (backend-only, no client-side provider keys)
// - Notifications (Slack webhook URL)
// - Appearance (dark/light toggle)
// - Emergency Controls (kill all bots)
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct SpatterCCSettingsView: View {
    @ObservedObject private var botService = SpatterBotService.shared
    @State private var slackWebhook: String = ""
    @State private var showEmergencyConfirm = false
    @State private var showSavedToast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.sdTextPrimary)
                Text("Global configuration for Spatter Social Autopilot")
                    .font(.system(size: 14))
                    .foregroundColor(.sdTextSecondary)
            }

            // AI Engine section — backend-only, no client-side provider keys
            CCSettingsSection(title: "AI Engine", icon: "brain.fill",
                              description: "Spatter AI uses a configured backend endpoint. No provider API keys are stored in the app.") {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundColor(.sdSuccess)
                    Text("Backend-only AI — no client-side provider keys")
                        .font(.system(size: 13))
                        .foregroundColor(.sdTextSecondary)
                }
                .padding(14)
                .background(Color.sdSuccess.opacity(0.08))
                .cornerRadius(10)
            }

            // Notifications section
            CCSettingsSection(title: "Notifications", icon: "bell.fill",
                              description: "Get Slack notifications when bots post content, hit errors, or need attention.") {
                VStack(alignment: .leading, spacing: 8) {
                    CCTextField(label: "Slack Webhook URL", value: $slackWebhook,
                                placeholder: "https://hooks.slack.com/services/...")

                    Text("Bot activity, errors, and daily summaries will be sent here")
                        .font(.system(size: 11))
                        .foregroundColor(.sdTextMuted)
                }
            }

            // Appearance section
            CCSettingsSection(title: "Appearance", icon: "paintbrush.fill",
                              description: nil) {
                Button {
                    // Toggle is no-op in the app (always dark)
                } label: {
                    HStack {
                        Image(systemName: "moon.fill")
                            .foregroundColor(.sdRed)
                        Text("Dark Mode (Always On)")
                            .foregroundColor(.sdTextPrimary)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.sdSuccess)
                    }
                    .font(.system(size: 14))
                    .padding(14)
                    .background(Color.sdSurface2)
                    .cornerRadius(10)
                }
            }

            // Emergency Controls
            CCSettingsSection(title: "Emergency Controls", icon: "exclamationmark.triangle.fill",
                              description: nil) {
                VStack(spacing: 12) {
                    if botService.globalPaused {
                        HStack(spacing: 8) {
                            Image(systemName: "pause.circle.fill")
                                .foregroundColor(Color(hex: "FFD600"))
                            Text("All bots are currently paused")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Color(hex: "FFD600"))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(Color(hex: "FFD600").opacity(0.1))
                        .cornerRadius(10)

                        Button {
                            botService.resumeAll()
                        } label: {
                            HStack {
                                Image(systemName: "play.fill")
                                Text("Resume All Bots")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.sdSuccess)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.sdSuccess.opacity(0.12))
                            .cornerRadius(10)
                        }
                    } else {
                        Button {
                            showEmergencyConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "exclamationmark.octagon.fill")
                                Text("Emergency Stop All Bots")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.sdDestructive)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.sdDestructive.opacity(0.12))
                            .cornerRadius(10)
                        }
                    }
                }
            }

            // Save button
            Button {
                botService.slackWebhook = slackWebhook
                withAnimation { showSavedToast = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { showSavedToast = false }
                }
            } label: {
                Text("Save Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.sdRed)
                    .cornerRadius(12)
            }

            if showSavedToast {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.sdSuccess)
                    Text("Settings saved")
                        .foregroundColor(.sdSuccess)
                }
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color.sdSuccess.opacity(0.1))
                .cornerRadius(10)
                .transition(.opacity)
            }
        }
        .alert("Emergency Stop", isPresented: $showEmergencyConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Stop All Bots", role: .destructive) {
                Task { await botService.emergencyStopAll() }
            }
        } message: {
            Text("This will immediately stop all active bots. Content in queue will be preserved but no new posts will go out.")
        }
    }
}

// MARK: - Settings Section

struct CCSettingsSection<Content: View>: View {
    let title: String
    let icon: String
    var description: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.sdRed)
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.sdTextPrimary)
            }

            if let description {
                Text(description)
                    .font(.system(size: 13))
                    .foregroundColor(.sdTextSecondary)
            }

            content()
        }
        .padding(16)
        .background(Color.sdSurface)
        .cornerRadius(14)
    }
}

// MARK: - Secure Field

struct CCSecureField: View {
    let label: String
    @Binding var value: String
    let placeholder: String
    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.sdTextSecondary)

            HStack {
                if isRevealed {
                    TextField(placeholder, text: $value)
                        .font(.system(size: 14, design: .monospaced))
                } else {
                    SecureField(placeholder, text: $value)
                        .font(.system(size: 14, design: .monospaced))
                }

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.sdTextMuted)
                }
            }
            .foregroundColor(.sdTextPrimary)
            .padding(12)
            .background(Color.sdSurface2)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.sdBorderLight, lineWidth: 1)
            )
        }
    }
}

// MARK: - Text Field

struct CCTextField: View {
    let label: String
    @Binding var value: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.sdTextSecondary)

            TextField(placeholder, text: $value)
                .font(.system(size: 14))
                .foregroundColor(.sdTextPrimary)
                .padding(12)
                .background(Color.sdSurface2)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.sdBorderLight, lineWidth: 1)
                )
        }
    }
}
