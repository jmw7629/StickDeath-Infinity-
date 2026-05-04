// StudioSettingsMenu.swift
// Bottom sheet settings — SF-Symbols icons, red toggles, "Make Movie" button
// Matches StickDeath Infinity reference design

import SwiftUI

struct StudioSettingsMenu: View {
    @ObservedObject var vm: EditorViewModel
    @Binding var activePanel: StudioPanel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 0) {
                // Grab handle
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.2))
                        .frame(width: 40, height: 4)
                    Spacer()
                }
                .padding(.top, 10)
                .padding(.bottom, 12)

                ScrollView {
                    VStack(spacing: 2) {
                        // Display settings
                        settingsSection("DISPLAY") {
                            settingsToggle("Onion Skin", icon: "rectangle.on.rectangle", isOn: $vm.showOnionSkin)
                            settingsToggle("Grid", icon: "grid", isOn: $vm.showGrid)
                            settingsToggle("Show Timeline", icon: "timeline.selection", isOn: $vm.showTimeline)
                        }

                        // Canvas
                        settingsSection("CANVAS") {
                            settingsRow("Canvas Size", icon: "arrow.up.left.and.arrow.down.right", value: "\(vm.project.canvas_width ?? 1920)×\(vm.project.canvas_height ?? 1080)")
                            settingsRow("FPS", icon: "speedometer", value: "\(vm.project.fps ?? 12)")
                            settingsRow("Background", icon: "paintbrush", value: "White")
                        }

                        // Tools
                        settingsSection("TOOLS") {
                            settingsNav("Frames Viewer", icon: "rectangle.split.3x3") { activePanel = .framesViewer }
                            settingsNav("Asset Vault", icon: "archivebox") { activePanel = .assetVault }
                            settingsNav("Import Video", icon: "film") { activePanel = .importVideo }
                        }

                        // Project
                        settingsSection("PROJECT") {
                            settingsNav("Project Settings", icon: "gearshape") { vm.showProjectSettings = true }
                            settingsNav("Publish", icon: "paperplane") { /* publish */ }
                        }

                        // Make Movie
                        Button {
                            activePanel = .export
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "film.stack")
                                    .font(.system(size: 16, weight: .bold))
                                Text("Make Movie")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "E03030")))
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                    }
                }
                .frame(maxHeight: UIScreen.main.bounds.height * 0.55)
            }
            .background(Color(hex: "1a1a1a"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.bottom, 112)
    }

    // MARK: - Settings Section
    func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.25))
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

            content()
        }
    }

    // MARK: - Settings Row Types
    func settingsToggle(_ label: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 24)
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: isOn)
                .tint(Color(hex: "E03030"))
                .scaleEffect(0.85)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.04)).frame(height: 1).padding(.leading, 52)
        }
    }

    func settingsRow(_ label: String, icon: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 24)
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(.white)
            Spacer()
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.04)).frame(height: 1).padding(.leading, 52)
        }
    }

    func settingsNav(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 24)
                Text(label)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.2))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.04)).frame(height: 1).padding(.leading, 52)
            }
        }
    }
}
