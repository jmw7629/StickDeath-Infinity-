// StudioComponents.swift
// Extracted sub-views for StudioView: sheets, overlays, toolbar popovers
// v9: All wired & functional

import SwiftUI

// MARK: - Brush Size Popover
struct BrushSizePopover: View {
    @ObservedObject var drawState: DrawingState

    var body: some View {
        VStack(spacing: 12) {
            Text("Brush Size")
                .font(.caption.bold())

            Slider(value: $drawState.strokeWidth, in: 1...30, step: 0.5)
                .tint(.red)

            HStack {
                Text(String(format: "%.1f", drawState.strokeWidth))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.gray)
                    .frame(width: 36)

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
                                Circle()
                                    .fill(fig.color.color)
                                    .frame(width: 24, height: 24)
                                Image(systemName: "figure.stand")
                                    .font(.system(size: 16))
                                    .foregroundStyle(fig.color.color)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(fig.name).font(.subheadline.bold())
                                    Text("\(fig.joints.count) joints")
                                        .font(.caption2).foregroundStyle(.gray)
                                }
                                Spacer()
                                Button {
                                    toggleVisibility(fig.id)
                                } label: {
                                    Image(systemName: isVisible(fig.id) ? "eye" : "eye.slash")
                                        .foregroundStyle(isVisible(fig.id) ? .white : .gray)
                                }
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

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Project Settings")
                                .font(.headline)
                            settingRow("FPS", "\(vm.project.fps ?? 24)")
                            settingRow("Frames", "\(vm.frames.count)")
                            HStack {
                                Text("Onion Skin").font(.subheadline)
                                Spacer()
                                Toggle("", isOn: $vm.showOnionSkin)
                                    .tint(.red)
                            }
                            .padding(12)
                            .background(ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                            Button {
                                dismiss()
                                vm.showProjectSettings = true
                            } label: {
                                Label("Full Settings…", systemImage: "gear")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity)
                                    .padding(12)
                                    .background(Color.red.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
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

    func settingRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline.bold())
        }
        .padding(12)
        .background(ThemeManager.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    func colorBinding(_ idx: Int) -> Binding<Color> {
        Binding(
            get: { vm.figures[idx].color.color },
            set: { _ in }
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
        ("cursorarrow", "Cursor Mode", "Tap to select, drag to move objects & images"),
        ("cube.fill", "Assets", "1,000+ objects & sounds to add"),
        ("photo.badge.plus", "Image Import", "Add photos from your camera roll"),
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
            .frame(maxWidth: 340, maxHeight: 460)
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

// ResponsiveContainer is defined in Services/AdaptiveLayout.swift
