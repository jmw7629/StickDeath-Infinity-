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
    @State private var browseAllSounds = false
    @State private var favoriteSounds = Set<String>()
    @State private var favoritesOnly = false
    @State private var favoritesNotice: String?
    @State private var soundDuration: StudioSoundCatalogue.DurationFilter = .any
    @State private var soundSort: StudioSoundCatalogue.Sort = .catalogue
    @State private var catalogue: StudioSoundCatalogue?
    @State private var catalogueError: String?
    @State private var catalogueLoadID = UUID()
    @State private var libraryTrack = 1
    @State private var trimCapture: StudioViewModel.AudioTrimCapture?
    @State private var fadeCapture: StudioViewModel.AudioFadeCapture?
    @State private var timelineZoom = 1.0
    private let background = Color(hex: "0D0D12")

    var body: some View {
        GeometryReader { geometry in
            // Keyboard presentation changes the available height. Keep the
            // same view hierarchy so the active search field retains focus.
            ScrollView(.vertical) {
                workspace(height: geometry.size.height)
                    .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("studio.audio.compact.scroll")
        }
        .frame(maxWidth: 900, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        .onAppear {
            showingLibrary = opensLibrary
        }
        .task(id: catalogueLoadID) {
            guard catalogue == nil else { return }
            catalogueError = nil
            do {
                let loaded = try await StudioSoundCatalogue.loadBundled()
                try Task.checkCancellation()
                catalogue = loaded
                favoriteSounds = StudioSoundFavorites(allowedIDs: Set(loaded.sounds.map(\.id))).ids
            } catch is CancellationError {
                // The panel disappeared; do not show a stale loading error.
            } catch {
                if !Task.isCancelled { catalogueError = error.localizedDescription }
            }
        }
        .onChange(of: search) { if search.count > 256 { search = String(search.prefix(256)) } }
        .onDisappear { audio.close(); timeline.close(); vm.stopPlayback(); fadeCapture = nil }
        .onChange(of: vm.document.id) { _, _ in audio.close(); timeline.close(); trimCapture = nil; fadeCapture = nil }
        .onChange(of: vm.playbackLoops) { _, _ in timeline.stop() }
        .onChange(of: vm.document.revision) { _, _ in
            timeline.stop(); audio.stop()
        }
        .onChange(of: vm.selectedCurrentAudioClip?.id) { _, _ in
            trimCapture = nil; fadeCapture = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { audio.close(); timeline.close(); vm.stopPlayback(); fadeCapture = nil }
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
                audioOperationStatus
                if timeline.isPreparing {
                    HStack {
                        ProgressView(value: timeline.progress).tint(.sdRed)
                        Button("Cancel") { timeline.stop() }.foregroundColor(.sdStudioActionText)
                    }.padding(.horizontal, 16).padding(.bottom, 8)
                }
                if let notice = timeline.notice ?? vm.message {
                    Text(notice).font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 16).accessibilityIdentifier("studio.audio.timelineNotice")
                }
                timelineControls
                timelineGrid
                    .frame(height: 306, alignment: .top)
                Spacer(minLength: 0)
                if let clip = vm.selectedCurrentAudioClip { clipInspector(clip) }
                HStack {
                    Text("Drag clips to move · Drag edges to trim").foregroundColor(.sdStudioSecondaryText)
                    Spacer()
                    Button("+ Add Sound") { showingLibrary = true }.foregroundColor(.sdStudioActionText)
                }.font(.specialElite(10)).padding(12)
            }
            .background(background).foregroundColor(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var audioOperationStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if audio.isBusy {
                HStack {
                    ProgressView(value: audio.progress).tint(.sdRed)
                        .accessibilityLabel("Audio operation progress")
                        .accessibilityValue("\(Int((audio.progress * 100).rounded())) percent")
                    Button("Cancel") { audio.cancel() }.font(.specialElite(12)).foregroundColor(.sdStudioActionText)
                        .frame(minWidth: 44, minHeight: 44).accessibilityLabel("Cancel audio import or analysis")
                        .accessibilityIdentifier("studio.audio.cancel")
                }
            }
            if let notice = audio.notice {
                Text(notice).font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)).foregroundColor(.sdStudioActionText)
                    .accessibilityIdentifier("studio.audio.notice")
            } else if let id = audio.lastImportedClipID, vm.audioClips.contains(where: { $0.id == id }) {
                Text("Audio added · \(vm.saveTimeAgo)").font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.sdStudioSecondaryText)
                    .accessibilityIdentifier("studio.audio.imported")
            }
        }.padding(.horizontal, 16).padding(.bottom, 8)
    }
    private var header: some View {
        HStack(spacing: 8) {
            Text("♫ Audio Timeline").font(.specialElite(16))
            Text("\(vm.audioClips.count) clips").font(.specialElite(10))
                .padding(5).background(Color.white.opacity(0.05)).clipShape(Capsule())
                .accessibilityIdentifier("studio.audio.clip-count")
            Spacer(minLength: 0)
            Button(vm.snapEnabled ? "Snap: ON" : "Snap: OFF") { vm.snapEnabled.toggle() }
                .font(.specialElite(10)).foregroundColor(.sdStudioActionText)
                .accessibilityIdentifier("studio.audio.snap")
                .accessibilityHint("Snap to frames, the playhead and other clip edges while dragging or trimming.")
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
                .accessibilityHint("Touch and hold for Loop playback options.")
                .contextMenu { Toggle("Loop playback", isOn: $vm.playbackLoops) }
            Button { seek(vm.audioDuration) } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }
                .accessibilityLabel("Audio end")
            Text(clock(vm.audioPlayheadTime)).foregroundColor(.sdStudioActionText)
            Text("/ " + clock(vm.audioDuration)).foregroundColor(.sdStudioSecondaryText)
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
            duration: vm.audioDuration, from: start, loop: vm.playbackLoops,
            stillCurrent: { vm.isEditing && vm.document.id == id && vm.document.revision == revision },
            onTime: { time, playing in
                guard vm.document.id == id, vm.document.revision == revision else { return }
                vm.displayAudioPlaybackTime(min(vm.audioDuration, time), playing: playing)
            })
    }
    private var library: some View {
        VStack(spacing: 10) {
            HStack {
                if category != nil || browseAllSounds { Button("‹") { category = nil; browseAllSounds = false; search = ""; soundDuration = .any; soundSort = .catalogue }.frame(width: 32, height: 44).accessibilityLabel("All sound categories") }
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
            ScrollViewReader { libraryScroll in
            ScrollView {
                VStack(spacing: 10) {
                    AudioFilesImportControls(vm: vm, audio: audio, stopPlayback: { timeline.stop(); audio.stop(); vm.stopPlayback() })
                    AudioProjectClips(vm: vm, audio: audio, timeline: timeline)
                    if let catalogue {
                        Text("\(catalogue.sounds.count) offline sounds · CC0")
                            .font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.sdStudioSecondaryText)
                            .accessibilityIdentifier("studio.audio.catalogue.count")
                        Toggle("Favorites only (\(favoriteSounds.count))", isOn: $favoritesOnly)
                            .font(.specialElite(12)).tint(.sdRed).padding(.horizontal, 16)
                            .accessibilityIdentifier("studio.audio.favorites.filter")
                        if let favoritesNotice {
                            Text(favoritesNotice).font(.specialElite(11)).foregroundColor(.sdStudioSecondaryText)
                        }
                        if category != nil || !search.isEmpty || browseAllSounds || favoritesOnly {
                            HStack {
                                Picker("Sound duration", selection: $soundDuration) {
                                    ForEach(StudioSoundCatalogue.DurationFilter.allCases) { Text($0.rawValue).tag($0) }
                                }.accessibilityIdentifier("studio.audio.filter.duration")
                                Picker("Sort sounds", selection: $soundSort) {
                                    ForEach(StudioSoundCatalogue.Sort.allCases) { Text($0.rawValue).tag($0) }
                                }.accessibilityIdentifier("studio.audio.sort")
                            }.pickerStyle(.menu).font(.specialElite(11)).tint(.sdStudioActionText)
                                .frame(minHeight: 44).padding(.horizontal, 12)
                            catalogueRows(catalogue)
                        } else {
                            Button("Browse all sounds") { browseAllSounds = true }
                                .font(.specialElite(12)).foregroundColor(.sdStudioActionText).frame(minHeight: 44)
                                .accessibilityIdentifier("studio.audio.browse-all")
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                ForEach(catalogue.categories, id: \.self) { name in
                                    Button { category = name } label: {
                                        VStack(alignment: .leading, spacing: 12) {
                                            Image(systemName: "waveform").font(.title2).foregroundColor(.sdStudioActionText)
                                            Text(name).font(.specialElite(15)).multilineTextAlignment(.leading)
                                            Text("\(catalogue.search("", category: name).count) sounds")
                                                .font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.sdStudioSecondaryText)
                                        }.frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                                            .padding(14).background(Color.sdRed.opacity(0.06)).cornerRadius(18)
                                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.sdRed.opacity(0.18)))
                                    }.accessibilityIdentifier("studio.audio.category." + name)
                                }
                            }.padding(.horizontal, 16)
                        }
                    } else if let catalogueError {
                        Text(catalogueError).font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.sdStudioSecondaryText).padding(16)
                        Button("Retry sound library") { self.catalogueError = nil; catalogueLoadID = UUID() }
                            .font(.specialElite(12)).foregroundColor(.sdStudioActionText).frame(minHeight: 44)
                            .accessibilityIdentifier("studio.audio.catalogue.retry")
                    } else {
                        ProgressView("Loading sound library…")
                            .font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)).tint(.sdRed).padding(16)
                            .accessibilityIdentifier("studio.audio.catalogue.loading")
                    }
                }.padding(.bottom, 12).id("studio.audio.library.start")
            }
            .accessibilityIdentifier("studio.audio.library.scroll")
            // A new filter is a new result list. Keeping the category grid's
            // offset would hide its count, Clear filters and first sounds.
            .onChange(of: category) { _, _ in libraryScroll.scrollTo("studio.audio.library.start", anchor: .top) }
            .onChange(of: search) { _, _ in libraryScroll.scrollTo("studio.audio.library.start", anchor: .top) }
            .onChange(of: soundDuration) { _, _ in libraryScroll.scrollTo("studio.audio.library.start", anchor: .top) }
            .onChange(of: soundSort) { _, _ in libraryScroll.scrollTo("studio.audio.library.start", anchor: .top) }
            .onChange(of: favoritesOnly) { _, _ in libraryScroll.scrollTo("studio.audio.library.start", anchor: .top) }
            .onChange(of: browseAllSounds) { _, _ in libraryScroll.scrollTo("studio.audio.library.start", anchor: .top) }
            }
        }
    }
    private func catalogueRows(_ catalogue: StudioSoundCatalogue) -> some View {
        let results = catalogue.search(search, category: category, duration: soundDuration, sort: soundSort)
            .filter { !favoritesOnly || favoriteSounds.contains($0.id) }
        return LazyVStack(spacing: 8) {
            HStack {
                Text("\(results.count) matching sounds").font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.sdStudioSecondaryText)
                    .accessibilityIdentifier("studio.audio.search.count")
                Spacer()
                Button("Clear filters") { favoritesOnly = false; search = ""; category = nil; soundDuration = .any; soundSort = .catalogue; browseAllSounds = true; searchFocused = false }
                    .font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)).foregroundColor(.sdStudioActionText)
                    .accessibilityIdentifier("studio.audio.search.clear")
            }.padding(.horizontal, 16)
            if results.isEmpty {
                Text(favoritesOnly && favoriteSounds.isEmpty ? "No favorite sounds yet. Turn off Favorites only and tap a sound’s star to save it here." : "No sounds match these filters. Try another word or clear the filters.")
                    .font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)).foregroundColor(.sdStudioSecondaryText).padding(16)
                    .accessibilityIdentifier("studio.audio.search.empty")
            }
            Picker("Add sounds to track", selection: $libraryTrack) {
                ForEach(1...4, id: \.self) { Text("Track \($0)").tag($0) }
            }.tint(.sdStudioActionText).accessibilityIdentifier("studio.audio.catalogue.track")
            ForEach(results) { sound in
                HStack(spacing: 12) {
                    Button {
                        timeline.stop(); vm.stopPlayback()
                        if audio.playingClipID == sound.id { audio.stop(); return }
                        let project = vm.document.id, revision = vm.document.revision
                        _ = audio.useCatalogueSound(sound, catalogue: catalogue,
                            stillCurrent: { vm.isEditing && vm.document.id == project && vm.document.revision == revision })
                    } label: {
                        Image(systemName: audio.playingClipID == sound.id ? "stop.fill" : "play.fill")
                            .frame(width: 44, height: 44).background(Color.white.opacity(0.06)).clipShape(Circle())
                    }.disabled(audio.isBusy || timeline.isPreparing)
                        .accessibilityLabel((audio.playingClipID == sound.id ? "Stop preview " : "Preview ") + sound.title)
                        .accessibilityIdentifier("studio.audio.catalogue.preview." + sound.id)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sound.title).font(.specialElite(14)).lineLimit(1)
                        HStack {
                            Text(String(format: "%.2fs", sound.duration)).font(.specialElite(11))
                            MeasuredAudioWaveform(peaks: sound.waveformPeaks).frame(width: 56, height: 14)
                        }.foregroundColor(.sdStudioSecondaryText)
                        if let tags = sound.tags, !tags.isEmpty {
                            Text(tags.prefix(3).joined(separator: " · "))
                                .font(.specialElite(9)).foregroundColor(.sdStudioActionText).lineLimit(1)
                                .accessibilityLabel("Tags: " + tags.joined(separator: ", "))
                        }
                        Text(sound.author + " · CC0").font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
                        Button {
                            let store = StudioSoundFavorites(allowedIDs: Set(catalogue.sounds.map(\.id)))
                            favoritesNotice = store.toggle(sound.id) ? nil : "Keep up to 256 favorite sounds. Remove a favorite before adding another."
                            favoriteSounds = store.ids
                        } label: {
                            Label(favoriteSounds.contains(sound.id) ? "Favorited" : "Favorite",
                                  systemImage: favoriteSounds.contains(sound.id) ? "star.fill" : "star")
                                .font(.specialElite(10)).frame(minHeight: 44)
                        }.foregroundColor(.sdStudioActionText)
                            .accessibilityLabel((favoriteSounds.contains(sound.id) ? "Remove favorite " : "Favorite ") + sound.title)
                            .accessibilityIdentifier("studio.audio.favorite." + sound.id)
                    }
                    Spacer(minLength: 0)
                    Button {
                        timeline.stop(); audio.stop(); vm.stopPlayback()
                        let target = AudioImportLease(projectID: vm.document.id, revision: vm.document.revision,
                            frameID: vm.document.activeFrameID, track: libraryTrack, playhead: vm.audioPlayheadTime)
                        _ = audio.useCatalogueSound(sound, catalogue: catalogue,
                            stillCurrent: { target.isCurrent(vm) }, attach: { imported in
                                try vm.attachImportedAudio(imported, expectedProjectID: target.projectID,
                                    expectedRevision: target.revision, frameID: target.frameID, trackNumber: target.track, atPlayhead: target.playhead)
                            })
                    } label: {
                        Image(systemName: "plus").foregroundColor(.sdStudioActionText).frame(width: 44, height: 44)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.sdRed.opacity(0.35)))
                    }.disabled(audio.isBusy || timeline.isPreparing || vm.isSaving)
                        .accessibilityLabel("Add " + sound.title)
                        .accessibilityIdentifier("studio.audio.catalogue.add." + sound.id)
                }.padding(.horizontal, 16)
                Divider().opacity(0.15)
            }
        }
    }
    private var timelineControls: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(vm.audioClips.sorted {
                    if $0.track != $1.track { return $0.track < $1.track }
                    if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
                    return $0.id < $1.id
                }) { clip in
                    Button("Track \(clip.track) · \(clip.soundName) · \(clock(clip.startTime))") {
                        timeline.stop(); audio.stop(); vm.stopPlayback()
                        vm.selectedAudioClip = clip
                    }.accessibilityIdentifier("studio.audio.select-clip.\(clip.id)")
                }
            } label: {
                Label("Clips", systemImage: "list.bullet").frame(minWidth: 68, minHeight: 44)
            }.disabled(vm.audioClips.isEmpty)
                .accessibilityLabel("Select audio clip")
                .accessibilityIdentifier("studio.audio.clip-picker")
            Spacer(minLength: 0)
            Button { timelineZoom = max(0.5, timelineZoom / 2) } label: {
                Image(systemName: "minus.magnifyingglass").frame(width: 44, height: 44)
            }.disabled(timelineZoom <= 0.5)
                .accessibilityLabel("Zoom audio timeline out")
                .accessibilityIdentifier("studio.audio.zoom-out")
            Text("\(Int(timelineZoom * 100))%")
                .frame(minWidth: 42)
                .accessibilityIdentifier("studio.audio.zoom-value")
            Button { timelineZoom = min(8, timelineZoom * 2) } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: 44, height: 44)
            }.disabled(timelineZoom >= 8)
                .accessibilityLabel("Zoom audio timeline in")
                .accessibilityIdentifier("studio.audio.zoom-in")
        }.font(.specialElite(11)).foregroundColor(.white.opacity(0.75))
            .padding(.horizontal, 12)
    }
    private var timelineGrid: some View {
        GeometryReader { geometry in
            let pps = 110.0 * timelineZoom
            let length = max(5, min(1300, vm.audioDuration + 1))
            let width = max(geometry.size.width - 44, length * pps)
            let rowHeight = 70.0
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Color.clear.frame(width: 44, height: 26)
                    ForEach(1...4, id: \.self) { track in
                        let muted = vm.document.isAudioTrackMuted(track)
                        VStack(spacing: 0) {
                            Text("\(track)").font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                            Button {
                                timeline.stop(); audio.stop(); vm.stopPlayback()
                                do { try vm.setAudioTrackMuted(track, muted: !muted, expectedRevision: vm.document.revision) }
                                catch { vm.message = error.localizedDescription }
                            } label: {
                                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .font(.system(size: 12)).frame(width: 44, height: 44)
                            }.disabled(vm.isSaving)
                                .accessibilityLabel(muted ? "Unmute track \(track)" : "Mute track \(track)")
                                .accessibilityValue(muted ? "Muted" : "Audible")
                                .accessibilityIdentifier("studio.audio.track-mute.\(track)")
                        }.frame(width: 44, height: rowHeight)
                    }
                }.frame(width: 44, alignment: .top)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("studio.audio.track-labels")
                // All four lanes scroll vertically with the workspace. A
                // second vertical scroller traps swipes and detaches labels.
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(Color.white.opacity(0.02))
                            ForEach(Array(stride(from: 0, through: Int(ceil(length)), by: length > 120 ? 10 : 1)), id: \.self) { second in
                                Text(clock(Double(second))).font(.specialElite(9))
                                    .foregroundColor(.sdStudioActionText).offset(x: Double(second) * pps + 3, y: 8)
                            }
                        }.frame(height: 26).contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { value in seek(Double(value.location.x) / pps) })
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Audio playhead")
                            .accessibilityValue(clock(vm.audioPlayheadTime))
                            .accessibilityIdentifier("studio.audio.playhead-ruler")
                            .accessibilityAdjustableAction { direction in
                                switch direction {
                                case .increment: seek(vm.audioPlayheadTime + 1 / Double(vm.fps))
                                case .decrement: seek(vm.audioPlayheadTime - 1 / Double(vm.fps))
                                @unknown default: break
                                }
                            }
                        ForEach(1...4, id: \.self) { track in
                            ZStack(alignment: .topLeading) {
                                Rectangle().fill(Color.white.opacity(track % 2 == 0 ? 0.018 : 0.008))
                                Rectangle().fill(Color.white.opacity(0.055)).frame(height: 1)
                                ForEach(vm.audioClips.filter { $0.track == track }) { clip in
                                    StudioAudioTimelineClip(vm: vm, clip: clip, pointsPerSecond: pps,
                                        measurement: clip.assetID.flatMap { audio.measurements[$0] },
                                        stop: { timeline.stop(); audio.stop(); vm.stopPlayback() })
                                        .frame(width: clip.duration * pps, height: 58)
                                        .offset(x: clip.startTime * pps, y: 6)
                                }
                            }.frame(height: rowHeight)
                        }
                    }.frame(width: width, height: 306, alignment: .topLeading)
                        .overlay(alignment: .topLeading) {
                            Rectangle().fill(Color.sdRed).frame(width: 2)
                                .overlay(alignment: .top) { Circle().fill(Color.sdRed).frame(width: 12, height: 12) }
                                .offset(x: vm.audioPlayheadTime * pps).allowsHitTesting(false)
                        }
                }.frame(height: 306, alignment: .top)
                    .accessibilityIdentifier("studio.audio.lanes")
            }.frame(width: geometry.size.width, height: 306, alignment: .topLeading)
        }
    }
    private func clipInspector(_ clip: AudioClip) -> some View {
        let duplication = vm.prepareAudioDuplication()
        let split = vm.prepareAudioSplit()
        return VStack(spacing: 6) {
            if vm.document.isAudioTrackMuted(clip.track) {
                Text("Track \(clip.track) is muted")
                    .font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.sdStudioActionText)
                    .accessibilityIdentifier("studio.audio.selected-track-muted")
            }
            HStack {
                Text(clip.soundName).font(.specialElite(12)).lineLimit(1)
                Button { apply(.mute(!clip.isMuted), clip: clip) } label: {
                    Image(systemName: clip.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 44, height: 44)
                }.accessibilityLabel(clip.isMuted ? "Unmute selected clip" : "Mute selected clip")
                    .accessibilityIdentifier("studio.audio.clip-mute")
                StudioAudioClipVolumeControl(vm: vm, clip: clip) {
                    timeline.stop(); audio.stop(); vm.stopPlayback()
                }
                .id("\(vm.document.id):\(vm.document.revision):\(clip.id)")
                Button("Delete") { timeline.stop(); audio.stop(); vm.stopPlayback(); vm.deleteAudioClip(clip.id) }
                    .foregroundColor(.sdStudioActionText).font(.specialElite(11)).frame(minHeight: 44)
                    .accessibilityIdentifier("studio.audio.delete")
            }
            if let id = clip.assetID, let measurement = audio.measurements[id] {
                MeasuredAudioWaveform(peaks: measurement.peaks, sourceDuration: measurement.duration,
                    sourceOffset: clip.sourceOffset, duration: clip.duration).frame(height: 28)
                    .accessibilityIdentifier("studio.audio.selected-waveform")
            } else if let id = clip.assetID, let track = vm.audioTrack(forAssetID: id) {
                Button("Load measured waveform") {
                    timeline.stop(); audio.stop(); vm.stopPlayback()
                    let project = vm.document.id
                    _ = audio.analyze(track, stillCurrent: {
                        vm.isEditing && vm.document.id == project && vm.audioTrack(forAssetID: id)?.audioData == track.audioData
                    })
                }.disabled(audio.isBusy || timeline.isPreparing)
                    .font(.specialElite(11)).frame(minHeight: 44)
                    .accessibilityIdentifier("studio.audio.analyze-waveform")
            }
            StudioAudioTrackVolumeControl(vm: vm, track: clip.track) {
                timeline.stop(); audio.stop(); vm.stopPlayback()
            }
            .id("\(vm.document.id):\(vm.document.revision):\(clip.track)")
            HStack {
                Text(String(format: "Start %.2fs · Source %.2fs · %.2fs", clip.startTime, clip.sourceOffset, clip.duration))
                    .font(.specialElite(11)).foregroundColor(.sdStudioSecondaryText)
                    .accessibilityIdentifier("studio.audio.clip-timing")
                Spacer()
                Button("− frame") { apply(.trim(sourceOffset: clip.sourceOffset, duration: max(1 / 48_000, clip.duration - 1 / Double(vm.fps))), clip: clip) }
                Button("+ frame") { apply(.trim(sourceOffset: clip.sourceOffset, duration: clip.duration + 1 / Double(vm.fps)), clip: clip) }
            }.font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.sdStudioActionText)
            HStack {
                Button("Earlier 1 frame") {
                    apply(.place(start: max(0, clip.startTime - 1 / Double(vm.fps)), track: clip.track), clip: clip)
                }.disabled(clip.startTime <= 0)
                    .accessibilityIdentifier("studio.audio.nudge-earlier")
                Button("Later 1 frame") {
                    apply(.place(start: clip.startTime + 1 / Double(vm.fps), track: clip.track), clip: clip)
                }.accessibilityIdentifier("studio.audio.nudge-later")
                Menu("Track \(clip.track)") {
                    ForEach(1...4, id: \.self) { track in
                        Button("Move to track \(track)") { apply(.place(start: clip.startTime, track: track), clip: clip) }
                            .disabled(track == clip.track)
                    }
                }.accessibilityIdentifier("studio.audio.place-track")
            }.font(.specialElite(11)).foregroundColor(.sdStudioActionText).frame(minHeight: 44)
                .disabled(vm.isSaving || audio.isBusy || timeline.isPreparing)
            HStack {
                Button("Duplicate after") {
                    guard let duplication else { return }
                    timeline.stop(); audio.stop(); vm.stopPlayback()
                    do { try vm.duplicateAudioClip(duplication) }
                    catch { vm.message = error.localizedDescription }
                }.disabled(duplication == nil || audio.isBusy || timeline.isPreparing)
                    .font(.specialElite(11)).foregroundColor(.sdStudioActionText).frame(minHeight: 44)
                    .accessibilityLabel("Duplicate selected audio clip after its end")
                    .accessibilityIdentifier("studio.audio.duplicate")
                Menu("Repeat") {
                    ForEach([2, 4, 8, 16, 32], id: \.self) { count in
                        Button("Add \(count) copies after this clip") {
                            guard let duplication else { return }
                            timeline.stop(); audio.stop(); vm.stopPlayback()
                            do { try vm.repeatAudioClip(duplication, additionalCopies: count) }
                            catch { vm.message = error.localizedDescription }
                        }
                    }
                }.disabled(duplication == nil || audio.isBusy || timeline.isPreparing)
                    .font(.specialElite(11)).foregroundColor(.sdStudioActionText).frame(minHeight: 44)
                    .accessibilityIdentifier("studio.audio.repeat")
                    .accessibilityHint("Adds consecutive editable clips using the same source and one Undo step.")
                Button("Split at playhead") {
                    guard let split else { return }
                    timeline.stop(); audio.stop(); vm.stopPlayback()
                    do { try vm.splitAudioClip(split) }
                    catch { vm.message = error.localizedDescription }
                }.disabled(split == nil || audio.isBusy || timeline.isPreparing)
                    .font(.specialElite(11)).foregroundColor(.sdStudioActionText).frame(minHeight: 44)
                    .accessibilityHint("Move the red playhead inside the selected clip first")
                    .accessibilityIdentifier("studio.audio.split")
                Button("Trim values") {
                    timeline.stop(); audio.stop(); vm.stopPlayback()
                    fadeCapture = nil
                    trimCapture = vm.prepareAudioTrim()
                }.disabled(duplication == nil || audio.isBusy || timeline.isPreparing)
                    .font(.specialElite(11)).foregroundColor(.sdStudioActionText).frame(minHeight: 44)
                    .accessibilityIdentifier("studio.audio.trim.open")
                Spacer()
            }
            HStack {
                Button {
                    timeline.stop(); audio.stop(); vm.stopPlayback(); trimCapture = nil
                    fadeCapture = vm.prepareAudioFades()
                } label: { Text("Fade in / out").frame(minHeight: 44) }
                    .disabled(duplication == nil || audio.isBusy || timeline.isPreparing)
                    .font(.specialElite(12)).foregroundColor(.sdStudioActionText)
                    .accessibilityIdentifier("studio.audio.fades.open")
                Spacer()
                Text(clip.fadeEnvelope == nil ? "No fades" : "Source fades on")
                    .font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.sdStudioSecondaryText)
                    .accessibilityIdentifier("studio.audio.fades.status")
            }
            if let fadeCapture {
                StudioAudioFadeEditor(vm: vm, capture: fadeCapture) { self.fadeCapture = nil }
                    .id(fadeCapture.selection.clip.id + ":" + String(fadeCapture.selection.revision))
            }
            if let trimCapture {
                StudioAudioNumericTrimEditor(vm: vm, capture: trimCapture) { self.trimCapture = nil }
                    .id(trimCapture.selection.clip.id + ":" + String(trimCapture.selection.revision))
            }
        }.padding(.horizontal, 12).padding(.bottom, 8)
            .background(Color.white.opacity(0.02))
    }
    private func apply(_ edit: StudioAudioClipEdit, clip: AudioClip) {
        timeline.stop(); audio.stop(); vm.stopPlayback()
        do { try vm.editSelectedAudioClip(clip.id, expectedRevision: vm.document.revision, edit: edit) }
        catch { vm.message = error.localizedDescription }
    }
}

