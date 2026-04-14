// StudioView.swift
// Main animation studio — FlipaClip-inspired layout
// v8: Full-screen canvas, left tool strip, bottom timeline, bottom-sheet panels
// Design refs: FlipaClip (tools left, timeline bottom) + Photoshop iPad (contextual UI)

import SwiftUI

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
            .padding(.top, 56) // below top bar

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

            // ── Watermark (non-Pro users) ──
            if !auth.isPro {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        WatermarkPreview()
                            .padding(.trailing, 12)
                            .padding(.bottom, 68) // above timeline
                    }
                }
                .allowsHitTesting(false)
            }

            // ── AI Panel overlay ──
            if vm.showAIPanel {
                AIAssistPanel(vm: vm)
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
        .task { await vm.loadProject() }
        .onDisappear { Task { await vm.saveProject() } }
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

            // Project name
            Text(vm.project.title)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .lineLimit(1)

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

            // Properties
            actionButton(icon: "slider.horizontal.3", label: "Props", active: showPropertiesSheet) {
                showPropertiesSheet.toggle()
            }

            // Onion skin toggle
            actionButton(icon: "circle.dotted", label: "Onion", active: vm.showOnionSkin) {
                vm.showOnionSkin.toggle()
            }

            Divider()
                .frame(width: 28)
                .background(Color.white.opacity(0.2))

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
                // Frame counter
                Text("\(vm.currentFrameIndex + 1)/\(vm.frames.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 40)

                // Scrollable frame strip
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(vm.frames.enumerated()), id: \.element.id) { idx, _ in
                                FrameThumb(
                                    index: idx,
                                    isSelected: idx == vm.currentFrameIndex,
                                    figureCount: vm.figures.count
                                )
                                .id(idx)
                                .onTapGesture {
                                    vm.currentFrameIndex = idx
                                    HapticManager.shared.frameSwitched()
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
        Button { vm.mode = mode } label: {
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

    var canvasGesture: some Gesture {
        vm.mode == .move
            ? AnyGesture(
                MagnificationGesture()
                    .simultaneously(with: DragGesture())
                    .onChanged { value in
                        if let scale = value.first { vm.canvasScale = scale }
                        if let drag = value.second { vm.canvasOffset = drag.translation }
                    }
                    .map { _ in () }
              )
            : AnyGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in }
                    .map { _ in () }
              )
    }
}

// MARK: - Frame Thumbnail (compact)
struct FrameThumb: View {
    let index: Int
    let isSelected: Bool
    let figureCount: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.red.opacity(0.3) : Color.white.opacity(0.08))
                .frame(width: 36, height: 36)

            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.red : Color.clear, lineWidth: 1.5)
                .frame(width: 36, height: 36)

            VStack(spacing: 1) {
                Image(systemName: "figure.stand")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.4))
                Text("\(index + 1)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.4))
            }
        }
    }
}

// MARK: - Brush Size Popover (sliders for size + opacity)
struct BrushSizePopover: View {
    @ObservedObject var drawState: DrawingState

    var body: some View {
        VStack(spacing: 16) {
            Text("Brush Settings")
                .font(.subheadline.bold())

            // Size slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Size").font(.caption)
                    Spacer()
                    Text("\(Int(drawState.strokeWidth))px").font(.caption.bold())
                }
                Slider(value: $drawState.strokeWidth, in: 1...30, step: 1)
                    .tint(.red)

                // Preview
                HStack {
                    Spacer()
                    Circle()
                        .fill(drawState.strokeColor)
                        .frame(width: max(4, drawState.strokeWidth * 2),
                               height: max(4, drawState.strokeWidth * 2))
                    Spacer()
                }
                .frame(height: 40)
            }

            // Fill toggle
            Toggle(isOn: $drawState.fillEnabled) {
                Text("Fill shapes").font(.caption)
            }
            .tint(.red)

            if drawState.fillEnabled {
                ColorPicker("Fill color", selection: $drawState.fillColor, supportsOpacity: true)
                    .font(.caption)
            }
        }
        .padding(16)
        .frame(width: 220)
    }
}

