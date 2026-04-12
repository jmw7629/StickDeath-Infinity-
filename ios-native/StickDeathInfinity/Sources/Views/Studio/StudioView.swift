// StudioView.swift
// Main animation studio — full-screen canvas with slide-out panels
// Includes quick-help tooltips, templates, and watermark preview

import SwiftUI

struct StudioView: View {
    @StateObject var vm: EditorViewModel
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @State private var showPublishSheet = false
    @State private var showTemplates = false
    @State private var showQuickHelp = false
    @State private var showExportOptions = false

    var body: some View {
        ZStack {
            // Full-screen dark background
            Color.black.ignoresSafeArea()

            // Canvas
            CanvasView(vm: vm)
                .gesture(canvasGesture)

            // Watermark preview (shows what the exported video will look like)
            if !auth.isPro {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        WatermarkPreview()
                            .padding(.trailing, 12)
                            .padding(.bottom, vm.showTimeline ? 130 : 12)
                    }
                }
                .allowsHitTesting(false)
            }

            // Floating top toolbar
            VStack {
                FloatingToolbar(
                    vm: vm,
                    onBack: { dismiss() },
                    onPublish: { showPublishSheet = true },
                    onTemplates: { showTemplates = true },
                    onHelp: { showQuickHelp.toggle() },
                    onExport: { showExportOptions = true }
                )
                Spacer()
            }

            // Slide-out left panel (Layers)
            if vm.showLayers {
                HStack {
                    LayersPanel(vm: vm)
                        .frame(width: 260)
                        .transition(.move(edge: .leading))
                    Spacer()
                }
            }

            // Slide-out right panel (Properties)
            if vm.showProperties {
                HStack {
                    Spacer()
                    PropertiesPanel(vm: vm)
                        .frame(width: 280)
                        .transition(.move(edge: .trailing))
                }
            }

            // Bottom timeline
            if vm.showTimeline {
                VStack {
                    Spacer()
                    TimelinePanel(vm: vm)
                        .frame(height: 120)
                        .transition(.move(edge: .bottom))
                }
            }

            // AI Panel
            if vm.showAIPanel {
                AIAssistPanel(vm: vm)
            }

            // Quick Help Overlay
            if showQuickHelp {
                QuickHelpOverlay(isShowing: $showQuickHelp)
            }