private struct StudioAudioClipVolumeControl: View {
    @ObservedObject var vm: StudioViewModel
    let clip: AudioClip
    let projectID: UUID
    let revision: Int
    let stopPlayback: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var volume: Double
    @State private var capture: StudioViewModel.AudioClipVolumeCapture?

    init(vm: StudioViewModel, clip: AudioClip, stopPlayback: @escaping () -> Void) {
        self.vm = vm; self.clip = clip; self.stopPlayback = stopPlayback
        projectID = vm.document.id; revision = vm.document.revision
        _volume = State(initialValue: clip.volume)
    }
    private func discardDraft() {
        capture = nil
        volume = vm.document.audioClips.first(where: { $0.id == clip.id })?.volume ?? clip.volume
    }
    var body: some View {
        HStack {
            Slider(value: $volume, in: 0...1, onEditingChanged: { editing in
                if editing {
                    stopPlayback()
                    guard let current = vm.prepareAudioClipVolume(),
                          current.selection.projectID == projectID,
                          current.selection.revision == revision,
                          current.selection.clip == clip else { discardDraft(); return }
                    capture = current
                } else {
                    defer { discardDraft() }
                    guard let capture else { return }
                    do { try vm.setAudioClipVolume(capture, volume: volume) }
                    catch { vm.message = error.localizedDescription }
                }
            }).tint(.sdRed)
                .disabled(vm.isSaving || vm.prepareAudioClipVolume() == nil)
                .accessibilityIdentifier("studio.audio.volume")
                .accessibilityLabel("Selected clip volume")
                .accessibilityValue("\(Int((volume * 100).rounded())) percent")
            Text("\(Int((volume * 100).rounded()))%")
                .font(.specialElite(11)).frame(width: 30)
                .accessibilityIdentifier("studio.audio.clip-volume-value")
        }
        .onDisappear { discardDraft() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { discardDraft() } }
    }
}