// MARK: - Layers Sheet (bottom sheet instead of side panel)
struct LayersSheet: View {
    @ObservedObject var vm: EditorViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(vm.figures) { fig in
                            HStack(spacing: 12) {
                                // Color indicator
                                Circle()
                                    .fill(fig.color.color)
                                    .frame(width: 24, height: 24)

                                // Figure icon
                                Image(systemName: "figure.stand")
                                    .font(.system(size: 16))
                                    .foregroundStyle(fig.color.color)

                                // Name
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(fig.name).font(.subheadline.bold())
                                    Text("\(fig.joints.count) joints")
                                        .font(.caption2).foregroundStyle(.gray)
                                }

                                Spacer()

                                // Visibility
                                Button {
                                    toggleVisibility(fig.id)
                                } label: {
                                    Image(systemName: isVisible(fig.id) ? "eye" : "eye.slash")
                                        .foregroundStyle(isVisible(fig.id) ? .white : .gray)
                                }

                                // Select
                                if vm.selectedFigureId == fig.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.red)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(.gray)
                                }
                            }
                            .padding(12)
                            .background(
                                vm.selectedFigureId == fig.id
                                    ? Color.red.opacity(0.1) : ThemeManager.surface
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .onTapGesture { vm.selectedFigureId = fig.id }
                            .contextMenu {
                                Button(role: .destructive) {
                                    vm.deleteFigure(fig.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }

                        // Add figure button
                        Button {
                            vm.addFigure()
                            HapticManager.shared.buttonTap()
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Add Figure")
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .background(Color.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.red)
                }
            }
        }
    }

    func isVisible(_ figureId: UUID) -> Bool {
        vm.frames[safe: vm.currentFrameIndex]?.figureStates.first(where: { $0.figureId == figureId })?.visible ?? true
    }

    func toggleVisibility(_ figureId: UUID) {
        guard let stateIdx = vm.frames[safe: vm.currentFrameIndex]?.figureStates.firstIndex(where: { $0.figureId == figureId }) else { return }
        vm.frames[vm.currentFrameIndex].figureStates[stateIdx].visible.toggle()
    }
}

// MARK: - Properties Sheet (bottom sheet)
struct PropertiesSheet: View {
    @ObservedObject var vm: EditorViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        if let fig = vm.selectedFigure {
                            // Figure properties
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Figure: \(fig.name)")
                                    .font(.headline)

                                HStack {
                                    Text("Color").font(.subheadline)
                                    Spacer()
                                    if let idx = vm.figures.firstIndex(where: { $0.id == vm.selectedFigureId }) {
                                        ColorPicker("", selection: colorBinding(idx))
                                            .labelsHidden()
                                    }
                                }
                                .padding(12)
                                .background(ThemeManager.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "figure.stand")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.gray)
                                Text("Select a figure to edit properties")
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                            }
                            .padding(.top, 40)
                        }

                        // Project settings
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Project Settings")
                                .font(.headline)

                            HStack {
                                Text("FPS").font(.subheadline)
                                Spacer()
                                Text("\(vm.project.fps ?? 24)").font(.subheadline.bold())
                            }
                            .padding(12)
                            .background(ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                            HStack {
                                Text("Frames").font(.subheadline)
                                Spacer()
                                Text("\(vm.frames.count)").font(.subheadline.bold())
                            }
                            .padding(12)
                            .background(ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                            HStack {
                                Text("Onion Skin").font(.subheadline)
                                Spacer()
                                Toggle("", isOn: $vm.showOnionSkin)
                                    .tint(.red)
                            }
                            .padding(12)
                            .background(ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Properties")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.red)
                }
            }
        }
    }

    func colorBinding(_ idx: Int) -> Binding<Color> {
        Binding(
            get: { vm.figures[idx].color.color },
            set: { _ in /* Color is stored as FigureColor enum, would need conversion */ }
        )
    }
}

