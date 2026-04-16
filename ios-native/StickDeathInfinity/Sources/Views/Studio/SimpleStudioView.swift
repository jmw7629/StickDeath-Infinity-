// SimpleStudioView.swift
// FlipaClip-style animation studio for Free & Pro users
// Clean layout: top bar, floating toolbar pill, white canvas, properties bar,
// frame strip (timeline), bottom action bar
// Icons: black with per-tool accent colors, embossed 3D effect

import SwiftUI
import PhotosUI

// MARK: - Tool Colors (distinct per tool)
private struct ToolPalette {
    static let brush   = Color(hex: "ff2d55")   // Pink
    static let eraser  = Color(hex: "ff9500")   // Orange
    static let lasso   = Color(hex: "5856d6")   // Indigo
    static let fill    = Color(hex: "34c759")   // Green
    static let text    = Color(hex: "007aff")   // Blue
    static let shapes  = Color(hex: "af52de")   // Purple
    static let audio   = Color(hex: "ff9500")   // Orange
    static let undo    = Color(hex: "8e8e93")   // Gray
    static let redo    = Color(hex: "8e8e93")   // Gray
    static let copy    = Color(hex: "5ac8fa")   // Cyan
    static let paste   = Color(hex: "5ac8fa")   // Cyan
    static let layer   = Color(hex: "ffcc00")   // Yellow
}

struct SimpleStudioView: View {
    @StateObject var vm: EditorViewModel
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @State private var showLayersSheet = false
    @State private var showExportSheet = false
    @State private var showProjectSettings = false
    @State private var showSaveConfirmation = false

    // Simplified tool set for Free/Pro
    enum SimpleTool: String, CaseIterable {
        case brush, eraser, lasso, fill, text
        var icon: String {
            switch self {
            case .brush:  return "paintbrush.fill"
            case .eraser: return "eraser.fill"
            case .lasso:  return "lasso"
            case .fill:   return "paintbrush.pointed.fill"
            case .text:   return "textformat"
            }
        }
        var accent: Color {
            switch self {
            case .brush:  return ToolPalette.brush
            case .eraser: return ToolPalette.eraser
            case .lasso:  return ToolPalette.lasso
            case .fill:   return ToolPalette.fill
            case .text:   return ToolPalette.text
            }
        }
        var drawingTool: DrawingTool {
            switch self {
            case .brush:  return .pencil
            case .eraser: return .eraser
            case .lasso:  return .lasso
            case .fill:   return .fill
            case .text:   return .text
            }
        }
    }

    @State private var activeTool: SimpleTool = .brush