private struct StudioAudioTrackVolumeControl: View {
    @ObservedObject var vm: StudioViewModel
    let track: Int
    let stopPlayback: () -> Void
    @State private var volume: Double
    @State private var capture: StudioViewModel.AudioTrackVolumeCapture?

    init(vm: StudioViewModel, track: Int, stopPlayback: @escaping () -> Void) {
        self.vm = vm; self.track = track; self.stopPlayback = stopPlayback
        _volume = State(initialValue: vm.document.audioTrackVolume(track))
    }
    var body: some View {
        HStack(spacing: 10) {
            Text("Track \(track) volume").font(.specialElite(10))
                .foregroundColor(.sdStudioSecondaryText)
            Slider(value: $volume, in: 0...1, onEditingChanged: { editing in
                if editing {
                    stopPlayback(); capture = vm.prepareAudioTrackVolume(track)
                } else {
                    defer { capture = nil; volume = vm.document.audioTrackVolume(track) }
                    guard let capture else { return }
                    do { try vm.setAudioTrackVolume(capture, volume: volume) }
                    catch { vm.message = error.localizedDescription }
                }
            }).tint(.sdRed)
                .disabled(vm.isSaving || vm.prepareAudioTrackVolume(track) == nil)
                .accessibilityLabel("Track \(track) volume")
                .accessibilityValue("\(Int((volume * 100).rounded())) percent")
                .accessibilityHint("Changes the whole track; individual clip levels stay unchanged")
                .accessibilityIdentifier("studio.audio.track-volume.\(track)")
            Text("\(Int((volume * 100).rounded()))%")
                .font(.specialElite(11)).frame(width: 38, alignment: .trailing)
                .accessibilityIdentifier("studio.audio.track-volume-value.\(track)")
        }.frame(minHeight: 44)
    }
}

