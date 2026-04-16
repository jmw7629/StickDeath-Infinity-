// AppSettingsView.swift
// App Settings — canvas rotation, stylus, draw input, time-lapse
// Ref: FlipaClip App Settings, adapted to StickDeath ∞ dark theme

import SwiftUI

class AppSettingsStore: ObservableObject {
    static let shared = AppSettingsStore()

    @AppStorage("canvasRotation") var canvasRotation = true
    @AppStorage("stylusPressure") var stylusPressure = true
    @AppStorage("drawInput") var drawInput: DrawInputMode = .stylusAndTouch
    @AppStorage("timeLapseEnabled") var timeLapseEnabled = false
    @AppStorage("autoSaveInterval") var autoSaveInterval: Int = 30
    @AppStorage("showFPSCounter") var showFPSCounter = false
    @AppStorage("reducedMotion") var reducedMotion = false
    @AppStorage("hapticFeedback") var hapticFeedback = true
}

enum DrawInputMode: String, CaseIterable, Identifiable {
    case touchOnly = "Touch only"
    case stylusOnly = "Stylus only"
    case stylusAndTouch = "Stylus and touch"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .touchOnly: return "hand.point.up"
        case .stylusOnly: return "applepencil"
        case .stylusAndTouch: return "hand.draw"
        }
    }
}

struct AppSettingsView: View {
    @StateObject private var settings = AppSettingsStore.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        // Layout
                        settingsSection("Layout") {
                            settingsRow("Version", icon: "square.grid.2x2") {
                                Text("v1.0")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }

                        // General
                        settingsSection("General") {
                            settingsToggle("Canvas Rotation", icon: "rotate.right",
                                         isOn: $settings.canvasRotation,
                                         subtitle: "Allow two-finger rotation on canvas")

                            Divider().opacity(0.2)

                            settingsToggle("Stylus Pressure", icon: "applepencil.tip",
                                         isOn: $settings.stylusPressure,
                                         subtitle: "Vary line width with Apple Pencil pressure")

                            Divider().opacity(0.2)

                            // Draw Input picker
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    Image(systemName: "hand.draw")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.red)
                                        .frame(width: 28)
                                    Text("Draw Input")
                                        .font(.custom("SpecialElite-Regular", size: 14))
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Text(settings.drawInput.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }

                                Picker("Draw Input", selection: $settings.drawInput) {
                                    ForEach(DrawInputMode.allCases) { mode in
                                        HStack {
                                            Image(systemName: mode.icon)
                                            Text(mode.rawValue)
                                        }.tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .tint(.red)
                            }

                            Divider().opacity(0.2)

                            settingsToggle("Time-Lapse", icon: "timelapse",
                                         isOn: $settings.timeLapseEnabled,
                                         subtitle: "Record your drawing process")

                            Divider().opacity(0.2)

                            settingsToggle("Haptic Feedback", icon: "waveform",
                                         isOn: $settings.hapticFeedback,
                                         subtitle: "Vibration for tools and actions")
                        }

                        // Performance
                        settingsSection("Performance") {
                            settingsToggle("Show FPS Counter", icon: "gauge.medium",
                                         isOn: $settings.showFPSCounter,
                                         subtitle: "Display frame rate during playback")

                            Divider().opacity(0.2)

                            settingsToggle("Reduced Motion", icon: "figure.walk",
                                         isOn: $settings.reducedMotion,
                                         subtitle: "Minimize UI animations")

                            Divider().opacity(0.2)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 10) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.red)
                                        .frame(width: 28)
                                    Text("Auto-Save")
                                        .font(.custom("SpecialElite-Regular", size: 14))
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Text("\(settings.autoSaveInterval)s")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.red)
                                }
                                Slider(value: Binding(
                                    get: { Double(settings.autoSaveInterval) },
                                    set: { settings.autoSaveInterval = Int($0) }
                                ), in: 10...120, step: 10)
                                .tint(.red)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("App Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }

    // MARK: - Components

    private func settingsSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.custom("SpecialElite-Regular", size: 12))
                .foregroundStyle(.red)
                .textCase(.uppercase)
            VStack(spacing: 12) {
                content()
            }
            .padding(14)
            .background(ThemeManager.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func settingsToggle(_ title: String, icon: String, isOn: Binding<Bool>, subtitle: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.red)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.custom("SpecialElite-Regular", size: 14))
                    .foregroundStyle(.white)
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.red)
        }
    }

    private func settingsRow(_ title: String, icon: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.red)
                .frame(width: 28)
            Text(title)
                .font(.custom("SpecialElite-Regular", size: 14))
                .foregroundStyle(.white)
            Spacer()
            trailing()
        }
    }
}
