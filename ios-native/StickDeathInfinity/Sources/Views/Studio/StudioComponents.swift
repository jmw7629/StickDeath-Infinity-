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
// MARK: - Export Format
enum ExportFormat: String, CaseIterable, Identifiable {
    case mp4 = "MP4"
    case gif = "GIF"
    case png = "PNG"
    case spritesheet = "Spritesheet"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .mp4: return "film"
        case .gif: return "photo.on.rectangle.angled"
        case .png: return "photo"
        case .spritesheet: return "rectangle.split.3x3"
        }
    }
    var subtitle: String {
        switch self {
        case .mp4: return "Video file, best for social media"
        case .gif: return "Animated image, loops forever"
        case .png: return "Individual frame images"
        case .spritesheet: return "All frames in one image"
        }
    }
    var proRequired: Bool {
        switch self {
        case .mp4: return false
        case .gif, .png, .spritesheet: return true
        }
    }
}

// MARK: - Export Quality
enum ExportQuality: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case hd = "HD"
    case fullHD = "Full HD"

    var id: String { rawValue }
    var resolution: String {
        switch self {
        case .standard: return "480p"
        case .hd: return "720p"
        case .fullHD: return "1080p"
        }
    }
    var proRequired: Bool {
        switch self {
        case .standard: return false
        case .hd, .fullHD: return true
        }
    }
}

