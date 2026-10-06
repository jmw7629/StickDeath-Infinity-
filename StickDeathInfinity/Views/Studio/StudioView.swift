// ═══════════════════════════════════════════════════════════════════
// StudioView — Native Studio shell and offline project editor
// Header → Tool Strip → Canvas → Frame Timeline → Bottom Toolbar
// Advanced tools, media and connected services remain under implementation.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct StudioView: View {
    @StateObject private var vm = StudioViewModel.shared
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var authVM: AuthViewModel
    @State private var spatterExportRequest: (projectID: UUID, revision: Int, accountID: String?)?
    
    var body: some View {
        Group {
            if vm.isEditing { editorBody }
            else { StudioProjectLibrary(vm: vm) }
        }
        .task {
            vm.projectThumbnailRenderer = { document, raster in
                try StudioExportService().projectThumbnail(document: document, raster: raster)
            }
            await vm.loadProjects()
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { vm.stopPlayback(); Task { await vm.flush() } }
        }
        .onDisappear { vm.stopPlayback(); Task { await vm.flush() } }
    }

    private var editorBody: some View {
        ZStack {
            Color(hex: "0D0D12").ignoresSafeArea()
            
            StudioEditorWorkspace(vm: vm, onDismiss: { Task { await vm.backToProjects() } })
            
            // Full-screen panels
            if vm.activePanel == .colorPicker { ColorPickerPanel(vm: vm) }
            if vm.activePanel == .gradientEndColor { ColorPickerPanel(vm: vm, target: .gradientEnd) }
            if vm.activePanel == .projectSettings { ProjectSettingsPanel(vm: vm) }
            if vm.activePanel == .layers { LayerPanel(vm: vm) }
            if vm.activePanel == .export { ExportPanel(vm: vm) }
            if vm.activePanel == .framesViewer { FramesViewerPanel(vm: vm) }
            if vm.activePanel == .soundLibrary { SoundLibraryPanel(vm: vm) }
            if vm.activePanel == .audioTimeline { AudioTimelinePanel(vm: vm) }
            if vm.activePanel == .stickerEmoji { StickerEmojiPanel(vm: vm) }
            if vm.activePanel == .backgroundLibrary { BackgroundLibraryPanel(vm: vm) }
            if vm.activePanel == .addImage { AddImagePanel(vm: vm) }
            if vm.activePanel == .rotoscope { RotoscopeSheet(vm: vm) }
        }
        .sheet(isPresented: showMenuBinding) {
            StudioMenuSheet(vm: vm)
        }
        .sheet(isPresented: showAIVoiceBinding) {
            AIVoiceMakerSheet(vm: vm)
        }
        .sheet(isPresented: showSpatterBinding, onDismiss: {
            guard let request = spatterExportRequest else { return }
            spatterExportRequest = nil
            guard vm.isEditing, scenePhase == .active, vm.activePanel == .none,
                  authVM.userId == request.accountID, vm.document.id == request.projectID,
                  vm.document.revision == request.revision else {
                vm.message = "The project changed before export opened. Open Export for the current project."
                return
            }
            vm.activePanel = .export
        }) {
            SpatterAISheet(vm: vm, onExport: {
                spatterExportRequest = (vm.document.id, vm.document.revision, authVM.userId)
                vm.activePanel = .none
            })
        }
        .sheet(isPresented: showMagicCutBinding) {
            MagicCutSheet(vm: vm)
        }
    }
    
    // A late dismissal belongs only to its own sheet; it must not close a
    // destination panel opened while the sheet dismissal animation finishes.
    // Sheet bindings
    var showMenuBinding: Binding<Bool> {
        Binding(get: { vm.activePanel == .menu }, set: { if !$0 && vm.activePanel == .menu { vm.activePanel = .none } })
    }
    var showAIVoiceBinding: Binding<Bool> {
        Binding(get: { vm.activePanel == .aiVoice }, set: { if !$0 && vm.activePanel == .aiVoice { vm.activePanel = .none } })
    }
    var showSpatterBinding: Binding<Bool> {
        Binding(get: { vm.activePanel == .spatterAI }, set: { if !$0 && vm.activePanel == .spatterAI { vm.activePanel = .none } })
    }
    var showMagicCutBinding: Binding<Bool> {
        Binding(get: { vm.activePanel == .magicCut }, set: { if !$0 && vm.activePanel == .magicCut { vm.activePanel = .none } })
    }
}

