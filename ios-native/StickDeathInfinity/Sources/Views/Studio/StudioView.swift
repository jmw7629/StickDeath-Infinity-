// StudioView.swift
// Full-screen animation studio — Illustrator-inspired layout for iPhone
// v5: Bottom toolbar, slide-up half-sheet panels, full-bleed canvas
// Compact, thumb-friendly, bold design

import SwiftUI

struct StudioView: View {
    @StateObject var vm: EditorViewModel
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) var hSize

    // Panel state — only one panel open at a time
    @State private var activePanel: StudioPanel? = nil
    @State private var showPublishSheet = false
    @State private var showAssetBrowser = false
    @State private var showExportOptions = false

    enum StudioPanel: String, CaseIterable {
        case layers, properties, colors, timeline
    }

    var isWide: Bool { hSize == .regular }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isWide {
                wideLayout
            } else {
                compactLayout
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: activePanel)
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .sheet(isPresented: $showPublishSheet) { PublishSheet(vm: vm) }
        .sheet(isPresented: $showExportOptions) { ExportOptionsSheet(vm: vm) }
        .sheet(isPresented: $showAssetBrowser) {
            AssetBrowserView(
                onObjectSelected: { vm.addPlacedObject(asset: $0) },
                onSoundSelected: { vm.addSoundClip(asset: $0) }
            )
        }
        .task { await vm.loadProject() }
        .onDisappear { Task { await vm.saveProject() } }
    }

    // MARK: - Compact Layout (iPhone) — Illustrator-inspired
    var compactLayout: some View {
        ZStack {
            // Layer 1: Full-bleed canvas
            CanvasView(vm: vm)
                .gesture(canvasGesture)
                .ignoresSafeArea()

            // Layer 2: Top status bar (minimal)
            VStack {
                StudioTopBar(
                    vm: vm,
                    onBack: { dismiss() },
                    onPublish: { showPublishSheet = true },
                    onExport: { showExportOptions = true }
                )
                Spacer()
            }

            // Layer 3: Watermark (non-Pro)
            if !auth.isPro {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        WatermarkBadge()
                            .padding(.trailing, 8)
                            .padding(.bottom, activePanel != nil ? 340 : 110)
                    }
                }
                .allowsHitTesting(false)
            }

            // Layer 4: Saving indicator
            if vm.isSaving {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Label("Saving...", systemImage: "icloud.and.arrow.up")
                            .font(.caption2)
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.trailing, 8)
                            .padding(.bottom, activePanel != nil ? 340 : 110)
                    }
                }
            }

            // Layer 5: Bottom panel + toolbar stack
            VStack(spacing: 0) {
                Spacer()

                // Half-sheet panel (slides up)
                if let panel = activePanel {
                    panelContent(panel)
                        .frame(height: 280)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Timeline strip (thin, above toolbar)
                TimelineStrip(vm: vm)

                // Bottom toolbar (always visible)
                StudioBottomToolbar(
                    vm: vm,
                    activePanel: $activePanel,
                    onAssets: { showAssetBrowser = true },
                    isPro: auth.isPro
                )
            }

            // AI Panel
            if vm.showAIPanel {
                AIAssistPanel(vm: vm)
            }
        }
    }

    // MARK: - Wide Layout (iPad/Mac — panels docked)
    var wideLayout: some View {
        HStack(spacing: 0) {
            if vm.showLayers {
                LayersPanel(vm: vm)
                    .frame(width: 280)
                    .transition(.move(edge: .leading))
            }

            VStack(spacing: 0) {
                StudioTopBar(
                    vm: vm,
                    onBack: { dismiss() },
                    onPublish: { showPublishSheet = true },
                    onExport: { showExportOptions = true }
                )
                CanvasView(vm: vm)
                    .gesture(canvasGesture)

                if vm.showTimeline {
                    TimelinePanel(vm: vm)
                        .frame(height: 120)
                }

                if !vm.soundClips.isEmpty {
                    SoundTimelineStrip(vm: vm).frame(height: 40)
                }
            }

            if vm.showProperties {
                PropertiesPanel(vm: vm)
                    .frame(width: 300)
                    .transition(.move(edge: .trailing))
            }
        }
    }

    // MARK: - Panel Content Router
    @ViewBuilder
    func panelContent(_ panel: StudioPanel) -> some View {
        switch panel {
        case .layers:
            CompactLayersPanel(vm: vm, onClose: { activePanel = nil })
        case .properties:
            CompactPropertiesPanel(vm: vm, onClose: { activePanel = nil })
        case .colors:
            CompactColorPanel(vm: vm, onClose: { activePanel = nil })
        case .timeline:
            CompactTimelinePanel(vm: vm, onClose: { activePanel = nil })
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

// MARK: - Top Status Bar (minimal — project name, zoom, undo/redo)
struct StudioTopBar: View {
    @ObservedObject var vm: EditorViewModel
    let onBack: () -> Void
    let onPublish: () -> Void
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Back button
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }

            // Project title
            Text(vm.project.title)
                .font(.subheadline.bold())
                .lineLimit(1)

            Spacer()

            // Zoom level (tappable to reset)
            Button {
                vm.canvasScale = 1.0
                vm.canvasOffset = .zero
            } label: {
                Text("\(Int(vm.canvasScale * 100))%")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }

            // Undo / Redo
            HStack(spacing: 4) {
                Button { vm.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(vm.undoStack.isEmpty ? .gray.opacity(0.3) : .white)
                        .frame(width: 32, height: 32)
                }
                .disabled(vm.undoStack.isEmpty)

                Button { vm.redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(vm.redoStack.isEmpty ? .gray.opacity(0.3) : .white)
                        .frame(width: 32, height: 32)
                }
                .disabled(vm.redoStack.isEmpty)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Export & Publish
            Button(action: onExport) {
                Image(systemName: "square.and.arrow.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }

            Button(action: onPublish) {
                Image(systemName: "paperplane.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(width: 32, height: 32)
                    .background(.orange)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
        )
    }
}

// MARK: - Timeline Strip (thin, always-visible, above bottom toolbar)
struct TimelineStrip: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        HStack(spacing: 6) {
            // Playback
            Button { vm.togglePlay() } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                    .frame(width: 28, height: 28)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(Circle())
            }

            // Frame counter
            Text("\(vm.currentFrameIndex + 1)/\(vm.frames.count)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(.gray)

            // Scrollable frame dots
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(Array(vm.frames.enumerated()), id: \.element.id) { index, _ in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(index == vm.currentFrameIndex ? Color.orange : Color.white.opacity(0.2))
                                .frame(width: index == vm.currentFrameIndex ? 18 : 10, height: 6)
                                .id(index)
                                .onTapGesture { vm.currentFrameIndex = index }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: vm.currentFrameIndex) { _, idx in
                    withAnimation { proxy.scrollTo(idx, anchor: .center) }
                }
            }

            // Quick actions
            Button { vm.addFrame() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: 24, height: 24)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.85))
    }
}