private struct StudioAudioFadeEditor: View {
    @ObservedObject var vm: StudioViewModel
    let capture: StudioViewModel.AudioFadeCapture
    let dismiss: () -> Void
    @State private var incoming: String
    @State private var outgoing: String
    @State private var notice: String?
    @FocusState private var focused: Field?
    private enum Field: Hashable { case incoming, outgoing }

    init(vm: StudioViewModel, capture: StudioViewModel.AudioFadeCapture, dismiss: @escaping () -> Void) {
        self.vm = vm; self.capture = capture; self.dismiss = dismiss
        let envelope = capture.selection.clip.fadeEnvelope, rate = StudioAudioTimelineGeometry.sampleRate
        _incoming = State(initialValue: String(Double(envelope?.fadeInFrames ?? 0) / rate))
        _outgoing = State(initialValue: String(Double(envelope?.fadeOutFrames ?? 0) / rate))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                input("Fade in (sec)", text: $incoming, field: .incoming)
                input("Fade out (sec)", text: $outgoing, field: .outgoing)
            }
            Text("Fades follow the source through Trim and Split. Apply resets them to this clip.")
                .font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.sdStudioSecondaryText)
            if let notice { Text(notice).font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).accessibilityIdentifier("studio.audio.fades.notice") }
            if vm.prepareAudioFades() != capture {
                Text("The clip changed. Cancel and reopen its fade options.").font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2))
            }
            HStack {
                Button { focused = nil; dismiss() } label: { Text("Cancel").frame(minHeight: 44) }
                    .accessibilityIdentifier("studio.audio.fades.cancel")
                Button { incoming = "0"; outgoing = "0"; notice = nil } label: { Text("Clear fades").frame(minHeight: 44) }
                    .accessibilityIdentifier("studio.audio.fades.clear")
                Spacer()
                Button {
                    focused = nil
                    guard let fadeIn = StudioViewModel.audioTrimSeconds(incoming),
                          let fadeOut = StudioViewModel.audioTrimSeconds(outgoing) else {
                        notice = "Enter a valid number of seconds in both fields."; return
                    }
                    do { try vm.setAudioFades(capture, fadeIn: fadeIn, fadeOut: fadeOut); dismiss() }
                    catch { notice = error.localizedDescription }
                } label: { Text("Apply fades").frame(minHeight: 44) }
                    .disabled(vm.prepareAudioFades() != capture)
                    .accessibilityIdentifier("studio.audio.fades.apply")
            }.font(.specialElite(12)).foregroundColor(.sdStudioActionText).frame(minHeight: 44)
        }.padding(10).background(Color.white.opacity(0.04)).cornerRadius(12)
    }
    private func input(_ title: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.sdStudioSecondaryText)
            TextField(title, text: text).keyboardType(.decimalPad).focused($focused, equals: field)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.specialElite(14)).padding(10).frame(minHeight: 44)
                .background(Color.white.opacity(0.06)).cornerRadius(8)
                .accessibilityIdentifier(field == .incoming ? "studio.audio.fades.in" : "studio.audio.fades.out")
        }.frame(maxWidth: .infinity)
    }
}