// Toolbar placement is workspace chrome; drawing, history and media stay in the VM.
struct StudioEditorWorkspace: View {
    @ObservedObject var vm: StudioViewModel
    var onDismiss: () -> Void
    @State private var toolbar = StudioToolbarLayout()
    @State private var dragOrigin: CGRect?
    @GestureState private var dragTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width > geometry.size.height && geometry.size.height < 500
            VStack(spacing: 0) {
                if vm.showToolbar {
                    StudioHeaderBar(vm: vm, onDismiss: onDismiss)
                }
                if let message = vm.message {
                    Text(message).font(.caption).foregroundColor(.white).padding(8)
                        .frame(maxWidth: .infinity).background(Color.red.opacity(0.2))
                        .accessibilityIdentifier("studio.status")
                }
                canvasStage(compactHeight: compact)
                if vm.showToolbar {
                    StudioTimeline(vm: vm)
                    StudioBottomBar(vm: vm)
                }
            }
        }
        .onChange(of: vm.selectedTool) { _, tool in
            if vm.activePanel == .toolSettings && !FloatingToolSettingsPanel.hasSettings(tool) { vm.activePanel = .none }
        }
    }

    private func canvasStage(compactHeight: Bool) -> some View {
        GeometryReader { geometry in
            let top: CGFloat = vm.showToolbar ? 0 : min(44, geometry.size.height)
            let bounds = CGRect(x: 0, y: top, width: geometry.size.width, height: max(0, geometry.size.height - top))
            let placement = toolbar.placement(in: bounds, compactHeight: compactHeight)
            let railFrame = dragOrigin.map { toolbar.draggingFrame(from: $0, translation: dragTranslation, in: bounds) } ?? placement.frame
            let popupFrame = StudioToolbarLayout.settingsFrame(in: bounds, toolbar: placement)
            let canvasFrame = StudioToolbarLayout.canvasFrame(in: bounds, toolbar: placement)
            ZStack(alignment: .topLeading) {
                StudioCanvasView(vm: vm)
                    .frame(width: canvasFrame.width, height: canvasFrame.height)
                    .position(x: canvasFrame.midX, y: canvasFrame.midY)

                StudioToolStrip(vm: vm, axis: placement.vertical ? .vertical : .horizontal,
                    handleGesture: AnyGesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("studio.toolbar.stage"))
                        .updating($dragTranslation) { value, state, _ in state = value.translation }
                        .onChanged { _ in if dragOrigin == nil { dragOrigin = placement.frame } }
                        .onEnded { value in
                            let origin = dragOrigin ?? placement.frame
                            toolbar.finishDrag(release: value.location,
                                proposedCenter: CGPoint(x: origin.midX + value.translation.width, y: origin.midY + value.translation.height),
                                in: bounds)
                            dragOrigin = nil
                        }),
                    onDock: { dock in toolbar.choose(dock, in: bounds); dragOrigin = nil })
                    .frame(width: railFrame.width, height: railFrame.height)
                    .position(x: railFrame.midX, y: railFrame.midY)

                if vm.activePanel == .toolSettings && FloatingToolSettingsPanel.hasSettings(vm.selectedTool) {
                    FloatingToolSettingsPanel(vm: vm,
                        alignToBottom: !placement.vertical && popupFrame.maxY <= placement.frame.minY)
                        .frame(width: popupFrame.width, height: popupFrame.height)
                        .position(x: popupFrame.midX, y: popupFrame.midY)
                        .transition(.opacity)
                }
            }
            .coordinateSpace(name: "studio.toolbar.stage")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("studio.toolbar.stage")
            .onChange(of: geometry.size) { _, _ in dragOrigin = nil }
            .overlay(alignment: .topLeading) {
                if !vm.showToolbar {
                    Button(action: { vm.showToolbar = true }) {
                        Text("SHOW TOOLS")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color(hex: "1A1A24"), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel("Show Studio tools")
                    .accessibilityIdentifier("studio.show-tools")
                    .padding(8)
                }
            }
        }
    }
}

// MARK: - Zoom Button
struct ZoomButton: View {
    let label: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: label == "FIT" ? 9 : 16, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color(hex: "1E1E2A")))
                .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
    }
}

// MARK: - Studio Bottom Bar
struct StudioBottomBar: View {
    @ObservedObject var vm: StudioViewModel
    
