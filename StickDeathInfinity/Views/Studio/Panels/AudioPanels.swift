import SwiftUI
import UniformTypeIdentifiers

// The historical catalog is retained as reference labels. Imported Files assets
// are the only enabled audio source until licensed bundled sounds are supplied.
struct SoundLibraryPanel: View {
    @ObservedObject var vm: StudioViewModel
    @StateObject private var audio = StudioAudioPreviewSession()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedCategoryIndex: Int?
    @State private var search = ""

    var body: some View {
        ScrollView {
        VStack(spacing: 8) {
            PanelHeader(title: "Sound Library", icon: "🎵", onClose: { vm.activePanel = .none })
            AudioFilesImportControls(vm: vm, audio: audio)
            AudioProjectClips(vm: vm, audio: audio, search: search)
            HStack {
                if selectedCategoryIndex != nil {
                    Button("‹ Categories") { selectedCategoryIndex = nil }.foregroundColor(.sdRed)
                }
                TextField("Search clips or catalog references", text: $search).font(.specialElite(11))
            }
            .padding(.horizontal, 14)
            Text("Catalog references · audio files and licensing are unavailable")
                .font(.caption2).foregroundColor(.white.opacity(0.5)).padding(.horizontal, 14)
            ScrollView {
                LazyVStack(spacing: 6) {
                    if let index = selectedCategoryIndex, SoundLibrary.categories.indices.contains(index) {
                        let category = SoundLibrary.categories[index]
                        ForEach(category.sounds.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { sound in
                            SoundRow(sound: sound, tagColor: category.color, onAdd: {})
                        }
                    } else {
                        ForEach(Array(SoundLibrary.categories.enumerated()), id: \.element.id) { index, category in
                            if search.isEmpty || category.name.localizedCaseInsensitiveContains(search) {
                                Button { selectedCategoryIndex = index } label: {
                                    HStack {
                                        Text(category.icon)
                                        Text(category.name).font(.specialElite(12)).foregroundColor(.white)
                                        Spacer(); Image(systemName: "chevron.right").foregroundColor(.white.opacity(0.4))
                                    }
                                    .padding(10).background(Color(hex: "12121a")).cornerRadius(8)
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 14)
            }.frame(maxHeight: 130)
            Button("Open Audio Timeline") { vm.activePanel = .audioTimeline }
                .font(.specialElite(12)).foregroundColor(.sdRed).padding(.bottom, 10)
        }
        }
        .frame(maxWidth: 680, maxHeight: .infinity)
        .background(Color(hex: "1a1a24")).cornerRadius(16, corners: [.topLeft, .topRight])
        .onDisappear { audio.close() }
        .onChange(of: vm.document.id) { _, _ in audio.close() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { audio.close() } }
    }
}

struct SoundRow: View {
    let sound: SoundEffect
    let tagColor: Color
    let onAdd: () -> Void // Retained signature; absent assets cannot be added.
    var body: some View {
        HStack {
            Image(systemName: "speaker.slash").foregroundColor(.white.opacity(0.3))
            VStack(alignment: .leading, spacing: 2) {
                Text(sound.name).font(.specialElite(12)).foregroundColor(.white)
                Text("Audio unavailable").font(.caption2).foregroundColor(.white.opacity(0.4))
            }
            Spacer()
            Text(sound.tag).font(.caption2).foregroundColor(tagColor)
        }
        .padding(10).background(Color(hex: "12121a")).cornerRadius(8)
    }
}

private struct AudioImportLease {
    let projectID: UUID, revision: Int, frameID: String, track: Int
    @MainActor func isCurrent(_ vm: StudioViewModel) -> Bool {
        vm.isEditing && !vm.isSaving && vm.document.id == projectID && vm.document.revision == revision
            && vm.document.activeFrameID == frameID
    }
}

private struct AudioFilesImportControls: View {
    @ObservedObject var vm: StudioViewModel
    @ObservedObject var audio: StudioAudioPreviewSession
    @State private var showingFiles = false
    @State private var lease: AudioImportLease?
    @State private var track = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Button("Import from Files") {
                    lease = .init(projectID: vm.document.id, revision: vm.document.revision,
                                  frameID: vm.document.activeFrameID, track: track)
                    showingFiles = true
                }
                .disabled(audio.isBusy || !vm.isEditing || vm.isSaving)
                .accessibilityIdentifier("studio.audio.import")
                .font(.specialElite(12)).foregroundColor(.sdRed)
                Spacer()
                Picker("Track", selection: $track) {
                    ForEach(1...4, id: \.self) { Text("Track \($0)").tag($0) }
                }.font(.caption).tint(.white).disabled(audio.isBusy)
            }
            Text("Up to 16 MB / 5 min · mono or stereo · decoded sample limits apply")
                .font(.caption2).foregroundColor(.white.opacity(0.45))
            Text("Adds audio at the selected frame. Preview plays one clip; timeline mixing and audio export are unfinished.")
                .font(.caption2).foregroundColor(.white.opacity(0.6))
            if let projectNotice = vm.message {
                Text(projectNotice).font(.caption).foregroundColor(.sdRed)
                    .accessibilityIdentifier("studio.audio.projectNotice")
            }
            if audio.isBusy {
                HStack {
                    ProgressView(value: audio.progress).tint(.sdRed)
                    Button("Cancel") { audio.cancel() }.font(.caption).foregroundColor(.sdRed)
                        .accessibilityIdentifier("studio.audio.cancel")
                }
            }
            if let notice = audio.notice {
                Text(notice).font(.caption).foregroundColor(.sdRed)
                    .accessibilityIdentifier("studio.audio.notice")
            } else if let id = audio.lastImportedClipID, vm.audioClips.contains(where: { $0.id == id }) {
                Text("Audio added · \(vm.saveTimeAgo)").font(.caption2).foregroundColor(.white.opacity(0.6))
                    .accessibilityIdentifier("studio.audio.imported")
            }
        }
        .padding(.horizontal, 14)
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            switch result {
            case .failure(let error): audio.pickerFailed(error)
            case .success(let urls):
                guard let url = urls.first, let target = lease else { return }
                _ = audio.importFile(url, stillCurrent: { target.isCurrent(vm) }, attach: { imported in
                    try vm.attachImportedAudio(imported, expectedProjectID: target.projectID,
                        expectedRevision: target.revision, frameID: target.frameID, trackNumber: target.track)
                })
            }
            lease = nil
        }
    }
}

private struct AudioProjectClips: View {
    @ObservedObject var vm: StudioViewModel
    @ObservedObject var audio: StudioAudioPreviewSession
    var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if vm.audioClips.isEmpty {
                Text("No imported clips. Historical audio records are preserved in the project.")
                    .font(.caption2).foregroundColor(.white.opacity(0.5))
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(vm.audioClips.filter { search.isEmpty || $0.soundName.localizedCaseInsensitiveContains(search) }) { clip in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Button { vm.selectedAudioClip = clip } label: {
                                    VStack(alignment: .leading) {
                                        Text(clip.soundName).font(.specialElite(12)).lineLimit(1)
                                        Text(String(format: "Track %d · %.2fs at %.2fs", clip.track, clip.duration, clip.startTime)).font(.caption2)
                                    }.foregroundColor(.white)
                                }
                                Spacer()
                                if let id = clip.assetID, let asset = vm.audioTrack(forAssetID: id), asset.audioData != nil {
                                    Button(audio.playingClipID == clip.id ? "Stop" : "Preview") {
                                        let project = vm.document.id, revision = vm.document.revision
                                        _ = audio.preview(clip, track: asset, stillCurrent: {
                                            vm.isEditing && vm.document.id == project && vm.document.revision == revision
                                                && vm.audioClips.contains(where: { $0.id == clip.id && $0.assetID == id })
                                        })
                                    }
                                    .disabled(audio.isBusy).font(.caption).foregroundColor(.sdRed)
                                    .accessibilityIdentifier("studio.audio.preview.\(clip.id)")
                                } else {
                                    Text("Audio unavailable").font(.caption2).foregroundColor(.white.opacity(0.5))
                                }
                            }
                            if let id = clip.assetID, let measurement = audio.measurements[id] {
                                MeasuredAudioWaveform(peaks: measurement.peaks).frame(height: 24)
                                if measurement.clipped { Text("Source contains clipped samples").font(.caption2).foregroundColor(.orange) }
                            }
                            if clip.startTime + clip.duration > Double(vm.frames.count) / Double(vm.fps) {
                                Text("Extends beyond the animation end").font(.caption2).foregroundColor(.white.opacity(0.45))
                            }
                            if audio.playingClipID == clip.id {
                                Text(String(format: "Preview %.2f / %.2fs", audio.currentTime, audio.playbackDuration))
                                    .font(.caption2).foregroundColor(.sdRed).accessibilityIdentifier("studio.audio.playback")
                            }
                        }
                        .padding(8).background(Color(hex: "12121a")).cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(vm.selectedCurrentAudioClip?.id == clip.id ? Color.sdRed : .clear))
                    }
                }
            }.frame(maxHeight: 130)
            if let clip = vm.selectedCurrentAudioClip {
                HStack {
                    Text("Volume").font(.caption2).foregroundColor(.white.opacity(0.6))
                    Slider(value: Binding(get: { vm.selectedCurrentAudioClip?.volume ?? 0 }, set: { value in
                        vm.setAudioClipVolume(clip.id, volume: value)
                        audio.setVolume(value, clipID: clip.id)
                    }), in: 0...1).tint(.sdRed).accessibilityIdentifier("studio.audio.volume")
                    Text("\(Int(clip.volume * 100))%").font(.caption2).foregroundColor(.white.opacity(0.6))
                    Button("Delete") { audio.stop(); vm.deleteAudioClip(clip.id) }
                        .font(.caption).foregroundColor(.sdRed).accessibilityIdentifier("studio.audio.delete")
                }
            }
        }
        .padding(.horizontal, 14)
        .onChange(of: vm.document.revision) { _, _ in
            if let id = audio.playingClipID, !vm.audioClips.contains(where: { $0.id == id }) { audio.stop() }
            if let clip = vm.audioClips.first(where: { $0.id == audio.playingClipID }) { audio.setVolume(clip.volume, clipID: clip.id) }
        }
    }
}