private struct StudioAudioNumericTrimEditor: View {
    @ObservedObject var vm: StudioViewModel
    let capture: StudioViewModel.AudioTrimCapture
    let dismiss: () -> Void
    @State private var source: String
    @State private var duration: String
    @State private var notice: String?
    @FocusState private var focused: Field?
    private enum Field: Hashable { case source, duration }

    init(vm: StudioViewModel, capture: StudioViewModel.AudioTrimCapture, dismiss: @escaping () -> Void) {
        self.vm = vm; self.capture = capture; self.dismiss = dismiss
        _source = State(initialValue: String(capture.selection.clip.sourceOffset))
        _duration = State(initialValue: String(capture.selection.clip.duration))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                input("Source start (sec)", text: $source, field: .source)
                input("Duration (sec)", text: $duration, field: .duration)
            }
            if let notice {
                Text(notice).font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.sdStudioActionText)
                    .accessibilityIdentifier("studio.audio.trim.notice")
            }
            if vm.prepareAudioTrim() != capture {
                Text("The clip changed. Cancel and reopen its trim values.").font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2))
            }
            HStack {
                Button("Cancel") { focused = nil; dismiss() }
                    .accessibilityIdentifier("studio.audio.trim.cancel")
                Spacer()
                Button("Apply trim") {
                    focused = nil
                    guard let offset = StudioViewModel.audioTrimSeconds(source),
                          let length = StudioViewModel.audioTrimSeconds(duration) else {
                        notice = "Enter a valid number of seconds in both fields."; return
                    }
                    do {
                        try vm.trimAudioClip(capture, sourceOffset: offset, duration: length)
                        dismiss()
                    } catch { notice = error.localizedDescription }
                }.disabled(vm.prepareAudioTrim() != capture)
                    .accessibilityIdentifier("studio.audio.trim.apply")
            }.font(.specialElite(12)).foregroundColor(.sdStudioActionText).frame(minHeight: 44)
        }.padding(10).background(Color.white.opacity(0.04)).cornerRadius(12)
    }
    private func input(_ title: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.sdStudioSecondaryText)
            TextField(title, text: text).keyboardType(.decimalPad).focused($focused, equals: field)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.specialElite(14)).padding(10)
                .background(Color.white.opacity(0.06)).cornerRadius(8)
                .accessibilityIdentifier(field == .source ? "studio.audio.trim.source" : "studio.audio.trim.duration")
        }.frame(maxWidth: .infinity)
    }
}