    var body: some View {
        HStack(spacing: 0) {
            // Audio
            BottomBarButton(icon: "music.note", label: "AUDIO") {
                vm.activePanel = vm.activePanel == .audioTimeline ? .none : .audioTimeline
            }
            .accessibilityIdentifier("studio.audio.open")
            
            // Undo
            BottomBarButton(icon: "arrow.uturn.backward", label: "UNDO", enabled: vm.canUndo) {
                vm.undo()
            }
            .accessibilityIdentifier("studio.undo")
            
            // Redo
            BottomBarButton(icon: "arrow.uturn.forward", label: "REDO", enabled: vm.canRedo) {
                vm.redo()
            }
            .accessibilityIdentifier("studio.redo")
            
            // Copy
            BottomBarButton(icon: "doc.on.doc", label: "COPY") {
                vm.copyFrame()
            }
            
            // Paste
            BottomBarButton(icon: "doc.on.clipboard", label: "PASTE", enabled: vm.canPaste) {
                vm.pasteClipboard()
            }
            .accessibilityIdentifier("studio.paste")
            .accessibilityLabel(vm.copiedDrawingCount == 1 ? "Paste drawing" : vm.copiedDrawingCount > 0 ? "Paste \(vm.copiedDrawingCount) drawings" : "Paste frame")
            
            // Delete
            BottomBarButton(icon: "trash", label: "DEL", enabled: vm.canDeleteSelected) {
                vm.deleteSelected()
            }
            
            // Layer (with red badge)
            Button(action: {
                vm.activePanel = vm.activePanel == .layers ? .none : .layers
            }) {
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 2) {
                        Image(systemName: "square.3.layers.3d")
                            .font(.system(size: 14))
                        Text("LAYER")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(.white.opacity(0.5))
                    
                    Text("\(vm.studioLayers.count)")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white)
                        .padding(2)
                        .background(Color.red)
                        .clipShape(Circle())
                        .offset(x: 8, y: -4)
                }
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("studio.layers.open")
            .accessibilityLabel("Layers")
        }
        .padding(.vertical, 8)
        .background(Color(hex: "0A0A10"))
    }
}

struct BottomBarButton: View {
    let icon: String
    let label: String
    var enabled: Bool = true
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(label)
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
            }
            .foregroundColor(enabled ? .white.opacity(0.5) : .white.opacity(0.2))
            .frame(maxWidth: .infinity)
        }
        .disabled(!enabled)
    }
}

// MARK: - Frames Viewer Panel
struct FramesViewerPanel: View {
    @ObservedObject var vm: StudioViewModel
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            
            VStack(spacing: 0) {
                PanelHeader(title: "Frames Viewer", icon: "film.fill") {
                    vm.activePanel = .none
                }
                
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(vm.frames.indices, id: \.self) { i in
                            Button(action: {
                                vm.currentFrameIndex = i
                                vm.activePanel = .none
                            }) {
                                VStack(spacing: 4) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.white)
                                            .frame(height: 80)
                                        
                                        // Render frame elements
                                        StudioFrameThumbnail(vm: vm, frame: vm.frames[i])
                                        .frame(height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(vm.currentFrameIndex == i ? Color.red : Color.white.opacity(0.1), lineWidth: vm.currentFrameIndex == i ? 2 : 1)
                                    )
                                    
                                    Text("Frame \(i + 1)")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(vm.currentFrameIndex == i ? .red : .white.opacity(0.5))
                                }
                            }
                        }
                        
                        // Add frame button
                        Button(action: { vm.addFrame() }) {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4]))
                                    .frame(height: 80)
                                    .overlay(
                                        Image(systemName: "plus")
                                            .foregroundColor(.white.opacity(0.3))
                                    )
                                Text("Add")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.3))
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

// MARK: - Background Library Panel
struct BackgroundLibraryPanel: View {
    @ObservedObject var vm: StudioViewModel
    @State private var selectedCategory = "Gradients"
    
    let categories = [
        ("Gradients", 24), ("Solid", 18), ("Patterns", 12), ("Nature", 8),
        ("Space", 6), ("Urban", 10), ("Abstract", 15), ("Textures", 9),
    ]
    