private struct MeasuredAudioWaveform: View {
    let peaks: [Float]
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                for (index, peak) in peaks.enumerated() where peak.isFinite && peak > 0 {
                    let x = (CGFloat(index) + 0.5) / CGFloat(max(1, peaks.count)) * geometry.size.width
                    let half = CGFloat(min(1, max(0, peak))) * geometry.size.height / 2
                    path.move(to: CGPoint(x: x, y: geometry.size.height / 2 - half))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height / 2 + half))
                }
            }.stroke(Color.sdRed.opacity(0.8), lineWidth: 1)
        }.accessibilityLabel("Measured audio waveform")
    }
}

struct AudioTimelinePanel: View {
    @ObservedObject var vm: StudioViewModel
    @StateObject private var audio = StudioAudioPreviewSession()
    @Environment(\.scenePhase) private var scenePhase
    private let colors: [Color] = [.sdRed, .blue, .green, .purple]
    var body: some View {
        ScrollView {
        VStack(spacing: 8) {
            PanelHeader(title: "Audio Timeline", icon: "🎵", onClose: { vm.activePanel = .none })
            AudioFilesImportControls(vm: vm, audio: audio)
            HStack {
                Button(vm.isPlaying ? "Pause animation" : "Play animation") { audio.stop(); vm.togglePlayback() }
                    .font(.specialElite(11)).foregroundColor(.sdRed)
                Text("Animation only").font(.caption2).foregroundColor(.white.opacity(0.5))
                Spacer()
                Button("Sound Library") { vm.activePanel = .soundLibrary }.font(.caption).foregroundColor(.white)
            }.padding(.horizontal, 14)
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 28), duration = max(0.1, vm.audioDuration)
                VStack(spacing: 2) {
                    HStack {
                        Text("0s"); Spacer(); Text(String(format: "%.2fs", duration))
                    }.font(.caption2).foregroundColor(.white.opacity(0.4))
                    ForEach(1...4, id: \.self) { track in
                        HStack(spacing: 2) {
                            Text("\(track)").font(.caption2).foregroundColor(.white.opacity(0.4)).frame(width: 24)
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color.white.opacity(0.035))
                                ForEach(vm.audioClips.filter { $0.track == track }) { clip in
                                    let x = min(width, max(0, clip.startTime / duration * width))
                                    let size = min(width - x, max(3, clip.duration / duration * width))
                                    Button { vm.selectedAudioClip = clip } label: {
                                        RoundedRectangle(cornerRadius: 3).fill(colors[track - 1].opacity(0.65))
                                            .overlay(Text(clip.soundName).font(.system(size: 8)).foregroundColor(.white).lineLimit(1))
                                    }.frame(width: max(1, size)).offset(x: x)
                                }
                            }.frame(height: 22).clipped()
                        }
                    }
                }
            }.frame(height: 116).padding(.horizontal, 14)
            Text("Clip placement, trimming, snapping and mixed playback are unfinished.")
                .font(.caption2).foregroundColor(.white.opacity(0.5)).padding(.horizontal, 14)
            AudioProjectClips(vm: vm, audio: audio)
            Spacer().frame(height: 4)
        }
        }
        .frame(maxWidth: 680, maxHeight: .infinity)
        .background(Color(hex: "1a1a24")).cornerRadius(16, corners: [.topLeft, .topRight])
        .onDisappear { audio.close() }
        .onChange(of: vm.document.id) { _, _ in audio.close() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { audio.close() } }
    }
}

extension Array where Element == Color {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