private struct StudioAudioTimelineClip: View {
    @ObservedObject var vm: StudioViewModel
    let clip: AudioClip
    let pointsPerSecond: Double
    let measurement: StudioAudioPreviewSession.Measurement?
    let stop: () -> Void
    @State private var revision: Int?
    @State private var captured: AudioClip?
    @State private var snapTargets: [Double] = []
    @State private var capturedPlayhead: Double?
    @State private var capturedScale: Double?
    @State private var capturedProjectID: UUID?
    @State private var capturedFPS: Int?
    @State private var capturedSnap: Bool?
    @GestureState private var gestureActive = false
    @State private var gestureInvalidated = false
    @State private var trimmingLeading: Bool?
    @GestureState private var trimTranslation: CGFloat = 0
    @GestureState private var translation: CGSize = .zero
    @ViewBuilder private var clipAppearance: some View {
        let visible = trimPreview ?? clip
        let width = visible.duration * pointsPerSecond
        let radius = min(14.0, width / 2)
        HStack(spacing: 0) {
            if clip.duration * pointsPerSecond >= 88 { handle(leading: true) }
            VStack(alignment: .leading, spacing: 3) {
                if width >= 44 {
                    Text(clip.soundName).lineLimit(1).font(.specialElite(11))
                    Text(String(format: "%.2fs", visible.duration)).font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                    if let measurement {
                        MeasuredAudioWaveform(peaks: measurement.peaks, sourceDuration: measurement.duration,
                            sourceOffset: visible.sourceOffset, duration: visible.duration)
                            .frame(height: 14).allowsHitTesting(false)
                    }
                } else if width >= 12 {
                    Image(systemName: "waveform").font(.system(size: 10))
                        .frame(maxWidth: .infinity)
                } else {
                    Color.clear
                }
            }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .clipped()
                .contentShape(Rectangle()).onTapGesture { stop(); vm.selectedAudioClip = clip }
                .gesture(moveGesture)
            if clip.duration * pointsPerSecond >= 88 { handle(leading: false) }
        }.frame(width: width, height: 58)
            .background(Color.sdRed.opacity(clip.isMuted || vm.document.isAudioTrackMuted(clip.track) ? 0.05 : 0.16))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(vm.selectedCurrentAudioClip?.id == clip.id ? Color.white.opacity(0.5) : Color.sdRed.opacity(0.5)))
            .opacity(clip.isMuted || vm.document.isAudioTrackMuted(clip.track) ? 0.55 : 1)
            .frame(width: clip.duration * pointsPerSecond, height: 58, alignment: .leading)
            .offset(previewOffset)
    }
    var body: some View {
        clipAppearance
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("studio.audio.clip.\(clip.id)")
            .accessibilityLabel("\(clip.soundName), track \(clip.track), start \(clip.startTime.formatted()) seconds, duration \(clip.duration.formatted()) seconds")
            .accessibilityAction(named: "Select clip") { stop(); vm.selectedAudioClip = clip }
            .accessibilityAction(named: "Move earlier one frame") {
                accessibleEdit(.place(start: max(0, clip.startTime - 1 / Double(vm.fps)), track: clip.track))
            }
            .accessibilityAction(named: "Move later one frame") {
                accessibleEdit(.place(start: clip.startTime + 1 / Double(vm.fps), track: clip.track))
            }
            .accessibilityAction(named: "Move to previous track") {
                accessibleEdit(.place(start: clip.startTime, track: max(1, clip.track - 1)))
            }
            .accessibilityAction(named: "Move to next track") {
                accessibleEdit(.place(start: clip.startTime, track: min(4, clip.track + 1)))
            }
            .onChange(of: gestureActive) { _, active in if !active { clearCapture(); gestureInvalidated = false } }
            .onChange(of: vm.document.id) { _, _ in invalidateCapture() }
            .onChange(of: vm.document.revision) { _, _ in invalidateCapture() }
            .onDisappear { clearCapture() }
    }
    private func accessibleEdit(_ edit: StudioAudioClipEdit) {
        guard !gestureActive, vm.audioClips.first(where: { $0.id == clip.id }) == clip else {
            vm.message = "The audio clip changed. Select it again before editing."
            return
        }
        let expectedRevision = vm.document.revision
        stop(); vm.selectedAudioClip = clip
        do { try vm.editSelectedAudioClip(clip.id, expectedRevision: expectedRevision, edit: edit) }
        catch { vm.message = error.localizedDescription }
    }
    private func begin() {
        guard revision == nil, !gestureInvalidated else { return }
        stop(); vm.selectedAudioClip = clip; revision = vm.document.revision; captured = clip
        capturedPlayhead = vm.audioPlayheadTime
        snapTargets = [vm.audioPlayheadTime, 0] + vm.audioClips.filter { $0.id != clip.id }.flatMap { [$0.startTime, $0.startTime + $0.duration] }
        capturedScale = pointsPerSecond
        capturedProjectID = vm.document.id; capturedFPS = vm.fps; capturedSnap = vm.snapEnabled
    }
    private func invalidateCapture() {
        if gestureActive { gestureInvalidated = true }
        clearCapture()
    }
    private func clearCapture() {
        revision = nil; captured = nil; capturedScale = nil; capturedPlayhead = nil; snapTargets = []
        capturedProjectID = nil; capturedFPS = nil; capturedSnap = nil; trimmingLeading = nil
    }
    private var captureIsCurrent: Bool {
        capturedPlayhead == vm.audioPlayheadTime && capturedProjectID == vm.document.id && revision == vm.document.revision &&
        capturedScale == pointsPerSecond && capturedFPS == vm.fps && capturedSnap == vm.snapEnabled
    }
    private var trimPreview: AudioClip? {
        guard captureIsCurrent, let captured, let leading = trimmingLeading,
              let assetID = captured.assetID, let asset = vm.audioTrack(forAssetID: assetID) else { return nil }
        let raw = (leading ? captured.startTime : captured.startTime + captured.duration) + Double(trimTranslation) / pointsPerSecond
        guard let boundary = StudioAudioTimelineGeometry.magneticTime(max(0, raw), targets: snapTargets,
            pointsPerSecond: pointsPerSecond, fps: vm.fps, enabled: vm.snapEnabled) else { return nil }
        var draft = captured
        if leading {
            let delta = boundary - captured.startTime
            draft.startTime = boundary; draft.sourceOffset += delta; draft.duration -= delta
        } else { draft.duration = boundary - captured.startTime }
        guard draft.sourceOffset >= 0, draft.duration >= 1 / 48_000,
              draft.sourceOffset + draft.duration <= asset.duration + 1 / 48_000 else { return nil }
        return draft
    }
    private var previewOffset: CGSize {
        if trimmingLeading != nil {
            return CGSize(width: ((trimPreview ?? clip).startTime - clip.startTime) * pointsPerSecond, height: 0)
        }
        guard captureIsCurrent, let captured,
              let time = StudioAudioTimelineGeometry.magneticTime(max(0, captured.startTime + translation.width / pointsPerSecond),
                duration: captured.duration, targets: snapTargets, pointsPerSecond: pointsPerSecond, fps: vm.fps, enabled: vm.snapEnabled) else { return .zero }
        let lane = min(4, max(1, captured.track + Int((translation.height / 70).rounded())))
        return CGSize(width: (time - captured.startTime) * pointsPerSecond, height: Double(lane - captured.track) * 70)
    }
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($gestureActive) { _, active, _ in active = true }
            .updating($translation) { value, state, _ in state = value.translation }
            .onChanged { _ in begin() }
            .onEnded { value in
                defer { clearCapture() }
                guard captureIsCurrent, let revision, let captured,
                      let time = StudioAudioTimelineGeometry.magneticTime(max(0, captured.startTime + value.translation.width / pointsPerSecond),
                        duration: captured.duration, targets: snapTargets, pointsPerSecond: pointsPerSecond, fps: vm.fps, enabled: vm.snapEnabled) else { return }
                let lane = min(4, max(1, captured.track + Int((value.translation.height / 70).rounded())))
                do { try vm.editSelectedAudioClip(clip.id, expectedRevision: revision, edit: .place(start: time, track: lane)) }
                catch { vm.message = error.localizedDescription }
            }
    }
    private func handle(leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.sdRed.opacity(0.8)).frame(width: 4)
            .padding(.horizontal, 5).padding(.vertical, 9).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .updating($gestureActive) { _, active, _ in active = true }
                .updating($trimTranslation) { value, delta, _ in delta = value.translation.width }
                .onChanged { _ in begin(); trimmingLeading = leading }
                .onEnded { value in
                    defer { clearCapture() }
                    guard captureIsCurrent, let revision, let captured else { return }
                    let delta = Double(value.translation.width) / pointsPerSecond
                    let raw = (leading ? captured.startTime : captured.startTime + captured.duration) + delta
                    guard let boundary = StudioAudioTimelineGeometry.magneticTime(max(0, raw), targets: snapTargets,
            pointsPerSecond: pointsPerSecond, fps: vm.fps, enabled: vm.snapEnabled) else { return }
                    let edit: StudioAudioClipEdit = leading ? .trimLeading(start: boundary)
                        : .trim(sourceOffset: captured.sourceOffset, duration: boundary - captured.startTime)
                    do { try vm.editSelectedAudioClip(clip.id, expectedRevision: revision, edit: edit) }
                    catch { vm.message = error.localizedDescription }
                })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(leading ? "Trim audio leading edge" : "Trim audio end")
            .accessibilityValue(String(format: "%.3f seconds", leading ? clip.startTime : clip.startTime + clip.duration))
            .accessibilityAdjustableAction { direction in
                let amount: Double
                switch direction {
                case .increment: amount = 1 / Double(vm.fps)
                case .decrement: amount = -1 / Double(vm.fps)
                @unknown default: return
                }
                if leading { accessibleEdit(.trimLeading(start: max(0, clip.startTime + amount))) }
                else { accessibleEdit(.trim(sourceOffset: clip.sourceOffset, duration: clip.duration + amount)) }
            }
            .accessibilityHint(leading ? "Moves the clip start and trims its source together, keeping the end fixed." : "Changes the clip end while preserving its start.")
    }
}