    let backgrounds: [(name: String, colors: [String])] = [
        ("Sunset", ["FF6B35", "F72585"]), ("Ocean", ["0077B6", "00B4D8"]),
        ("Forest", ["2D6A4F", "40916C"]), ("Neon", ["7209B7", "F72585"]),
        ("Midnight", ["0D1B2A", "1B263B"]), ("Fire", ["D00000", "FFBA08"]),
        ("Ice", ["48CAE4", "ADE8F4"]), ("Void", ["0A0A0F", "1A1A24"]),
    ]
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            
            VStack(spacing: 0) {
                PanelHeader(title: "Background Library", icon: "photo.on.rectangle") {
                    vm.activePanel = .none
                }
                
                HStack(spacing: 0) {
                    // Sidebar categories (pill style with red bg)
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(categories, id: \.0) { cat in
                                Button(action: { selectedCategory = cat.0 }) {
                                    Text("\(cat.0) (\(cat.1))")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(selectedCategory == cat.0 ? .white : .white.opacity(0.4))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(selectedCategory == cat.0 ? Color.red : Color(hex: "1A1A24"))
                                        .cornerRadius(8)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .frame(width: 120)
                    .background(Color(hex: "0D0D14"))
                    
                    // Background grid
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(backgrounds, id: \.name) { bg in
                                Button(action: {
                                    // Apply background
                                    vm.activePanel = .none
                                }) {
                                    VStack(spacing: 4) {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(
                                                LinearGradient(
                                                    colors: bg.colors.map { Color(hex: $0) },
                                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(height: 80)
                                        
                                        Text(bg.name)
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.6))
                                    }
                                }
                            }
                        }
                        .padding(12)
                    }
                }
            }
        }
    }
}

// MARK: - Add Image Panel
struct AddImagePanel: View {
    @ObservedObject var vm: StudioViewModel
    var body: some View { StudioImageImportPanel(vm: vm) }
}

struct AddImageOption: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(.red)
                    .frame(width: 44, height: 44)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(10)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.2))
            }
            .padding(16)
            .background(Color(hex: "12121A"))
            .cornerRadius(14)
        }
    }
}

// MARK: - Studio Menu Sheet
struct StudioMenuSheet: View {
    @ObservedObject var vm: StudioViewModel
    @State private var showingOnionSettings = false
    @State private var showingGridSettings = false
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            
            ScrollView {
            VStack(spacing: 0) {
                // Drag handle
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.2)).frame(width: 36, height: 4)
                    Spacer()
                }.frame(height: 44).overlay(alignment: .trailing) {
                    Button(action: { dismiss() }) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("Close Studio menu").accessibilityIdentifier("studio.menu.close")
                }
                
                // PROJECT section
                SectionLabel(text: "PROJECT")
                
                MenuSheetRow(icon: "⚙️", label: "Project Settings") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vm.activePanel = .projectSettings
                    }
                }
                
                Divider().background(Color.white.opacity(0.06)).padding(.horizontal, 16)
                
                // TOOLS section
                SectionLabel(text: "TOOLS")
                
                MenuSheetRow(icon: "🎬", label: "Frames Viewer") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vm.activePanel = .framesViewer
                    }
                }
                
                MenuSheetToggleRow(icon: "🧅", label: "Onion", hasEdit: true, isOn: $vm.showOnionSkin, onEdit: { showingOnionSettings.toggle() })
                if showingOnionSettings { StudioOnionSettingsControls(vm: vm) }
                MenuSheetToggleRow(icon: "📐", label: "Grid", hasEdit: true, isOn: $vm.gridEnabled, onEdit: { showingGridSettings.toggle() })
                if showingGridSettings { StudioGridSettingsControls(vm: vm) }
                
                MenuSheetRow(icon: "✨", label: "Magic Cut") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vm.activePanel = .magicCut
                    }
                }
                
                MenuSheetRow(icon: "🖼️", label: "Background Library") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vm.activePanel = .backgroundLibrary
                    }
                }
                
                MenuSheetRow(icon: "🎬", label: "Rotoscope / Video") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vm.activePanel = .rotoscope
                    }
                }
                
                MenuSheetRow(icon: "🖼️", label: "Add Picture") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vm.activePanel = .addImage
                    }
                }
                
                MenuSheetRow(icon: "🗣️", label: "Voice Maker") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vm.activePanel = .aiVoice
                    }
                }
                
                MenuSheetRow(icon: "🎨", label: "Spatter AI", accent: true) {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vm.activePanel = .spatterAI
                    }
                }
                .accessibilityIdentifier("studio.spatter.open")
                
                Spacer()
            }
            }.accessibilityIdentifier("studio.menu.scroll")
        }
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(.white.opacity(0.3))
            .tracking(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }
}

struct MenuSheetRow: View {
    let icon: String
    let label: String
    var accent: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(icon).font(.system(size: 18))
                Text(label)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(accent ? .red : .white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.2))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

struct MenuSheetToggleRow: View {
    let icon: String
    let label: String
    var hasEdit: Bool = false
    @Binding var isOn: Bool
    var onEdit: (() -> Void)? = nil
    
