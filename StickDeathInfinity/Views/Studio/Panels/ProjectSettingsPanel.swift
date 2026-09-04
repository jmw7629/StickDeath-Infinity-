import SwiftUI

// ═══════════════════════════════════════════════════════════════════════
// Project Settings / Tools Menu — Matches the ⋯ menu in the video
// ═══════════════════════════════════════════════════════════════════════

struct ProjectSettingsPanel: View {
    @ObservedObject var vm: StudioViewModel

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            // Header
            HStack {
                Text("⋯")
                    .font(.system(size: 20))
                Text("Project Menu")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { vm.activePanel = .none }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)

            // Project Settings row
            PanelSettingsRow(icon: "⚙️", label: "Project Settings") {
                // Navigate to project settings detail
            }

            Divider().background(Color.white.opacity(0.05)).padding(.horizontal, 14)

            // TOOLS section
            Text("TOOLS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
                .tracking(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)

            PanelSettingsRow(icon: "🎞", label: "Frames Viewer") {
                vm.activePanel = .framesViewer
            }

            // Onion Skin (toggle — wired to vm.showOnionSkin)
            HStack(spacing: 10) {
                Text("🧅")
                    .font(.system(size: 16))
                Text("Onion")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()

                Button(action: {}) {
                    Text("Edit")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.05))
                        )
                }
                .disabled(true)
                .opacity(0.4)
                .help("Onion skin settings — configurable in a future release")

                Toggle("", isOn: $vm.showOnionSkin)
                    .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#DC2626")))
                    .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            // Grid (toggle — wired to vm.gridEnabled)
            HStack(spacing: 10) {
                Text("⊞")
                    .font(.system(size: 16))
                Text("Grid")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()

                Button(action: {}) {
                    Text("Edit")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.05))
                        )
                }
                .disabled(true)
                .opacity(0.4)
                .help("Grid settings — configurable in a future release")

                Toggle("", isOn: $vm.gridEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#DC2626")))
                    .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            PanelSettingsRow(icon: "✨", label: "Magic Cut") {
                vm.activePanel = .magicCut
            }
            PanelSettingsRow(icon: "🖼", label: "Background Library") {
                vm.activePanel = .backgroundLibrary
            }
            PanelSettingsRow(icon: "🎬", label: "Rotoscope / Video") {
                vm.activePanel = .rotoscope
            }

            PanelSettingsRow(icon: "📸", label: "Add Picture") {
                vm.activePanel = .addImage
            }

            PanelSettingsRow(icon: "😀", label: "Stickers & Emoji") {
                vm.activePanel = .stickerEmoji
            }

            PanelSettingsRow(icon: "📤", label: "Export") {
                vm.activePanel = .export
            }

            Spacer().frame(height: 20)
        }
        .background(Color(hex: "#1a1a24"))
        .cornerRadius(16, corners: [.topLeft, .topRight])
    }
}

// MARK: - Settings Row
struct PanelSettingsRow: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(icon)
                    .font(.system(size: 16))
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.2))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Frames Viewer Panel
// ═══════════════════════════════════════════════════════════════════════

