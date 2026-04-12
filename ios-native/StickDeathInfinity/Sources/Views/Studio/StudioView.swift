// StudioView.swift
// Main animation studio — full-screen canvas with slide-out panels

import SwiftUI

struct StudioView: View {
    @StateObject var vm: EditorViewModel
    @Environment(\.dismiss) var dismiss
    @State private var showPublishSheet = false

    var body: some View {
        ZStack {
            // Full-screen dark background
            Color.black.ignoresSafeArea()

            // Canvas
            CanvasView(vm: vm)
                .gesture(canvasGesture)

            // Floating top toolbar
            VStack {
                FloatingToolbar(vm: vm, onBack: { dismiss() }, onPublish: { showPublishSheet = true })
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
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .sheet(isPresented: $showPublishSheet) {
            PublishSheet(vm: vm)
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

// MARK: - Floating Toolbar
struct FloatingToolbar: View {
    @ObservedObject var vm: EditorViewModel
    let onBack: () -> Void
    let onPublish: () -> Void

    var body: some View {
        HStack(spacing: 12) {
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

            // AI (Pro only)
            if AuthManager.shared.isPro {
                Button { vm.showAIPanel.toggle() } label: {
                    Image(systemName: "sparkles")
                        .toolbarButtonStyle(active: vm.showAIPanel, tint: .purple)
                }
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