    var body: some View {
        HStack(spacing: 12) {
            Text(icon).font(.system(size: 18))
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
            Spacer()
            if hasEdit, let onEdit {
                Button("Edit", action: onEdit)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Edit " + label)
                    .accessibilityIdentifier("studio.menu.edit." + label.lowercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.red)
            }
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - AI Voice Maker Sheet (Purple theme)
struct AIVoiceMakerSheet: View {
    @ObservedObject var vm: StudioViewModel
    @StateObject private var voice = StudioVoiceSession()
    @State private var scriptText = ""
    @State private var selectedVoice = ""
    @State private var speed = 1.0
    @State private var pitch = 1.0
    @State private var track = 1
    @State private var target: (project: UUID, revision: Int, frame: String, account: String?)?
    @State private var error: String?
    @EnvironmentObject private var authVM: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private var targetIsCurrent: Bool {
        guard let target else { return false }
        return scenePhase == .active && vm.isEditing && !vm.isSaving && !vm.isPlaying
            && vm.document.id == target.project && vm.document.revision == target.revision
            && vm.document.activeFrameID == target.frame && authVM.userId == target.account
    }
    private func invalidate() { voice.cancel(); target = nil; error = nil }
    private func generate() {
        guard scenePhase == .active, vm.isEditing, !vm.isSaving else { return }
        vm.stopPlayback()
        target = (vm.document.id, vm.document.revision, vm.document.activeFrameID, authVM.userId)
        error = nil
        voice.generate(text: scriptText, voiceID: selectedVoice, speed: speed, pitch: pitch)
    }
    private func add() {
        guard targetIsCurrent, let target, let audio = voice.prepared else {
            error = "The project changed. Generate the voice again before adding it."
            return
        }
        do {
            _ = try vm.attachImportedAudio(audio.track, expectedProjectID: target.project,
                expectedRevision: target.revision, frameID: target.frame, trackNumber: track)
            voice.cancel(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
    var body: some View {
        ZStack {
            Color(hex: "1A0A2E").ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Text("Voice Maker").font(.system(size: 18, weight: .bold, design: .monospaced))
                    Spacer()
                    Button("Done") { invalidate(); dismiss() }
                }
                .foregroundColor(Color(hex: "A78BFA"))
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("On-device system voices · no microphone or cloud AI")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                        Text("Script / Dialogue · \(scriptText.count)/1,500")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                        TextEditor(text: $scriptText)
                            .font(.system(size: 14)).foregroundColor(.white)
                            .scrollContentBackground(.hidden).frame(height: 110)
                            .padding(12).background(Color(hex: "2A1A3E")).cornerRadius(12)
                            .accessibilityLabel("Voiceover script")
                            .accessibilityIdentifier("studio.voice.script")
                        if voice.voices.isEmpty {
                            Text("No system voices are available on this device.").font(.caption)
                        } else {
                            Picker("Installed voice", selection: $selectedVoice) {
                                Text("Choose a voice").tag("")
                                ForEach(voice.voices) { item in
                                    Text("\(item.name) · \(item.language)").tag(item.id)
                                }
                            }.tint(Color(hex: "A78BFA"))
                        }
                        HStack {
                            Text("Speed")
                            Slider(value: $speed, in: 0.5...2).tint(Color(hex: "A78BFA"))
                            Text(String(format: "%.1fx", speed))
                        }.font(.caption)
                        HStack {
                            Text("Pitch")
                            Slider(value: $pitch, in: 0.5...2).tint(Color(hex: "A78BFA"))
                            Text(String(format: "%.1fx", pitch))
                        }.font(.caption)
                        Picker("Audio track", selection: $track) {
                            ForEach(1...4, id: \.self) { Text("Track \($0)").tag($0) }
                        }.tint(Color(hex: "A78BFA"))
                        Text("Adds at the selected frame. Audio stays in your project and can be trimmed, moved, mixed, exported or undone. Up to 2 minutes / 15 MB per voice clip.")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                        if voice.isBusy {
                            HStack {
                                ProgressView().tint(.white)
                                Text("Generating voice…")
                                Spacer()
                                Button("Cancel") { invalidate() }
                            }
                        } else {
                            Button(voice.prepared == nil ? "Generate voice" : "Regenerate voice", action: generate)
                                .disabled(selectedVoice.isEmpty || scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || scriptText.count > 1_500 || !vm.isEditing || vm.isSaving)
                                .accessibilityIdentifier("studio.voice.generate")
                        }
                        if let notice = error ?? voice.notice {
                            Text(notice).font(.caption).accessibilityIdentifier("studio.voice.notice")
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button(voice.isPlaying ? "Stop preview" : "Preview") { voice.preview() }
                        .disabled(voice.prepared == nil || !targetIsCurrent)
                        .accessibilityIdentifier("studio.voice.preview")
                    Spacer()
                    Button("Add to Timeline", action: add)
                        .disabled(voice.prepared == nil || !targetIsCurrent)
                        .accessibilityIdentifier("studio.voice.add")
                }
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .buttonStyle(.borderedProminent).tint(Color(hex: "7C3AED"))
            }
            .foregroundColor(.white).padding(16)
        }
        .onChange(of: scriptText) { _ in invalidate() }
        .onChange(of: selectedVoice) { _ in invalidate() }
        .onChange(of: speed) { _ in invalidate() }
        .onChange(of: pitch) { _ in invalidate() }
        .onChange(of: vm.document.id) { _ in invalidate() }
        .onChange(of: vm.document.revision) { _ in invalidate() }
        .onChange(of: vm.document.activeFrameID) { _ in invalidate() }
        .onChange(of: authVM.userId) { _ in invalidate(); scriptText = ""; dismiss() }
        .onChange(of: scenePhase) { if $0 != .active { invalidate() } }
        .onDisappear { invalidate() }
    }
}

// MARK: - Spatter AI Sheet
struct SpatterAISheet: View {
    @ObservedObject var vm: StudioViewModel
    let onExport: () -> Void
    @State private var showLocalRecipe = false
    @StateObject private var spatterVM = SpatterAIViewModel()
    @EnvironmentObject private var authVM: AuthViewModel
    @State private var prompt = ""
    @State private var contextError: String?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            if showLocalRecipe {
                SpatterMotionRecipePanel(vm: vm, onBack: { showLocalRecipe = false }, onExport: onExport)
            } else {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("🎨 Spatter AI")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                        Text(spatterVM.statusText).font(.caption).foregroundColor(.white.opacity(0.6))
                            .accessibilityIdentifier("spatter.studio.status")
                    }
                    Spacer()
                    Button("Done") { dismiss() }.foregroundColor(.red)
                        .accessibilityIdentifier("spatter.studio.close")
                }
                .padding(16)

                VStack(alignment: .leading, spacing: 6) {
                    Text(SpatterAIViewModel.capabilityNotice).font(.caption2).foregroundColor(.white.opacity(0.6))
                    Button("Local Studio edits…") { showLocalRecipe = true }
                        .font(.caption).foregroundColor(.red)
                        .disabled(spatterVM.isThinking)
                        .accessibilityIdentifier("spatter.studio.local-motion")
                    Toggle("Cloud advice", isOn: $spatterVM.useCloud).font(.caption)
                        .disabled(spatterVM.isThinking)
                        .accessibilityIdentifier("spatter.studio.cloud")
                    if spatterVM.useCloud {
                        Text("Sends your message, this sheet's earlier cloud messages and a limited project/tool/layer/frame/audio summary to the configured authenticated backend. Drawings, audio files and file paths are not sent.")
                            .font(.caption2).foregroundColor(.white.opacity(0.6))
                    }
                    if let notice = contextError ?? spatterVM.notice {
                        Text(notice).font(.caption).foregroundColor(.white.opacity(0.8))
                            .accessibilityIdentifier("spatter.studio.notice")
                    }
                    if spatterVM.isThinking {
                        Button("Cancel request") { spatterVM.cancel() }
                            .accessibilityIdentifier("spatter.studio.cancel")
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 8)

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(spatterVM.messages) { message in
                            HStack {
                                if message.role == .user { Spacer() }
                                VStack(alignment: .leading, spacing: 4) {
                                    if let origin = message.origin {
                                        Text(origin == .local ? "LOCAL GUIDE" : "CLOUD ADVICE")
                                            .font(.caption2).foregroundColor(.white.opacity(0.6))
                                    }
                                    Text(message.content).font(.system(size: 13)).foregroundColor(.white)
                                }
                                .padding(12)
                                .background(message.role == .user ? Color.red : Color(hex: "1A1A24"))
                                .cornerRadius(12)
                                .frame(maxWidth: 280, alignment: message.role == .user ? .trailing : .leading)
                                if message.role == .assistant { Spacer() }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                HStack(spacing: 8) {
                    TextField("Ask Spatter for advice...", text: $prompt)
                        .font(.system(size: 14)).foregroundColor(.white)
                        .padding(12).background(Color(hex: "1A1A24")).cornerRadius(12)
                        .accessibilityIdentifier("spatter.studio.input")
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)).foregroundColor(.red)
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || spatterVM.isThinking)
                    .accessibilityIdentifier("spatter.studio.send")
                }
                .padding(16)
            }
            }
        }
        .onDisappear { spatterVM.endSession() }
        .onChange(of: authVM.userId) { _ in spatterVM.endSession(); prompt = ""; contextError = nil }
    }

    private func sendMessage() {
        guard let context = SpatterContext.studio(vm.commandScreenContext), let snapshot = context.studio else {
            contextError = "This Studio project is no longer open. Your draft has been kept."
            return
        }
        contextError = nil
        let submitted = prompt
        if spatterVM.submit(submitted, context: context, stillCurrent: { [weak vm] in
            guard let vm else { return false }
            return vm.isEditing && vm.document.id == snapshot.projectID && vm.document.revision == snapshot.revision
        }) { prompt = "" }
    }
}

