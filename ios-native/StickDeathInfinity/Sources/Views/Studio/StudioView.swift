// StudioView.swift
// Main animation studio — FlipaClip-inspired layout
// v10: Scrollable top taskbar with Rig/Bone tool, IK-aware posing
// Design refs: FlipaClip (tools left, timeline bottom) + Stick Nodes (rigging)

import SwiftUI
import PhotosUI

struct StudioView: View {
    @StateObject var vm: EditorViewModel
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) var hSize
    @State private var showPublishSheet = false
    @State private var showTemplates = false
    @State private var showExportOptions = false
    @State private var showAssetBrowser = false
    @State private var showLayersSheet = false
    @State private var showPropertiesSheet = false
    @State private var showMoreMenu = false
    @State private var showQuickHelp = false
    @State private var lastDragTranslation: CGSize = .zero

    var isWide: Bool { hSize == .regular }

    var body: some View {
        ZStack {
            // Full-screen dark background
            Color.black.ignoresSafeArea()

            // ── Canvas (takes ALL available space) ──
            CanvasView(vm: vm)
                .gesture(canvasGesture)
                .ignoresSafeArea()

            // ── Drawing overlay (when in draw mode) ──
            if vm.mode == .draw {
                DrawingOverlay(
                    drawState: vm.drawState,
                    canvasCenter: CGPoint(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height / 2),
                    canvasScale: vm.canvasScale
                )
                .allowsHitTesting(false)
            }

            // ── Text input overlay (draw mode → text tool) ──
            if vm.drawState.showTextInput {
                textInputOverlay
            }

            // ── Top Taskbar (scrollable slider — compact) ──
            VStack(spacing: 0) {
                topTaskbar
                Spacer()
            }

            // ── Left Tool Strip ──
            HStack(spacing: 0) {
                leftToolStrip
                Spacer()
            }
            .padding(.top, 52)

            // ── Right Action Strip ──
            HStack(spacing: 0) {
                Spacer()
                rightActionStrip
            }
            .padding(.top, 52)

            // ── Bottom Timeline ──
            VStack(spacing: 0) {
                Spacer()
                bottomTimeline
            }

            // ── Cursor mode: delete button ──
            if vm.mode == .cursor && (vm.selectedImageId != nil || vm.selectedPlacedObjectId != nil) {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            vm.deleteSelected()
                            HapticManager.shared.buttonTap()
                        } label: {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.red)
                                .clipShape(Circle())
                                .shadow(color: .red.opacity(0.5), radius: 8)
                        }
                        .padding(.trailing, 60)
                        .padding(.bottom, 80)
                    }
                }
            }

            // ── Watermark (non-Pro users) ──
            if !auth.isPro {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        WatermarkPreview()
                            .padding(.trailing, 12)
                            .padding(.bottom, 68)
                    }
                }
                .allowsHitTesting(false)
            }

            // ── AI Panel overlay ──
            if vm.showAIPanel {
                AIAssistPanel(vm: vm)
            }

            // ── Quick Help overlay ──
            if showQuickHelp {
                QuickHelpOverlay(isShowing: $showQuickHelp)
            }

            // ── Saving indicator ──
            if vm.isSaving {
                VStack {
                    HStack {
                        Spacer()
                        Label("Saving…", systemImage: "icloud.and.arrow.up")
                            .font(.caption2)
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.top, 50)
                            .padding(.trailing, 56)
                    }
                    Spacer()
                }
            }
        }
        .animation(.spring(response: 0.3), value: vm.mode)
        .animation(.spring(response: 0.3), value: vm.showTimeline)
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .sheet(isPresented: $showPublishSheet) { PublishSheet(vm: vm) }
        .sheet(isPresented: $showTemplates) { TemplatesView { vm.applyTemplate($0) } }
        .sheet(isPresented: $showExportOptions) { ExportOptionsSheet(vm: vm) }
        .sheet(isPresented: $showAssetBrowser) {
            AssetBrowserView(
                onObjectSelected: { asset in vm.addPlacedObject(asset: asset) },
                onSoundSelected: { asset in vm.addSoundClip(asset: asset) }
            )
        }
        .sheet(isPresented: $showLayersSheet) {
            LayersSheet(vm: vm)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPropertiesSheet) {
            PropertiesSheet(vm: vm)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $vm.showProjectSettings) {
            ProjectSettingsView(vm: vm)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $vm.showFramesViewer) {
            FramesGridView(vm: vm)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .photosPicker(isPresented: $vm.showImagePicker, selection: $vm.importedPhotoItem, matching: .images)
        .onChange(of: vm.importedPhotoItem) { newItem in
            Task { await vm.processPhotoPicker(item: newItem) }
        }
        .task { await vm.loadProject() }
        .onDisappear { Task { await vm.saveProject() } }
    }

    // MARK: - Canvas Gesture (mode-dependent)
    var canvasGesture: some Gesture {
        switch vm.mode {
        case .move:
            return AnyGesture(moveGesture.map { _ in () })
        case .draw:
            return AnyGesture(drawGesture.map { _ in () })
        case .cursor:
            return AnyGesture(cursorGesture.map { _ in () })
        case .rig:
            return AnyGesture(rigGesture.map { _ in () })
        case .pose:
            return AnyGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in }
                    .map { _ in () }
            )
        }
    }

    // Pan + zoom for move mode
    var moveGesture: some Gesture {
        MagnificationGesture()
            .simultaneously(with: DragGesture())
            .onChanged { value in
                if let scale = value.first { vm.canvasScale = max(0.3, min(5.0, scale)) }
                if let drag = value.second { vm.canvasOffset = drag.translation }
            }
    }

    // Drawing gesture
    var drawGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if vm.drawState.currentPath.isEmpty {
                    vm.handleDrawingBegan(at: drag.startLocation)
                }
                vm.handleDrawingMoved(to: drag.location)
            }
            .onEnded { drag in
                vm.handleDrawingEnded(at: drag.location)
            }
    }

    // Cursor gesture
    var cursorGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let dist = hypot(drag.translation.width, drag.translation.height)
                if dist > 4 {
                    let delta = CGSize(
                        width: drag.translation.width - lastDragTranslation.width,
                        height: drag.translation.height - lastDragTranslation.height
                    )
                    vm.handleCursorDrag(translation: delta)
                    lastDragTranslation = drag.translation
                }
            }
            .onEnded { drag in
                let dist = hypot(drag.translation.width, drag.translation.height)
                if dist <= 4 {
                    vm.handleCursorTap(at: drag.startLocation)
                } else {
                    vm.pushUndo()
                }
                lastDragTranslation = .zero
            }
    }

    // Rig gesture — IK-aware dragging, bone creation, selection
    var rigGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let dist = hypot(drag.translation.width, drag.translation.height)
                if dist > 4 {
                    if lastDragTranslation == .zero {
                        vm.handleRigDragBegan(at: drag.startLocation)
                    }
                    vm.handleRigDragMoved(to: drag.location)
                    lastDragTranslation = drag.translation
                }
            }
            .onEnded { drag in
                let dist = hypot(drag.translation.width, drag.translation.height)
                if dist <= 4 {
                    vm.handleRigTap(at: drag.startLocation)
                } else {
                    vm.handleRigDragEnded(at: drag.location)
                }
                lastDragTranslation = .zero
            }
    }

    // MARK: - Text Input Overlay
    var textInputOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                TextField("Type text…", text: $vm.drawState.textInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                Button("Add") {
                    vm.commitTextElement(vm.drawState.textInput)
                    HapticManager.shared.buttonTap()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button("Cancel") {
                    vm.drawState.showTextInput = false
                    vm.drawState.textInput = ""
                }
                .foregroundStyle(.gray)
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            .padding(.bottom, 70)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - TOP TASKBAR (SCROLLABLE SLIDER)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    var topTaskbar: some View {
        HStack(spacing: 0) {
            // ── Fixed left: Back ──
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
            }
            .padding(.leading, 6)

            // ── Project name ──
            Button { vm.showProjectSettings = true } label: {
                HStack(spacing: 3) {
                    Text(vm.project.title)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7))
                        .foregroundStyle(.gray)
                }
            }
            .frame(maxWidth: 80)

            // ── Scrollable tool strip (THE SLIDER) ──
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    // Divider dot
                    toolDivider

                    // Creative modes
                    taskbarTool(.pose, icon: "figure.stand", label: "Pose")
                    taskbarTool(.move, icon: "hand.draw", label: "Move")
                    taskbarTool(.draw, icon: "pencil.tip", label: "Draw")
                    taskbarTool(.cursor, icon: "cursorarrow", label: "Select")
                    taskbarTool(.rig, icon: "figure.stand.line.dotted.figure.stand", label: "Rig")

                    toolDivider

                    // Undo / Redo
                    taskbarAction(icon: "arrow.uturn.backward", label: "Undo",
                                  disabled: vm.undoStack.isEmpty) { vm.undo() }
                    taskbarAction(icon: "arrow.uturn.forward", label: "Redo",
                                  disabled: vm.redoStack.isEmpty) { vm.redo() }

                    toolDivider

                    // Play
                    taskbarAction(icon: vm.isPlaying ? "pause.fill" : "play.fill",
                                  label: vm.isPlaying ? "Pause" : "Play",
                                  tint: .red) { vm.togglePlay() }

                    toolDivider

                    // Canvas tools
                    taskbarToggle(icon: "circle.dotted", label: "Onion", active: vm.showOnionSkin) {
                        vm.showOnionSkin.toggle()
                    }
                    taskbarToggle(icon: "grid", label: "Grid", active: vm.showGrid) {
                        vm.showGrid.toggle()
                    }

                    // Rig bone overlay toggle (quick access in toolbar)
                    if vm.mode == .rig {
                        taskbarToggle(icon: vm.showBoneOverlay ? "eye.fill" : "eye.slash",
                                      label: "Bones", active: vm.showBoneOverlay, tint: .green) {
                            vm.toggleBoneVisibility()
                        }
                    }

                    toolDivider

                    // Import / Assets
                    taskbarAction(icon: "photo.badge.plus", label: "Photo", tint: .green) {
                        vm.showImagePicker = true
                    }
                    taskbarAction(icon: "cube.fill", label: "Assets", tint: .mint) {
                        showAssetBrowser = true
                    }

                    if auth.isPro {
                        taskbarAction(icon: "sparkles", label: "AI", tint: .purple) {
                            vm.showAIPanel.toggle()
                        }
                    }

                    taskbarAction(icon: "rectangle.split.3x3", label: "Frames") {
                        vm.showFramesViewer = true
                    }
                    taskbarAction(icon: "square.3.layers.3d", label: "Layers") {
                        showLayersSheet = true
                    }
                    taskbarAction(icon: "square.and.arrow.down", label: "Export") {
                        showExportOptions = true
                    }
                    taskbarAction(icon: "questionmark.circle", label: "Help") {
                        showQuickHelp = true
                    }
                }
                .padding(.horizontal, 4)
            }

            // ── Fixed right: Publish ──
            Button { showPublishSheet = true } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.black)
                    .frame(width: 30, height: 30)
                    .background(Color.red)
                    .clipShape(Circle())
            }
            .padding(.trailing, 8)
        }
        .frame(height: 46)
        .background(
            LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.6), .clear],
                          startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    // Taskbar tool button (mode selector)
    func taskbarTool(_ mode: EditorMode, icon: String, label: String) -> some View {
        Button {
            vm.mode = mode
            if mode != .cursor { vm.clearSelection() }
            HapticManager.shared.buttonTap()
        } label: {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: vm.mode == mode ? .bold : .medium))
                    .foregroundStyle(vm.mode == mode ? .red : .white.opacity(0.7))
                Text(label)
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(vm.mode == mode ? .red : .white.opacity(0.4))
            }
            .frame(width: 38, height: 38)
            .background(vm.mode == mode ? Color.red.opacity(0.2) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // Taskbar action button
    func taskbarAction(icon: String, label: String, disabled: Bool = false, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(disabled ? .gray.opacity(0.3) : tint.opacity(0.8))
                Text(label)
                    .font(.system(size: 7))
                    .foregroundStyle(disabled ? .gray.opacity(0.2) : .white.opacity(0.4))
            }
            .frame(width: 36, height: 38)
        }
        .disabled(disabled)
    }

    // Taskbar toggle button
    func taskbarToggle(icon: String, label: String, active: Bool, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(active ? tint : .white.opacity(0.4))
                Text(label)
                    .font(.system(size: 7))
                    .foregroundStyle(active ? tint.opacity(0.7) : .white.opacity(0.3))
            }
            .frame(width: 36, height: 38)
            .background(active ? tint.opacity(0.1) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // Small visual divider between tool groups
    var toolDivider: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.white.opacity(0.12))
            .frame(width: 1, height: 24)
            .padding(.horizontal, 2)
    }

    // MARK: - Left Tool Strip (contextual sub-tools)
    var leftToolStrip: some View {
        VStack(spacing: 6) {
            // Mode-specific sub-tools
            switch vm.mode {
            case .draw:
                drawingSubTools
            case .rig:
                RigToolPanel(vm: vm)
            default:
                // Minimal: figure selector
                if vm.figures.count > 1 {
                    figureSelector
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 8)
        )
        .padding(.leading, 8)
        .frame(maxWidth: 52)
    }

    // Drawing sub-tools (pencil, line, rect, circle, etc.)
    var drawingSubTools: some View {
        VStack(spacing: 4) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(DrawingTool.allCases, id: \.self) { tool in
                        drawToolButton(tool)
                    }
                }
            }
            .frame(maxHeight: 220)

            Divider().frame(width: 28).background(Color.white.opacity(0.2))

            ColorPicker("", selection: $vm.drawState.strokeColor, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 30, height: 30)

            Button { vm.showBrushSizePopover.toggle() } label: {
                ZStack {
                    Circle().stroke(.white.opacity(0.3), lineWidth: 1).frame(width: 30, height: 30)
                    Circle()
                        .fill(vm.drawState.strokeColor)
                        .frame(width: min(22, max(4, vm.drawState.strokeWidth * 2)),
                               height: min(22, max(4, vm.drawState.strokeWidth * 2)))
                }
            }
            .popover(isPresented: $vm.showBrushSizePopover) {
                BrushSizePopover(drawState: vm.drawState)
            }

            Button { vm.undoLastDrawnElement(); HapticManager.shared.buttonTap() } label: {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 30, height: 30)
            }
            .disabled(vm.frames[safe: vm.currentFrameIndex]?.drawnElements.isEmpty ?? true)

            Button { vm.clearDrawnElements(); HapticManager.shared.buttonTap() } label: {
                Image(systemName: "trash.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.red.opacity(0.6))
                    .frame(width: 30, height: 30)
            }
        }
    }

    // Figure selector (when multiple figures)
    var figureSelector: some View {
        VStack(spacing: 4) {
            ForEach(vm.figures) { fig in
                Button {
                    vm.selectedFigureId = fig.id
                } label: {
                    Circle()
                        .fill(fig.color.color.opacity(vm.selectedFigureId == fig.id ? 1 : 0.4))
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle().stroke(.red, lineWidth: vm.selectedFigureId == fig.id ? 2 : 0)
                        )
                }
            }
        }
    }

    // MARK: - Right Action Strip (slim — most tools moved to taskbar)
    var rightActionStrip: some View {
        VStack(spacing: 6) {
            // Settings
            actionButton(icon: "slider.horizontal.3", label: "Settings") {
                vm.showProjectSettings = true
            }

            // Add figure
            actionButton(icon: "person.badge.plus", label: "Figure", tint: .cyan) {
                vm.addFigure()
            }

            // Templates
            actionButton(icon: "square.on.square.dashed", label: "Tmpl", tint: .cyan) {
                showTemplates = true
            }

            // More
            Menu {
                Button { showExportOptions = true } label: {
                    Label("Export Video", systemImage: "square.and.arrow.down")
                }
                Button { showTemplates = true } label: {
                    Label("Templates", systemImage: "square.on.square.dashed")
                }
                Button { showQuickHelp = true } label: {
                    Label("Quick Help", systemImage: "questionmark.circle")
                }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.08))
                        .clipShape(Circle())
                    Text("More").font(.system(size: 8)).foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 8)
        )
        .padding(.trailing, 8)
    }

    // MARK: - Bottom Timeline
    var bottomTimeline: some View {
        VStack(spacing: 0) {
            if !vm.soundClips.isEmpty {
                SoundTimelineStrip(vm: vm)
                    .frame(height: 28)
            }

            HStack(spacing: 0) {
                Button { vm.showFramesViewer = true } label: {
                    Text("\(vm.currentFrameIndex + 1)/\(vm.frames.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 40)
                }

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(vm.frames.enumerated()), id: \.element.id) { idx, frame in
                                FrameThumb(
                                    index: idx,
                                    isSelected: idx == vm.currentFrameIndex,
                                    figureCount: vm.figures.count,
                                    hasDrawing: !frame.drawnElements.isEmpty,
                                    hasImages: !frame.importedImages.isEmpty
                                )
                                .id(idx)
                                .onTapGesture { vm.goToFrame(idx) }
                                .contextMenu {
                                    Button {
                                        vm.currentFrameIndex = idx
                                        vm.duplicateFrame()
                                    } label: {
                                        Label("Duplicate", systemImage: "doc.on.doc")
                                    }
                                    if vm.frames.count > 1 {
                                        Button(role: .destructive) {
                                            vm.currentFrameIndex = idx
                                            vm.deleteFrame()
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .onChange(of: vm.currentFrameIndex) { newVal in
                        withAnimation { proxy.scrollTo(newVal, anchor: .center) }
                    }
                }

                Button {
                    vm.addFrame()
                    HapticManager.shared.buttonTap()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                        .background(Color.red.opacity(0.15))
                        .clipShape(Circle())
                }
                .padding(.trailing, 8)
            }
            .frame(height: 48)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Helpers

    func drawToolButton(_ tool: DrawingTool) -> some View {
        Button { vm.drawState.tool = tool } label: {
            Image(systemName: tool.icon)
                .font(.system(size: 13))
                .foregroundStyle(vm.drawState.tool == tool ? .red : .white.opacity(0.6))
                .frame(width: 30, height: 30)
                .background(vm.drawState.tool == tool ? Color.red.opacity(0.2) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    func actionButton(icon: String, label: String, active: Bool = false, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(active ? tint : .white.opacity(0.7))
                    .frame(width: 36, height: 36)
                    .background(active ? tint.opacity(0.2) : .white.opacity(0.08))
                    .clipShape(Circle())
                Text(label)
                    .font(.system(size: 8))
                    .foregroundStyle(active ? tint : .white.opacity(0.5))
            }
        }
    }
}

// MARK: - Frame Thumbnail (compact)
struct FrameThumb: View {
    let index: Int
    let isSelected: Bool
    let figureCount: Int
    var hasDrawing: Bool = false
    var hasImages: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.red.opacity(0.3) : Color.white.opacity(0.08))
                .frame(width: 36, height: 36)
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.red : Color.clear, lineWidth: 1.5)
                .frame(width: 36, height: 36)
            VStack(spacing: 1) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: isSelected ? .bold : .regular, design: .monospaced))
                    .foregroundStyle(isSelected ? .red : .white.opacity(0.6))
                HStack(spacing: 2) {
                    if hasDrawing { Circle().fill(Color.orange).frame(width: 4, height: 4) }
                    if hasImages { Circle().fill(Color.green).frame(width: 4, height: 4) }
                }
            }
        }
    }
}