    var body: some View {
        ZStack {
            Color(hex: "0a0a0f").ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                toolbarPill
                canvasArea
                propertiesBar
                frameStrip
                bottomActionBar
            }

            // Text input overlay
            if vm.drawState.showTextInput { textInputOverlay }

            // Save toast
            if showSaveConfirmation {
                VStack {
                    HStack {
                        Spacer()
                        Label("Saved ✓".loc, systemImage: "checkmark.circle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(hex: "111118"))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.green.opacity(0.3), lineWidth: 1))
                            .padding(.top, 52)
                            .padding(.trailing, 8)
                    }
                    Spacer()
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            // Saving indicator
            if vm.isSaving {
                VStack {
                    HStack {
                        Spacer()
                        Label("Saving…".loc, systemImage: "icloud.and.arrow.up")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.top, 52)
                            .padding(.trailing, 8)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // Watermark for free users
            if !auth.isPro {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        WatermarkPreview()
                            .padding(.trailing, 12)
                            .padding(.bottom, 160)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .sheet(isPresented: $showLayersSheet) {
            LayersSheet(vm: vm)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showExportSheet) {
            ExportOptionsSheet(vm: vm)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showProjectSettings) {
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
        .onChange(of: activeTool) { newTool in
            vm.mode = .draw
            vm.drawState.tool = newTool.drawingTool
        }
        .task { await vm.loadProject() }
        .onDisappear { Task { await vm.saveProject() } }
    }

    // MARK: - Drawing Gesture
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

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 1. TOP BAR
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    var topBar: some View {
        HStack(spacing: 8) {
            // Back
            Button { dismiss() } label: {
                embossedIcon("chevron.left", color: .white, size: 16)
                    .frame(width: 36, height: 36)
            }

            // Title + metadata
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.project.title)
                    .font(.custom("SpecialElite-Regular", size: 15))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(vm.project.fps ?? 12) FPS · \(vm.frames.count) " + "frames".loc)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: "72728a"))
            }
            .onTapGesture { showProjectSettings = true }

            Spacer()

            // Save button
            Button {
                Task {
                    await vm.saveProject()
                    showSaveConfirmation = true
                    HapticManager.shared.buttonTap()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    showSaveConfirmation = false
                }
            } label: {
                embossedIcon("square.and.arrow.down.fill", color: .white, size: 16)
                    .frame(width: 34, height: 34)
            }

            // Export
            Button { showExportSheet = true } label: {
                embossedIcon("square.and.arrow.up", color: Color(hex: "dc2626"), size: 16)
                    .frame(width: 34, height: 34)
            }

            // More menu
            Menu {
                Button { showProjectSettings = true } label: {
                    Label("Project Settings".loc, systemImage: "gear")
                }
                Button { vm.showFramesViewer = true } label: {
                    Label("All Frames".loc, systemImage: "rectangle.split.3x3")
                }
                Button { vm.showImagePicker = true } label: {
                    Label("Import Photo".loc, systemImage: "photo.badge.plus")
                }
                Divider()
                Button {
                    Task { await vm.saveProject() }
                } label: {
                    Label("Save Now".loc, systemImage: "square.and.arrow.down")
                }
            } label: {
                embossedIcon("ellipsis", color: .white.opacity(0.6), size: 16)
                    .frame(width: 34, height: 34)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(Color(hex: "111118"))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 2. TOOLBAR PILL
    // Floating pill with embossed 3D icons, distinct accent per tool
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    var toolbarPill: some View {
        HStack(spacing: 0) {
            Spacer()
            HStack(spacing: 2) {
                // Grip handle
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: "444444"))
                    .frame(width: 28, height: 40)

                // Main tools
                ForEach(SimpleTool.allCases, id: \.self) { tool in
                    Button {
                        activeTool = tool
                        HapticManager.shared.buttonTap()
                    } label: {
                        toolPillIcon(tool)
                    }
                }

                // Shapes overflow
                Menu {
                    Button {
                        vm.drawState.tool = .line
                        vm.mode = .draw
                    } label: { Label("Line".loc, systemImage: "line.diagonal") }
                    Button {
                        vm.drawState.tool = .rectangle
                        vm.mode = .draw
                    } label: { Label("Rectangle".loc, systemImage: "rectangle") }
                    Button {
                        vm.drawState.tool = .circle
                        vm.mode = .draw
                    } label: { Label("Circle".loc, systemImage: "circle") }
                    Button {
                        vm.drawState.tool = .arrow
                        vm.mode = .draw
                    } label: { Label("Arrow".loc, systemImage: "arrow.up.right") }
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(hex: "1e1e2e"))
                            .frame(width: 42, height: 42)
                        embossedIcon("ellipsis", color: ToolPalette.shapes, size: 18)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color(hex: "141420"))
                    .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(Color(hex: "2a2a3a").opacity(0.4), lineWidth: 1)
                    )
            )
            Spacer()
        }
        .padding(.vertical, 6)
        .background(Color(hex: "0a0a0f").opacity(0.01)) // Transparent bg
    }

    // Single tool button in the pill — embossed 3D look
    func toolPillIcon(_ tool: SimpleTool) -> some View {
        let isActive = activeTool == tool
        return ZStack {
            // Background — raised when active
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    isActive
                        ? LinearGradient(
                            colors: [tool.accent, tool.accent.opacity(0.7)],
                            startPoint: .top, endPoint: .bottom)
                        : LinearGradient(
                            colors: [Color(hex: "1e1e2e"), Color(hex: "161622")],
                            startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 42, height: 42)
                .shadow(
                    color: isActive ? tool.accent.opacity(0.4) : .black.opacity(0.5),
                    radius: isActive ? 4 : 2,
                    x: 0, y: isActive ? 1 : 2
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isActive
                                ? Color.white.opacity(0.3)
                                : Color(hex: "333344").opacity(0.5),
                            lineWidth: 1
                        )
                )

            // Icon — embossed effect via shadow + highlight offset
            ZStack {
                // Dark shadow underneath (inner bevel)
                Image(systemName: tool.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.6))
                    .offset(x: 0, y: 1.5)

                // Light highlight on top (raised look)
                Image(systemName: tool.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(
                        isActive
                            ? Color.white.opacity(0.2)
                            : Color.white.opacity(0.08)
                    )
                    .offset(x: 0, y: -0.5)

                // Main icon
                Image(systemName: tool.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(
                        isActive
                            ? .white
                            : tool.accent
                    )
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 3. CANVAS AREA (WHITE)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    var canvasArea: some View {
        ZStack {
            // White canvas background
            RoundedRectangle(cornerRadius: 4)
                .fill(.white)
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 2)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)

            CanvasView(vm: vm)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .gesture(drawGesture)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "0a0a0f"))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 4. PROPERTIES BAR
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    var propertiesBar: some View {
        HStack(spacing: 12) {
            // Color swatch
            ColorPicker("", selection: $vm.drawState.strokeColor, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 28, height: 28)

            // Brush size display
            Text("\(Int(vm.drawState.strokeWidth))")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 24)

            // Brush size slider
            Slider(value: $vm.drawState.strokeWidth, in: 1...80, step: 1)
                .tint(activeTool.accent)

            // Onion skin toggle — embossed
            Button {
                vm.showOnionSkin.toggle()
                HapticManager.shared.buttonTap()
            } label: {
                embossedIcon(
                    vm.showOnionSkin ? "eye.fill" : "eye.slash",
                    color: vm.showOnionSkin ? .white : Color(hex: "555555"),
                    size: 15
                )
                .frame(width: 30, height: 30)
                .background(
                    vm.showOnionSkin
                        ? Color.white.opacity(0.1)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Grid toggle — embossed
            Button {
                vm.showGrid.toggle()
                HapticManager.shared.buttonTap()
            } label: {
                embossedIcon(
                    "grid",
                    color: vm.showGrid ? .white : Color(hex: "555555"),
                    size: 15
                )
                .frame(width: 30, height: 30)
                .background(
                    vm.showGrid
                        ? Color.white.opacity(0.1)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(hex: "111118"))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 5. FRAME STRIP (Timeline)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    var frameStrip: some View {
        HStack(spacing: 6) {
            // ◀ Prev
            Button {
                if vm.currentFrameIndex > 0 {
                    vm.currentFrameIndex -= 1
                    HapticManager.shared.buttonTap()
                }
            } label: {
                embossedIcon("chevron.left", color: Color(hex: "999999"), size: 13)
                    .frame(width: 28, height: 28)
            }

            // ▶ Play / ⏸ Pause
            Button {
                vm.togglePlay()
                HapticManager.shared.buttonTap()
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            vm.isPlaying
                                ? LinearGradient(colors: [Color(hex: "dc2626"), Color(hex: "b91c1c")],
                                                startPoint: .top, endPoint: .bottom)
                                : LinearGradient(colors: [Color(hex: "2a2a3a"), Color(hex: "1a1a24")],
                                                startPoint: .top, endPoint: .bottom)
                        )
                        .frame(width: 34, height: 34)
                        .shadow(color: vm.isPlaying ? Color(hex: "dc2626").opacity(0.4) : .black.opacity(0.4),
                                radius: 3, x: 0, y: 2)
                        .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                    embossedIcon(vm.isPlaying ? "pause.fill" : "play.fill", color: .white, size: 13)
                }
            }

            // Next ▶
            Button {
                if vm.currentFrameIndex < vm.frames.count - 1 {
                    vm.currentFrameIndex += 1
                    HapticManager.shared.buttonTap()
                }
            } label: {
                embossedIcon("chevron.right", color: Color(hex: "999999"), size: 13)
                    .frame(width: 28, height: 28)
            }

            // Separator
            RoundedRectangle(cornerRadius: 1)
                .fill(Color(hex: "2a2a3a"))
                .frame(width: 1, height: 24)

            // Frame thumbnails
            ScrollView(.horizontal, showsIndicators: false) {
                ScrollViewReader { proxy in
                    HStack(spacing: 4) {
                        ForEach(vm.frames.indices, id: \.self) { i in
                            Button {
                                vm.currentFrameIndex = i
                                HapticManager.shared.buttonTap()
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color(hex: "0a0a0f"))
                                        .frame(width: 48, height: 40)
                                    Text("\(i + 1)")
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundStyle(
                                            vm.currentFrameIndex == i ? .white : Color(hex: "555555")
                                        )
                                }
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(
                                            vm.currentFrameIndex == i
                                                ? Color(hex: "dc2626")
                                                : Color(hex: "2a2a3a"),
                                            lineWidth: vm.currentFrameIndex == i ? 2 : 1
                                        )
                                )
                            }
                            .id(i)
                            .contextMenu {
                                Button {
                                    vm.currentFrameIndex = i
                                    vm.duplicateFrame()
                                } label: {
                                    Label("Duplicate".loc, systemImage: "doc.on.doc")
                                }
                                Button {
                                    vm.currentFrameIndex = i
                                    vm.addFrame()
                                } label: {
                                    Label("Insert After".loc, systemImage: "plus")
                                }
                                if vm.frames.count > 1 {
                                    Divider()
                                    Button(role: .destructive) {
                                        vm.currentFrameIndex = i
                                        vm.deleteFrame()
                                    } label: {
                                        Label("Delete".loc, systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .onChange(of: vm.currentFrameIndex) { idx in
                        withAnimation { proxy.scrollTo(idx, anchor: .center) }
                    }
                }
            }

            // Separator
            RoundedRectangle(cornerRadius: 1)
                .fill(Color(hex: "2a2a3a"))
                .frame(width: 1, height: 24)

            // Add frame
            Button {
                vm.addFrame()
                HapticManager.shared.buttonTap()
            } label: {
                embossedIcon("plus", color: Color(hex: "999999"), size: 14)
                    .frame(width: 32, height: 32)
            }

            // Frame counter
            Text("\(vm.currentFrameIndex + 1)/\(vm.frames.count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(hex: "555555"))
                .frame(width: 32)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(hex: "111118"))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 6. BOTTOM ACTION BAR
    // Embossed 3D icons with distinct per-action colors
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    var bottomActionBar: some View {
        HStack(spacing: 0) {
            actionButton(icon: "music.note", label: "AUDIO",
                         color: ToolPalette.audio) {
                // Audio — placeholder
            }
            actionButton(icon: "arrow.uturn.backward", label: "UNDO",
                         color: ToolPalette.undo,
                         disabled: vm.undoStack.isEmpty) {
                vm.undo()
            }
            actionButton(icon: "arrow.uturn.forward", label: "REDO",
                         color: ToolPalette.redo,
                         disabled: vm.redoStack.isEmpty) {
                vm.redo()
            }
            actionButton(icon: "doc.on.doc", label: "COPY",
                         color: ToolPalette.copy) {
                vm.copiedFrameData = vm.frames[safe: vm.currentFrameIndex]
            }
            actionButton(icon: "doc.on.clipboard", label: "PASTE",
                         color: ToolPalette.paste,
                         disabled: vm.copiedFrameData == nil) {
                vm.pasteFrameAfterCurrent()
            }
            actionButton(icon: "square.3.layers.3d", label: "LAYER",
                         color: ToolPalette.layer,
                         badge: 1) {
                showLayersSheet = true
            }
        }
        .padding(.vertical, 6)
        .padding(.bottom, 2)
        .background(
            LinearGradient(
                colors: [Color(hex: "111118"), Color(hex: "0e0e14")],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    func actionButton(icon: String, label: String, color: Color,
                       disabled: Bool = false, badge: Int? = nil,
                       action: @escaping () -> Void) -> some View {
        Button(action: {
            action()
            HapticManager.shared.buttonTap()
        }) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    // Embossed icon
                    ZStack {
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.black.opacity(0.5))
                            .offset(y: 1.5)
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.08))
                            .offset(y: -0.5)
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(disabled ? Color(hex: "333333") : color)
                    }

                    if let badge = badge {
                        Text("\(badge)")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background(Color(hex: "ff2d55"))
                            .clipShape(Circle())
                            .offset(x: 6, y: -4)
                    }
                }
                Text(label)
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(disabled ? Color(hex: "333333") : color.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .disabled(disabled)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - EMBOSSED ICON HELPER
    // Creates a 3D "raised" look via layered shadows + highlight
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    func embossedIcon(_ systemName: String, color: Color, size: CGFloat) -> some View {
        ZStack {
            // Dark drop shadow
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.black.opacity(0.5))
                .offset(y: 1.5)
            // Light highlight
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.1))
                .offset(y: -0.5)
            // Main color
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)
        }
    }

    // MARK: - Text Input Overlay
    var textInputOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                TextField("Type text…".loc, text: $vm.drawState.textInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                Button("Add".loc) {
                    vm.commitTextElement(vm.drawState.textInput)
                    HapticManager.shared.buttonTap()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "dc2626"))
                Button("Cancel".loc) {
                    vm.drawState.showTextInput = false
                    vm.drawState.textInput = ""
                }
                .foregroundStyle(.gray)
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            .padding(.bottom, 160)
        }
    }
}