            // Saving indicator
            if vm.isSaving {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Label("Saving...", systemImage: "icloud.and.arrow.up")
                            .font(.caption)
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding()
                    }
                }
            }
        }
        .animation(.spring(response: 0.3), value: vm.showLayers)
        .animation(.spring(response: 0.3), value: vm.showProperties)
        .animation(.spring(response: 0.3), value: vm.showTimeline)
        .animation(.spring(response: 0.3), value: showQuickHelp)
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .sheet(isPresented: $showPublishSheet) {
            PublishSheet(vm: vm)
        }
        .sheet(isPresented: $showTemplates) {
            TemplatesView { template in
                vm.applyTemplate(template)
            }
        }
        .sheet(isPresented: $showExportOptions) {
            ExportOptionsSheet(vm: vm)
        }
        .task { await vm.loadProject() }
        .onDisappear { Task { await vm.saveProject() } }
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
        ("arrow.up.and.down.and.arrow.left.and.right", "Move Mode", "Pan & zoom the canvas"),
        ("pencil.tip", "Draw Mode", "Freehand sketch on the canvas"),
        ("timeline.selection", "Timeline", "Add frames, reorder, set timing"),
        ("square.3.layers.3d", "Layers", "Manage multiple figures"),
        ("slider.horizontal.3", "Properties", "Adjust figure colors & sizes"),
        ("sparkles", "AI Assist", "Let AI generate animations (Pro)"),
        ("arrow.uturn.backward", "Undo", "Up to 50 steps of undo"),
        ("eye", "Onion Skin", "See ghost of previous frame"),
        ("paperplane.fill", "Publish", "Share to all platforms"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture { isShowing = false }

            VStack(spacing: 0) {
                HStack {
                    Text("Quick Reference")
                        .font(.headline)
                    Spacer()
                    Button { isShowing = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.gray)
                    }
                }
                .padding()

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
                            HStack(spacing: 14) {
                                Image(systemName: tip.0)
                                    .font(.body)
                                    .foregroundStyle(.orange)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tip.1)
                                        .font(.subheadline.bold())
                                    Text(tip.2)
                                        .font(.caption)
                                        .foregroundStyle(.gray)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                    }
                }

                // Shortcut to full help
                Button {
                    isShowing = false
                } label: {
                    Text("Full Help Center available in Profile → Help & Instructions")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(12)
                }
            }
            .background(ThemeManager.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: 340, maxHeight: 480)
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
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)

                    Text("Export to Camera Roll")
                        .font(.title2.bold())

                    Text("Save a copy of your animation as a video file to your device.")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    // Watermark toggle (Pro only can remove)
                    VStack(spacing: 8) {
                        if auth.isPro {
                            Toggle(isOn: $includeWatermark) {
                                VStack(alignment: .leading) {
                                    Text("Include watermark")
                                        .font(.subheadline.bold())
                                    Text("\"StickDeath ∞\" branding on the video")
                                        .font(.caption)
                                        .foregroundStyle(.gray)
                                }
                            }
                            .tint(.orange)
                            .padding()
                            .background(ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            HStack(spacing: 10) {
                                Image(systemName: "seal.fill")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading) {
                                    Text("Watermark included")
                                        .font(.subheadline.bold())
                                    Text("Upgrade to Pro to export without watermark")
                                        .font(.caption)
                                        .foregroundStyle(.gray)
                                }
                                Spacer()
                            }
                            .padding()
                            .background(ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(.horizontal, 24)

                    if exportSuccess {
                        Label("Saved to Camera Roll!", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    Button {
                        Task { await exportVideo() }
                    } label: {
                        if isExporting {
                            ProgressView().tint(.black)
                        } else {
                            Label("Export Video", systemImage: "square.and.arrow.down")
                                .font(.headline)
                                .foregroundStyle(.black)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 40)
                    .disabled(isExporting)

                    Spacer()
                }
                .padding(.top, 32)
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    func exportVideo() async {
        isExporting = true
        let watermark = auth.isPro ? includeWatermark : true
        do {
            let _ = try await PublishService.shared.exportLocally(
                projectId: vm.project.id,
                watermark: watermark
            )
            exportSuccess = true
        } catch {
            print("Export error: \(error)")
        }
        isExporting = false
    }
}

// MARK: - Floating Toolbar (updated with new buttons)
struct FloatingToolbar: View {
    @ObservedObject var vm: EditorViewModel
    let onBack: () -> Void
    let onPublish: () -> Void
    let onTemplates: () -> Void
    let onHelp: () -> Void
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Back
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .toolbarButtonStyle()
            }

            Text(vm.project.title)
                .font(.subheadline.bold())
                .lineLimit(1)

            Spacer()

            // Mode picker
            HStack(spacing: 4) {
                modeButton(.pose, icon: "figure.stand", label: "Pose")
                modeButton(.move, icon: "arrow.up.and.down.and.arrow.left.and.right", label: "Move")
                modeButton(.draw, icon: "pencil.tip", label: "Draw")
            }
            .padding(4)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Spacer()

            // Undo / Redo
            Button { vm.undo() } label: { Image(systemName: "arrow.uturn.backward").toolbarButtonStyle() }
                .disabled(vm.undoStack.isEmpty)
            Button { vm.redo() } label: { Image(systemName: "arrow.uturn.forward").toolbarButtonStyle() }
                .disabled(vm.redoStack.isEmpty)

            // Panels
            Button { vm.showLayers.toggle() } label: { Image(systemName: "square.3.layers.3d").toolbarButtonStyle(active: vm.showLayers) }
            Button { vm.showProperties.toggle() } label: { Image(systemName: "slider.horizontal.3").toolbarButtonStyle(active: vm.showProperties) }
            Button { vm.showTimeline.toggle() } label: { Image(systemName: "timeline.selection").toolbarButtonStyle(active: vm.showTimeline) }

            // Templates
            Button(action: onTemplates) {
                Image(systemName: "square.on.square.dashed")
                    .toolbarButtonStyle(tint: .cyan)
            }

            // AI (Pro only)
            if AuthManager.shared.isPro {
                Button { vm.showAIPanel.toggle() } label: {
                    Image(systemName: "sparkles")
                        .toolbarButtonStyle(active: vm.showAIPanel, tint: .purple)
                }
            }

            // Quick Help
            Button(action: onHelp) {
                Image(systemName: "questionmark.circle")
                    .toolbarButtonStyle(tint: .green)
            }

            // Export (save to device)
            Button(action: onExport) {
                Image(systemName: "square.and.arrow.down")
                    .toolbarButtonStyle(tint: .white)
            }

            // Publish
            Button(action: onPublish) {
                Image(systemName: "paperplane.fill")
                    .toolbarButtonStyle(tint: .orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    func modeButton(_ mode: EditorMode, icon: String, label: String) -> some View {
        Button {
            vm.mode = mode
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.caption)
                Text(label).font(.system(size: 9))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(vm.mode == mode ? Color.orange : Color.clear)
            .foregroundStyle(vm.mode == mode ? .black : .white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Toolbar Button Style
extension Image {
    func toolbarButtonStyle(active: Bool = false, tint: Color = .white) -> some View {
        self
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(active ? tint : .white.opacity(0.7))
            .frame(width: 36, height: 36)
            .background(active ? tint.opacity(0.2) : .clear)
            .clipShape(Circle())
    }
}