private struct AudioImportLease {
    let projectID: UUID, revision: Int, frameID: String, track: Int
    let playhead: Double
    @MainActor func isCurrent(_ vm: StudioViewModel) -> Bool {
        vm.isEditing && !vm.isSaving && !vm.isPlaying && playhead.isFinite && (0...1000).contains(playhead)
            && vm.audioPlayheadTime == playhead && vm.document.id == projectID && vm.document.revision == revision
            && vm.document.activeFrameID == frameID
    }
}

private struct AudioFilesImportControls: View {
    @ObservedObject var vm: StudioViewModel
    @ObservedObject var audio: StudioAudioPreviewSession
    let stopPlayback: () -> Void
    @State private var showingFiles = false
    @State private var lease: AudioImportLease?
    @State private var track = 1
    @State private var movieAudio = false
    @State private var sourceStart = 0.0
    @State private var sourceEnd = 5.0
    @State private var movieSpeed = 1.0
    @State private var capturedMovieMapping: StudioVideoFrameImportService.Mapping?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Button("Import from Files") {
                    stopPlayback()
                    lease = .init(projectID: vm.document.id, revision: vm.document.revision,
                                  frameID: vm.document.activeFrameID, track: track, playhead: vm.audioPlayheadTime)
                    capturedMovieMapping = movieAudio ? .init(sourceStartSeconds: sourceStart,
                        sourceEndSeconds: sourceEnd,
                        projectStartSeconds: vm.audioPlayheadTime,
                        speed: movieSpeed) : nil
                    showingFiles = true
                }
                .disabled(audio.isBusy || !vm.isEditing || vm.isSaving || (movieAudio && sourceEnd <= sourceStart))
                .accessibilityIdentifier("studio.audio.import")
                .font(.specialElite(12)).foregroundColor(.sdStudioActionText)
                Spacer()
                Picker("Track", selection: $track) {
                    ForEach(1...4, id: \.self) { Text("Track \($0)").tag($0) }
                }.font(.specialElite(12)).tint(.white).disabled(audio.isBusy)
            }
            Toggle("Extract audio from a video", isOn: $movieAudio)
                .font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)).tint(.sdRed).disabled(audio.isBusy || showingFiles)
                .accessibilityIdentifier("studio.audio.movie")
            if movieAudio {
                Stepper("Source start: \(sourceStart, specifier: "%.1f")s", value: $sourceStart, in: 0...3599, step: 0.5)
                    .accessibilityIdentifier("studio.audio.movie.start")
                Stepper("Source end: \(sourceEnd, specifier: "%.1f")s", value: $sourceEnd, in: 0.5...3600, step: 0.5)
                    .accessibilityIdentifier("studio.audio.movie.end")
                Picker("Video audio speed", selection: $movieSpeed) {
                    ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { Text("\($0, specifier: "%.2g")×").tag($0) }
                }.accessibilityIdentifier("studio.audio.movie.speed")
                Text("Choose MP4 or MOV. Extracts only the selected soundtrack interval; the original video stays in Files. Speed changes duration and pitch. No microphone or upload.")
                    .font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.sdStudioSecondaryText)
            }
            Text("Up to 16 MB / 5 min · mono or stereo · decoded sample limits apply")
                .font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.sdStudioSecondaryText)
            Text("Adds audio at the captured timeline playhead. Move and trim clips in the timeline, then include them in MP4 export.")
                .font(.custom("SpecialElite-Regular", size: 11, relativeTo: .caption2)).foregroundColor(.sdStudioSecondaryText)
            if let projectNotice = vm.message {
                Text(projectNotice).font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)).foregroundColor(.sdStudioActionText)
                    .accessibilityIdentifier("studio.audio.projectNotice")
            }

        }
        .padding(.horizontal, 14)
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: movieAudio ? [.mpeg4Movie, .quickTimeMovie] : [.audio], allowsMultipleSelection: false) { result in
            switch result {
            case .failure(let error): audio.pickerFailed(error)
            case .success(let urls):
                guard let url = urls.first, let target = lease else { return }
                let mapping = capturedMovieMapping
                let prepare: StudioAudioPreviewSession.AudioPreparation? = mapping.map { captured in
                    { progress in try await StudioVideoAudioImportService.shared.extract(from: url, mapping: captured, progress: progress).audio }
                }
                _ = audio.importFile(url, prepare: prepare, stillCurrent: { target.isCurrent(vm) }, attach: { imported in
                    try vm.attachImportedAudio(imported, expectedProjectID: target.projectID,
                        expectedRevision: target.revision, frameID: target.frameID, trackNumber: target.track, atPlayhead: target.playhead)
                })
            }
            lease = nil; capturedMovieMapping = nil
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
                        let wasAuditioning = auditionID == clip.id && (timeline.isPlaying || timeline.isPreparing)
                        audio.stop(); timeline.stop(); vm.stopPlayback(); vm.selectedAudioClip = clip
                        auditionID = nil
                        if wasAuditioning { return }
                        guard let id = clip.assetID, let track = vm.audioTrack(forAssetID: id) else { return }
                        var solo = vm.document; var audible = clip; audible.startTime = 0; solo.audioClips = [audible]
                        let project = vm.document.id, revision = vm.document.revision
                        auditionID = clip.id
                        let accepted = timeline.play(document: solo, tracks: [track], duration: clip.duration, from: 0,
                            stillCurrent: { vm.isEditing && vm.document.id == project && vm.document.revision == revision },
                            onTime: { _, playing in if !playing { auditionID = nil } })
                        if !accepted { auditionID = nil }
                    } label: {
                        Image(systemName: auditionID == clip.id && timeline.isPlaying ? "stop.fill" : "play.fill")
                            .frame(width: 44, height: 44).background(Color.white.opacity(0.06)).clipShape(Circle())
                    }.disabled(audio.isBusy || (timeline.isPreparing && auditionID != clip.id) || clip.assetID == nil)
                        .accessibilityLabel((auditionID == clip.id && (timeline.isPlaying || timeline.isPreparing) ? "Stop preview " : "Preview ") + clip.soundName)
                        .accessibilityIdentifier("studio.audio.project.preview." + clip.id)
                    Button { vm.selectedAudioClip = clip } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(clip.soundName).font(.specialElite(14)).lineLimit(1)
                            Text(String(format: "%.2fs · Track %d%@", clip.duration, clip.track, clip.isMuted ? " · Muted" : ""))
                                .font(.specialElite(11)).foregroundColor(.sdStudioSecondaryText)
                            Text(String(format: "Source %.2f–%.2fs", clip.sourceOffset, clip.sourceOffset + clip.duration))
                                .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                            if clip.isMuted || vm.document.isAudioTrackMuted(clip.track) {
                                Text("Preview is silent: clip or track is muted")
                                    .font(.specialElite(10)).foregroundColor(.sdStudioActionText)
                            } else if clip.volume == 0 || vm.document.audioTrackVolume(clip.track) == 0 {
                                Text("Preview is silent: clip or track volume is zero")
                                    .font(.specialElite(10)).foregroundColor(.sdStudioActionText)
                            }
                            if auditionID == clip.id {
                                if timeline.isPreparing {
                                    Text("Preparing trimmed preview…").font(.specialElite(10))
                                } else if timeline.isPlaying {
                                    ProgressView(value: min(clip.duration, max(0, timeline.currentTime)), total: clip.duration)
                                        .tint(.sdRed).accessibilityLabel("Selected clip preview progress")
                                    Text(String(format: "%.2f / %.2fs", timeline.currentTime, clip.duration))
                                        .font(.specialElite(10)).foregroundColor(.sdStudioSecondaryText)
                                }
                            }
                            if let id = clip.assetID, let measured = audio.measurements[id] {
                                MeasuredAudioWaveform(peaks: measured.peaks, sourceDuration: measured.duration,
                                    sourceOffset: clip.sourceOffset, duration: clip.duration).frame(height: 14)
                            }
                        }
                    }
                    Spacer()
                }.padding(.horizontal, 16)
                Divider().opacity(0.1)
            }
        }
        .onChange(of: timeline.isPreparing) { _, preparing in
            if !preparing && !timeline.isPlaying { auditionID = nil }
        }
        .onChange(of: vm.document.id) { _, _ in auditionID = nil }
        .onDisappear { auditionID = nil }
    }
}