// MARK: - Magic Cut Sheet
struct MagicCutSheet: View {
    @ObservedObject var vm: StudioViewModel
    @EnvironmentObject private var authVM: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var allFrames = false
    @State private var background: Color = .white
    @State private var tolerance = 8.0
    @State private var capture: StudioViewModel.ImageCutCapture?
    @State private var accountID: String?
    @State private var replacements: [String: Data] = [:]
    @State private var preview: UIImage?
    @State private var notice: String?
    @State private var isProcessing = false
    @State private var task: Task<Void, Never>?
    @State private var token = UUID()
    @State private var confirmAll = false

    private func cancel() {
        token = UUID(); task?.cancel(); task = nil; isProcessing = false
        replacements = [:]; preview = nil; capture = nil; notice = nil; confirmAll = false
    }
    private var current: Bool {
        guard let capture else { return false }
        return scenePhase == .active && authVM.userId == accountID
            && (try? vm.prepareImageCut(allFrames: allFrames)) == capture
    }
    private func generate() {
        cancel(); vm.stopPlayback()
        guard scenePhase == .active else { return }
        do {
            let target = try vm.prepareImageCut(allFrames: allFrames)
            var inputs: [String: Data] = [:]
            for id in Set(target.assetsByFrame.values) {
                guard let data = vm.rasterData(id) else { throw StudioRasterImage.Failure.missing }
                inputs[id] = data
            }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(background).getRed(&r, green: &g, blue: &b, alpha: &a) else {
                throw StudioDocumentError.invalid("Choose an RGB background color.")
            }
            let red = UInt8((min(1, max(0, r)) * 255).rounded())
            let green = UInt8((min(1, max(0, g)) * 255).rounded())
            let blue = UInt8((min(1, max(0, b)) * 255).rounded())
            let threshold = Int(tolerance.rounded()), request = token
            let previewID = target.assetsByFrame[vm.currentFrame.id] ?? inputs.keys.sorted().first!
            capture = target; accountID = authVM.userId; isProcessing = true
            let immutableInputs = inputs
            task = Task {
                let worker = Task.detached(priority: .userInitiated) { () throws -> [String: StudioBackgroundCut.Result] in
                    var results: [String: StudioBackgroundCut.Result] = [:]
                    for id in immutableInputs.keys.sorted() {
                        try Task.checkCancellation()
                        results[id] = try StudioBackgroundCut.remove(from: immutableInputs[id]!, red: red,
                            green: green, blue: blue, tolerance: threshold)
                    }
                    return results
                }
                do {
                    let results = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                         onCancel: { worker.cancel() })
                    try Task.checkCancellation()
                    guard token == request, current else { if token == request { cancel() }; return }
                    replacements = results.filter { $0.value.removedPixels > 0 }.mapValues { $0.png }
                    preview = results[previewID].flatMap { UIImage(data: $0.png) }
                    let changed = target.assetsByFrame.values.filter { replacements[$0] != nil }.count
                    notice = changed == 0 ? "No matching edge-connected background found. Nothing changed."
                        : "Preview ready · \(changed) frame(s). Apply changes all affected frames in one Undo step."
                    isProcessing = false; task = nil
                } catch {
                    guard token == request else { return }
                    isProcessing = false; replacements = [:]; preview = nil; task = nil
                    notice = error is CancellationError ? "Cancelled. The project is unchanged." : error.localizedDescription
                }
            }
        } catch { notice = error.localizedDescription }
    }
    private func apply() {
        guard current, let capture else { cancel(); notice = "The project changed. Preview again."; return }
        do {
            let changed = try vm.applyImageCut(capture, replacements: replacements)
            cancel(); vm.message = "Background removed from \(changed) frame(s). Undo restores the previous images."
            dismiss()
        } catch { notice = error.localizedDescription }
    }
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Text("Magic Cut").font(.system(size: 18, weight: .bold, design: .monospaced))
                    Spacer()
                    Button("Done") { cancel(); dismiss() }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Edge-connected color removal").font(.headline)
                        Text("Removes the chosen background color from the original imported image's edges. Enclosed areas, drawing layers and original files are preserved. This is color-based removal, not AI subject recognition.")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                        Picker("Scope", selection: $allFrames) {
                            Text("Current frame").tag(false)
                            Text("All imported frames").tag(true)
                        }.pickerStyle(.segmented)
                        ColorPicker("Background color", selection: $background, supportsOpacity: false)
                        HStack {
                            Text("Tolerance")
                            Slider(value: $tolerance, in: 0...100, step: 1)
                            Text("\(Int(tolerance))%").monospacedDigit()
                        }
                        Text("Higher tolerance removes a wider color range. Transparent squares below show the removed area. Preview shows the source image before canvas crop or rotation.")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                        if let preview {
                            ZStack {
                                Canvas { context, size in
                                    for y in stride(from: 0.0, to: size.height, by: 12) {
                                        for x in stride(from: 0.0, to: size.width, by: 12) {
                                            let alternate = (Int(x / 12) + Int(y / 12)) % 2 == 0
                                            context.fill(Path(CGRect(x: x, y: y, width: 12, height: 12)),
                                                with: .color(alternate ? .gray.opacity(0.5) : .white.opacity(0.8)))
                                        }
                                    }
                                }
                                Image(uiImage: preview).resizable().scaledToFit()
                            }.frame(height: 200).clipped().accessibilityLabel("Background removal preview")
                        }
                        if let notice { Text(notice).font(.caption).accessibilityIdentifier("studio.cut.notice") }
                        Text("Limit: 64 image frames, 16 distinct images / 16 megapixels per batch; 4 megapixels per image. Hidden or locked image layers must be shown and unlocked first.")
                            .font(.caption2).foregroundColor(.white.opacity(0.6))
                    }
                }
                HStack {
                    if isProcessing {
                        ProgressView().tint(.red)
                        Button("Cancel") { cancel() }
                    } else {
                        Button("Preview Cut", action: generate).accessibilityIdentifier("studio.cut.preview")
                    }
                    Spacer()
                    Button("Apply Cut") { if allFrames { confirmAll = true } else { apply() } }
                        .disabled(isProcessing || replacements.isEmpty || !current)
                        .accessibilityIdentifier("studio.cut.apply")
                }.buttonStyle(.borderedProminent).tint(.red)
            }.foregroundColor(.white).padding(16)
        }
        .confirmationDialog("Apply the previewed cut to all affected imported frames?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Apply to previewed frames", action: apply)
            Button("Cancel", role: .cancel) { }
        } message: { Text("Original files stay intact. Undo restores every affected frame together.") }
        .onChange(of: background) { _ in cancel() }
        .onChange(of: tolerance) { _ in cancel() }
        .onChange(of: allFrames) { _ in cancel() }
        .onChange(of: vm.document.id) { _ in cancel() }
        .onChange(of: vm.document.revision) { _ in cancel() }
        .onChange(of: vm.document.activeFrameID) { _ in cancel() }
        .onChange(of: authVM.userId) { _ in cancel(); dismiss() }
        .onChange(of: scenePhase) { if $0 != .active { cancel() } }
        .onDisappear { cancel() }
    }
}

// MARK: - Rotoscope Sheet
struct RotoscopeSheet: View {
    @ObservedObject var vm: StudioViewModel
    var body: some View { StudioImageImportPanel(vm: vm, videoFrameMode: true) }
}

// MARK: - Panel Header (reusable)
struct PanelHeader: View {
    let title: String
    let icon: String
    let onClose: () -> Void
    
    var body: some View {
        HStack {
            if icon.count <= 3 && icon.unicodeScalars.contains(where: { $0.value > 0x1F000 }) {
                Text(icon)
                    .font(.system(size: 18))
            } else {
                Image(systemName: icon)
                    .foregroundColor(.red)
            }
            Text(title)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.4))
            }
            .accessibilityLabel("Close \(title)")
            .accessibilityIdentifier("studio.panel.close.\(title)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(hex: "0D0D14"))
    }
}
