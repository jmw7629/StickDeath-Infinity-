// StudioView.swift
// Animation Studio — Illustrator layout × FlipaClip simplicity
// v6: Clean rebuild matching Replit web version
// Left floating toolbar, bottom timeline, proper safe areas, bold colors

import SwiftUI

// ═══════════════════════════════════════════════════════
// MARK: - StudioView
// ═══════════════════════════════════════════════════════
struct StudioView: View {
    @StateObject var vm: EditorViewModel
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) var hSize

    // Panel state — only one panel open at a time
    @State private var activePanel: PanelType?
    @State private var showPublish = false
    @State private var showAssets = false
    @State private var showTooltip: String?

    enum PanelType: Equatable {
        case layers, properties, ai
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if hSize == .regular {
                wideLayout
            } else {
                compactLayout
            }

            // Panel overlay (slides up from bottom)
            if let panel = activePanel {
                panelOverlay(panel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Tooltip overlay
            if let tip = showTooltip {
                tooltipBubble(tip)
            }
        }
        .navigationBarHidden(true)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: activePanel)
        .sheet(isPresented: $showPublish) { PublishSheet(vm: vm) }
        .sheet(isPresented: $showAssets) {
            AssetBrowserView(
                onObjectSelected: { vm.addPlacedObject(asset: $0) },
                onSoundSelected: { vm.addSoundClip(asset: $0) }
            )
        }
        .task { await vm.loadProject() }
        .onDisappear { Task { await vm.saveProject() } }
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Compact Layout (iPhone)
    // ═══════════════════════════════════════════════════════
    var compactLayout: some View {
        VStack(spacing: 0) {
            topBar
            canvasWithToolbar
            bottomStack
        }
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Wide Layout (iPad / Mac)
    // ═══════════════════════════════════════════════════════
    var wideLayout: some View {
        VStack(spacing: 0) {
            topBar

            HStack(spacing: 0) {
                // Left panel — Layers
                if activePanel == .layers {
                    LayersPanel(vm: vm)
                        .frame(width: 260)
                        .transition(.move(edge: .leading))
                }

                // Center — Canvas
                VStack(spacing: 0) {
                    canvasWithToolbar
                    TimelinePanel(vm: vm)
                        .frame(height: 120)
                }

                // Right panel — Properties
                if activePanel == .properties {
                    PropertiesPanel(vm: vm)
                        .frame(width: 280)
                        .transition(.move(edge: .trailing))
                }
            }

            wideBottomBar
        }
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Top Bar
    // ═══════════════════════════════════════════════════════
    var topBar: some View {
        HStack(spacing: 12) {
            // Back button — always visible, high contrast
            Button {
                Task { await vm.saveProject() }
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.body.bold())
                    Text("Back")
                        .font(.subheadline.bold())
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.15))
                .clipShape(Capsule())
            }

            // Project title
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.project.title)
                    .font(ThemeManager.headline(size: 18))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                Text("\(vm.frames.count) frames · \(vm.figures.count) figures")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(white: 0.5))
            }

            Spacer()

            // Undo / Redo
            HStack(spacing: 6) {
                circleButton("arrow.uturn.backward", enabled: !vm.undoStack.isEmpty) {
                    vm.undo()
                }
                circleButton("arrow.uturn.forward", enabled: !vm.redoStack.isEmpty) {
                    vm.redo()
                }
            }

            // Save status
            if vm.isSaving {
                HStack(spacing: 4) {
                    ProgressView().tint(.orange).scaleEffect(0.6)
                    Text("Saving").font(.caption2).foregroundStyle(.gray)
                }
                .transition(.opacity)
            }

            // Publish
            Button { showPublish = true } label: {
                Image(systemName: "square.and.arrow.up.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(Color.orange)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.06))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.orange.opacity(0.2)).frame(height: 1)
        }
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Canvas + Floating Toolbar
    // ═══════════════════════════════════════════════════════
    var canvasWithToolbar: some View {
        ZStack(alignment: .topLeading) {
            // Full canvas
            CanvasView(vm: vm)
                .gesture(canvasGestures)
                .clipped()

            // Floating tool palette (left edge, like Replit)
            floatingToolPalette
                .padding(.top, 16)
                .padding(.leading, 10)

            // Mode indicator (top-right)
            VStack {
                HStack {
                    Spacer()
                    modeIndicator
                        .padding(.top, 10)
                        .padding(.trailing, 12)
                }
                Spacer()
            }
        }
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Floating Tool Palette (Left, Replit-style)
    // ═══════════════════════════════════════════════════════
    var floatingToolPalette: some View {
        VStack(spacing: 4) {
            // Selection / Pose tool
            paletteButton(
                icon: "cursorarrow",
                label: "Pose",
                active: vm.mode == .pose,
                tip: "Drag joints to pose figures"
            ) { vm.mode = .pose }

            // Move / Pan tool
            paletteButton(
                icon: "hand.raised",
                label: "Move",
                active: vm.mode == .move,
                tip: "Pan and zoom the canvas"
            ) { vm.mode = .move }

            // Draw tool
            paletteButton(
                icon: "paintbrush.pointed",
                label: "Draw",
                active: vm.mode == .draw,
                tip: "Freehand draw on canvas"
            ) { vm.mode = .draw }

            // Divider
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 28, height: 1)
                .padding(.vertical, 2)

            // Add Figure
            paletteButton(
                icon: "person.badge.plus",
                label: "Figure",
                active: false,
                tip: "Add a new stick figure"
            ) { vm.addFigure() }

            // Assets
            paletteButton(
                icon: "square.grid.2x2",
                label: "Assets",
                active: false,
                tip: "Browse objects & sounds"
            ) { showAssets = true }

            // Onion Skin toggle
            paletteButton(
                icon: vm.showOnionSkin ? "square.stack.3d.up.fill" : "square.stack.3d.up.slash",
                label: "Onion",
                active: vm.showOnionSkin,
                tip: vm.showOnionSkin ? "Hide previous frame ghost" : "Show previous frame ghost"
            ) { vm.showOnionSkin.toggle() }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial.opacity(0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 8, x: 2, y: 2)
        )
    }

    // Single palette button
    func paletteButton(icon: String, label: String, active: Bool, tip: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            // Flash tooltip briefly
            showTooltip = tip
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if showTooltip == tip { showTooltip = nil }
            }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: active ? .bold : .regular))
                    .frame(width: 40, height: 30)
                Text(label)
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(active ? .white : Color(white: 0.6))
            .frame(width: 48, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Color.orange : Color.clear)
            )
        }
    }

    // Mode indicator (top-right corner of canvas)
    var modeIndicator: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.orange).frame(width: 6, height: 6)
            Text(vm.mode == .pose ? "POSE" : vm.mode == .move ? "MOVE" : "DRAW")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.6))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.orange.opacity(0.3), lineWidth: 1))
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Bottom Stack (iPhone)
    // ═══════════════════════════════════════════════════════
    var bottomStack: some View {
        VStack(spacing: 0) {
            playbackBar
            frameStrip
            actionBar
        }
        .background(Color(white: 0.06))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.orange.opacity(0.15)).frame(height: 1)
        }
    }

    // ── Playback Controls ──
    var playbackBar: some View {
        HStack(spacing: 0) {
            // Transport
            HStack(spacing: 12) {
                transportButton("backward.end.fill") { vm.currentFrameIndex = 0 }
                transportButton("backward.fill") { vm.currentFrameIndex = max(0, vm.currentFrameIndex - 1) }

                // Play / Pause — larger, orange
                Button { vm.togglePlay() } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.orange)
                        .frame(width: 40, height: 40)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.orange.opacity(0.4), lineWidth: 1))
                }

                transportButton("forward.fill") { vm.currentFrameIndex = min(vm.frames.count - 1, vm.currentFrameIndex + 1) }
                transportButton("forward.end.fill") { vm.currentFrameIndex = vm.frames.count - 1 }
            }

            Spacer()

            // Frame info
            Text("\(vm.currentFrameIndex + 1)/\(vm.frames.count)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(.orange)
            Text("@ \(vm.project.fps ?? 24)fps")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color(white: 0.5))
                .padding(.leading, 2)

            Spacer()

            // Frame actions
            HStack(spacing: 10) {
                Button { vm.addFrame() } label: {
                    Image(systemName: "plus.rectangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button { vm.duplicateFrame() } label: {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Button { vm.deleteFrame() } label: {
                    Image(systemName: "trash.fill")
                        .font(.caption)
                        .foregroundStyle(vm.frames.count > 1 ? .red.opacity(0.7) : .gray.opacity(0.3))
                }
                .disabled(vm.frames.count <= 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    func transportButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    // ── Frame Strip ──
    var frameStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(vm.frames.enumerated()), id: \.element.id) { idx, frame in
                        let selected = idx == vm.currentFrameIndex
                        let figCount = frame.figureStates.filter(\.visible).count

                        VStack(spacing: 2) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selected ? Color.orange.opacity(0.2) : Color(white: 0.1))
                                    .frame(width: 46, height: 46)

                                // Mini figure preview
                                Image(systemName: figCount > 0 ? "figure.stand" : "rectangle.dashed")
                                    .font(.system(size: figCount > 0 ? 16 : 14))
                                    .foregroundStyle(selected ? .orange : Color(white: 0.4))
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(selected ? Color.orange : Color(white: 0.2), lineWidth: selected ? 2 : 0.5)
                            )

                            Text("\(idx + 1)")
                                .font(.system(size: 9, weight: .bold).monospacedDigit())
                                .foregroundStyle(selected ? .orange : Color(white: 0.4))
                        }
                        .id(idx)
                        .onTapGesture { vm.currentFrameIndex = idx }
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 62)
            .onChange(of: vm.currentFrameIndex) { _, newIdx in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(newIdx, anchor: .center) }
            }
        }
    }

    // ── Action Bar (bottom) ──
    var actionBar: some View {
        HStack(spacing: 0) {
            actionButton("square.3.layers.3d", "Layers", active: activePanel == .layers) {
                togglePanel(.layers)
            }
            actionButton("slider.horizontal.3", "Properties", active: activePanel == .properties) {
                togglePanel(.properties)
            }
            actionButton("sparkles", "AI", active: activePanel == .ai) {
                togglePanel(.ai)
            }

            Spacer()

            // Zoom controls
            HStack(spacing: 8) {
                Button { vm.canvasScale = max(0.3, vm.canvasScale - 0.25) } label: {
                    Image(systemName: "minus").font(.caption2.bold())
                }
                .foregroundStyle(.white)

                Text("\(Int(vm.canvasScale * 100))%")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.orange)
                    .frame(width: 36)

                Button { vm.canvasScale = min(3.0, vm.canvasScale + 0.25) } label: {
                    Image(systemName: "plus").font(.caption2.bold())
                }
                .foregroundStyle(.white)

                Button {
                    withAnimation(.easeOut(duration: 0.3)) {
                        vm.canvasScale = 1.0
                        vm.canvasOffset = .zero
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(white: 0.1))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(white: 0.2), lineWidth: 0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .padding(.bottom, 2)
    }

    func actionButton(_ icon: String, _ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: active ? .bold : .regular))
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(active ? .orange : Color(white: 0.55))
            .frame(width: 60, height: 42)
            .background(active ? Color.orange.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // Wide bottom bar (iPad)
    var wideBottomBar: some View {
        HStack(spacing: 16) {
            actionButton("square.3.layers.3d", "Layers", active: activePanel == .layers) { togglePanel(.layers) }
            actionButton("slider.horizontal.3", "Properties", active: activePanel == .properties) { togglePanel(.properties) }
            actionButton("sparkles", "AI Assist", active: activePanel == .ai) { togglePanel(.ai) }
            actionButton("square.grid.2x2", "Assets", active: false) { showAssets = true }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(white: 0.06))
    }

    func togglePanel(_ panel: PanelType) {
        withAnimation { activePanel = activePanel == panel ? nil : panel }
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Panel Overlay
    // ═══════════════════════════════════════════════════════
    @ViewBuilder
    func panelOverlay(_ panel: PanelType) -> some View {
        VStack(spacing: 0) {
            // Tap outside to dismiss
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { withAnimation { activePanel = nil } }

            // Panel card
            VStack(spacing: 0) {
                // Header bar with handle and close
                HStack {
                    // Drag handle
                    Capsule()
                        .fill(Color.gray.opacity(0.4))
                        .frame(width: 36, height: 4)

                    Spacer()

                    // Panel title
                    Text(panelTitle(panel))
                        .font(.caption.bold())
                        .foregroundStyle(.orange)

                    Spacer()

                    // Close
                    Button { withAnimation { activePanel = nil } } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color(white: 0.5))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)

                Divider().background(Color.orange.opacity(0.2))

                // Panel content
                Group {
                    switch panel {
                    case .layers:   layersContent
                    case .properties: propertiesContent
                    case .ai:       aiContent
                    }
                }
            }
            .frame(height: 320)
            .background(Color(white: 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.orange.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 20, y: -5)
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
        }
    }

    func panelTitle(_ panel: PanelType) -> String {
        switch panel {
        case .layers: return "LAYERS"
        case .properties: return "PROPERTIES"
        case .ai: return "AI ASSIST"
        }
    }

    // ── Layers Content ──
    var layersContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Add figure button
            HStack {
                Spacer()
                Button { vm.addFigure() } label: {
                    Label("Add Figure", systemImage: "plus.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if vm.figures.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "figure.stand")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange.opacity(0.3))
                    Text("No figures yet")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color(white: 0.5))
                    Text("Tap 'Add Figure' to get started")
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.35))
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(vm.figures.enumerated()), id: \.element.id) { idx, fig in
                            figureRow(fig, index: idx)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    func figureRow(_ fig: StickFigure, index: Int) -> some View {
        let selected = fig.id == vm.selectedFigureId
        return HStack(spacing: 10) {
            // Color indicator
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(fig.color.color.opacity(0.3))
                    .frame(width: 32, height: 32)
                Text("\(index + 1)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(fig.color.color)
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(fig.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Line: \(String(format: "%.0f", fig.lineWidth))pt")
                    .font(.caption2)
                    .foregroundStyle(Color(white: 0.5))
            }

            Spacer()

            // Visibility
            let visible = isVisible(fig.id)
            Button { toggleVisibility(fig.id) } label: {
                Image(systemName: visible ? "eye.fill" : "eye.slash")
                    .font(.caption)
                    .foregroundStyle(visible ? .orange : Color(white: 0.35))
                    .frame(width: 28, height: 28)
                    .background(Color(white: 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Delete
            if vm.figures.count > 1 {
                Button { vm.deleteFigure(fig.id) } label: {
                    Image(systemName: "trash.fill")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.orange.opacity(0.12) : Color(white: 0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
        .onTapGesture { vm.selectedFigureId = fig.id }
    }

    func isVisible(_ figureId: UUID) -> Bool {
        vm.frames[safe: vm.currentFrameIndex]?.figureStates.first { $0.figureId == figureId }?.visible ?? true
    }

    func toggleVisibility(_ figureId: UUID) {
        guard let stateIdx = vm.frames[safe: vm.currentFrameIndex]?.figureStates.firstIndex(where: { $0.figureId == figureId }) else { return }
        vm.frames[vm.currentFrameIndex].figureStates[stateIdx].visible.toggle()
    }

    // ── Properties Content ──
    var propertiesContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let idx = vm.figures.firstIndex(where: { $0.id == vm.selectedFigureId }) {
                    // Figure properties
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("FIGURE", icon: "figure.stand")

                        TextField("Figure name", text: $vm.figures[idx].name)
                            .stickDeathTextField()

                        sliderRow("Line Width", value: $vm.figures[idx].lineWidth, range: 1...10, step: 0.5, format: "%.1fpt")
                        sliderRow("Head Size", value: $vm.figures[idx].headRadius, range: 5...30, step: 1, format: "%.0f")

                        HStack {
                            Text("Color").font(.caption.bold()).foregroundStyle(Color(white: 0.6))
                            Spacer()
                            Circle()
                                .fill(vm.figures[idx].color.color)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                            ColorPicker("", selection: Binding(
                                get: { vm.figures[idx].color.color },
                                set: { vm.figures[idx].color = CodableColor($0) }
                            ))
                            .labelsHidden()
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.tap")
                            .font(.title2)
                            .foregroundStyle(.orange.opacity(0.4))
                        Text("Select a figure to edit")
                            .font(.subheadline)
                            .foregroundStyle(Color(white: 0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }

                Divider().background(Color(white: 0.2))

                // Canvas settings
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("CANVAS", icon: "rectangle.on.rectangle")

                    Toggle(isOn: $vm.showOnionSkin) {
                        HStack(spacing: 6) {
                            Image(systemName: vm.showOnionSkin ? "square.stack.3d.up.fill" : "square.stack.3d.up.slash")
                                .foregroundStyle(vm.showOnionSkin ? .orange : .gray)
                            Text("Onion Skin").font(.subheadline)
                        }
                    }
                    .tint(.orange)

                    sliderRow("Zoom", value: $vm.canvasScale, range: 0.3...3.0, step: 0.1, format: { "\(Int($0 * 100))%" })

                    Button {
                        withAnimation {
                            vm.canvasScale = 1.0
                            vm.canvasOffset = .zero
                        }
                    } label: {
                        Label("Reset View", systemImage: "arrow.counterclockwise")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.orange.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(16)
        }
    }

    // ── AI Content ──
    var aiContent: some View {
        VStack(spacing: 12) {
            if auth.isPro {
                // AI suggestion display
                if let suggestion = vm.aiSuggestion {
                    ScrollView {
                        Text(suggestion)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.purple.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .padding(.horizontal, 16)
                } else {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.title)
                            .foregroundStyle(.purple.opacity(0.5))
                        Text("Ask Spatter for help")
                            .font(.subheadline)
                            .foregroundStyle(Color(white: 0.5))
                        Text("Pose suggestions, animation tips, ideas")
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.35))
                    }
                    Spacer()
                }

                // Input
                AIPromptBar(vm: vm)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 32))
                        .foregroundStyle(.purple.opacity(0.5))
                    Text("AI Assist — Pro Feature")
                        .font(.headline)
                    Text("Upgrade to Pro ($4.99/mo) for AI-powered\nanimation help from Spatter")
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.5))
                        .multilineTextAlignment(.center)
                    Button {
                        // Trigger upgrade flow
                    } label: {
                        Text("Upgrade to Pro")
                            .font(.subheadline.bold())
                            .foregroundStyle(.black)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Color.orange)
                            .clipShape(Capsule())
                    }
                }
                Spacer()
            }
        }
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Tooltip Bubble
    // ═══════════════════════════════════════════════════════
    func tooltipBubble(_ text: String) -> some View {
        VStack {
            HStack {
                Text(text)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.orange.opacity(0.9))
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 6)
                    .padding(.leading, 70)
                    .padding(.top, 60)
                Spacer()
            }
            Spacer()
        }
        .allowsHitTesting(false)
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
        .animation(.easeOut(duration: 0.2), value: showTooltip)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Helpers
    // ═══════════════════════════════════════════════════════
    func circleButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(enabled ? .white : Color(white: 0.25))
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(enabled ? 0.08 : 0.03))
                .clipShape(Circle())
        }
        .disabled(!enabled)
    }

    func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(.orange)
            Text(title).font(.caption.bold()).foregroundStyle(Color(white: 0.5))
        }
    }

    func sliderRow(_ label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, step: CGFloat, format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.bold()).foregroundStyle(Color(white: 0.6))
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.orange)
            }
            Slider(value: value, in: range, step: step)
                .tint(.orange)
        }
    }

    func sliderRow(_ label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, step: CGFloat, format: @escaping (CGFloat) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.bold()).foregroundStyle(Color(white: 0.6))
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.orange)
            }
            Slider(value: value, in: range, step: step)
                .tint(.orange)
        }
    }

    var canvasGestures: some Gesture {
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

// ═══════════════════════════════════════════════════════
// MARK: - AI Prompt Input Bar
// ═══════════════════════════════════════════════════════
struct AIPromptBar: View {
    @ObservedObject var vm: EditorViewModel
    @State private var prompt = ""
    @State private var loading = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.purple)

            TextField("Ask Spatter anything...", text: $prompt)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .tint(.orange)

            Button {
                guard !prompt.isEmpty else { return }
                loading = true
                let p = prompt
                prompt = ""
                Task {
                    await vm.requestAIAssist(prompt: p)
                    loading = false
                }
            } label: {
                if loading {
                    ProgressView().tint(.purple).scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(prompt.isEmpty ? Color(white: 0.3) : .orange)
                }
            }
            .disabled(prompt.isEmpty || loading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.purple.opacity(0.3), lineWidth: 1)
        )
    }
}
