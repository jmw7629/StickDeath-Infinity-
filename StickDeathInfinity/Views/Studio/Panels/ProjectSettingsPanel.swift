import SwiftUI

// ═══════════════════════════════════════════════════════════════════════
// Project Settings / Tools Menu — Matches the ⋯ menu in the video
// ═══════════════════════════════════════════════════════════════════════

struct ProjectSettingsPanel: View {
    @ObservedObject var vm: StudioViewModel
    @State private var showingOnionSettings = false
    @State private var showingGridSettings = false
    
    var body: some View {
        ScrollView {
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
            
            // Onion Skin (toggle + Edit)
            HStack(spacing: 10) {
                Text("🧅")
                    .font(.system(size: 16))
                Text("Onion")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                
                Button(action: { showingOnionSettings.toggle() }) {
                    Text("Edit")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.05))
                        )
                }
                
                Toggle("", isOn: $vm.showOnionSkin)
                    .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#DC2626")))
                    .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            
            if showingOnionSettings {
                StudioOnionSettingsControls(vm: vm)
            }

            // Grid (toggle + Edit)
            HStack(spacing: 10) {
                Text("⊞")
                    .font(.system(size: 16))
                Text("Grid")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                
                Button(action: { showingGridSettings.toggle() }) {
                    Text("Edit")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.05))
                        )
                }
                
                Toggle("", isOn: $vm.gridEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#DC2626")))
                    .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            
            if showingGridSettings { StudioGridSettingsControls(vm: vm) }

            PanelSettingsRow(icon: "✨", label: "Magic Cut") {}
            PanelSettingsRow(icon: "🖼", label: "Background Library") {}
            PanelSettingsRow(icon: "🎬", label: "Rotoscope / Video") {}
            
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

struct StudioOnionSettingsControls: View {
    @ObservedObject var vm: StudioViewModel
    var body: some View {
                VStack(alignment: .leading, spacing: 10) {
                    Stepper("Previous: \(vm.onionPreviousCount)", value: $vm.onionPreviousCount, in: 0...2)
                        .accessibilityIdentifier("studio.onion.previous")
                    Stepper("Next: \(vm.onionNextCount)", value: $vm.onionNextCount, in: 0...2)
                        .accessibilityIdentifier("studio.onion.next")
                    Text("Opacity: \(Int((vm.onionOpacity * 100).rounded()))%")
                    Slider(value: $vm.onionOpacity, in: 0.05...0.8)
                        .accessibilityLabel("Onion opacity").accessibilityIdentifier("studio.onion.opacity")
                    Toggle("Red previous / blue next", isOn: $vm.onionTinted)
                        .accessibilityIdentifier("studio.onion.tint")
                    Text("Farther frames fade. Ghosts are hidden during playback and never included in export.")
                        .font(.caption2).foregroundColor(.secondary)
                }.font(.system(size: 11, design: .monospaced)).padding(.horizontal, 14).padding(.vertical, 8)
    }
}

struct StudioGridSettingsControls: View {
    @ObservedObject var vm: StudioViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Spacing: \(Int(vm.gridSpacing.rounded())) canvas points")
            Slider(value: $vm.gridSpacing, in: 8...160, step: 1)
                .accessibilityLabel("Grid spacing").accessibilityIdentifier("studio.grid.spacing")
            Text("Opacity: \(Int((vm.gridOpacity * 100).rounded()))%")
            Slider(value: $vm.gridOpacity, in: 0.05...0.6)
                .accessibilityLabel("Grid opacity").accessibilityIdentifier("studio.grid.opacity")
            Picker("Tint", selection: $vm.gridTint) {
                ForEach(StudioGridSettings.Tint.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("studio.grid.tint")
            Text("Grid moves and zooms with the canvas. It is a visual guide and is never included in exported artwork.")
                .font(.caption2).foregroundColor(.secondary)
        }.font(.system(size: 11, design: .monospaced)).padding(.horizontal, 14).padding(.vertical, 8)
    }
}
