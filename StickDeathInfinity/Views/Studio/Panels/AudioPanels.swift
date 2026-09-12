import SwiftUI
import UniformTypeIdentifiers

struct SoundLibraryPanel: View {
    @ObservedObject var vm: StudioViewModel
    var body: some View { StudioAudioWorkspace(vm: vm, opensLibrary: true) }
}
struct AudioTimelinePanel: View {
    @ObservedObject var vm: StudioViewModel
    var body: some View { StudioAudioWorkspace(vm: vm, opensLibrary: false) }
}

private struct StudioAudioWorkspace: View {
    @ObservedObject var vm: StudioViewModel
    let opensLibrary: Bool
    @StateObject private var audio = StudioAudioPreviewSession()
    @StateObject private var timeline = StudioAudioTimelineSession()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingLibrary = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var category: String?
    @State private var catalogue: StudioSoundCatalogue?
    @State private var catalogueError: String?
    @State private var libraryTrack = 1
    @State private var volume = 0.8
    @State private var volumeRevision: Int?
    private let background = Color(hex: "0D0D12")

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.height < 520 {
                ScrollView(.vertical) {
                    workspace(height: 760).frame(height: 760)
                }.accessibilityIdentifier("studio.audio.compact.scroll")
            } else {
                workspace(height: geometry.size.height)
            }
        }
        .frame(maxWidth: 900, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        .onAppear {
            showingLibrary = opensLibrary; volume = vm.selectedCurrentAudioClip?.volume ?? 0.8
            do { catalogue = try StudioSoundCatalogue.bundled() } catch { catalogueError = error.localizedDescription }
        }
        .onDisappear { audio.close(); timeline.close(); vm.stopPlayback() }
        .onChange(of: vm.document.id) { _, _ in audio.close(); timeline.close() }
        .onChange(of: vm.document.revision) { _, _ in
            timeline.stop(); audio.stop(); volume = vm.selectedCurrentAudioClip?.volume ?? 0.8
        }
        .onChange(of: vm.selectedCurrentAudioClip?.id) { _, _ in
            volume = vm.selectedCurrentAudioClip?.volume ?? 0.8; volumeRevision = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { audio.close(); timeline.close(); vm.stopPlayback() }
        }
    }
    private func workspace(height: CGFloat) -> some View {
            VStack(spacing: 0) {
                if showingLibrary {
                    library
                        .frame(height: max(160, min(height * 0.40, 390)))
                    Divider().overlay(Color.white.opacity(0.3))
                }
                header
                transport
                if timeline.isPreparing {
                    HStack {
                        ProgressView(value: timeline.progress).tint(.sdRed)
                        Button("Cancel") { timeline.stop() }.foregroundColor(.sdRed)
                    }.padding(.horizontal, 16).padding(.bottom, 8)
                }
                if let notice = timeline.notice ?? vm.message {
                    Text(notice).font(.caption2).foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 16).accessibilityIdentifier("studio.audio.timelineNotice")
                }
                timelineGrid
                    .frame(minHeight: 160, maxHeight: .infinity, alignment: .top)
                if let clip = vm.selectedCurrentAudioClip { clipInspector(clip) }
                HStack {
                    Text("Drag clips to move · Drag edges to trim").foregroundColor(.white.opacity(0.4))
                    Spacer()
                    Button("+ Add Sound") { showingLibrary = true }.foregroundColor(.sdRed)
                }.font(.specialElite(10)).padding(12)
            }
            .background(background).foregroundColor(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var header: some View {
        HStack(spacing: 8) {
            Text("♫ Audio Timeline").font(.specialElite(16))
            Text("\(vm.audioClips.count) clips").font(.specialElite(10))
                .padding(5).background(Color.white.opacity(0.05)).clipShape(Capsule())
                .accessibilityIdentifier("studio.audio.clip-count")
            Spacer(minLength: 0)
            Button(vm.snapEnabled ? "Snap: ON" : "Snap: OFF") { vm.snapEnabled.toggle() }
                .font(.specialElite(10)).foregroundColor(.sdRed)
                .accessibilityIdentifier("studio.audio.snap")
            Button("+ Add") { showingLibrary = true }
                .font(.specialElite(12)).padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.sdRed).clipShape(Capsule())
                .accessibilityIdentifier("studio.audio.library.open")
            Button { audio.close(); timeline.close(); vm.activePanel = .none } label: {
                Image(systemName: "xmark").font(.system(size: 10)).frame(width: 44, height: 44)
            }.accessibilityLabel("Close audio workspace").accessibilityIdentifier("studio.audio.close")
        }.padding(.leading, 12)
    }
    private var transport: some View {
        HStack(spacing: 12) {
            Button { seek(0) } label: { Image(systemName: "backward.end.fill").frame(width: 44, height: 44) }
                .accessibilityLabel("Audio beginning")
            Button { togglePlayback() } label: {
                Image(systemName: timeline.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 54, height: 54).background(Color.sdRed).cornerRadius(18)
            }.disabled(timeline.isPreparing || audio.isBusy)
                .accessibilityLabel(timeline.isPlaying ? "Pause mixed audio" : "Play mixed audio")
                .accessibilityIdentifier("studio.audio.timelinePlay")
            Button { seek(vm.audioDuration) } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }
                .accessibilityLabel("Audio end")
            Text(clock(vm.audioPlayheadTime)).foregroundColor(.sdRed)
            Text("/ " + clock(vm.audioDuration)).foregroundColor(.white.opacity(0.35))
            Spacer(minLength: 0)
        }.font(.specialElite(14)).padding(.horizontal, 12).padding(.bottom, 10)
    }
    private func clock(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "00:00.00" }
        return String(format: "%02d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
    private func seek(_ time: Double) {
        timeline.stop(); audio.stop(); vm.stopPlayback()
        vm.displayAudioPlaybackTime(min(vm.audioDuration, max(0, time)), playing: false)
    }
    private func togglePlayback() {
        if timeline.isPlaying { timeline.stop(); return }
        audio.stop(); vm.stopPlayback()
        let id = vm.document.id, revision = vm.document.revision
        let start = vm.audioPlayheadTime < vm.audioDuration ? vm.audioPlayheadTime : 0
        _ = timeline.play(document: vm.document, tracks: vm.projectAudioTracks,
            duration: vm.audioDuration, from: start,
            stillCurrent: { vm.isEditing && vm.document.id == id && vm.document.revision == revision },
            onTime: { time, playing in
                guard vm.document.id == id, vm.document.revision == revision else { return }
                vm.displayAudioPlaybackTime(min(vm.audioDuration, time), playing: playing)
            })
    }
    private var library: some View {
        VStack(spacing: 10) {
            HStack {
                if category != nil { Button("‹") { category = nil }.frame(width: 32, height: 44) }
                Text(category ?? "Sound Library").font(.specialElite(16))
                Spacer()
                Button { showingLibrary = false } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).frame(width: 44, height: 44)
                }.accessibilityLabel("Close sound library")
                    .accessibilityIdentifier("studio.audio.library.close")
            }.padding(.horizontal, 12)
            TextField("Search sounds, tags, categories…", text: $search)
                .focused($searchFocused).submitLabel(.search)
                .onSubmit { searchFocused = false }
                .font(.specialElite(14)).padding(14).background(Color(hex: "1B1B28"))
                .cornerRadius(16).padding(.horizontal, 16)
                .accessibilityIdentifier("studio.audio.search")
            ScrollView {
                VStack(spacing: 10) {
                    AudioFilesImportControls(vm: vm, audio: audio)
                    AudioProjectClips(vm: vm, audio: audio, timeline: timeline)
                    if let catalogue {
                        Text("\(catalogue.sounds.count) offline sounds · CC0")
                            .font(.caption2).foregroundColor(.white.opacity(0.5))
                            .accessibilityIdentifier("studio.audio.catalogue.count")
                        if category != nil || !search.isEmpty {
                            catalogueRows(catalogue)
                        } else {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                ForEach(catalogue.categories, id: \.self) { name in
                                    Button { category = name } label: {
                                        VStack(alignment: .leading, spacing: 12) {
                                            Image(systemName: "waveform").font(.title2).foregroundColor(.sdRed)
                                            Text(name).font(.specialElite(15)).multilineTextAlignment(.leading)
                                            Text("\(catalogue.search("", category: name).count) sounds")
                                                .font(.caption2).foregroundColor(.white.opacity(0.4))
                                        }.frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                                            .padding(14).background(Color.sdRed.opacity(0.06)).cornerRadius(18)
                                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.sdRed.opacity(0.18)))
                                    }.accessibilityIdentifier("studio.audio.category." + name)
                                }
                            }.padding(.horizontal, 16)
                        }
                    } else if let catalogueError {
                        Text(catalogueError).font(.caption2).foregroundColor(.white.opacity(0.6)).padding(16)
                    }
                }.padding(.bottom, 12)
            }
            .accessibilityIdentifier("studio.audio.library.scroll")
        }
    }
    private func catalogueRows(_ catalogue: StudioSoundCatalogue) -> some View {
        LazyVStack(spacing: 8) {
            Picker("Add sounds to track", selection: $libraryTrack) {
                ForEach(1...4, id: \.self) { Text("Track \($0)").tag($0) }
            }.tint(.sdRed).accessibilityIdentifier("studio.audio.catalogue.track")
            ForEach(catalogue.search(search, category: category)) { sound in
                HStack(spacing: 12) {
                    Button {
                        timeline.stop(); vm.stopPlayback()
                        if audio.playingClipID == sound.id { audio.stop(); return }
                        do {
                            let track = try catalogue.previewTrack(sound)
                            let clip = AudioClip(id: sound.id, soundName: sound.title, track: libraryTrack,
                                startTime: 0, duration: track.duration, assetID: track.id)
                            let project = vm.document.id, revision = vm.document.revision
                            _ = audio.preview(clip, track: track,
                                stillCurrent: { vm.isEditing && vm.document.id == project && vm.document.revision == revision })
                        } catch { vm.message = error.localizedDescription }
                    } label: {
                        Image(systemName: audio.playingClipID == sound.id ? "stop.fill" : "play.fill")
                            .frame(width: 44, height: 44).background(Color.white.opacity(0.06)).clipShape(Circle())
                    }.disabled(audio.isBusy || timeline.isPreparing)
                        .accessibilityLabel("Preview " + sound.title)
                        .accessibilityIdentifier("studio.audio.catalogue.preview." + sound.id)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sound.title).font(.specialElite(14)).lineLimit(1)
                        HStack {
                            Text(String(format: "%.2fs", sound.duration)).font(.caption2)
                            MeasuredAudioWaveform(peaks: sound.waveformPeaks).frame(width: 56, height: 14)
                        }.foregroundColor(.white.opacity(0.45))
                        Text(sound.author + " · CC0").font(.system(size: 9)).foregroundColor(.white.opacity(0.35))
                    }
                    Spacer(minLength: 0)
                    Button {
                        timeline.stop(); audio.stop(); vm.stopPlayback()
                        do {
                            let resource = try catalogue.checkedResource(sound)
                            let target = AudioImportLease(projectID: vm.document.id, revision: vm.document.revision,
                                frameID: vm.document.activeFrameID, track: libraryTrack)
                            _ = audio.importFile(resource.url, name: sound.title, expectedSHA256: sound.sha256,
                                stillCurrent: { target.isCurrent(vm) }, attach: { imported in
                                    try vm.attachImportedAudio(imported, expectedProjectID: target.projectID,
                                        expectedRevision: target.revision, frameID: target.frameID, trackNumber: target.track)
                                })
                        } catch { vm.message = error.localizedDescription }
                    } label: {
                        Image(systemName: "plus").foregroundColor(.sdRed).frame(width: 44, height: 44)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.sdRed.opacity(0.35)))
                    }.disabled(audio.isBusy || timeline.isPreparing || vm.isSaving)
                        .accessibilityLabel("Add " + sound.title)
                        .accessibilityIdentifier("studio.audio.catalogue.add." + sound.id)
                }.padding(.horizontal, 16)
                Divider().opacity(0.15)
            }
        }
    }
    private var timelineGrid: some View {
        GeometryReader { geometry in
            let pps = 110.0
            let length = max(5, min(1300, vm.audioDuration + 1))
            let width = max(geometry.size.width - 44, length * pps)
            let rowHeight = 70.0
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 26)
                    ForEach(1...4, id: \.self) { track in
                        let clips = vm.audioClips.filter { $0.track == track }
                        let muted = !clips.isEmpty && clips.allSatisfy(\.isMuted)
                        VStack(spacing: 0) {
                            Text("\(track)").font(.specialElite(10)).foregroundColor(.white.opacity(0.45))
                            Button {
                                timeline.stop(); audio.stop(); vm.stopPlayback()
                                do { try vm.setAudioTrackMuted(track, muted: !muted, expectedRevision: vm.document.revision) }
                                catch { vm.message = error.localizedDescription }
                            } label: {
                                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .font(.system(size: 12)).frame(width: 44, height: 44)
                            }.disabled(clips.isEmpty)
                                .accessibilityLabel(muted ? "Unmute track \(track)" : "Mute track \(track)")
                        }.frame(width: 44, height: rowHeight)
                    }
                }
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 0) {
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(Color.white.opacity(0.02))
                            ForEach(Array(stride(from: 0, through: Int(ceil(length)), by: length > 120 ? 10 : 1)), id: \.self) { second in
                                Text(clock(Double(second))).font(.specialElite(9))
                                    .foregroundColor(.sdRed.opacity(0.65)).offset(x: Double(second) * pps + 3, y: 8)
                            }
                        }.frame(height: 26).contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { value in seek(Double(value.location.x) / pps) })
                        ForEach(1...4, id: \.self) { track in
                            ZStack(alignment: .topLeading) {
                                Rectangle().fill(Color.white.opacity(track % 2 == 0 ? 0.018 : 0.008))
                                Rectangle().fill(Color.white.opacity(0.055)).frame(height: 1)
                                ForEach(vm.audioClips.filter { $0.track == track }) { clip in
                                    StudioAudioTimelineClip(vm: vm, clip: clip, pointsPerSecond: pps,
                                        stop: { timeline.stop(); audio.stop(); vm.stopPlayback() })
                                        .frame(width: max(64, clip.duration * pps), height: 58)
                                        .offset(x: clip.startTime * pps, y: 6)
                                }
                            }.frame(height: rowHeight)
                        }
                    }.frame(width: width, alignment: .leading)
                        .overlay(alignment: .topLeading) {
                            Rectangle().fill(Color.sdRed).frame(width: 2)
                                .overlay(alignment: .top) { Circle().fill(Color.sdRed).frame(width: 12, height: 12) }
                                .offset(x: vm.audioPlayheadTime * pps).allowsHitTesting(false)
                        }
                }
            }
        }
    }
    private func clipInspector(_ clip: AudioClip) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(clip.soundName).font(.specialElite(12)).lineLimit(1)
                Button { apply(.mute(!clip.isMuted), clip: clip) } label: {
                    Image(systemName: clip.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 44, height: 44)
                }.accessibilityLabel(clip.isMuted ? "Unmute selected clip" : "Mute selected clip")
                Slider(value: $volume, in: 0...1, onEditingChanged: { editing in
                    if editing { timeline.stop(); audio.stop(); vm.stopPlayback(); volumeRevision = vm.document.revision }
                    else if let revision = volumeRevision {
                        do { try vm.editSelectedAudioClip(clip.id, expectedRevision: revision, edit: .volume(volume)) }
                        catch { vm.message = error.localizedDescription }
                        volumeRevision = nil
                    }
                }).tint(.sdRed).accessibilityIdentifier("studio.audio.volume")
                Text("\(Int(volume * 100))%").font(.caption2).frame(width: 30)
                Button("Delete") { timeline.stop(); audio.stop(); vm.stopPlayback(); vm.deleteAudioClip(clip.id) }
                    .foregroundColor(.sdRed).font(.specialElite(11)).frame(minHeight: 44)
                    .accessibilityIdentifier("studio.audio.delete")
            }
            HStack {
                Text(String(format: "Start %.2fs · Source %.2fs · %.2fs", clip.startTime, clip.sourceOffset, clip.duration))
                    .font(.caption2).foregroundColor(.white.opacity(0.5))
                    .accessibilityIdentifier("studio.audio.clip-timing")
                Spacer()
                Button("− frame") { apply(.trim(sourceOffset: clip.sourceOffset, duration: max(1 / 48_000, clip.duration - 1 / Double(vm.fps))), clip: clip) }
                Button("+ frame") { apply(.trim(sourceOffset: clip.sourceOffset, duration: clip.duration + 1 / Double(vm.fps)), clip: clip) }
            }.font(.caption2).foregroundColor(.sdRed)
        }.padding(.horizontal, 12).padding(.bottom, 8)
            .background(Color.white.opacity(0.02))
    }
    private func apply(_ edit: StudioAudioClipEdit, clip: AudioClip) {
        timeline.stop(); audio.stop(); vm.stopPlayback()
        do { try vm.editSelectedAudioClip(clip.id, expectedRevision: vm.document.revision, edit: edit) }
        catch { vm.message = error.localizedDescription }
    }
}

