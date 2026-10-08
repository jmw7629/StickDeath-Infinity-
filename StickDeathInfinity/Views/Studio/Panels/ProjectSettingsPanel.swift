import SwiftUI

struct ProjectSettingsPanel: View {
    @ObservedObject var vm: StudioViewModel
    @EnvironmentObject private var authVM: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var projectName = ""
    @State private var width = 1080
    @State private var height = 1920
    @State private var fps = 12
    @State private var backgroundID: String?
    @State private var capturedProjectID: UUID?
    @State private var capturedRevision = -1
    @State private var notice: String?
    @State private var showingOnionSettings = false
    @State private var showingGridSettings = false

    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("Project Settings").font(.specialElite(25)).foregroundStyle(.white)
                        Spacer()
                        Button { vm.activePanel = .none } label: {
                            Image(systemName: "xmark").foregroundStyle(.gray).frame(width: 44, height: 44)
                        }.accessibilityLabel("Close project settings").accessibilityIdentifier("studio.settings.close")
                    }
                    StudioProjectConfigurationCard(name: $projectName, width: $width, height: $height,
                        fps: $fps, backgroundID: $backgroundID, submitTitle: "Apply Changes →",
                        submitIdentifier: "studio.settings.rename", nameIdentifier: "studio.settings.name",
                        notice: notice, busy: vm.isSaving,
                        canSubmit: capturedProjectID != nil && scenePhase == .active && !vm.isPlaying,
                        chooseExistingBackground: chooseBackground, onSubmit: apply)
                    Text("Canvas changes keep artwork at its original position and change the visible area. Frame rate changes animation speed; audio stays at its time in seconds. Undo restores the previous settings.")
                        .font(.specialElite(12)).foregroundStyle(.gray)
                    Button("Reload current settings") { load() }
                        .font(.specialElite(14)).foregroundStyle(.red).frame(minHeight: 44)
                        .accessibilityIdentifier("studio.settings.reload-name")
                    extraTools
                }.padding(20).padding(.bottom, 24).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("studio.settings.scroll")
        }
        .onAppear { load() }
        .onChange(of: authVM.userId) { _, _ in capturedProjectID = nil; vm.activePanel = .none }
        .onChange(of: vm.document.id) { _, _ in capturedProjectID = nil; vm.activePanel = .none }
    }
    private func load() {
        projectName = vm.projectName; width = vm.canvasWidth; height = vm.canvasHeight; fps = vm.fps
        capturedProjectID = vm.document.id; capturedRevision = vm.document.revision; notice = nil
    }
    private func apply() {
        guard let id = capturedProjectID, scenePhase == .active else { return }
        if vm.updateProjectSettings(name: projectName, width: width, height: height, fps: fps,
                                    expectedProjectID: id, expectedRevision: capturedRevision) {
            load(); notice = "Project settings updated."
        } else { notice = vm.message ?? "Settings could not be changed." }
    }
    private func chooseBackground() {
        guard capturedProjectID == vm.document.id, capturedRevision == vm.document.revision,
              projectName == vm.projectName, width == vm.canvasWidth, height == vm.canvasHeight, fps == vm.fps else {
            notice = "Apply or reload your settings before opening Background Library."; return
        }
        vm.activePanel = .backgroundLibrary
    }
    private var extraTools: some View {
        VStack(spacing: 0) {
            // TOOLS section
            Text("TOOLS")
                .font(.specialElite(11))
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
                    .font(.specialElite(13))
                    .foregroundColor(.white)
                Spacer()
                
                Button(action: { showingOnionSettings.toggle() }) {
                    Text("Edit")
                        .font(.specialElite(11))
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
                    .font(.specialElite(13))
                    .foregroundColor(.white)
                Spacer()
                
                Button(action: { showingGridSettings.toggle() }) {
                    Text("Edit")
                        .font(.specialElite(11))
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

            PanelSettingsRow(icon: "✨", label: "Magic Cut") { vm.activePanel = .magicCut }
            PanelSettingsRow(icon: "🖼", label: "Background Library") { chooseBackground() }
            PanelSettingsRow(icon: "🎬", label: "Rotoscope / Video") { vm.activePanel = .rotoscope }
            
            PanelSettingsRow(icon: "📸", label: "Add Picture") {
                vm.activePanel = .addImage
            }
            
            PanelSettingsRow(icon: "😀", label: "Stickers & Emoji") {
                vm.activePanel = .stickerEmoji
            }
            
            PanelSettingsRow(icon: "📤", label: "Export") {
                vm.activePanel = .export
            }
            
        }
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
                    .font(.specialElite(12))
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
                }.font(.specialElite(11)).padding(.horizontal, 14).padding(.vertical, 8)
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
        }.font(.specialElite(11)).padding(.horizontal, 14).padding(.vertical, 8)
    }
}