struct ExportOptionsSheet: View {
    @ObservedObject var vm: EditorViewModel
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @State private var selectedFormat: ExportFormat = .mp4
    @State private var selectedQuality: ExportQuality = .standard
    @State private var includeWatermark = true
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportSuccess = false
    @State private var exportError: String?
    // Social share
    @State private var showShareSheet = false
    @State private var selectedPlatforms: Set<String> = []
    @State private var shareTitle = ""
    @State private var shareDescription = ""

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {

                        // ── Format Picker ──
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Format".loc).font(.caption.bold()).foregroundStyle(.gray).textCase(.uppercase)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                ForEach(ExportFormat.allCases) { fmt in
                                    Button {
                                        if !fmt.proRequired || auth.isPro { selectedFormat = fmt }
                                    } label: {
                                        VStack(spacing: 6) {
                                            Image(systemName: fmt.icon).font(.title2)
                                            Text(fmt.rawValue).font(.subheadline.bold())
                                            Text(fmt.subtitle).font(.caption2).foregroundStyle(.gray).lineLimit(2).multilineTextAlignment(.center)
                                            if fmt.proRequired && !auth.isPro {
                                                Text("PRO".loc).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                                    .background(Color.red.opacity(0.2)).foregroundStyle(.red).clipShape(Capsule())
                                            }
                                        }
                                        .frame(maxWidth: .infinity).padding(12)
                                        .background(selectedFormat == fmt ? Color.red.opacity(0.15) : ThemeManager.surface)
                                        .overlay(RoundedRectangle(cornerRadius: 12)
                                            .stroke(selectedFormat == fmt ? Color.red : Color.clear, lineWidth: 2))
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .foregroundStyle(fmt.proRequired && !auth.isPro ? .gray : .white)
                                    }
                                    .disabled(fmt.proRequired && !auth.isPro)
                                }
                            }
                        }
                        .padding(.horizontal, 16)

                        // ── Quality Picker (MP4 / GIF) ──
                        if selectedFormat == .mp4 || selectedFormat == .gif {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Quality".loc).font(.caption.bold()).foregroundStyle(.gray).textCase(.uppercase)
                                HStack(spacing: 8) {
                                    ForEach(ExportQuality.allCases) { q in
                                        Button {
                                            if !q.proRequired || auth.isPro { selectedQuality = q }
                                        } label: {
                                            VStack(spacing: 4) {
                                                Text(q.rawValue).font(.subheadline.bold())
                                                Text(q.resolution).font(.caption).foregroundStyle(.gray)
                                                if q.proRequired && !auth.isPro {
                                                    Text("PRO".loc).font(.system(size: 8).bold()).padding(.horizontal, 4).padding(.vertical, 1)
                                                        .background(Color.red.opacity(0.2)).foregroundStyle(.red).clipShape(Capsule())
                                                }
                                            }
                                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                                            .background(selectedQuality == q ? Color.red.opacity(0.15) : ThemeManager.surface)
                                            .overlay(RoundedRectangle(cornerRadius: 10)
                                                .stroke(selectedQuality == q ? Color.red : Color.clear, lineWidth: 2))
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                            .foregroundStyle(q.proRequired && !auth.isPro ? .gray : .white)
                                        }
                                        .disabled(q.proRequired && !auth.isPro)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        // ── Watermark Toggle ──
                        VStack(alignment: .leading, spacing: 10) {
                            if auth.isPro {
                                Toggle(isOn: $includeWatermark) {
                                    VStack(alignment: .leading) {
                                        Text("Include watermark".loc).font(.subheadline.bold())
                                        Text("\"StickDeath ∞\" branding".loc).font(.caption).foregroundStyle(.gray)
                                    }
                                }
                                .tint(.red).padding().background(ThemeManager.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                            } else {
                                HStack(spacing: 10) {
                                    Image(systemName: "seal.fill").foregroundStyle(.red)
                                    VStack(alignment: .leading) {
                                        Text("Watermark included".loc).font(.subheadline.bold())
                                        Text("Upgrade to Pro to remove".loc).font(.caption).foregroundStyle(.gray)
                                    }
                                    Spacer()
                                }
                                .padding().background(ThemeManager.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .padding(.horizontal, 16)

                        // ── Share to Social ──
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Share To".loc).font(.caption.bold()).foregroundStyle(.gray).textCase(.uppercase)
                            VStack(spacing: 0) {
                                // Camera Roll (always available)
                                ShareRow(icon: "square.and.arrow.down", name: "Camera Roll".loc, color: "#34C759",
                                         selected: true, locked: false, action: {})

                                Divider().background(Color(hex: "2a2a3a"))

                                // Social platforms
                                ForEach(SocialAccountsManager.allPlatforms) { platform in
                                    let isSelected = selectedPlatforms.contains(platform.id)
                                    ShareRow(
                                        icon: platform.icon,
                                        name: platform.name,
                                        color: platform.color,
                                        selected: isSelected,
                                        locked: !auth.isPro,
                                        action: {
                                            if auth.isPro {
                                                if isSelected { selectedPlatforms.remove(platform.id) }
                                                else { selectedPlatforms.insert(platform.id) }
                                            }
                                        }
                                    )
                                    if platform.id != SocialAccountsManager.allPlatforms.last?.id {
                                        Divider().background(Color(hex: "2a2a3a"))
                                    }
                                }
                            }
                            .background(ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                            if !auth.isPro {
                                HStack(spacing: 6) {
                                    Image(systemName: "lock.fill").font(.caption2)
                                    Text("Upgrade to Pro or Creator to share directly to social platforms".loc).font(.caption2)
                                }
                                .foregroundStyle(.gray)
                            }
                        }
                        .padding(.horizontal, 16)

                        // ── Title / Description (when sharing to social) ──
                        if !selectedPlatforms.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Post Details".loc).font(.caption.bold()).foregroundStyle(.gray).textCase(.uppercase)
                                TextField("Title".loc, text: $shareTitle)
                                    .textFieldStyle(.plain).padding(12)
                                    .background(ThemeManager.surface).clipShape(RoundedRectangle(cornerRadius: 10))
                                TextField("Description (optional)".loc, text: $shareDescription, axis: .vertical)
                                    .lineLimit(3).textFieldStyle(.plain).padding(12)
                                    .background(ThemeManager.surface).clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .padding(.horizontal, 16)
                        }

                        // ── Progress / Success ──
                        if isExporting {
                            VStack(spacing: 8) {
                                ProgressView(value: exportProgress)
                                    .tint(.red).padding(.horizontal, 40)
                                Text("Exporting \(selectedFormat.rawValue)…".loc)
                                    .font(.caption).foregroundStyle(.gray)
                            }
                        }

                        if exportSuccess {
                            Label("Export Complete!".loc, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.headline)
                        }

                        if let error = exportError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red).font(.caption)
                        }

                        // ── Export Button ──
                        Button {
                            Task { await performExport() }
                        } label: {
                            HStack(spacing: 8) {
                                if isExporting {
                                    ProgressView().tint(.black)
                                } else {
                                    Image(systemName: "square.and.arrow.up.fill")
                                    Text(selectedPlatforms.isEmpty ? "Export \(selectedFormat.rawValue)".loc : "Export & Share".loc)
                                        .font(.headline)
                                }
                            }
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(Color.red).clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .padding(.horizontal, 40).disabled(isExporting)

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 16)
                }
            }
            .navigationTitle("Export".loc).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel".loc) { dismiss() } }
            }
        }
    }

    func performExport() async {
        isExporting = true
        exportError = nil
        exportProgress = 0.1
        let watermark = auth.isPro ? includeWatermark : true

        do {
            exportProgress = 0.3
            // Export to Camera Roll (always)
            let _ = try await PublishService.shared.exportLocally(projectId: vm.project.id, watermark: watermark)
            exportProgress = 0.7

            // Share to selected social platforms
            if !selectedPlatforms.isEmpty {
                exportProgress = 0.8
                try await PublishService.shared.publishToSocial(
                    projectId: vm.project.id,
                    platforms: Array(selectedPlatforms),
                    title: shareTitle.isEmpty ? (vm.project.title ?? "Untitled") : shareTitle,
                    description: shareDescription,
                    watermark: watermark
                )
            }

            exportProgress = 1.0
            exportSuccess = true
            HapticManager.shared.notification(.success)
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
            HapticManager.shared.notification(.error)
            print("Export error: \(error)")
        }
        isExporting = false
    }
}

// MARK: - Share Row
private struct ShareRow: View {
    let icon: String
    let name: String
    let color: String
    let selected: Bool
    let locked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.body).foregroundStyle(Color(hex: color)).frame(width: 24)
                Text(name).font(.subheadline).foregroundStyle(locked ? .gray : .white)
                Spacer()
                if locked {
                    Text("PRO".loc).font(.system(size: 9).bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.red.opacity(0.2)).foregroundStyle(.red).clipShape(Capsule())
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color(hex: color) : .gray)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .disabled(locked)
    }
}

// ResponsiveContainer is defined in Services/AdaptiveLayout.swift