private struct StudioAudioTimelineClip: View {
    @ObservedObject var vm: StudioViewModel
    let clip: AudioClip
    let pointsPerSecond: Double
    let stop: () -> Void
    @State private var revision: Int?
    @State private var captured: AudioClip?
    @GestureState private var translation: CGSize = .zero
    var body: some View {
        HStack(spacing: 0) {
            handle(leading: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(clip.soundName).lineLimit(1).font(.specialElite(11))
                Text(String(format: "%.2fs", clip.duration)).font(.system(size: 8)).foregroundColor(.white.opacity(0.4))
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle()).onTapGesture { stop(); vm.selectedAudioClip = clip }
                .gesture(moveGesture)
            handle(leading: false)
        }.background(Color.sdRed.opacity(clip.isMuted ? 0.05 : 0.16)).cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(vm.selectedCurrentAudioClip?.id == clip.id ? Color.white.opacity(0.5) : Color.sdRed.opacity(0.5)))
            .opacity(clip.isMuted ? 0.55 : 1)
            .offset(x: translation.width)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("studio.audio.clip.\(clip.id)")
            .onChange(of: translation) { old, new in
                if new == .zero, old != .zero { revision = nil; captured = nil }
            }
    }
    private func begin() {
        guard revision == nil else { return }
        stop(); vm.selectedAudioClip = clip; revision = vm.document.revision; captured = clip
    }
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($translation) { value, state, _ in state = value.translation }
            .onChanged { _ in begin() }
            .onEnded { value in
                defer { revision = nil; captured = nil }
                guard let revision, let captured,
                      let time = StudioAudioTimelineGeometry.time(at: captured.startTime * pointsPerSecond + value.translation.width,
                        pointsPerSecond: pointsPerSecond, fps: vm.fps, snap: vm.snapEnabled) else { return }
                let lane = min(4, max(1, captured.track + Int((value.translation.height / 70).rounded())))
                do { try vm.editSelectedAudioClip(clip.id, expectedRevision: revision, edit: .place(start: time, track: lane)) }
                catch { vm.message = error.localizedDescription }
            }
    }
    private func handle(leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.sdRed.opacity(0.8)).frame(width: 4)
            .padding(.horizontal, 5).padding(.vertical, 9).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 6)
                .onChanged { _ in begin() }
                .onEnded { value in
                    defer { revision = nil; captured = nil }
                    guard let revision, let captured else { return }
                    let delta = Double(value.translation.width) / pointsPerSecond
                    let raw = leading ? captured.sourceOffset + delta : captured.duration + delta
                    guard let changed = StudioAudioTimelineGeometry.snapped(max(0, raw), fps: vm.fps, enabled: vm.snapEnabled) else { return }
                    let offset = leading ? changed : captured.sourceOffset
                    let duration = leading ? captured.duration + captured.sourceOffset - changed : changed
                    do { try vm.editSelectedAudioClip(clip.id, expectedRevision: revision, edit: .trim(sourceOffset: offset, duration: duration)) }
                    catch { vm.message = error.localizedDescription }
                })
            .accessibilityLabel(leading ? "Trim audio source start" : "Trim audio end")
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
            Text("Adds audio at the selected frame. Move and trim clips in the timeline, then include them in MP4 export.")
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
    @ObservedObject var timeline: StudioAudioTimelineSession
    @State private var auditionID: String?
    var body: some View {
        LazyVStack(spacing: 8) {
            ForEach(vm.audioClips) { clip in
                HStack {
                    Button {
                        audio.stop(); timeline.stop(); vm.stopPlayback(); vm.selectedAudioClip = clip
                        if auditionID == clip.id { auditionID = nil; return }
                        guard let id = clip.assetID, let track = vm.audioTrack(forAssetID: id) else { return }
                        var solo = vm.document; var audible = clip; audible.startTime = 0; solo.audioClips = [audible]
                        let project = vm.document.id, revision = vm.document.revision
                        auditionID = clip.id
                        _ = timeline.play(document: solo, tracks: [track], duration: clip.duration, from: 0,
                            stillCurrent: { vm.isEditing && vm.document.id == project && vm.document.revision == revision },
                            onTime: { _, playing in if !playing { auditionID = nil } })
                    } label: {
                        Image(systemName: auditionID == clip.id && timeline.isPlaying ? "stop.fill" : "play.fill")
                            .frame(width: 44, height: 44).background(Color.white.opacity(0.06)).clipShape(Circle())
                    }.disabled(audio.isBusy || timeline.isPreparing || clip.assetID == nil)
                        .accessibilityLabel("Preview " + clip.soundName)
                    Button { vm.selectedAudioClip = clip } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(clip.soundName).font(.specialElite(14)).lineLimit(1)
                            Text(String(format: "%.2fs · Track %d%@", clip.duration, clip.track, clip.isMuted ? " · Muted" : ""))
                                .font(.caption2).foregroundColor(.white.opacity(0.5))
                            if let id = clip.assetID, let measured = audio.measurements[id] {
                                MeasuredAudioWaveform(peaks: measured.peaks).frame(height: 14)
                            }
                        }
                    }
                    Spacer()
                }.padding(.horizontal, 16)
                Divider().opacity(0.1)
            }
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
