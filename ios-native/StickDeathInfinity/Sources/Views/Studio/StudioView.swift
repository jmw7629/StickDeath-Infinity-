// StudioView.swift
// Main animation studio — pixel-perfect match to StickDeath Infinity reference design
// Layout: Top bar → Canvas → Tool settings → Frame strip → Action bar
// Plus floating toolbar, color picker, layer manager, settings overlays

import SwiftUI
import PhotosUI

struct StudioView: View {
    @StateObject var vm: EditorViewModel
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss

    // Panel state
    @State private var activePanel: StudioPanel = .none
    @State private var showPublishSheet = false

    var body: some View {
        ZStack {
            // Full-screen dark background
            Color(hex: "0a0a0a").ignoresSafeArea()

            // ── Main Layout ──
            VStack(spacing: 0) {
                topBar
                canvasArea
                frameStrip
                actionBar
            }

            // ── Floating Toolbar (movable white pill) ──
            FloatingToolbar(vm: vm, activePanel: $activePanel)

            // ── Bottom Sheet Panels ──
            if activePanel == .none && vm.mode == .draw {
                ToolSettingsSheet(vm: vm)
            }
            if activePanel == .colorPicker {
                StudioColorPicker(vm: vm)
            }
            if activePanel == .layers {
                StudioLayerManager(vm: vm)
            }
            if activePanel == .settings {
                StudioSettingsMenu(vm: vm, activePanel: $activePanel)
            }

            // ── Full-Screen Overlays ──
            if activePanel == .audio {
                StudioAudioTimeline(vm: vm, activePanel: $activePanel)
            }
            if activePanel == .soundLibrary {
                StudioSoundLibrary(vm: vm, activePanel: $activePanel)
            }
            if activePanel == .export {
                StudioExportPanel(vm: vm, activePanel: $activePanel)
            }
            if activePanel == .assetVault {
                StudioAssetVault(vm: vm, activePanel: $activePanel)
            }
            if activePanel == .importVideo {
                StudioImportVideo(vm: vm, activePanel: $activePanel)
            }
            if activePanel == .framesViewer {
                StudioFramesViewer(vm: vm, activePanel: $activePanel)
            }

            // Text input overlay
            if vm.drawState.showTextInput {
                textInputOverlay
            }
        }
        .sheet(isPresented: $showPublishSheet) {
            PublishSheet(vm: vm)
        }
        .statusBarHidden(true)
    }

    // MARK: - Top Bar
    var topBar: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 36, height: 36)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(vm.project.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(vm.project.fps ?? 12) FPS · \(vm.frames.count) frames · \(currentLayerCount) layers")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.35))
            }

            Spacer()

            Button { activePanel = .export } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(hex: "E03030"))
                    .frame(width: 36, height: 36)
            }

            Button { activePanel = activePanel == .settings ? .none : .settings } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(hex: "111111"))
    }

    // MARK: - Canvas
    var canvasArea: some View {
        GeometryReader { geo in
            ZStack {
                // Dark margins
                Color(hex: "0a0a0a")

                // White canvas
                CanvasView(vm: vm)
                    .background(.white)
                    .frame(
                        width: geo.size.width * 0.76,
                        height: geo.size.height
                    )
                    .clipShape(Rectangle())
                    .shadow(color: .black.opacity(0.15), radius: 15)
                    .gesture(canvasGesture)
            }
        }
    }

    // MARK: - Frame Strip
    var frameStrip: some View {
        HStack(spacing: 8) {
            // Nav + play
            Button { vm.currentFrameIndex = max(0, vm.currentFrameIndex - 1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 28, height: 28)
            }

            Button { vm.isPlaying.toggle() } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color(hex: "222222")))
            }

            Button { vm.currentFrameIndex = min(vm.frames.count - 1, vm.currentFrameIndex + 1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 28, height: 28)
            }

            // Separator
            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(width: 1, height: 28)
                .padding(.horizontal, 2)

            // Frame thumbnails
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(vm.frames.enumerated()), id: \.offset) { index, _ in
                        Button {
                            vm.currentFrameIndex = index
                        } label: {
                            VStack(spacing: 0) {
                                Rectangle()
                                    .fill(.white)
                                    .frame(width: 40, height: 28)
                                Rectangle()
                                    .fill(index == vm.currentFrameIndex ? Color(hex: "E03030") : .white.opacity(0.15))
                                    .frame(width: 40, height: 10)
                                    .overlay(
                                        Text("\(index + 1)")
                                            .font(.system(size: 7, weight: .bold))
                                            .foregroundStyle(index == vm.currentFrameIndex ? .white : Color(hex: "666666"))
                                    )
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(index == vm.currentFrameIndex ? Color(hex: "E03030") : .white.opacity(0.1), lineWidth: 2)
                            )
                        }
                    }
                }
            }

            // Add frame
            Button { vm.addFrame() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 28, height: 28)
            }

            // Counter
            Text("\(vm.currentFrameIndex + 1)/\(vm.frames.count)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(Color(hex: "111111"))
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
        }
    }

    // MARK: - Action Bar
    var actionBar: some View {
        HStack(spacing: 0) {
            actionBarItem(icon: "music.note", label: "AUDIO") { activePanel = .audio }
            actionBarItem(icon: "arrow.uturn.backward", label: "UNDO") { vm.undo() }
            actionBarItem(icon: "arrow.uturn.forward", label: "REDO") { vm.redo() }
            actionBarItem(icon: "doc.on.doc", label: "COPY") { /* copy */ }
            actionBarItem(icon: "doc.on.clipboard", label: "PASTE") { /* paste */ }
            actionBarItem(icon: "square.3.layers.3d", label: "LAYER", badge: currentLayerCount) {
                activePanel = activePanel == .layers ? .none : .layers
            }
        }
        .frame(height: 56)
        .background(Color(hex: "111111"))
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
        }
    }

    func actionBarItem(icon: String, label: String, badge: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.6))
                    if let badge = badge {
                        Text("\(badge)")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 12, minHeight: 12)
                            .background(Circle().fill(Color(hex: "E03030")))
                            .offset(x: 6, y: -4)
                    }
                }
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Helpers
    var currentLayerCount: Int {
        guard vm.currentFrameIndex < vm.frames.count else { return 1 }
        return max(1, vm.frames[vm.currentFrameIndex].drawnElements.isEmpty ? 1 : 1) // Simplified - 1 layer per frame in current model
    }

    var canvasGesture: some Gesture {
        SimultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in
                    vm.canvasScale = max(0.3, min(5.0, scale))
                },
            DragGesture()
                .onChanged { value in
                    if vm.mode != .draw {
                        vm.canvasOffset = value.translation
                    }
                }
        )
    }

    var textInputOverlay: some View {
        VStack {
            Spacer()
            HStack {
                TextField("Enter text", text: $vm.drawState.textInput)
                    .font(.custom("SpecialElite-Regular", size: 18))
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: 300)

                Button("Done") {
                    vm.commitTextElement(vm.drawState.textInput)
                    vm.drawState.showTextInput = false
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(hex: "E03030"))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding()
            Spacer()
        }
        .background(.black.opacity(0.5))
    }
}

// MARK: - Panel Enum
enum StudioPanel {
    case none
    case colorPicker
    case audio
    case soundLibrary
    case layers
    case export
    case settings
    case framesViewer
    case assetVault
    case importVideo
}