// MARK: - Bottom Toolbar (thumb-friendly, labeled icons)
struct StudioBottomToolbar: View {
    @ObservedObject var vm: EditorViewModel
    @Binding var activePanel: StudioView.StudioPanel?
    let onAssets: () -> Void
    let isPro: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Tool modes (left group)
            HStack(spacing: 2) {
                toolModeButton(.pose, icon: "figure.stand", label: "Pose")
                toolModeButton(.move, icon: "hand.draw", label: "Move")
                toolModeButton(.draw, icon: "pencil.tip", label: "Draw")
            }

            Divider()
                .frame(height: 28)
                .background(ThemeManager.border)
                .padding(.horizontal, 6)

            // Panel toggles (center group)
            HStack(spacing: 2) {
                panelButton(.layers, icon: "square.3.layers.3d", label: "Layers")
                panelButton(.properties, icon: "slider.horizontal.3", label: "Props")
                panelButton(.colors, icon: "paintpalette", label: "Color")
                panelButton(.timeline, icon: "film.stack", label: "Frames")
            }

            Divider()
                .frame(height: 28)
                .background(ThemeManager.border)
                .padding(.horizontal, 6)

            // Actions (right group)
            HStack(spacing: 2) {
                actionButton(icon: "cube.fill", label: "Assets", tint: .mint, action: onAssets)

                if isPro {
                    actionButton(icon: "sparkles", label: "AI", tint: .purple) {
                        vm.showAIPanel.toggle()
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThickMaterial)
        .overlay(
            Rectangle()
                .fill(ThemeManager.border)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    func toolModeButton(_ mode: EditorMode, icon: String, label: String) -> some View {
        Button { vm.mode = mode } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(vm.mode == mode ? .orange : .white.opacity(0.5))
            .frame(width: 48, height: 40)
            .background(vm.mode == mode ? Color.orange.opacity(0.15) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    func panelButton(_ panel: StudioView.StudioPanel, icon: String, label: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                activePanel = activePanel == panel ? nil : panel
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(activePanel == panel ? .orange : .white.opacity(0.5))
            .frame(width: 44, height: 40)
            .background(activePanel == panel ? Color.orange.opacity(0.15) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    func actionButton(icon: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(tint)
            .frame(width: 44, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Compact Layers Panel (half-sheet)
struct CompactLayersPanel: View {
    @ObservedObject var vm: EditorViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            panelHeader("Layers", icon: "square.3.layers.3d", onClose: onClose) {
                Button { vm.addFigure() } label: {
                    Label("Add", systemImage: "plus")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }

            if vm.figures.isEmpty {
                emptyState(icon: "square.3.layers.3d", message: "No layers yet", hint: "Tap + to add a figure")
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(vm.figures.enumerated()), id: \.element.id) { index, figure in
                            let isSelected = figure.id == vm.selectedFigureId
                            HStack(spacing: 10) {
                                // Color dot + number
                                ZStack {
                                    Circle()
                                        .fill(figure.color.color)
                                        .frame(width: 28, height: 28)
                                    Text("\(index + 1)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.black)
                                }

                                Text(figure.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)

                                Spacer()

                                // Visibility
                                Button {
                                    toggleVisibility(figure.id)
                                } label: {
                                    Image(systemName: isVisible(figure.id) ? "eye.fill" : "eye.slash")
                                        .font(.caption)
                                        .foregroundStyle(isVisible(figure.id) ? .orange : .gray)
                                }

                                // Delete
                                if vm.figures.count > 1 {
                                    Button { vm.deleteFigure(figure.id) } label: {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                            .foregroundStyle(.red.opacity(0.6))
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(isSelected ? Color.orange.opacity(0.12) : ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(isSelected ? .orange.opacity(0.4) : .clear, lineWidth: 1)
                            )
                            .onTapGesture { vm.selectedFigureId = figure.id }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(ThemeManager.background.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ThemeManager.border, lineWidth: 0.5)
        )
        .padding(.horizontal, 4)
    }

    func isVisible(_ figureId: UUID) -> Bool {
        vm.frames[safe: vm.currentFrameIndex]?.figureStates.first { $0.figureId == figureId }?.visible ?? true
    }
    func toggleVisibility(_ figureId: UUID) {
        guard let idx = vm.frames[safe: vm.currentFrameIndex]?.figureStates.firstIndex(where: { $0.figureId == figureId }) else { return }
        vm.frames[vm.currentFrameIndex].figureStates[idx].visible.toggle()
    }
}

// MARK: - Compact Properties Panel (half-sheet)
struct CompactPropertiesPanel: View {
    @ObservedObject var vm: EditorViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            panelHeader("Properties", icon: "slider.horizontal.3", onClose: onClose)

            if let idx = vm.figures.firstIndex(where: { $0.id == vm.selectedFigureId }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Name
                        TextField("Name", text: $vm.figures[idx].name)
                            .stickDeathTextField()

                        // Line width
                        sliderRow(label: "Line Width", value: $vm.figures[idx].lineWidth, range: 1...10, step: 0.5, unit: "pt")

                        // Head size
                        sliderRow(label: "Head Size", value: $vm.figures[idx].headRadius, range: 5...30, step: 1, unit: "")

                        // Canvas settings
                        HStack {
                            Image(systemName: vm.showOnionSkin ? "square.stack.3d.up.fill" : "square.stack.3d.up.slash")
                                .foregroundStyle(vm.showOnionSkin ? .orange : .gray)
                            Toggle("Onion Skin", isOn: $vm.showOnionSkin)
                                .tint(.orange).font(.subheadline)
                        }
                    }
                    .padding(12)
                }
            } else {
                emptyState(icon: "hand.tap", message: "Select a figure", hint: "Tap a figure on the canvas or open Layers")
            }
        }
        .background(ThemeManager.background.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ThemeManager.border, lineWidth: 0.5))
        .padding(.horizontal, 4)
    }

    func sliderRow(label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, step: CGFloat, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.bold()).foregroundStyle(ThemeManager.textSecondary)
                Spacer()
                Text("\(String(format: step >= 1 ? "%.0f" : "%.1f", value.wrappedValue))\(unit)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.orange)
            }
            Slider(value: value, in: range, step: step).tint(.orange)
        }
    }
}

// MARK: - Compact Color Panel (half-sheet — swatches + picker)
struct CompactColorPanel: View {
    @ObservedObject var vm: EditorViewModel
    let onClose: () -> Void

    private let presetColors: [Color] = [
        .white, .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink,
        Color(hex: "#FF4500"), Color(hex: "#00FF7F"), Color(hex: "#1E90FF"),
        Color(hex: "#FF1493"), Color(hex: "#FFD700"), Color(hex: "#00CED1"),
        Color(hex: "#9400D3"), Color(hex: "#FF6347"), Color(hex: "#7CFC00"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            panelHeader("Color", icon: "paintpalette", onClose: onClose)

            if let idx = vm.figures.firstIndex(where: { $0.id == vm.selectedFigureId }) {
                VStack(spacing: 16) {
                    // Current color preview
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(vm.figures[idx].color.color)
                            .frame(width: 48, height: 48)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.3), lineWidth: 1))

                        VStack(alignment: .leading) {
                            Text("Figure Color").font(.caption.bold())
                            Text(vm.figures[idx].name).font(.caption).foregroundStyle(ThemeManager.textSecondary)
                        }

                        Spacer()

                        ColorPicker("", selection: Binding(
                            get: { vm.figures[idx].color.color },
                            set: { vm.figures[idx].color = CodableColor($0) }
                        ))
                        .labelsHidden()
                    }
                    .padding(.horizontal, 12)

                    // Swatch grid (Illustrator-style)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 9), spacing: 6) {
                        ForEach(Array(presetColors.enumerated()), id: \.offset) { _, color in
                            Button {
                                vm.figures[idx].color = CodableColor(color)
                            } label: {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(color)
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(vm.figures[idx].color.color == color ? .white : .white.opacity(0.1), lineWidth: vm.figures[idx].color.color == color ? 2 : 0.5)
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.vertical, 12)
            } else {
                emptyState(icon: "paintpalette", message: "Select a figure", hint: "Choose a figure to change its color")
            }
        }
        .background(ThemeManager.background.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ThemeManager.border, lineWidth: 0.5))
        .padding(.horizontal, 4)
    }
}

// MARK: - Compact Timeline Panel (half-sheet — full frame management)
struct CompactTimelinePanel: View {
    @ObservedObject var vm: EditorViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            panelHeader("Timeline", icon: "film.stack", onClose: onClose) {
                HStack(spacing: 8) {
                    Button { vm.addFrame() } label: {
                        Label("Add", systemImage: "plus.rectangle").font(.caption.bold()).foregroundStyle(.orange)
                    }
                    Button { vm.duplicateFrame() } label: {
                        Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            // Playback controls
            HStack(spacing: 20) {
                Button { vm.currentFrameIndex = 0 } label: { Image(systemName: "backward.end.fill").font(.caption) }
                Button { vm.currentFrameIndex = max(0, vm.currentFrameIndex - 1) } label: { Image(systemName: "backward.fill").font(.caption) }
                Button { vm.togglePlay() } label: {
                    Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2).foregroundStyle(.orange)
                }
                Button { vm.currentFrameIndex = min(vm.frames.count - 1, vm.currentFrameIndex + 1) } label: { Image(systemName: "forward.fill").font(.caption) }
                Button { vm.currentFrameIndex = vm.frames.count - 1 } label: { Image(systemName: "forward.end.fill").font(.caption) }
            }
            .padding(.vertical, 8)

            // Frame grid
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(vm.frames.enumerated()), id: \.element.id) { index, frame in
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(index == vm.currentFrameIndex ? Color.orange.opacity(0.2) : ThemeManager.surface)
                                    .frame(width: 56, height: 56)
                                    .overlay(
                                        VStack(spacing: 2) {
                                            Image(systemName: "figure.stand")
                                                .font(.system(size: 18))
                                                .foregroundStyle(index == vm.currentFrameIndex ? .orange : .gray)
                                            Text("\(frame.figureStates.filter(\.visible).count) fig")
                                                .font(.system(size: 8))
                                                .foregroundStyle(.gray)
                                        }
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(index == vm.currentFrameIndex ? .orange : .clear, lineWidth: 2)
                                    )

                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                                    .foregroundStyle(index == vm.currentFrameIndex ? .orange : .gray)
                            }
                            .id(index)
                            .onTapGesture { vm.currentFrameIndex = index }
                            .contextMenu {
                                Button { vm.duplicateFrame() } label: { Label("Duplicate", systemImage: "doc.on.doc") }
                                if vm.frames.count > 1 {
                                    Button(role: .destructive) { vm.deleteFrame() } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .onChange(of: vm.currentFrameIndex) { _, idx in
                    withAnimation { proxy.scrollTo(idx, anchor: .center) }
                }
            }
            .padding(.bottom, 8)
        }
        .background(ThemeManager.background.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ThemeManager.border, lineWidth: 0.5))
        .padding(.horizontal, 4)
    }
}

// MARK: - Sound Timeline Strip (thin visualization)
struct SoundTimelineStrip: View {
    @ObservedObject var vm: EditorViewModel
    var body: some View {
        if !vm.soundClips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(vm.soundClips) { clip in
                        HStack(spacing: 3) {
                            Image(systemName: "speaker.wave.2.fill").font(.system(size: 8))
                            Text(clip.name).font(.system(size: 9)).lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(soundColor(clip.category).opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contextMenu {
                            Button(role: .destructive) { vm.removeSoundClip(clip.id) } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 28)
            .background(Color.black.opacity(0.6))
        }
    }

    func soundColor(_ cat: String) -> Color {
        switch cat {
        case "combat": return .red; case "movement": return .cyan; case "voices": return .orange
        case "environment_sfx": return .green; case "music_stings": return .purple
        default: return .gray
        }
    }
}

// MARK: - Watermark Badge
struct WatermarkBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "figure.run").font(.system(size: 8))
            Text("StickDeath ∞").font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(.white.opacity(0.35))
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Shared Panel Helpers
func panelHeader(_ title: String, icon: String, onClose: @escaping () -> Void, @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
    HStack {
        // Drag handle
        Capsule().fill(.gray.opacity(0.4)).frame(width: 36, height: 4)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
    .overlay(
        HStack {
            Image(systemName: icon).font(.caption).foregroundStyle(.orange)
            Text(title).font(.subheadline.bold())
            Spacer()
            trailing()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.gray)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    )
    .padding(.bottom, 8)
}

func emptyState(icon: String, message: String, hint: String) -> some View {
    VStack(spacing: 8) {
        Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.orange.opacity(0.4))
        Text(message).font(.subheadline.weight(.medium))
        Text(hint).font(.caption).foregroundStyle(ThemeManager.textSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
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
                    Image(systemName: "square.and.arrow.down.fill").font(.system(size: 40)).foregroundStyle(.orange)
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
                            .tint(.orange).padding().background(ThemeManager.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            HStack(spacing: 10) {
                                Image(systemName: "seal.fill").foregroundStyle(.orange)
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
                    .frame(maxWidth: .infinity).padding(.vertical, 16).background(.orange)
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

// MARK: - TextField Style (shared from ThemeManager)
extension View {
    /// Only define stickDeathTextField here if ThemeManager doesn't already have it.
    /// If ThemeManager.swift already defines this modifier, delete this extension.
}
