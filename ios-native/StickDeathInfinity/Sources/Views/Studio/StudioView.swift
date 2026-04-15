// StudioView.swift
// Main animation studio — FlipaClip-inspired layout
// v9: Drawing gestures wired, cursor/select tool, image import, project settings, frames viewer
// Design refs: FlipaClip (tools left, timeline bottom) + Photoshop iPad (contextual UI)

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

            // ── Drawing overlay (when in draw mode — renders completed elements) ──
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

            // ── Top Bar (ultra-thin) ──
            VStack(spacing: 0) {
                topBar
                Spacer()
            }

            // ── Left Tool Strip (FlipaClip-style) ──
            HStack(spacing: 0) {
                leftToolStrip
                Spacer()
            }
            .padding(.top, 56)

            // ── Right Action Strip ──
            HStack(spacing: 0) {
                Spacer()
                rightActionStrip
            }
            .padding(.top, 56)

            // ── Bottom Timeline (always visible as thin strip) ──
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
        case .pose:
            // Pose mode joint dragging handled by JointHandle in CanvasView
            return AnyGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in }
                    .map { _ in () }
            )
        }
    }

    // Pan + zoom gesture for move mode
    var moveGesture: some Gesture {
        MagnificationGesture()
            .simultaneously(with: DragGesture())
            .onChanged { value in
                if let scale = value.first { vm.canvasScale = max(0.3, min(5.0, scale)) }
                if let drag = value.second { vm.canvasOffset = drag.translation }
            }
    }

    // Drawing gesture — forwards touch events to EditorViewModel
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

    // Cursor gesture — tap to select, drag to move
    var cursorGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let dist = hypot(drag.translation.width, drag.translation.height)
                if dist > 4 {
                    // Dragging — move selected object
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
                    // Tap — select object at point
                    vm.handleCursorTap(at: drag.startLocation)
                } else {
                    vm.pushUndo()
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

    // MARK: - Top Bar (ultra-thin, like FlipaClip)
    var topBar: some View {
        HStack(spacing: 12) {
            // Back
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
            }

            // Project name (tap for settings)
            Button {
                vm.showProjectSettings = true
            } label: {
                HStack(spacing: 4) {
                    Text(vm.project.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(.gray)
                }
            }

            Spacer()

            // Undo / Redo
            Button { vm.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 15))
                    .foregroundStyle(vm.undoStack.isEmpty ? .gray.opacity(0.4) : .white)
                    .frame(width: 32, height: 32)
            }
            .disabled(vm.undoStack.isEmpty)

            Button { vm.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 15))
                    .foregroundStyle(vm.redoStack.isEmpty ? .gray.opacity(0.4) : .white)
                    .frame(width: 32, height: 32)
            }
            .disabled(vm.redoStack.isEmpty)

            // Play / Pause
            Button { vm.togglePlay() } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.red)
                    .frame(width: 36, height: 36)
                    .background(Color.red.opacity(0.15))
                    .clipShape(Circle())
            }

            // Publish
            Button { showPublishSheet = true } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.black)
                    .frame(width: 32, height: 32)
                    .background(Color.red)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0)],
                          startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - Left Tool Strip (FlipaClip-style vertical toolbar)
    var leftToolStrip: some View {
        VStack(spacing: 6) {
            // Mode tools
            toolButton(.pose, icon: "figure.stand", label: "Pose")
            toolButton(.move, icon: "hand.draw", label: "Move")
            toolButton(.draw, icon: "pencil.tip", label: "Draw")
            toolButton(.cursor, icon: "cursorarrow", label: "Cursor")

            Divider()
                .frame(width: 28)
                .background(Color.white.opacity(0.2))

            // Drawing sub-tools (visible in draw mode)
            if vm.mode == .draw {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(DrawingTool.allCases, id: \.self) { tool in
                            drawToolButton(tool)
                        }
                    }
                }
                .frame(maxHeight: 220)

                Divider()
                    .frame(width: 28)
                    .background(Color.white.opacity(0.2))

                // Color indicator (tap for wheel)
                ColorPicker("", selection: $vm.drawState.strokeColor, supportsOpacity: true)
                    .labelsHidden()
                    .frame(width: 30, height: 30)

                // Brush size indicator
                Button {
                    vm.showBrushSizePopover.toggle()
                } label: {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.3), lineWidth: 1)
                            .frame(width: 30, height: 30)
                        Circle()
                            .fill(vm.drawState.strokeColor)
                            .frame(width: min(22, max(4, vm.drawState.strokeWidth * 2)),
                                   height: min(22, max(4, vm.drawState.strokeWidth * 2)))
                    }
                }
                .popover(isPresented: $vm.showBrushSizePopover) {
                    BrushSizePopover(drawState: vm.drawState)
                }

                // Drawing undo (erase last stroke)
                Button {
                    vm.undoLastDrawnElement()
                    HapticManager.shared.buttonTap()
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 30, height: 30)
                }

                // Clear all drawn elements
                Button {
                    vm.clearDrawnElements()
                    HapticManager.shared.buttonTap()
                } label: {
                    Image(systemName: "trash.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.red.opacity(0.6))
                        .frame(width: 30, height: 30)
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
    }

    // MARK: - Right Action Strip
    var rightActionStrip: some View {
        VStack(spacing: 6) {
            // Layers
            actionButton(icon: "square.3.layers.3d", label: "Layers", active: showLayersSheet) {
                showLayersSheet.toggle()
            }

            // Properties / Project Settings
            actionButton(icon: "slider.horizontal.3", label: "Settings") {
                vm.showProjectSettings = true
            }

            // Frames viewer
            actionButton(icon: "rectangle.split.3x3", label: "Frames") {
                vm.showFramesViewer = true
            }

            // Onion skin toggle
            actionButton(icon: "circle.dotted", label: "Onion", active: vm.showOnionSkin) {
                vm.showOnionSkin.toggle()
            }

            // Grid toggle
            actionButton(icon: "grid", label: "Grid", active: vm.showGrid) {
                vm.showGrid.toggle()
            }

            Divider()
                .frame(width: 28)
                .background(Color.white.opacity(0.2))

            // Import image from camera roll
            actionButton(icon: "photo.badge.plus", label: "Image", tint: .green) {
                vm.showImagePicker = true
            }

            // Assets
            actionButton(icon: "cube.fill", label: "Assets", tint: .mint) {
                showAssetBrowser = true
            }

            // Templates
            actionButton(icon: "square.on.square.dashed", label: "Tmpl", tint: .cyan) {
                showTemplates = true
            }

            // AI (Pro)
            if auth.isPro {
                actionButton(icon: "sparkles", label: "AI", active: vm.showAIPanel, tint: .purple) {
                    vm.showAIPanel.toggle()
                }
            }

            // More (export, help)
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

    // MARK: - Bottom Timeline (compact, expandable)
    var bottomTimeline: some View {
        VStack(spacing: 0) {
            // Sound clips strip (if any)
            if !vm.soundClips.isEmpty {
                SoundTimelineStrip(vm: vm)
                    .frame(height: 28)
            }

            // Frame timeline
            HStack(spacing: 0) {
                // Frame counter (tap for full frames view)
                Button {
                    vm.showFramesViewer = true
                } label: {
                    Text("\(vm.currentFrameIndex + 1)/\(vm.frames.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 40)
                }

                // Scrollable frame strip
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
                                .onTapGesture {
                                    vm.goToFrame(idx)
                                }
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

                // Add frame button
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

    func toolButton(_ mode: EditorMode, icon: String, label: String) -> some View {
        Button {
            vm.mode = mode
            if mode != .cursor { vm.clearSelection() }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(vm.mode == mode ? .red : .white.opacity(0.7))
                    .frame(width: 36, height: 36)
                    .background(vm.mode == mode ? Color.red.opacity(0.2) : .white.opacity(0.08))
                    .clipShape(Circle())
                Text(label)
                    .font(.system(size: 8))
                    .foregroundStyle(vm.mode == mode ? .red : .white.opacity(0.5))
            }
        }
    }

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
                // Frame number
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: isSelected ? .bold : .regular, design: .monospaced))
                    .foregroundStyle(isSelected ? .red : .white.opacity(0.6))

                // Indicators
                HStack(spacing: 2) {
                    if hasDrawing {
                        Circle().fill(Color.orange).frame(width: 4, height: 4)
                    }
                    if hasImages {
                        Circle().fill(Color.green).frame(width: 4, height: 4)
                    }
                }
            }
        }
    }
}