// MARK: - Sound Timeline Strip (compact)
struct SoundTimelineStrip: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(vm.soundClips) { clip in
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 8))
                        Text(clip.name)
                            .font(.system(size: 9))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(colorForCategory(clip.category).opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contextMenu {
                        Button(role: .destructive) { vm.removeSoundClip(clip.id) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .background(Color.black.opacity(0.6))
    }

    func colorForCategory(_ cat: String) -> Color {
        switch cat {
        case "combat": return .red
        case "movement": return .cyan
        case "voices": return .red
        case "environment_sfx": return .green
        case "music_stings": return .purple
        case "comedy": return .pink
        default: return .gray
        }
    }
}

// MARK: - Watermark Preview
struct WatermarkPreview: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "figure.run")
                .font(.system(size: 8))
            Text("StickDeath ∞")
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(.white.opacity(0.4))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Quick Help Overlay
struct QuickHelpOverlay: View {
    @Binding var isShowing: Bool

    private let tips = [
        ("figure.stand", "Pose Mode", "Drag joints to pose your stick figures"),
        ("hand.draw", "Move Mode", "Pan & zoom the canvas"),
        ("pencil.tip", "Draw Mode", "Freehand sketch on the canvas"),
        ("cube.fill", "Assets", "1,000+ objects & sounds to add"),
        ("timeline.selection", "Timeline", "Add frames, reorder, set timing"),
        ("square.3.layers.3d", "Layers", "Manage multiple figures"),
        ("sparkles", "AI Assist", "Let AI generate animations (Pro)"),
        ("arrow.uturn.backward", "Undo", "Up to 50 steps of undo"),
        ("paperplane.fill", "Publish", "Share to all platforms"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture { isShowing = false }

            VStack(spacing: 0) {
                HStack {
                    Text("Quick Reference").font(.headline)
                    Spacer()
                    Button { isShowing = false } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.gray)
                    }
                }
                .padding()

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
                            HStack(spacing: 14) {
                                Image(systemName: tip.0).font(.body).foregroundStyle(.red).frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tip.1).font(.subheadline.bold())
                                    Text(tip.2).font(.caption).foregroundStyle(.gray)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                        }
                    }
                }
            }
            .background(ThemeManager.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: 340, maxHeight: 420)
            .shadow(color: .black.opacity(0.5), radius: 20)
        }
    }
}

// MARK: - Export Options Sheet
struct ExportOptionsSheet: View {
    @ObservedObject var vm: EditorViewModel
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @State private var isExporting = false
    @State private var exportSuccess = false
    @State private var includeWatermark = true

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "square.and.arrow.down.fill").font(.system(size: 40)).foregroundStyle(.red)
                    Text("Export to Camera Roll").font(.title2.bold())
                    Text("Save a copy of your animation as a video file to your device.")
                        .font(.subheadline).foregroundStyle(.gray).multilineTextAlignment(.center).padding(.horizontal, 32)

                    VStack(spacing: 8) {
                        if auth.isPro {
                            Toggle(isOn: $includeWatermark) {
                                VStack(alignment: .leading) {
                                    Text("Include watermark").font(.subheadline.bold())
                                    Text("\"StickDeath ∞\" branding on the video").font(.caption).foregroundStyle(.gray)
                                }
                            }
                            .tint(.red).padding().background(ThemeManager.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            HStack(spacing: 10) {
                                Image(systemName: "seal.fill").foregroundStyle(.red)
                                VStack(alignment: .leading) {
                                    Text("Watermark included").font(.subheadline.bold())
                                    Text("Upgrade to Pro to export without watermark").font(.caption).foregroundStyle(.gray)
                                }
                                Spacer()
                            }
                            .padding().background(ThemeManager.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(.horizontal, 24)

                    if exportSuccess {
                        Label("Saved to Camera Roll!", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }

                    Button {
                        Task { await exportVideo() }
                    } label: {
                        if isExporting { ProgressView().tint(.black) }
                        else { Label("Export Video", systemImage: "square.and.arrow.down").font(.headline).foregroundStyle(.black) }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16).background(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 40).disabled(isExporting)

                    Spacer()
                }
                .padding(.top, 32)
            }
            .navigationTitle("Export").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    func exportVideo() async {
        isExporting = true
        let watermark = auth.isPro ? includeWatermark : true
        do {
            let _ = try await PublishService.shared.exportLocally(projectId: vm.project.id, watermark: watermark)
            exportSuccess = true
        } catch { print("Export error: \(error)") }
        isExporting = false
    }
}