private struct MeasuredAudioWaveform: View {
    let peaks: [Float]
    var sourceDuration: Double? = nil
    var sourceOffset: Double = 0
    var duration: Double? = nil
    private var visibleRange: ClosedRange<Double>? {
        guard let sourceDuration else { return 0...1 }
        guard sourceDuration.isFinite, sourceDuration > 0, sourceOffset.isFinite, sourceOffset >= 0,
              let duration, duration.isFinite, duration > 0 else { return nil }
        let start = min(1, sourceOffset / sourceDuration)
        let end = min(1, (sourceOffset + duration) / sourceDuration)
        return end > start ? start...end : nil
    }
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                if let range = visibleRange {
                    for (index, peak) in peaks.enumerated() where peak.isFinite && peak > 0 {
                        let lower = max(range.lowerBound, Double(index) / Double(max(1, peaks.count)))
                        let upper = min(range.upperBound, Double(index + 1) / Double(max(1, peaks.count)))
                        guard upper > lower else { continue }
                        // Peaks are measured bins, not invented samples. Clip the
                        // overlapping bins to the audible source range at any zoom.
                        let position = ((lower + upper) / 2 - range.lowerBound) / (range.upperBound - range.lowerBound)
                        let x = CGFloat(position) * geometry.size.width
                        let half = CGFloat(min(1, max(0, peak))) * geometry.size.height / 2
                        path.move(to: CGPoint(x: x, y: geometry.size.height / 2 - half))
                        path.addLine(to: CGPoint(x: x, y: geometry.size.height / 2 + half))
                    }
                }
            }.stroke(Color.sdRed.opacity(0.8), lineWidth: 1)
        }.accessibilityLabel("Measured source waveform overview")
            .accessibilityHint("Shows measured peak bins for the clip's source range before volume and fades.")
    }
}
