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
    @State private var anchor: StudioCanvasAnchor = .topLeading
    @State private var capturedProjectID: UUID?
    @State private var capturedRevision = -1
    @State private var notice: String?
    @State private var showingOnionSettings = false
    @State private var showingGridSettings = false

    private var settingsAreCurrent: Bool {
        capturedProjectID == vm.document.id && capturedRevision == vm.document.revision
    }
    private var settingsNotice: String? {
        if capturedProjectID != nil && !settingsAreCurrent {
            return "The project changed after these settings were opened. Your entered values are still shown. Reload current settings before applying."
        }
        return notice
    }
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
                        notice: settingsNotice, busy: vm.isSaving,
                        canSubmit: capturedProjectID != nil && settingsAreCurrent && scenePhase == .active && !vm.isPlaying,
                        chooseExistingBackground: chooseBackground, onSubmit: apply)
                    if width != vm.canvasWidth || height != vm.canvasHeight {
                        StudioCanvasAnchorPicker(anchor: $anchor, fromWidth: vm.canvasWidth, fromHeight: vm.canvasHeight,
                                                 toWidth: width, toHeight: height)
                    }
                    Text("Canvas changes keep artwork at its original size and change the visible area; the anchor chooses which edge or corner stays fixed. Frame rate changes animation speed; audio stays at its time in seconds. Undo restores the previous settings. Resizing may be unavailable for historical flattened images, pixel effects or a smaller size that would discard fill coverage.")
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
        anchor = .topLeading
        capturedProjectID = vm.document.id; capturedRevision = vm.document.revision; notice = nil
    }
    private func apply() {
        guard let id = capturedProjectID, scenePhase == .active else { return }
        if vm.updateProjectSettings(name: projectName, width: width, height: height, fps: fps, anchor: anchor,
                                    expectedProjectID: id, expectedRevision: capturedRevision) {
            load(); notice = vm.isDirty ? "Settings applied to the open project. Check the Studio save indicator for device-save status." : "Settings match the current project."
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
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Edit onion skin settings")
                .accessibilityValue(showingOnionSettings ? "Expanded" : "Collapsed")
                
                Toggle("Onion skin", isOn: $vm.showOnionSkin)
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
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Edit canvas grid settings")
                .accessibilityValue(showingGridSettings ? "Expanded" : "Collapsed")
                
                Toggle("Canvas grid", isOn: $vm.gridEnabled)
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

// MARK: - Resize anchor
/// 3×3 picker for the canvas point that stays fixed while an existing project
/// is resized. New projects have nothing to anchor, so the card never shows it.
struct StudioCanvasAnchorPicker: View {
    @Binding var anchor: StudioCanvasAnchor
    var fromWidth: Int
    var fromHeight: Int
    var toWidth: Int
    var toHeight: Int
    private static let names = ["top left", "top", "top right", "left", "center", "right", "bottom left", "bottom", "bottom right"]
    private var offset: StudioCanvasAnchor.Offset {
        anchor.offset(fromWidth: fromWidth, height: fromHeight, toWidth: toWidth, height: toHeight)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RESIZE ANCHOR").font(.specialElite(11, relativeTo: .caption)).foregroundStyle(.white.opacity(0.5)).tracking(1)
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { column in
                                let value = StudioCanvasAnchor.grid[row * 3 + column]
                                let selected = anchor == value
                                Button { anchor = value } label: {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(selected ? Color(hex: "E03030") : Color.white.opacity(0.08))
                                        .frame(width: 44, height: 44)
                                        .overlay(Circle().fill(selected ? Color.white : Color.white.opacity(0.35)).frame(width: 8, height: 8))
                                }
                                .accessibilityLabel("Keep \(Self.names[row * 3 + column]) fixed")
                                .accessibilityAddTraits(selected ? .isSelected : [])
                                .accessibilityIdentifier("studio.settings.anchor.\(row)\(column)")
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("studio.settings.anchor")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keeps the \(Self.names[StudioCanvasAnchor.grid.firstIndex(of: anchor) ?? 0]) fixed.")
                        .font(.specialElite(12)).foregroundStyle(.white)
                    Text("\(fromWidth)×\(fromHeight) → \(toWidth)×\(toHeight); artwork moves \(offset.dx >= 0 ? "+" : "")\(offset.dx), \(offset.dy >= 0 ? "+" : "")\(offset.dy) px. One Undo step restores the previous size and position.")
                        .font(.specialElite(11, relativeTo: .caption)).foregroundStyle(.gray)
                        .accessibilityIdentifier("studio.settings.anchor.offset")
                }
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
                        .font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.secondary)
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
                .font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.secondary)
        }.font(.specialElite(11)).padding(.horizontal, 14).padding(.vertical, 8)
    }
}
