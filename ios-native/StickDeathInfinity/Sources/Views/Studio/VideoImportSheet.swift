// VideoImportSheet.swift
// Video import UI — pick a video, preview extracted frames, insert into timeline
// Matches FlipaClip-inspired bottom-sheet design from Viktor Space studio

import SwiftUI
import PhotosUI
import AVKit

struct VideoImportSheet: View {
    @ObservedObject var vm: EditorViewModel
    @StateObject private var importManager = VideoImportManager()
    @Environment(\.dismiss) var dismiss

    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var videoInfo: VideoImportManager.VideoInfo?
    @State private var showVideoPreview = false

    // Import options
    @State private var insertMode: InsertMode = .newFrames
    @State private var targetFPS: Int = 12
    @State private var maxFrames: Int = 60
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0

    enum InsertMode: String, CaseIterable {
        case newFrames = "New Frames"
        case asImages = "As Images on Current Frame"

        var icon: String {
            switch self {
            case .newFrames: return "film.stack"
            case .asImages: return "photo.on.rectangle"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Step 1: Pick Video
                        videoPickerSection

                        // Step 2: Video Info + Preview
                        if let info = videoInfo {
                            videoInfoSection(info)
                            importOptionsSection(info)
                        }

                        // Step 3: Import Progress
                        if importManager.isImporting {
                            progressSection
                        }

                        // Step 4: Preview extracted frames
                        if !importManager.previewFrames.isEmpty && !importManager.isImporting {
                            previewSection
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Add Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.gray)
                }
            }
        }
        .onChange(of: selectedVideoItem) { newItem in
            Task { await loadVideo(from: newItem) }
        }
        .onAppear {
            targetFPS = vm.project.fps ?? 12
        }
    }

    // MARK: - Video Picker

    private var videoPickerSection: some View {
        VStack(spacing: 12) {
            if videoURL == nil {
                PhotosPicker(
                    selection: $selectedVideoItem,
                    matching: .videos,
                    photoLibrary: .shared()
                ) {
                    VStack(spacing: 12) {
                        Image(systemName: "video.badge.plus")
                            .font(.system(size: 40))
                            .foregroundStyle(.red)
                        Text("Choose Video")
                            .font(.custom("SpecialElite-Regular", size: 16))
                            .foregroundStyle(.white)
                        Text("Select from your camera roll")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .background(ThemeManager.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.red.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [8]))
                    )
                }
            } else {
                // Video selected — show thumbnail
                HStack(spacing: 12) {
                    if let info = videoInfo {
                        // Video thumbnail
                        AsyncVideoThumbnail(url: info.url)
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Video Selected")
                            .font(.custom("SpecialElite-Regular", size: 14))
                            .foregroundStyle(.white)
                        if let info = videoInfo {
                            Text("\(info.formattedDuration) · \(info.formattedSize) · \(Int(info.fps)) fps")
                                .font(.caption)
                                .foregroundStyle(.gray)
                        }
                    }

                    Spacer()

                    PhotosPicker(
                        selection: $selectedVideoItem,
                        matching: .videos,
                        photoLibrary: .shared()
                    ) {
                        Text("Change")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(12)
                .background(ThemeManager.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Video Info

    private func videoInfoSection(_ info: VideoImportManager.VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Video Details", icon: "info.circle")

            HStack(spacing: 16) {
                infoChip("Duration", value: info.formattedDuration, icon: "clock")
                infoChip("Size", value: info.formattedSize, icon: "aspectratio")
                infoChip("FPS", value: "\(Int(info.fps))", icon: "gauge.medium")
                infoChip("Frames", value: "\(info.totalFrames)", icon: "film")
            }
        }
    }

    // MARK: - Import Options

    private func importOptionsSection(_ info: VideoImportManager.VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Import Options", icon: "slider.horizontal.3")

            // Insert mode
            VStack(alignment: .leading, spacing: 6) {
                Text("Insert As")
                    .font(.caption)
                    .foregroundStyle(.gray)

                HStack(spacing: 8) {
                    ForEach(InsertMode.allCases, id: \.rawValue) { mode in
                        Button {
                            insertMode = mode
                            HapticManager.shared.buttonTap()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: mode.icon)
                                    .font(.caption2)
                                Text(mode.rawValue)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(insertMode == mode ? Color.red.opacity(0.2) : ThemeManager.surface)
                            .foregroundStyle(insertMode == mode ? .red : .gray)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(insertMode == mode ? Color.red : Color.gray.opacity(0.3), lineWidth: 1)
                            )
                        }
                    }
                }
            }

            // Target FPS
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sample Rate")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    Spacer()
                    Text("\(targetFPS) fps")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                }
                Slider(value: Binding(
                    get: { Double(targetFPS) },
                    set: { targetFPS = Int($0) }
                ), in: 1...30, step: 1)
                .tint(.red)
            }

            // Max frames
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Max Frames")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    Spacer()
                    Text("\(maxFrames)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                }
                Slider(value: Binding(
                    get: { Double(maxFrames) },
                    set: { maxFrames = Int($0) }
                ), in: 10...300, step: 10)
                .tint(.red)
            }

            // Estimated frames
            let estimatedFrames = min(maxFrames, Int(info.duration * Double(targetFPS)))
            Text("≈ \(estimatedFrames) frames will be extracted")
                .font(.caption)
                .foregroundStyle(.gray)

            // Import button
            Button {
                Task { await performImport(info: info) }
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import \(estimatedFrames) Frames")
                        .font(.custom("SpecialElite-Regular", size: 14))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.red)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(importManager.isImporting)
        }
        .padding(12)
        .background(ThemeManager.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Extracting frames…")
                    .font(.caption)
                    .foregroundStyle(.white)
                Spacer()
                Text("\(Int(importManager.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.red)
            }

            ProgressView(value: importManager.progress)
                .tint(.red)
                .scaleEffect(y: 2)

            // Live preview thumbnails
            if !importManager.previewFrames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(importManager.previewFrames.enumerated()), id: \.offset) { _, img in
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(ThemeManager.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Preview Section

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Preview", icon: "eye")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(importManager.previewFrames.enumerated()), id: \.offset) { idx, img in
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                Text("\(idx + 1)")
                                    .font(.system(size: 8).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(2)
                                    .background(.black.opacity(0.6))
                                    .clipShape(RoundedRectangle(cornerRadius: 2)),
                                alignment: .bottomTrailing
                            )
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.red)
            Text(title)
                .font(.custom("SpecialElite-Regular", size: 13))
                .foregroundStyle(.white)
        }
    }

    private func infoChip(_ label: String, value: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.red)
            Text(value)
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(ThemeManager.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private func loadVideo(from item: PhotosPickerItem?) async {
        guard let item = item else { return }

        // Load video as a transferable movie
        if let videoData = try? await item.loadTransferable(type: VideoTransferable.self) {
            videoURL = videoData.url
            if let url = videoURL {
                videoInfo = try? await importManager.analyzeVideo(url: url)
                if let info = videoInfo {
                    trimEnd = info.duration
                }
            }
        }
    }

    private func performImport(info: VideoImportManager.VideoInfo) async {
        let config = VideoImportManager.ImportConfig(
            targetFPS: targetFPS,
            maxDimension: 1080,
            startTime: trimStart,
            endTime: trimEnd > 0 ? trimEnd : nil,
            sampleMode: .matchFPS
        )

        do {
            let result = try await importManager.extractFrames(from: info.url, config: config)

            switch insertMode {
            case .newFrames:
                vm.importVideoFrames(result.frames)
            case .asImages:
                // Import first frame as an image on current frame
                if let first = result.frames.first {
                    vm.importImage(first)
                }
            }

            HapticManager.shared.objectPlaced()
            dismiss()
        } catch {
            importManager.importError = error.localizedDescription
        }
    }
}

// MARK: - Video Transferable (for PhotosPicker)

struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let tempDir = FileManager.default.temporaryDirectory
            let destURL = tempDir.appendingPathComponent("import_\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: destURL)
            return Self(url: destURL)
        }
    }
}

// MARK: - Async Video Thumbnail

struct AsyncVideoThumbnail: View {
    let url: URL
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumb = thumbnail {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(ThemeManager.surface)
                    .overlay(
                        Image(systemName: "video")
                            .foregroundStyle(.gray)
                    )
            }
        }
        .task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 160)
            if let (cgImage, _) = try? await generator.image(at: .zero) {
                thumbnail = UIImage(cgImage: cgImage)
            }
        }
    }
}
