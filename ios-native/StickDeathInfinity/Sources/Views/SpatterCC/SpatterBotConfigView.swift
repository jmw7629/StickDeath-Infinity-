// ═══════════════════════════════════════════════════════════════════
// SpatterBotConfigView — Per-platform bot configuration
// Matches: spatter-admin /bots/{platform} exactly
// - Platform header with icon, name, tagline, status badge
// - API Credentials section (secure fields per platform)
// - Posting Schedule picker (Standard vs Aggressive etc.)
// - Bot Features toggle list
// - Save / Activate button
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct SpatterBotConfigView: View {
    let platform: BotPlatform
    @ObservedObject private var botService = SpatterBotService.shared

    @State private var credentials: [String: String] = [:]
    @State private var selectedSchedule: String = ""
    @State private var enabledFeatures: Set<String> = []
    @State private var isActive: Bool = false
    @State private var showSaved = false

    private var config: BotConfiguration? {
        botService.botConfigs[platform.rawValue]
    }

    private var isConfigured: Bool {
        !credentials.values.filter({ !$0.isEmpty }).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Platform header
            platformHeader

            // API Credentials
            credentialsSection

            // Posting Schedule
            scheduleSection

            // Bot Features
            featuresSection

            // Save button
            saveButton

            if showSaved {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.sdSuccess)
                    Text("Configuration saved")
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
        .onAppear { loadFromConfig() }
    }

    // MARK: - Platform Header
    private var platformHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Text(platform.icon)
                    .font(.system(size: 36))
                    .frame(width: 56, height: 56)
                    .background(platform.color.opacity(0.15))
                    .cornerRadius(14)

                VStack(alignment: .leading, spacing: 4) {
                    Text(platform.displayName)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.sdTextPrimary)
                    Text(platform.tagline)
                        .font(.system(size: 13))
                        .foregroundColor(.sdTextSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Status
            HStack(spacing: 8) {
                if isActive {
                    CCStatusBadge(text: "Active", color: .sdSuccess)
                } else if isConfigured {
                    CCStatusBadge(text: "Configured", color: Color(hex: "FFD600"))
                } else {
                    CCStatusBadge(text: "Not configured", color: .sdTextMuted)
                }

                Spacer()

                if isConfigured {
                    Toggle("", isOn: $isActive)
                        .tint(.sdRed)
                        .labelsHidden()
                }
            }
        }
        .padding(16)
        .background(Color.sdSurface)
        .cornerRadius(14)
    }

    // MARK: - Credentials Section
    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API Credentials")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.sdTextPrimary)

            VStack(spacing: 14) {
                ForEach(platform.credentialFields) { field in
                    CCSecureField(
                        label: field.label,
                        value: Binding(
                            get: { credentials[field.key] ?? "" },
                            set: { credentials[field.key] = $0 }
                        ),
                        placeholder: field.placeholder
                    )
                }
            }
            .padding(16)
            .background(Color.sdSurface)
            .cornerRadius(14)
        }
    }

    // MARK: - Schedule Section
    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Posting Schedule")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.sdTextPrimary)

            VStack(spacing: 8) {
                ForEach(platform.scheduleOptions) { option in
                    let isSelected = selectedSchedule == option.name

                    Button {
                        selectedSchedule = option.name
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(isSelected ? .sdTextPrimary : .sdTextSecondary)
                                Text(option.description)
                                    .font(.system(size: 12))
                                    .foregroundColor(.sdTextMuted)
                                Text(option.cron)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.sdTextMuted)
                            }

                            Spacer()

                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.sdRed)
                                    .font(.system(size: 18))
                            } else {
                                Image(systemName: "circle")
                                    .foregroundColor(.sdBorderLight)
                                    .font(.system(size: 18))
                            }
                        }
                        .padding(14)
                        .background(isSelected ? Color.sdRed.opacity(0.08) : Color.sdSurface)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isSelected ? Color.sdRed.opacity(0.3) : Color.sdBorder, lineWidth: 1)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Features Section
    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bot Features")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.sdTextPrimary)

            VStack(spacing: 0) {
                ForEach(platform.botFeatures) { feature in
                    let enabled = enabledFeatures.contains(feature.name)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.sdTextPrimary)
                            Text(feature.description)
                                .font(.system(size: 12))
                                .foregroundColor(.sdTextMuted)
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { enabled },
                            set: { newVal in
                                if newVal { enabledFeatures.insert(feature.name) }
                                else { enabledFeatures.remove(feature.name) }
                            }
                        ))
                        .tint(.sdRed)
                        .labelsHidden()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    if feature.id != platform.botFeatures.last?.id {
                        Divider().background(Color.sdBorder)
                    }
                }
            }
            .background(Color.sdSurface)
            .cornerRadius(14)
        }
    }

    // MARK: - Save Button
    private var saveButton: some View {
        Button {
            saveConfig()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.fill")
                Text("Save Configuration")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.sdRed)
            .cornerRadius(12)
        }
    }

    // MARK: - Load / Save
    private func loadFromConfig() {
        if let config {
            credentials = config.credentials
            selectedSchedule = config.selectedSchedule ?? platform.scheduleOptions.first?.name ?? ""
            enabledFeatures = Set(config.enabledFeatures)
            isActive = config.isActive
        } else {
            selectedSchedule = platform.scheduleOptions.first?.name ?? ""
            enabledFeatures = Set(platform.botFeatures.map(\.name)) // all on by default
        }
    }

    private func saveConfig() {
        let config = BotConfiguration(
            id: self.config?.id,
            platform: platform.rawValue,
            isActive: isActive,
            credentials: credentials,
            selectedSchedule: selectedSchedule,
            enabledFeatures: Array(enabledFeatures)
        )
        Task {
            try? await botService.saveBotConfig(config)
            withAnimation { showSaved = true }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { showSaved = false }
        }
    }
}
