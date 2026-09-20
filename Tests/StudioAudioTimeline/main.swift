import Foundation
import AVFoundation

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}
@main @MainActor struct AudioTimelineTests {
    static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-audio-timeline-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let scratch = root.appendingPathComponent("scratch")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("quartered.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        pcm.frameLength = 96_000
        for channel in 0..<2 {
            for frame in 0..<96_000 {
                pcm.floatChannelData![channel][frame] = frame < 48_000 ? 0 : (channel == 0 ? 0.25 : -0.5)
            }
        }
        do { let f = try AVAudioFile(forWriting: source, settings: format.settings); try f.write(from: pcm) }
        let imported = try await StudioAudioImportService.shared.importAudio(from: source, scratchParent: scratch) { _ in }
        let docs = root.appendingPathComponent("documents")
        let storage = DeviceStorageManager(documentsDirectory: docs, cachesDirectory: docs)
        let vm = StudioViewModel(storage: storage)
        let created = await vm.createProject(name: "Real edited audio", width: 64, height: 64, fps: 8)
        try check(created, "project create")
        let id = try vm.attachImportedAudio(imported.track, expectedProjectID: vm.document.id,
            expectedRevision: vm.document.revision, frameID: vm.document.activeFrameID, trackNumber: 1)
        var passed = 0
        func test(_ name: String, _ body: () async throws -> Void) async throws {
            try await body(); passed += 1; print("PASS \(name)")
        }
        try await test("audio attachment during playback preserves the current document and source ownership") {
            let before = vm.document
            vm.displayAudioPlaybackTime(0, playing: true)
            do {
                _ = try vm.attachImportedAudio(imported.track, expectedProjectID: before.id,
                    expectedRevision: before.revision, frameID: before.activeFrameID, trackNumber: 2)
                throw Failure(message: "import accepted during playback")
            } catch is StudioDocumentError { }
            vm.displayAudioPlaybackTime(0, playing: false)
            try check(vm.document == before && vm.audioClips.count == 1, "busy import altered document")
        }
        try await test("historical clip decoding supplies additive defaults and preserves bytes") {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(vm.audioClips[0])) as! [String: Any]
            object.removeValue(forKey: "sourceOffset"); object.removeValue(forKey: "isMuted")
            let old = try JSONDecoder().decode(AudioClip.self, from: JSONSerialization.data(withJSONObject: object))
            try check(old.sourceOffset == 0 && !old.isMuted && old.assetID == imported.id, "legacy decode changed source")
            try check(try JSONDecoder().decode(AudioClip.self, from: JSONEncoder().encode(old)) == old, "roundtrip")
        }
        try await test("actual selected clip move snaps and commits one reversible document revision") {
            let revision = vm.document.revision
            let snapped = StudioAudioTimelineGeometry.snapped(0.31, fps: 8, enabled: true)!
            try check(snapped == 0.25, "snap grid")
            try vm.editSelectedAudioClip(id, expectedRevision: revision, edit: .place(start: snapped, track: 3))
            try check(vm.document.revision == revision + 1 && vm.audioClips[0].track == 3 && vm.audioClips[0].startTime == 0.25, "move")
            vm.undo(); try check(vm.audioClips[0].track == 1 && vm.audioClips[0].startTime == 0, "undo move")
            vm.redo(); try check(vm.audioClips[0].track == 3, "redo move")
        }
        try await test("invalid stale and unselected edits preserve whole document and stored source") {
            let before = vm.document
            for edit in [StudioAudioClipEdit.trim(sourceOffset: 1.9, duration: 1), .place(start: .nan, track: 1), .place(start: 0, track: 5), .volume(2)] {
                do { try vm.editSelectedAudioClip(id, expectedRevision: before.revision, edit: edit); throw Failure(message: "invalid accepted") }
                catch is StudioDocumentError { }
                try check(vm.document == before, "invalid edit mutated")
            }
            do { try vm.editSelectedAudioClip(id, expectedRevision: before.revision - 1, edit: .mute(true)); throw Failure(message: "stale accepted") }
            catch is StudioDocumentError { }
            vm.selectedAudioClip = nil
            do { try vm.editSelectedAudioClip(id, expectedRevision: before.revision, edit: .mute(true)); throw Failure(message: "no selection accepted") }
            catch is StudioDocumentError { }
            vm.selectedAudioClip = before.audioClips[0]
            try check(vm.document == before && vm.audioTrack(forAssetID: imported.id)?.audioData == imported.track.audioData, "original bytes changed")
        }
        try await test("trim source volume mute save cold reopen and full undo use production storage") {
            try vm.editSelectedAudioClip(id, expectedRevision: vm.document.revision, edit: .trim(sourceOffset: 1, duration: 0.5))
            try vm.editSelectedAudioClip(id, expectedRevision: vm.document.revision, edit: .volume(0.5))
            try vm.editSelectedAudioClip(id, expectedRevision: vm.document.revision, edit: .mute(true))
            try check(vm.document.schemaVersion == 4, "old readers would silently discard trims")
            let saved = await vm.save(); try check(saved, "save")
            let other = StudioViewModel(storage: storage)
            await other.loadProjects()
            guard let metadata = other.savedProjects.first(where: { $0.id == vm.document.id }) else { throw Failure(message: "saved project absent") }
            let opened = await other.openProject(metadata); try check(opened, "reopen")
            try check(other.audioClips == vm.audioClips && other.audioTrack(forAssetID: imported.id)?.audioData == imported.track.audioData, "reopened trim or bytes")
            vm.undo(); try check(!vm.audioClips[0].isMuted, "mute undo")
            vm.redo(); try check(vm.audioClips[0].isMuted, "mute redo")
        }
        try await test("track mute toggle preserves a deliberately muted clip") {
            let originalClips = vm.audioClips
            try check(originalClips[0].isMuted, "fixture must contain an individually muted clip")
            try vm.setAudioTrackMuted(3, muted: true, expectedRevision: vm.document.revision)
            try vm.setAudioTrackMuted(3, muted: false, expectedRevision: vm.document.revision)
            try check(vm.audioClips == originalClips, "Track mute/unmute overwrote the individual clip mute setting")
        }

        try await test("track mute has one reversible revision and survives real save/cold reopen without changing clips") {
            let before = vm.document, clips = vm.audioClips
            try vm.setAudioTrackMuted(3, muted: true, expectedRevision: before.revision)
            try check(vm.document.revision == before.revision + 1 && vm.document.schemaVersion == 12 && vm.document.isAudioTrackMuted(3), "track state/revision")
            try check(vm.audioClips == clips && vm.selectedCurrentAudioClip?.id == id, "track mute changed clip settings or selection")
            vm.undo(); try check(!vm.document.isAudioTrackMuted(3) && vm.audioClips == clips, "track Undo")
            vm.redo(); try check(vm.document.isAudioTrackMuted(3) && vm.audioClips == clips, "track Redo")
            let saved = await vm.save(); try check(saved, "track mute save")
            let other = StudioViewModel(storage: storage); await other.loadProjects()
            guard let metadata = other.savedProjects.first(where: { $0.id == vm.document.id }) else { throw Failure(message: "muted project absent") }
            let opened = await other.openProject(metadata)
            try check(opened && other.document == vm.document && other.document.isAudioTrackMuted(3), "track state lost on cold reopen")
            try check(other.audioClips == clips && other.projectAudioTracks[0].audioData == imported.track.audioData, "cold reopen changed clips/original bytes")
            try vm.setAudioTrackMuted(3, muted: false, expectedRevision: vm.document.revision)
            try check(vm.audioClips == clips && vm.audioClips[0].isMuted, "track unmute discarded individual mute")
            // The next real PCM fixture needs an audible clip: explicitly unmute
            // that clip rather than relying on a track action to overwrite it.
            try vm.editSelectedAudioClip(id, expectedRevision: vm.document.revision, edit: .mute(false))
        }
        try await test("track mute invalid/stale/no-op and early/late cancellation preserve the complete document") {
            let before = vm.document
            for lane in [-1, 0, 5, Int.max] {
                do { try vm.setAudioTrackMuted(lane, muted: true, expectedRevision: before.revision); throw Failure(message: "invalid track accepted") }
                catch is StudioDocumentError { }
            }
            do { try vm.setAudioTrackMuted(3, muted: true, expectedRevision: before.revision - 1); throw Failure(message: "stale track accepted") }
            catch is StudioDocumentError { }
            try vm.setAudioTrackMuted(3, muted: false, expectedRevision: before.revision)
            for cancellationAt in [1, 2] {
                var calls = 0
                do {
                    try vm.setAudioTrackMuted(3, muted: true, expectedRevision: before.revision, checkCancellation: {
                        calls += 1; if calls == cancellationAt { throw CancellationError() }
                    })
                    throw Failure(message: "cancelled track edit accepted")
                } catch is CancellationError { }
                try check(calls == cancellationAt && vm.document == before, "cancellation or no-op modified document")
            }
            try check(vm.document == before && vm.projectAudioTracks[0].audioData == imported.track.audioData, "rejected edit changed original")
        }
        try await test("empty-lane mute applies to newly attached clips and follows lane rather than clip identity") {
            let localDocs = root.appendingPathComponent("empty-track-docs")
            let local = StudioViewModel(storage: DeviceStorageManager(documentsDirectory: localDocs, cachesDirectory: localDocs))
            let made = await local.createProject(name: "Muted empty track", width: 64, height: 64, fps: 8)
            try check(made, "empty track create")
            try local.setAudioTrackMuted(2, muted: true, expectedRevision: local.document.revision)
            try check(local.audioClips.isEmpty && local.document.isAudioTrackMuted(2), "empty track mute")
            let attached = try local.attachImportedAudio(imported.track, expectedProjectID: local.document.id, expectedRevision: local.document.revision, frameID: local.document.activeFrameID, trackNumber: 2)
            try check(local.audioClips[0].track == 2 && !local.audioClips[0].isMuted && local.document.isAudioTrackMuted(2), "new clip did not retain independent state")
            try local.editSelectedAudioClip(attached, expectedRevision: local.document.revision, edit: .place(start: 0, track: 4))
            try check(local.document.isAudioTrackMuted(2) && !local.document.isAudioTrackMuted(4) && !local.audioClips[0].isMuted, "move dragged track mute with clip")
            await local.flush()
        }
        try await test("historical document decoding defaults to no track mute and rejects invalid newer metadata") {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(vm.document)) as! [String: Any]
            object.removeValue(forKey: "mutedAudioTracks"); object["schemaVersion"] = 4
            let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let old = try JSONDecoder().decode(StudioDocument.self, from: original); try old.validate()
            try check(old.mutedAudioTracks == nil && !(1...4).contains(where: old.isAudioTrackMuted), "historical default")
            try check(try JSONDecoder().decode(StudioDocument.self, from: JSONEncoder().encode(old)) == old, "historical roundtrip")
            for lanes in [[0], [5], [1, 1], [4, 1], [1, 2, 3, 4, 4]] {
                var invalid = old; invalid.schemaVersion = 12; invalid.mutedAudioTracks = lanes
                do { try invalid.validate(); throw Failure(message: "invalid mute metadata accepted") } catch is StudioDocumentError { }
            }
            var downgraded = old; downgraded.mutedAudioTracks = [3]
            do { try downgraded.validate(); throw Failure(message: "old schema accepted mute metadata") } catch is StudioDocumentError { }
            try check(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) == original, "historical input bytes altered")
        }
        try await test("captured clip volume is one reversible edit and preserves source and track settings on cold reopen") {
            let folder = root.appendingPathComponent("clip-gain-docs")
            let store = DeviceStorageManager(documentsDirectory: folder, cachesDirectory: folder)
            let local = StudioViewModel(storage: store)
            let made = await local.createProject(name: "Clip gain", width: 64, height: 64, fps: 8)
            try check(made, "create clip gain fixture")
            let clipID = try local.attachImportedAudio(imported.track, expectedProjectID: local.document.id,
                expectedRevision: local.document.revision, frameID: local.document.activeFrameID, trackNumber: 3)
            try local.editSelectedAudioClip(clipID, expectedRevision: local.document.revision, edit: .mute(true))
            try local.setAudioTrackMuted(3, muted: true, expectedRevision: local.document.revision)
            guard let track = local.prepareAudioTrackVolume(3) else { throw Failure(message: "track capture") }
            try local.setAudioTrackVolume(track, volume: 0.25)
            guard let capture = local.prepareAudioClipVolume() else { throw Failure(message: "clip capture") }
            let before = local.document
            try local.setAudioClipVolume(capture, volume: 0.4)
            var expected = capture.selection.clip; expected.volume = 0.4
            try check(local.document.revision == before.revision + 1 && local.audioClips == [expected]
                      && local.selectedCurrentAudioClip == expected, "clip gain changed identity/settings or made multiple edits")
            try check(local.document.audioTrackVolume(3) == 0.25 && local.document.isAudioTrackMuted(3), "clip gain changed track state")
            local.undo()
            try check(local.audioClips == before.audioClips && local.document.audioTrackVolumes == before.audioTrackVolumes
                      && local.document.mutedAudioTracks == before.mutedAudioTracks, "clip gain Undo")
            local.redo(); try check(local.audioClips == [expected], "clip gain Redo")
            let saved = await local.save(); try check(saved, "clip gain save")
            let other = StudioViewModel(storage: store); await other.loadProjects()
            guard let metadata = other.savedProjects.first(where: { $0.id == local.document.id }) else { throw Failure(message: "clip gain project absent") }
            let opened = await other.openProject(metadata)
            try check(opened && other.document == local.document, "clip gain cold reopen changed document")
            try check(other.projectAudioTracks[0].audioData == imported.track.audioData, "clip gain rewrote source bytes")
        }
        try await test("clip gain rejects invalid stale foreign and cancelled edits without document or history mutation") {
            let folder = root.appendingPathComponent("clip-gain-rejections")
            let local = StudioViewModel(storage: DeviceStorageManager(documentsDirectory: folder, cachesDirectory: folder))
            let made = await local.createProject(name: "Rejected clip gain", width: 64, height: 64, fps: 8)
            try check(made, "create rejection fixture")
            let clipID = try local.attachImportedAudio(imported.track, expectedProjectID: local.document.id,
                expectedRevision: local.document.revision, frameID: local.document.activeFrameID, trackNumber: 1)
            guard let capture = local.prepareAudioClipVolume() else { throw Failure(message: "clip capture") }
            let before = local.document, undo = local.canUndo, redo = local.canRedo
            for invalid in [-0.1, 1.1, Double.nan, Double.infinity] {
                do { try local.setAudioClipVolume(capture, volume: invalid); throw Failure(message: "invalid clip gain accepted") }
                catch is StudioDocumentError { }
            }
            var changed = capture.selection.clip; changed.volume = 0.3
            let invalidCaptures: [StudioViewModel.AudioClipVolumeCapture] = [
                .init(selection: .init(projectID: UUID(), revision: capture.selection.revision, clip: capture.selection.clip)),
                .init(selection: .init(projectID: capture.selection.projectID, revision: capture.selection.revision + 1, clip: capture.selection.clip)),
                .init(selection: .init(projectID: capture.selection.projectID, revision: capture.selection.revision, clip: changed))
            ]
            for invalid in invalidCaptures {
                do { try local.setAudioClipVolume(invalid, volume: 0.5); throw Failure(message: "foreign/stale clip gain accepted") }
                catch is StudioDocumentError { }
            }
            for cancellationAt in [1, 2] {
                var calls = 0
                do {
                    try local.setAudioClipVolume(capture, volume: 0.5, checkCancellation: {
                        calls += 1; if calls == cancellationAt { throw CancellationError() }
                    }); throw Failure(message: "cancelled clip gain accepted")
                } catch is CancellationError { }
                try check(calls == cancellationAt, "missing clip gain cancellation boundary")
            }
            local.selectedAudioClip = nil
            try check(local.prepareAudioClipVolume() == nil, "unselected gain available")
            do { try local.setAudioClipVolume(capture, volume: 0.5); throw Failure(message: "unselected gain accepted") }
            catch is StudioDocumentError { }
            local.selectedAudioClip = capture.selection.clip
            local.displayAudioPlaybackTime(0, playing: true)
            try check(local.prepareAudioClipVolume() == nil, "playing gain available")
            do { try local.setAudioClipVolume(capture, volume: 0.5); throw Failure(message: "playing gain accepted") }
            catch is StudioDocumentError { }
            local.setAudioClipVolume(clipID, volume: 0.5)
            local.displayAudioPlaybackTime(0, playing: false)
            try check(local.document == before && local.canUndo == undo && local.canRedo == redo
                      && local.audioTrack(forAssetID: imported.id)?.audioData == imported.track.audioData,
                      "rejected gain changed document/history/bytes")
            await local.flush()
        }
        try await test("clip gain never overwrites an intervening edit or targets a newly selected clip") {
            let folder = root.appendingPathComponent("clip-gain-late-context")
            let local = StudioViewModel(storage: DeviceStorageManager(documentsDirectory: folder, cachesDirectory: folder))
            let made = await local.createProject(name: "Late clip gain", width: 64, height: 64, fps: 8)
            try check(made, "create late context fixture")
            let first = try local.attachImportedAudio(imported.track, expectedProjectID: local.document.id,
                expectedRevision: local.document.revision, frameID: local.document.activeFrameID, trackNumber: 1)
            guard let duplication = local.prepareAudioDuplication() else { throw Failure(message: "duplicate capture") }
            _ = try local.duplicateAudioClip(duplication)
            guard let second = local.selectedCurrentAudioClip else { throw Failure(message: "second clip") }
            local.selectedAudioClip = local.audioClips.first(where: { $0.id == first })
            guard let capture = local.prepareAudioClipVolume() else { throw Failure(message: "capture") }
            let before = local.document; var calls = 0
            do {
                try local.setAudioClipVolume(capture, volume: 0.1, checkCancellation: {
                    calls += 1; if calls == 2 { local.selectedAudioClip = second }
                }); throw Failure(message: "gain followed new selection")
            } catch is StudioDocumentError { }
            try check(calls == 2 && local.document == before && local.selectedCurrentAudioClip == second, "gain overwrote selected clip")
            local.selectedAudioClip = capture.selection.clip; calls = 0
            do {
                try local.setAudioClipVolume(capture, volume: 0.1, checkCancellation: {
                    calls += 1
                    if calls == 2 { try local.editSelectedAudioClip(first, expectedRevision: local.document.revision, edit: .mute(true)) }
                }); throw Failure(message: "gain overwrote newer edit")
            } catch is StudioDocumentError { }
            try check(calls == 2 && local.document.revision == before.revision + 1
                      && local.audioClips.first(where: { $0.id == first })?.volume == capture.selection.clip.volume
                      && local.audioClips.first(where: { $0.id == first })?.isMuted == true, "late gain lost mute or added history")
            local.undo(); try check(local.audioClips == before.audioClips, "late rejection inserted history")
            await local.flush()
        }
        try await test("unchanged clip gain preserves redo and legacy entry uses the validated gain command") {
            let folder = root.appendingPathComponent("clip-gain-noop")
            let local = StudioViewModel(storage: DeviceStorageManager(documentsDirectory: folder, cachesDirectory: folder))
            let made = await local.createProject(name: "Clip gain history", width: 64, height: 64, fps: 8)
            try check(made, "create history fixture")
            let clipID = try local.attachImportedAudio(imported.track, expectedProjectID: local.document.id,
                expectedRevision: local.document.revision, frameID: local.document.activeFrameID, trackNumber: 1)
            local.setAudioClipVolume(clipID, volume: 0.25)
            try check(local.selectedCurrentAudioClip?.volume == 0.25, "legacy entry failed")
            local.undo(); local.selectedAudioClip = local.audioClips.first
            guard let capture = local.prepareAudioClipVolume() else { throw Failure(message: "capture after Undo") }
            let before = local.document
            try local.setAudioClipVolume(capture, volume: capture.selection.clip.volume)
            try check(local.document == before && local.canRedo, "no-op gain consumed redo")
            local.redo(); try check(local.audioClips.first?.volume == 0.25, "redo lost clip gain")
            await local.flush()
        }
        try await test("track volume preserves clip gain and mute through undo redo save and cold reopen") {
            let folder = root.appendingPathComponent("track-volume-docs")
            let store = DeviceStorageManager(documentsDirectory: folder, cachesDirectory: folder)
            let local = StudioViewModel(storage: store)
            let made = await local.createProject(name: "Track volume", width: 64, height: 64, fps: 8)
            try check(made, "create track volume fixture")
            let clipID = try local.attachImportedAudio(imported.track, expectedProjectID: local.document.id,
                expectedRevision: local.document.revision, frameID: local.document.activeFrameID, trackNumber: 3)
            try local.editSelectedAudioClip(clipID, expectedRevision: local.document.revision, edit: .volume(0.4))
            try local.editSelectedAudioClip(clipID, expectedRevision: local.document.revision, edit: .mute(true))
            try local.setAudioTrackMuted(3, muted: true, expectedRevision: local.document.revision)
            let before = local.document, clips = local.audioClips
            guard let capture = local.prepareAudioTrackVolume(3) else { throw Failure(message: "missing volume capture") }
            try local.setAudioTrackVolume(capture, volume: 0.25)
            try check(local.document.schemaVersion == 13 && local.document.revision == before.revision + 1,
                      "track volume must be one schema-versioned edit")
            try check(local.document.audioTrackVolume(3) == 0.25 && local.document.audioTrackVolume(1) == 1,
                      "wrong lane gain")
            try check(local.audioClips == clips && local.document.isAudioTrackMuted(3)
                      && local.selectedCurrentAudioClip?.id == clipID, "gain changed clip gain/mute or selection")
            local.undo()
            try check(local.document.audioTrackVolumes == nil && local.document.schemaVersion == before.schemaVersion
                      && local.audioClips == clips && local.document.isAudioTrackMuted(3), "volume Undo")
            local.redo()
            try check(local.document.audioTrackVolume(3) == 0.25 && local.audioClips == clips, "volume Redo")
            let saved = await local.save(); try check(saved, "volume save")
            let other = StudioViewModel(storage: store); await other.loadProjects()
            guard let metadata = other.savedProjects.first(where: { $0.id == local.document.id }) else { throw Failure(message: "volume project absent") }
            let opened = await other.openProject(metadata)
            try check(opened && other.document == local.document, "complete volume document changed on cold reopen")
            try check(other.projectAudioTracks[0].audioData == imported.track.audioData, "volume changed source bytes")
        }
        try await test("track volume rejects invalid stale busy and cancelled captures without changing document or history") {
            let folder = root.appendingPathComponent("track-volume-rejection")
            let local = StudioViewModel(storage: DeviceStorageManager(documentsDirectory: folder, cachesDirectory: folder))
            let made = await local.createProject(name: "Volume rejection", width: 64, height: 64, fps: 8)
            try check(made, "create rejection fixture")
            guard let capture = local.prepareAudioTrackVolume(2) else { throw Failure(message: "empty lane capture") }
            let before = local.document, undo = local.canUndo, redo = local.canRedo
            try local.setAudioTrackVolume(capture, volume: 1)
            for invalid in [-0.1, 1.1, Double.nan, Double.infinity] {
                do { try local.setAudioTrackVolume(capture, volume: invalid); throw Failure(message: "invalid volume accepted") }
                catch is StudioDocumentError { }
            }
            let invalidCaptures: [StudioViewModel.AudioTrackVolumeCapture] = [
                .init(projectID: UUID(), revision: capture.revision, track: 2, volume: 1),
                .init(projectID: capture.projectID, revision: capture.revision + 1, track: 2, volume: 1),
                .init(projectID: capture.projectID, revision: capture.revision, track: 0, volume: 1),
                .init(projectID: capture.projectID, revision: capture.revision, track: 5, volume: 1),
                .init(projectID: capture.projectID, revision: capture.revision, track: 2, volume: 0.5)
            ]
            for invalid in invalidCaptures {
                do { try local.setAudioTrackVolume(invalid, volume: 0.5); throw Failure(message: "invalid capture accepted") }
                catch is StudioDocumentError { }
            }
            for cancellationAt in [1, 2] {
                var calls = 0
                do {
                    try local.setAudioTrackVolume(capture, volume: 0.5, checkCancellation: {
                        calls += 1; if calls == cancellationAt { throw CancellationError() }
                    }); throw Failure(message: "cancelled volume accepted")
                } catch is CancellationError { }
                try check(calls == cancellationAt, "volume cancellation boundary")
            }
            local.displayAudioPlaybackTime(0, playing: true)
            try check(local.prepareAudioTrackVolume(2) == nil, "volume available during playback")
            do { try local.setAudioTrackVolume(capture, volume: 0.5); throw Failure(message: "busy volume accepted") }
            catch is StudioDocumentError { }
            local.displayAudioPlaybackTime(0, playing: false)
            try check(local.document == before && local.canUndo == undo && local.canRedo == redo, "rejected/no-op volume changed document/history")
            var checks = 0
            do {
                try local.setAudioTrackVolume(capture, volume: 0.5, checkCancellation: {
                    checks += 1
                    if checks == 2 { try local.setAudioTrackMuted(2, muted: true, expectedRevision: local.document.revision) }
                }); throw Failure(message: "late stale volume accepted")
            } catch is StudioDocumentError { }
            try check(checks == 2 && local.document.isAudioTrackMuted(2) && local.document.audioTrackVolumes == nil,
                      "late stale volume overwrote the intervening edit")
            await local.flush()
        }
        try await test("empty track volume applies to later clips and moving a clip uses destination track gain") {
            let folder = root.appendingPathComponent("empty-track-volume")
            let local = StudioViewModel(storage: DeviceStorageManager(documentsDirectory: folder, cachesDirectory: folder))
            let made = await local.createProject(name: "Empty track volume", width: 64, height: 64, fps: 8)
            try check(made, "empty volume create")
            guard let capture = local.prepareAudioTrackVolume(4) else { throw Failure(message: "empty capture") }
            try local.setAudioTrackVolume(capture, volume: 0.1)
            let clipID = try local.attachImportedAudio(imported.track, expectedProjectID: local.document.id,
                expectedRevision: local.document.revision, frameID: local.document.activeFrameID, trackNumber: 4)
            let originalGain = local.audioClips[0].volume
            try check(local.document.audioTrackVolume(local.audioClips[0].track) == 0.1, "new clip bypassed lane gain")
            try local.editSelectedAudioClip(clipID, expectedRevision: local.document.revision, edit: .place(start: 0, track: 1))
            try check(local.document.audioTrackVolume(local.audioClips[0].track) == 1
                      && local.document.audioTrackVolume(4) == 0.1 && local.audioClips[0].volume == originalGain,
                      "move dragged lane volume or rewrote clip gain")
            await local.flush()
        }
        try await test("historical track volume defaults to unity and malformed or downgraded metadata is rejected") {
            let old = try StudioDocument.new(name: "Historical", width: 64, height: 64, fps: 8)
            let bytes = try JSONEncoder().encode(old)
            let decoded = try JSONDecoder().decode(StudioDocument.self, from: bytes); try decoded.validate()
            try check(decoded.audioTrackVolumes == nil && (1...4).allSatisfy { decoded.audioTrackVolume($0) == 1 }, "historical gain default")
            try check(decoded == old && decoded.schemaVersion == 1, "decoding migrated original")
            let invalidValues: [[Double]] = [[], [1], [1, 1, 1], [1, 1, 1, 1, 1], [-0.1, 1, 1, 1], [1, 1, 1, 1.1], [1, 1, .nan, 1], [.infinity, 1, 1, 1]]
            for volumes in invalidValues {
                var invalid = old; invalid.schemaVersion = 13; invalid.audioTrackVolumes = volumes
                do { try invalid.validate(); throw Failure(message: "invalid track volumes accepted") } catch is StudioDocumentError { }
            }
            var downgraded = old; downgraded.schemaVersion = 12; downgraded.audioTrackVolumes = [1, 1, 1, 1]
            do { try downgraded.validate(); throw Failure(message: "older schema accepted bus gain") } catch is StudioDocumentError { }
            try check(try JSONDecoder().decode(StudioDocument.self, from: bytes) == old, "historical bytes changed")
        }
        func decode(_ out: StudioAudioMixService.Output) throws -> [[Float]] {
            let file = try AVAudioFile(forReading: out.checkedURL())
            let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: pcm)
            return (0..<2).map { Array(UnsafeBufferPointer(start: pcm.floatChannelData![$0], count: Int(pcm.frameLength))) }
        }
        try await test("real mixed CAF reads trimmed source at placed time with exact gain and silent gaps") {
            let out = try await StudioAudioMixService().mix(document: vm.document, retainedAudioTracks: vm.projectAudioTracks,
                durationSeconds: 1, outputParent: scratch)
            defer { try? out.cleanup() }
            let data = try decode(out)
            try check(data[0].count == 48_000 && data[0][0..<12_000].allSatisfy { $0 == 0 }, "leading gap")
            for n in 12_000..<36_000 {
                try check(abs(data[0][n] - 0.125) < 0.0001 && abs(data[1][n] + 0.25) < 0.0001, "source offset or gain wrong")
            }
            try check(data[0][36_000...].allSatisfy { $0 == 0 }, "trailing trim")
        }
        try await test("mute changes actual mixed samples without discarding the source") {
            try vm.editSelectedAudioClip(id, expectedRevision: vm.document.revision, edit: .mute(true))
            let out = try await StudioAudioMixService().mix(document: vm.document, retainedAudioTracks: vm.projectAudioTracks,
                durationSeconds: 1, outputParent: scratch)
            defer { try? out.cleanup() }
            try check(try decode(out).flatMap { $0 }.allSatisfy { $0 == 0 }, "mute left signal")
            try check(vm.audioTrack(forAssetID: imported.id)?.audioData == imported.track.audioData, "mute dropped source")
            vm.undo()
        }
        try await test("mixed timeline starts a real zero-gain player only after verified output and stops cleanly") {
            let session = StudioAudioTimelineSession(scratchParent: scratch)
            let doc = vm.document
            var updates: [(Double, Bool)] = []
            try check(session.play(document: doc, tracks: vm.projectAudioTracks, duration: 1, from: 0.1,
                auditionVolume: 0, stillCurrent: { true }, onTime: { updates.append(($0, $1)) }), "prepare refused")
            for _ in 0..<2000 { if !session.isPreparing { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            try check(!session.isPreparing && session.actualPlayerIsPlaying && session.isPlaying && session.actualPlayerVolume == 0, session.notice ?? "real player not started")
            try check(updates.first?.0 == 0.1 && updates.first?.1 == true, "clock not tied to actual play")
            session.stop()
            try check(!session.actualPlayerIsPlaying && !session.isPlaying && updates.last?.1 == false, "stop")
            try check(try fm.contentsOfDirectory(atPath: scratch.path).isEmpty, "output leaked")
        }
        try await test("natural completion survives a clock poll before its queued delegate") {
            let session = StudioAudioTimelineSession(scratchParent: scratch)
            defer { session.close() }
            var updates: [(Double, Bool)] = []
            try check(session.play(document: vm.document, tracks: vm.projectAudioTracks, duration: 1, from: 0.85,
                auditionVolume: 0, stillCurrent: { true }, onTime: { updates.append(($0, $1)) }), "end-race prepare")
            for _ in 0..<2000 { if !session.isPreparing { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            try check(session.actualPlayerIsPlaying, session.notice ?? "end-race real player absent")
            // Hold this actor while the real short WAV finishes, then poll before
            // the delegate's queued actor task. No simulated playback result.
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.5)
            try check(!session.actualPlayerIsPlaying, "actual short player did not reach its end")
            session.tick()
            for _ in 0..<100 { if updates.last?.1 == false { break }; try await Task.sleep(nanoseconds: 2_000_000) }
            try check(updates.last?.1 == false && abs((updates.last?.0 ?? -1) - 1) < 0.000001,
                      "clock poll discarded the real completion delegate and exact final time")
            try check(updates.filter { !$0.1 }.count == 1, "natural completion notified twice")
            try check(try fm.contentsOfDirectory(atPath: scratch.path).isEmpty, "completed mix retained files")
        }
        try await test("missing completion remains an explicit failure instead of a fabricated final time") {
            let session = StudioAudioTimelineSession(scratchParent: scratch)
            defer { session.close() }
            var updates: [(Double, Bool)] = []
            try check(session.play(document: vm.document, tracks: vm.projectAudioTracks, duration: 1, from: 0.85,
                auditionVolume: 0, stillCurrent: { true }, onTime: { updates.append(($0, $1)) }), "missing-completion prepare")
            for _ in 0..<2000 { if !session.isPreparing { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            try check(session.actualPlayerIsPlaying, session.notice ?? "missing-completion real player absent")
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.5)
            try check(!session.actualPlayerIsPlaying, "actual short player still playing")
            // Controlled monotonic-clock advancement while the real delegate is
            // still queued. This exercises the bounded failure, not a device call.
            session.tick(at: 1000)
            session.tick(at: 1002.001)
            try check(!session.isPlaying && session.notice?.contains("completion was confirmed") == true,
                      "unconfirmed completion was not reported")
            try check(updates.last?.1 == false && (updates.last?.0 ?? 1) < 1,
                      "unconfirmed stop fabricated an exact end")
            for _ in 0..<10 { await Task.yield() }
            try check(updates.filter { !$0.1 }.count == 1, "late delegate notified a released session")
            try check(try fm.contentsOfDirectory(atPath: scratch.path).isEmpty, "failed completion retained files")
        }
        try await test("cancel and stale context produce no real playback or leaked output") {
            for cancel in [true, false] {
                let session = StudioAudioTimelineSession(scratchParent: scratch)
                var current = true, active = 0
                try check(session.play(document: vm.document, tracks: vm.projectAudioTracks, duration: 1, from: 0,
                    auditionVolume: 0, stillCurrent: { current }, onTime: { _, playing in if playing { active += 1 } }), "prepare")
                if cancel { session.stop() } else { current = false }
                for _ in 0..<2000 { if !session.isPreparing { break }; try await Task.sleep(nanoseconds: 5_000_000) }
                try check(!session.isPreparing && !session.actualPlayerIsPlaying && active == 0 && session.notice != nil, "cancel or stale started audio")
                try check(try fm.contentsOfDirectory(atPath: scratch.path).isEmpty, "cancel leak")
            }
        }
        try await test("geometry rejects invalid values and schema guards prevent silent feature downgrade") {
            for x in [Double.nan, .infinity, -1, 1001] {
                try check(StudioAudioTimelineGeometry.snapped(x, fps: 8, enabled: true) == nil, "invalid snap")
            }
            try check(StudioAudioTimelineGeometry.snapped(0.31, fps: 8, enabled: false) == 0.31, "snap off")
            var old = vm.document; old.schemaVersion = 3
            do { try old.validate(); throw Failure(message: "new trim under old schema") } catch is StudioDocumentError { }
        }
        try await test("stopped display frame agrees with real insertion and frame clipboard") {
            let probeVM = StudioViewModel(storage: storage)
            let made = await probeVM.createProject(name: "Stopped target", width: 64, height: 64, fps: 8)
            try check(made, "probe create")
            let firstID = probeVM.document.activeFrameID
            let red = DrawnElement(id: "first-red", tool: .circle, points: [StrokePoint(x: 4, y: 4), StrokePoint(x: 20, y: 20)], color: "FF0000", width: 2, opacity: 1, layerID: probeVM.activeLayerID)
            try check(probeVM.commitElement(red), "first drawing")
            probeVM.addFrame(); probeVM.addFrame()
            let lastID = probeVM.document.activeFrameID
            let blue = DrawnElement(id: "last-blue", tool: .circle, points: [StrokePoint(x: 30, y: 30), StrokePoint(x: 50, y: 50)], color: "0000FF", width: 2, opacity: 1, layerID: probeVM.activeLayerID)
            try check(probeVM.commitElement(blue), "last drawing")
            probeVM.currentFrameIndex = 0
            probeVM.displayAudioPlaybackTime(0.25, playing: false)
            try check(probeVM.currentFrame.id == lastID && probeVM.document.activeFrameID == lastID && !probeVM.isPlaying, "stopped display and selected frame differ")
            let extra = DrawnElement(id: "insert-after-stop", tool: .circle, points: [StrokePoint(x: 2, y: 2), StrokePoint(x: 8, y: 8)], color: "00FF00", width: 2, opacity: 1, layerID: probeVM.activeLayerID)
            try check(probeVM.commitElement(extra), "default insertion")
            try check(!probeVM.document.frames[0].elements.contains { $0.id == extra.id } && probeVM.currentFrame.elements.contains { $0.id == extra.id }, "default insertion targeted a hidden frame")
            probeVM.copyFrame(); probeVM.pasteFrame()
            try check(!probeVM.currentFrame.elements.contains { $0.color == "FF0000" } && probeVM.currentFrame.elements.contains { $0.color == "0000FF" }, "clipboard copied a hidden frame")
        }
        try await test("stop callback is one-shot even with a reentrant stop") {
            let session = StudioAudioTimelineSession(scratchParent: scratch)
            var stoppedCallbacks = 0
            try check(session.play(document: vm.document, tracks: vm.projectAudioTracks, duration: 1, from: 0,
                auditionVolume: 0, stillCurrent: { true }, onTime: { _, playing in
                    if !playing { stoppedCallbacks += 1; if stoppedCallbacks == 1 { session.stop() } }
                }), "reentrant prepare")
            for _ in 0..<2000 { if !session.isPreparing { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            try check(session.actualPlayerIsPlaying, session.notice ?? "reentrant player absent")
            session.stop()
            try check(stoppedCallbacks == 1, "stop callback fired twice")
        }
        try await test("failed mix retains recovery across panel sessions and retries safely") {
            let session = StudioAudioTimelineSession(scratchParent: scratch)
            try check(session.play(document: vm.document, tracks: vm.projectAudioTracks, duration: 4, from: 0,
                auditionVolume: 0, stillCurrent: { true }, onTime: { _, _ in }), "conflict prepare")
            var conflictDirectory: URL?
            for _ in 0..<10000 {
                let folders = try fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)
                if let folder = folders.first(where: { $0.lastPathComponent.hasPrefix(".sdi-audio-mix-") && fm.fileExists(atPath: $0.appendingPathComponent("mix.caf").path) }) {
                    try Data("foreign sentinel".utf8).write(to: folder.appendingPathComponent("foreign.txt"), options: .withoutOverwriting)
                    conflictDirectory = folder; break
                }
                if !session.isPreparing { break }
                await Task.yield()
            }
            guard let directory = conflictDirectory else { throw Failure(message: "could not inject owned test conflict before mix returned") }
            for _ in 0..<2000 { if !session.isPreparing { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            try check(!session.isPreparing && !session.actualPlayerIsPlaying, "conflict did not fail closed")
            try check(try String(contentsOf: directory.appendingPathComponent("foreign.txt")) == "foreign sentinel", "foreign evidence removed")
            try fm.removeItem(at: directory.appendingPathComponent("foreign.txt"))
            let reopenedPanel = StudioAudioTimelineSession(scratchParent: scratch)
            reopenedPanel.stop()
            try check(!fm.fileExists(atPath: directory.path), "captured failed output could not recover across panels")
        }
        try await test("close before task starts releases the process lease without selection callbacks") {
            var session: StudioAudioTimelineSession? = StudioAudioTimelineSession(scratchParent: scratch)
            weak var lifetime = session
            var callbacks = 0
            try check(session!.play(document: vm.document, tracks: vm.projectAudioTracks, duration: 1, from: 0,
                auditionVolume: 0, stillCurrent: { true }, onTime: { _, _ in callbacks += 1 }), "early prepare")
            session!.close(); session = nil
            for _ in 0..<2000 { if lifetime == nil { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            try check(lifetime == nil && callbacks == 0, "cancel retained owner or changed stopped selection")
            let next = StudioAudioTimelineSession(scratchParent: scratch)
            try check(next.play(document: vm.document, tracks: vm.projectAudioTracks, duration: 1, from: 0,
                auditionVolume: 0, stillCurrent: { true }, onTime: { _, _ in }), "old lease stranded later playback")
            next.close()
            for _ in 0..<2000 { if !next.isPreparing { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            try check(!next.isPreparing && !next.actualPlayerIsPlaying, "new cancelled owner did not settle")
            try check(try fm.contentsOfDirectory(atPath: scratch.path).isEmpty, "early cancellation leaked")
        }
        func duplicationFixture() async throws -> StudioViewModel {
            let local = StudioViewModel(storage: storage)
            let made = await local.createProject(name: "Audio duplicate \(UUID())", width: 64, height: 64, fps: 8)
            try check(made, "duplicate fixture create")
            _ = try local.attachImportedAudio(imported.track, expectedProjectID: local.document.id,
                expectedRevision: local.document.revision, frameID: local.document.activeFrameID, trackNumber: 3)
            return local
        }
        try await test("duplicate reuses immutable bytes and preserves trim gain mute track with one Undo and cold reopen") {
            let local = try await duplicationFixture();let selected = local.audioClips[0].id
            try local.editSelectedAudioClip(selected, expectedRevision: local.document.revision, edit: .trim(sourceOffset: 1, duration: 0.5))
            try local.editSelectedAudioClip(selected, expectedRevision: local.document.revision, edit: .place(start: 0.25, track: 3))
            try local.editSelectedAudioClip(selected, expectedRevision: local.document.revision, edit: .volume(0.5))
            try local.editSelectedAudioClip(selected, expectedRevision: local.document.revision, edit: .mute(true))
            let before = local.document;let capture = local.prepareAudioDuplication()!
            let copiedID = try local.duplicateAudioClip(capture)
            let copied = local.audioClips[1]
            try check(local.document.revision == before.revision + 1 && local.audioClips[0] == before.audioClips[0], "duplicate changed original")
            try check(copiedID != selected && copied.id == copiedID && copied.startTime == 0.75 && copied.duration == 0.5 && copied.sourceOffset == 1 && copied.volume == 0.5 && copied.isMuted && copied.track == 3 && copied.assetID == imported.id, "copy lost clip settings")
            try check(local.selectedCurrentAudioClip?.id == copiedID && local.projectAudioTracks.count == 1 && local.projectAudioTracks[0].audioData == imported.track.audioData, "selection or source duplication")
            local.undo();try check(local.audioClips == before.audioClips, "one Undo did not restore original clips")
            local.redo();try check(local.audioClips == before.audioClips + [copied], "Redo changed identity or timing")
            let saved = await local.save();try check(saved, "duplicate save failed")
            let reopened = StudioViewModel(storage: storage);await reopened.loadProjects()
            let metadata = reopened.savedProjects.first { $0.id == local.document.id }!
            let opened = await reopened.openProject(metadata);try check(opened, "duplicate cold reopen failed")
            try check(reopened.audioClips == local.audioClips && reopened.projectAudioTracks.count == 1 && reopened.projectAudioTracks[0].audioData == imported.track.audioData, "cold reopen changed copied clips or source")
        }
        try await test("duplicated trimmed clips produce adjacent real stereo samples with correct gain and gaps") {
            let local = try await duplicationFixture();let selected = local.audioClips[0].id
            try local.editSelectedAudioClip(selected, expectedRevision: local.document.revision, edit: .trim(sourceOffset: 1, duration: 0.5))
            try local.editSelectedAudioClip(selected, expectedRevision: local.document.revision, edit: .place(start: 0.25, track: 3))
            try local.editSelectedAudioClip(selected, expectedRevision: local.document.revision, edit: .volume(0.5))
            try local.duplicateAudioClip(local.prepareAudioDuplication()!)
            let output = try await StudioAudioMixService().mix(document: local.document, retainedAudioTracks: local.projectAudioTracks, durationSeconds: 1.5, outputParent: scratch)
            defer { try? output.cleanup() };let data = try decode(output)
            try check(data[0].count == 72_000 && data[0][0..<12_000].allSatisfy { $0 == 0 } && data[0][60_000...].allSatisfy { $0 == 0 }, "duplicate changed duration/gaps")
            for n in 12_000..<60_000 { try check(abs(data[0][n] - 0.125) < 0.0001 && abs(data[1][n] + 0.25) < 0.0001, "duplicate source offset or gain incorrect") }
        }
        try await test("duplicate rejects missing selection different project stale revision and active playback") {
            let local = try await duplicationFixture();let capture = local.prepareAudioDuplication()!;let before = local.document
            local.selectedAudioClip = nil
            do { try local.duplicateAudioClip(capture);throw Failure(message: "unselected duplicate accepted") } catch is StudioDocumentError { }
            local.selectedAudioClip = capture.clip
            let wrongProject = StudioViewModel.AudioDuplicationCapture(projectID: UUID(), revision: capture.revision, clip: capture.clip)
            do { try local.duplicateAudioClip(wrongProject);throw Failure(message: "wrong project duplicate accepted") } catch is StudioDocumentError { }
            let stale = StudioViewModel.AudioDuplicationCapture(projectID: capture.projectID, revision: capture.revision - 1, clip: capture.clip)
            do { try local.duplicateAudioClip(stale);throw Failure(message: "stale duplicate accepted") } catch is StudioDocumentError { }
            local.displayAudioPlaybackTime(0, playing: true)
            do { try local.duplicateAudioClip(capture);throw Failure(message: "playing duplicate accepted") } catch is StudioDocumentError { }
            local.stopPlayback();try check(local.document == before && local.projectAudioTracks.count == 1, "rejection mutated project")
        }
        try await test("cancelled duplicate leaves document history selection and original bytes unchanged") {
            let local = try await duplicationFixture();let capture = local.prepareAudioDuplication()!;let before = local.document
            for cancellationPoint in [1,2] {
                var checks = 0
                do { try local.duplicateAudioClip(capture, checkCancellation: { checks += 1;if checks == cancellationPoint { throw CancellationError() } });throw Failure(message: "cancelled duplicate accepted") } catch is CancellationError { }
                try check(local.document == before && local.selectedCurrentAudioClip == capture.clip && local.projectAudioTracks[0].audioData == imported.track.audioData, "cancel changed document/selection/source")
            }
            local.undo();try check(local.audioClips.isEmpty, "cancel inserted a hidden history entry")
        }
        try await test("duplicate enforces actual clip-count and timeline placement bounds without mutation") {
            let local = try await duplicationFixture();let original = local.audioClips[0]
            local.audioClips = (0..<128).map { i in AudioClip(id: "bounded-\(i)", soundName: original.soundName, track: 3, startTime: 0, duration: original.duration, assetID: original.assetID) }
            local.selectedAudioClip = local.audioClips[0];let full = local.document
            do { try local.duplicateAudioClip(local.prepareAudioDuplication()!);throw Failure(message: "129th clip accepted") } catch is StudioDocumentError { }
            try check(local.document == full, "limit failure changed project")
            let edge = try await duplicationFixture();let clip = edge.audioClips[0]
            try edge.editSelectedAudioClip(clip.id, expectedRevision: edge.document.revision, edit: .place(start: 1000, track: 3))
            let before = edge.document
            do { try edge.duplicateAudioClip(edge.prepareAudioDuplication()!);throw Failure(message: "duplicate beyond timeline bound accepted") } catch is StudioDocumentError { }
            try check(edge.document == before, "placement rejection changed source")
        }
        try await test("split preserves source metadata and left identity with one Undo and actual cold reopen") {
            let local = try await duplicationFixture();let id = local.audioClips[0].id
            try local.editSelectedAudioClip(id, expectedRevision: local.document.revision, edit: .trim(sourceOffset: 1, duration: 0.5))
            try local.editSelectedAudioClip(id, expectedRevision: local.document.revision, edit: .place(start: 0.25, track: 3))
            try local.editSelectedAudioClip(id, expectedRevision: local.document.revision, edit: .volume(0.5))
            try local.editSelectedAudioClip(id, expectedRevision: local.document.revision, edit: .mute(true))
            local.displayAudioPlaybackTime(0.5, playing: false)
            let before = local.document;let capture = local.prepareAudioSplit()!
            let rightID = try local.splitAudioClip(capture);let after = local.document
            let left = local.audioClips[0], right = local.audioClips[1]
            try check(left.id == id && right.id == rightID && rightID != id && left.duration == 0.25 && right.duration == 0.25 && right.startTime == 0.5 && right.sourceOffset == 1.25, "split identity/timing")
            try check(left.sourceOffset == 1 && left.startTime == 0.25 && left.isMuted && right.isMuted && left.volume == 0.5 && right.volume == 0.5 && left.track == 3 && right.track == 3 && left.assetID == right.assetID, "split settings")
            try check(after.revision == before.revision + 1 && local.selectedCurrentAudioClip?.id == rightID && local.projectAudioTracks.count == 1, "split transaction/source duplication")
            local.undo();try check(local.audioClips == before.audioClips, "split Undo")
            local.redo();try check(local.audioClips == after.audioClips, "split Redo identity")
            let saved = await local.save();try check(saved, "split save")
            let reopened = StudioViewModel(storage: storage);await reopened.loadProjects()
            let opened = await reopened.openProject(reopened.savedProjects.first { $0.id == local.document.id }!)
            try check(opened && reopened.audioClips == after.audioClips && reopened.projectAudioTracks.count == 1 && reopened.projectAudioTracks[0].audioData == imported.track.audioData, "split cold reopen/source bytes")
        }
        try await test("split at fractional sample phases preserves every real decoded stereo sample") {
            let url = root.appendingPathComponent("split-ramp.wav")
            let ramp = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12_000)!;ramp.frameLength = 12_000
            for n in 0..<12_000 {
                ramp.floatChannelData![0][n] = Float(n % 977) / 1024
                ramp.floatChannelData![1][n] = -Float(n % 631) / 1024
            }
            do { let file = try AVAudioFile(forWriting: url, settings: format.settings);try file.write(from: ramp) }
            let sound = try await StudioAudioImportService.shared.importAudio(from: url, scratchParent: scratch) { _ in }
            for cut in [0.147211, 0.156241, 0.189999] {
                let local = StudioViewModel(storage: storage)
                let made = await local.createProject(name: "Sample-phase split", width: 64, height: 64, fps: 8);try check(made, "phase project")
                let id = try local.attachImportedAudio(sound.track, expectedProjectID: local.document.id, expectedRevision: local.document.revision, frameID: local.document.activeFrameID, trackNumber: 2)
                try local.editSelectedAudioClip(id, expectedRevision: local.document.revision, edit: .trim(sourceOffset: 0.020006, duration: 0.1))
                try local.editSelectedAudioClip(id, expectedRevision: local.document.revision, edit: .place(start: 0.100014, track: 2))
                try local.editSelectedAudioClip(id, expectedRevision: local.document.revision, edit: .volume(0.75))
                let before = try await StudioAudioMixService().mix(document: local.document, retainedAudioTracks: local.projectAudioTracks, durationSeconds: 0.25, outputParent: scratch)
                defer { try? before.cleanup() };let expected = try decode(before)
                local.displayAudioPlaybackTime(cut, playing: false)
                let capture = local.prepareAudioSplit()!;try local.splitAudioClip(capture)
                let after = try await StudioAudioMixService().mix(document: local.document, retainedAudioTracks: local.projectAudioTracks, durationSeconds: 0.25, outputParent: scratch)
                defer { try? after.cleanup() };let actual = try decode(after)
                try check(actual == expected, "split shifted, repeated or lost a decoded source sample at \(cut)")
                try check(abs(capture.boundary - cut) <= 0.5 / 48_000 && local.projectAudioTracks[0].audioData == sound.track.audioData, "split quantization or original changed")
            }
        }
        try await test("split rejects endpoints sub-sample fragments and nonfinite playheads without mutation") {
            let local = try await duplicationFixture();let clip = local.audioClips[0];let before = local.document
            for value in [Double.nan, .infinity, -1, clip.startTime, clip.startTime + clip.duration, clip.startTime + 0.25 / 48_000, clip.startTime + clip.duration - 0.25 / 48_000] {
                local.audioPlayheadTime = value
                try check(local.prepareAudioSplit() == nil, "invalid split boundary accepted")
            }
            try check(local.document == before && local.projectAudioTracks[0].audioData == imported.track.audioData, "invalid boundary changed source")
        }
        try await test("split rejects stale project selection revision playback and changed playhead") {
            let local = try await duplicationFixture();local.displayAudioPlaybackTime(0.5, playing: false)
            let capture = local.prepareAudioSplit()!;let before = local.document
            local.selectedAudioClip = nil
            do { try local.splitAudioClip(capture);throw Failure(message: "split without selection") } catch is StudioDocumentError { }
            local.selectedAudioClip = capture.selection.clip
            let wrong = StudioViewModel.AudioSplitCapture(selection: .init(projectID: UUID(), revision: capture.selection.revision, clip: capture.selection.clip), playhead: capture.playhead, boundary: capture.boundary, rightSourceOffset: capture.rightSourceOffset)
            do { try local.splitAudioClip(wrong);throw Failure(message: "split wrong project") } catch is StudioDocumentError { }
            local.displayAudioPlaybackTime(0.75, playing: false)
            do { try local.splitAudioClip(capture);throw Failure(message: "split moved playhead") } catch is StudioDocumentError { }
            local.displayAudioPlaybackTime(0.5, playing: true)
            do { try local.splitAudioClip(capture);throw Failure(message: "split active playback") } catch is StudioDocumentError { }
            local.stopPlayback();try check(local.document == before, "rejected split mutated project")
            try local.editSelectedAudioClip(capture.selection.clip.id, expectedRevision: local.document.revision, edit: .volume(0.5))
            let changed = local.document
            do { try local.splitAudioClip(capture);throw Failure(message: "split stale revision") } catch is StudioDocumentError { }
            try check(local.document == changed, "stale split changed existing edit")
        }
        try await test("split cancellation and late playhead changes preserve history and original bytes") {
            let local = try await duplicationFixture();local.displayAudioPlaybackTime(0.5, playing: false)
            let capture = local.prepareAudioSplit()!;let before = local.document
            for point in [1,2] {
                var calls = 0
                do { try local.splitAudioClip(capture, checkCancellation: { calls += 1;if calls == point { throw CancellationError() } });throw Failure(message: "split ignored cancellation") } catch is CancellationError { }
                try check(local.document == before && local.selectedCurrentAudioClip == capture.selection.clip, "cancelled split mutated state")
            }
            var calls = 0
            do { try local.splitAudioClip(capture, checkCancellation: { calls += 1;if calls == 2 { local.audioPlayheadTime = 0.75 } });throw Failure(message: "late playhead accepted") } catch is StudioDocumentError { }
            try check(local.document == before && local.projectAudioTracks[0].audioData == imported.track.audioData, "late split changed source")
            local.undo();try check(local.audioClips.isEmpty, "cancelled split inserted a history entry")
        }
        try await test("split enforces the real 128-clip document limit without removing the original") {
            let local = try await duplicationFixture();let original = local.audioClips[0]
            local.audioClips = (0..<128).map { i in AudioClip(id: "split-limit-\(i)", soundName: original.soundName, track: 3, startTime: 0, duration: original.duration, assetID: original.assetID) }
            local.selectedAudioClip = local.audioClips[0];local.displayAudioPlaybackTime(0.5, playing: false);let before = local.document
            do { try local.splitAudioClip(local.prepareAudioSplit()!);throw Failure(message: "split over clip limit") } catch is StudioDocumentError { }
            try check(local.document == before && local.audioClips[0].id == "split-limit-0", "limit rejection lost original")
        }
        try await test("split promotes existing trimmed-audio format atomically and Undo restores prior format") {
            let local = try await duplicationFixture();let before = local.document
            try check(before.schemaVersion == 1 && before.audioClips[0].sourceOffset == 0, "untrimmed input fixture")
            local.displayAudioPlaybackTime(1, playing: false)
            try local.splitAudioClip(local.prepareAudioSplit()!)
            try check(local.document.schemaVersion == 4 && local.audioClips[1].sourceOffset == 1, "split did not preserve additive trim format")
            let clips = local.audioClips
            local.undo();try check(local.document.schemaVersion == before.schemaVersion && local.audioClips == before.audioClips, "split format change escaped Undo")
            local.redo();let saved = await local.save();try check(saved, "format split save")
            let reopened = StudioViewModel(storage: storage);await reopened.loadProjects()
            let opened = await reopened.openProject(reopened.savedProjects.first { $0.id == local.document.id }!)
            try check(opened && reopened.document.schemaVersion == 4 && reopened.audioClips == clips, "trim format lost on cold reopen")
        }
        try await test("numeric trim input accepts decimal locale and exact roundtrips but rejects invalid values") {
            for value in [0.0, 0.125, 1 / 48_000.0, 299.987654321] {
                try check(StudioViewModel.audioTrimSeconds(String(value), decimalSeparator: ".") == value, "numeric roundtrip")
            }
            try check(StudioViewModel.audioTrimSeconds(" 1,25 ", decimalSeparator: ",") == 1.25, "localized decimal")
            for text in ["", " ", "NaN", "inf", "-1", "1e999", "1.2.3", "1,2.3", "1 000", String(repeating: "0", count: 65)] {
                try check(StudioViewModel.audioTrimSeconds(text, decimalSeparator: ",") == nil, "invalid input accepted: \(text)")
            }
            try check(StudioViewModel.audioTrimSeconds("1,25", decimalSeparator: ".") == nil, "foreign separator silently treated as grouping")
        }
        try await test("numeric trim commits both fields once with actual mixed pixels-free samples and cold reopen") {
            let local = try await duplicationFixture();let original = local.audioClips[0]
            let capture = local.prepareAudioTrim()!;let before = local.document
            try local.trimAudioClip(capture, sourceOffset: 1.25, duration: 0.5)
            let clip = local.audioClips[0]
            try check(local.document.revision == before.revision + 1 && clip.id == original.id && clip.sourceOffset == 1.25 && clip.duration == 0.5 && clip.startTime == original.startTime && clip.track == original.track && clip.volume == original.volume, "numeric trim identity/transaction")
            let output = try await StudioAudioMixService().mix(document: local.document, retainedAudioTracks: local.projectAudioTracks, durationSeconds: 1, outputParent: scratch)
            defer { try? output.cleanup() };let samples = try decode(output)
            try check(samples[0][0..<24_000].allSatisfy { abs($0 - 0.2) < 0.0001 } && samples[1][0..<24_000].allSatisfy { abs($0 + 0.4) < 0.0001 } && samples[0][24_000...].allSatisfy { $0 == 0 }, "numeric source/duration did not reach actual mixer")
            local.undo();try check(local.audioClips == before.audioClips && local.document.schemaVersion == before.schemaVersion, "one undo did not restore both trim values")
            local.redo();try check(local.audioClips == [clip], "trim redo")
            let saved = await local.save();try check(saved, "numeric save")
            let reopened = StudioViewModel(storage: storage);await reopened.loadProjects()
            let opened = await reopened.openProject(reopened.savedProjects.first { $0.id == local.document.id }!)
            try check(opened && reopened.audioClips == [clip] && reopened.projectAudioTracks[0].audioData == imported.track.audioData, "numeric trim cold reopen or original bytes")
        }
        try await test("numeric trim invalid boundaries and unchanged values create no document or history edit") {
            let local = try await duplicationFixture();let before = local.document;let capture = local.prepareAudioTrim()!
            for (offset, duration) in [(Double.nan, 1.0), (0.0, Double.infinity), (-0.1, 1), (0, 0), (0, 0.5 / 48_000), (1.9, 0.2)] {
                do { try local.trimAudioClip(capture, sourceOffset: offset, duration: duration);throw Failure(message: "invalid numeric trim accepted") } catch is StudioDocumentError { }
                try check(local.document == before, "invalid trim changed document")
            }
            try local.trimAudioClip(capture, sourceOffset: before.audioClips[0].sourceOffset, duration: before.audioClips[0].duration)
            try check(local.document == before, "unchanged values created revision")
            local.undo();try check(local.audioClips.isEmpty, "no-op inserted history")
        }
        try await test("numeric trim rejects captured project revision selection and playback changes") {
            let local = try await duplicationFixture();let capture = local.prepareAudioTrim()!
            local.selectedAudioClip = nil;let before = local.document
            do { try local.trimAudioClip(capture, sourceOffset: 1, duration: 0.5);throw Failure(message: "unselected trim") } catch is StudioDocumentError { }
            try check(local.document == before, "unselected trim mutated")
            local.selectedAudioClip = capture.selection.clip
            local.displayAudioPlaybackTime(0, playing: true)
            do { try local.trimAudioClip(capture, sourceOffset: 1, duration: 0.5);throw Failure(message: "playing trim") } catch is StudioDocumentError { }
            local.displayAudioPlaybackTime(0, playing: false)
            try local.editSelectedAudioClip(capture.selection.clip.id, expectedRevision: local.document.revision, edit: .volume(0.4))
            let changed = local.document
            do { try local.trimAudioClip(capture, sourceOffset: 1, duration: 0.5);throw Failure(message: "stale trim") } catch is StudioDocumentError { }
            try check(local.document == changed, "stale trim changed document")
            let other = try await duplicationFixture();let otherBefore = other.document
            do { try other.trimAudioClip(capture, sourceOffset: 1, duration: 0.5);throw Failure(message: "wrong-project trim") } catch is StudioDocumentError { }
            try check(other.document == otherBefore, "wrong-project trim mutated")
        }
        try await test("numeric trim cancellation and late selection change preserve source and history") {
            let local = try await duplicationFixture();let capture = local.prepareAudioTrim()!;let before = local.document
            for point in [1, 2] {
                var calls = 0
                do { try local.trimAudioClip(capture, sourceOffset: 1, duration: 0.5, checkCancellation: { calls += 1;if calls == point { throw CancellationError() } });throw Failure(message: "trim ignored cancellation") } catch is CancellationError { }
                try check(local.document == before, "cancelled trim changed document")
            }
            var calls = 0
            do { try local.trimAudioClip(capture, sourceOffset: 1, duration: 0.5, checkCancellation: { calls += 1;if calls == 2 { local.selectedAudioClip = nil } });throw Failure(message: "late selection accepted") } catch is StudioDocumentError { }
            try check(local.document == before && local.projectAudioTracks[0].audioData == imported.track.audioData, "late trim modified original")
            local.undo();try check(local.audioClips.isEmpty, "cancelled trim inserted history")
        }
        try await test("opening and cancelling a numeric trim draft does not commit or enter history") {
            let local = try await duplicationFixture();let before = local.document
            let capture = local.prepareAudioTrim();try check(capture != nil && local.document == before, "opening trim changed document")
            _ = StudioViewModel.audioTrimSeconds("0.25")
            try check(local.document == before && local.projectAudioTracks[0].audioData == imported.track.audioData, "draft parsing changed original")
            local.undo();try check(local.audioClips.isEmpty, "draft created history")
        }
        func fadeFixture(_ name: String) async throws -> (StudioViewModel, String, DeviceStorageManager) {
            let folder = root.appendingPathComponent(name)
            let store = DeviceStorageManager(documentsDirectory: folder, cachesDirectory: folder)
            let local = StudioViewModel(storage: store)
            let made = await local.createProject(name: name, width: 64, height: 64, fps: 8)
            try check(made, "fade fixture create")
            let clipID = try local.attachImportedAudio(imported.track, expectedProjectID: local.document.id,
                expectedRevision: local.document.revision, frameID: local.document.activeFrameID, trackNumber: 1)
            try local.editSelectedAudioClip(clipID, expectedRevision: local.document.revision, edit: .trim(sourceOffset: 1, duration: 1))
            return (local, clipID, store)
        }
        try await test("fades use one reversible edit and real saved archive retains envelope source and original bytes") {
            let (local, clipID, store) = try await fadeFixture("fade-history")
            let before = local.document
            guard let captured = local.prepareAudioFades() else { throw Failure(message: "fade capture") }
            try local.setAudioFades(captured, fadeIn: 0.25, fadeOut: 0.375)
            let envelope = AudioFadeEnvelope(sourceStartFrame: 48_000, frameCount: 48_000, fadeInFrames: 12_000, fadeOutFrames: 18_000)
            try check(local.audioClips[0].fadeEnvelope == envelope && local.document.schemaVersion == 14
                && local.document.revision == before.revision + 1 && local.selectedCurrentAudioClip?.id == clipID, "fade edit metadata/history")
            local.undo(); try check(local.audioClips == before.audioClips, "fade Undo")
            local.redo(); try check(local.audioClips[0].fadeEnvelope == envelope, "fade Redo")
            let saved = await local.save(); try check(saved, "fade save")
            let cold = StudioViewModel(storage: store); await cold.loadProjects()
            guard let metadata = cold.savedProjects.first(where: { $0.id == local.document.id }) else { throw Failure(message: "saved fade project absent") }
            let opened = await cold.openProject(metadata)
            try check(opened && cold.document == local.document && cold.audioClips[0].fadeEnvelope == envelope, "cold fade archive changed")
            try check(cold.audioTrack(forAssetID: imported.id)?.audioData == imported.track.audioData, "fade changed original sound bytes")
            await cold.flush(); await local.flush()
        }
        try await test("fade reset preserves redo for no-op and clears only the selected envelope in one Undo") {
            let (local, _, _) = try await fadeFixture("fade-clear")
            try local.setAudioFades(local.prepareAudioFades()!, fadeIn: 0.25, fadeOut: 0.25)
            let envelope = local.audioClips[0].fadeEnvelope
            local.undo(); local.selectedAudioClip = local.audioClips[0]
            let before = local.document
            try local.setAudioFades(local.prepareAudioFades()!, fadeIn: 0, fadeOut: 0)
            try check(local.document == before && local.canRedo, "no-op fades consumed Redo")
            local.redo(); local.selectedAudioClip = local.audioClips[0]
            let restored = local.audioClips[0]
            try local.setAudioFades(local.prepareAudioFades()!, fadeIn: 0, fadeOut: 0)
            try check(local.audioClips[0].fadeEnvelope == nil && local.audioClips[0].volume == restored.volume, "reset changed volume or kept fade")
            local.undo(); try check(local.audioClips[0].fadeEnvelope == envelope, "reset Undo lost envelope")
            await local.flush()
        }
        try await test("invalid stale foreign busy and early or late cancelled fade commands preserve project and history") {
            let (local, _, _) = try await fadeFixture("fade-rejection")
            let captured = local.prepareAudioFades()!, before = local.document
            for (incoming, outgoing) in [(-0.1,0.0),(Double.nan,0.1),(0.1,Double.infinity),(0.8,0.3),(1.01,0.0)] {
                do { try local.setAudioFades(captured, fadeIn: incoming, fadeOut: outgoing); throw Failure(message: "invalid fade accepted") }
                catch is AudioFadeEnvelope.Failure { }
                try check(local.document == before, "invalid fade mutated")
            }
            for point in 1...2 {
                var calls = 0
                do { try local.setAudioFades(captured, fadeIn: 0.1, fadeOut: 0.1) { calls += 1; if calls == point { throw CancellationError() } }; throw Failure(message: "fade cancellation ignored") }
                catch is CancellationError { }
                try check(calls == point && local.document == before, "cancelled fade mutated")
            }
            let foreign = StudioViewModel.AudioFadeCapture(selection: .init(projectID: UUID(), revision: captured.selection.revision, clip: captured.selection.clip))
            do { try local.setAudioFades(foreign, fadeIn: 0.1, fadeOut: 0.1); throw Failure(message: "foreign fade accepted") } catch is StudioDocumentError { }
            local.displayAudioPlaybackTime(0, playing: true)
            try check(local.prepareAudioFades() == nil, "playing fade capture accepted")
            do { try local.setAudioFades(captured, fadeIn: 0.1, fadeOut: 0.1); throw Failure(message: "busy fade accepted") } catch is StudioDocumentError { }
            local.displayAudioPlaybackTime(0, playing: false)
            local.selectedAudioClip = nil
            do { try local.setAudioFades(captured, fadeIn: 0.1, fadeOut: 0.1); throw Failure(message: "unselected fade accepted") } catch is StudioDocumentError { }
            try check(local.document == before, "rejected fade mutated")
            await local.flush()
        }
        try await test("late fade validation never overwrites a newly selected clip or intervening mute edit") {
            let (local, first, _) = try await fadeFixture("fade-late-context")
            _ = try local.duplicateAudioClip(local.prepareAudioDuplication()!)
            let second = local.selectedCurrentAudioClip!
            local.selectedAudioClip = local.audioClips.first(where: { $0.id == first })
            let captured = local.prepareAudioFades()!, before = local.document
            var calls = 0
            do { try local.setAudioFades(captured, fadeIn: 0.1, fadeOut: 0.1) { calls += 1; if calls == 2 { local.selectedAudioClip = second } }; throw Failure(message: "fade followed new selection") } catch is StudioDocumentError { }
            try check(calls == 2 && local.document == before && local.selectedCurrentAudioClip == second, "late fade overwrote selection")
            local.selectedAudioClip = captured.selection.clip; calls = 0
            do { try local.setAudioFades(captured, fadeIn: 0.1, fadeOut: 0.1) {
                calls += 1
                if calls == 2 { try local.editSelectedAudioClip(first, expectedRevision: local.document.revision, edit: .mute(true)) }
            }; throw Failure(message: "fade overwrote intervening edit") } catch is StudioDocumentError { }
            try check(local.document.revision == before.revision + 1 && local.audioClips[0].isMuted
                && local.audioClips.allSatisfy { $0.fadeEnvelope == nil }, "late fade lost independent edit")
            local.undo(); try check(local.audioClips == before.audioClips, "late fade inserted history")
            await local.flush()
        }
        try await test("actual production split trim duplicate and move preserve source fade phase and cold reopen") {
            let (local, first, store) = try await fadeFixture("fade-derived-clips")
            try local.setAudioFades(local.prepareAudioFades()!, fadeIn: 0.25, fadeOut: 0.25)
            let envelope = local.audioClips[0].fadeEnvelope
            _ = try local.duplicateAudioClip(local.prepareAudioDuplication()!)
            try check(local.audioClips.count == 2 && local.audioClips.allSatisfy { $0.fadeEnvelope == envelope }, "duplicate lost fades")
            local.selectedAudioClip = local.audioClips.first(where: { $0.id == first }); local.audioPlayheadTime = 0.125
            guard let split = local.prepareAudioSplit() else { throw Failure(message: "fade split capture") }
            let rightID = try local.splitAudioClip(split)
            try check(local.audioClips.count == 3 && local.audioClips.allSatisfy { $0.fadeEnvelope == envelope }, "split restarted envelope")
            try local.editSelectedAudioClip(rightID, expectedRevision: local.document.revision, edit: .trim(sourceOffset: 1.25, duration: 0.5))
            try local.editSelectedAudioClip(rightID, expectedRevision: local.document.revision, edit: .place(start: 0.25, track: 4))
            try check(local.selectedCurrentAudioClip?.fadeEnvelope == envelope && local.audioClips[1].sourceOffset == 1.25, "trim or lane move changed envelope")
            let saved = await local.save(); try check(saved, "derived fades save")
            let cold = StudioViewModel(storage: store); await cold.loadProjects()
            let opened = await cold.openProject(cold.savedProjects.first(where: { $0.id == local.document.id })!)
            try check(opened && cold.document == local.document && cold.projectAudioTracks.first?.audioData == imported.track.audioData, "derived envelope or bytes lost on reopen")
            await cold.flush(); await local.flush()
        }
        try await test("historical audio and full documents remain unchanged when fade metadata is absent") {
            let clip = AudioClip(id: "historical-fade-default", soundName: "Existing sound", track: 1, startTime: 0, duration: 1, assetID: imported.id)
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clip)) as! [String: Any]
            object.removeValue(forKey: "fadeEnvelope")
            let bytes = try JSONSerialization.data(withJSONObject: object)
            let historical = try JSONDecoder().decode(AudioClip.self, from: bytes)
            try check(historical == clip && historical.fadeEnvelope == nil, "absent envelope altered old clip")
            var old = try StudioDocument.new(name: "Historical fades", width: 64, height: 64, fps: 8); old.audioClips = [historical]
            let archive = try JSONEncoder().encode(old), restored = try JSONDecoder().decode(StudioDocument.self, from: archive)
            try restored.validate(); try check(restored == old && restored.schemaVersion == 1, "decode rewrote historical document")
            var invalid = old; invalid.audioClips[0].fadeEnvelope = .init(sourceStartFrame: 0, frameCount: 48_000, fadeInFrames: 100, fadeOutFrames: 100)
            do { try invalid.validate(); throw Failure(message: "old schema accepted fades") } catch is StudioDocumentError { }
        }
        func audioCommandFixture(_ name: String) async throws -> (StudioViewModel, DeviceStorageManager, String) {
            let folder = root.appendingPathComponent(name)
            let store = DeviceStorageManager(documentsDirectory: folder, cachesDirectory: folder)
            let local = StudioViewModel(storage: store)
            let made = await local.createProject(name: name, width: 64, height: 64, fps: 8)
            try check(made, "command fixture create")
            let clipID = try local.attachImportedAudio(imported.track, expectedProjectID: local.document.id,
                expectedRevision: local.document.revision, frameID: local.document.activeFrameID, trackNumber: 2)
            try local.editSelectedAudioClip(clipID, expectedRevision: local.document.revision, edit: .trim(sourceOffset: 1, duration: 1))
            await local.flush()
            return (local, store, clipID)
        }
        func audioRequest(_ local: StudioViewModel, _ id: String, _ settings: StudioAudioClipSettings) -> StudioCommandRequest {
            .init(requestID: UUID(), projectID: local.document.id, expectedRevision: local.document.revision,
                  action: .apply([.updateAudioClip(.init(clipID: id, settings: settings))]))
        }
        func content(_ value: StudioDocument) -> StudioDocument {
            var value = value; value.revision = 0; value.modifiedAt = value.createdAt; return value
        }
        try await test("strict audio command reaches actual stereo PCM full Undo and cold production reopen") {
            let (local, store, clipID) = try await audioCommandFixture("command-pcm")
            let trackCapture = local.prepareAudioTrackVolume(2)!
            try local.setAudioTrackVolume(trackCapture, volume: 0.5)
            let before = local.document
            let receipt = try local.applyStudioCommands(JSONEncoder().encode(audioRequest(local, clipID,
                .init(volume: 0.4, isMuted: false, fades: .init(fadeIn: 0.25, fadeOut: 0.25)))))
            let edited = local.document
            try check(receipt.changedAudioClipIDs == [clipID] && receipt.outcome == .applied
                      && edited.revision == before.revision + 1, "command receipt/revision")
            local.undo(); try check(content(local.document) == content(before), "full audio command Undo")
            local.redo(); try check(content(local.document) == content(edited), "full audio command Redo")
            let output = try await StudioAudioMixService().mix(document: local.document,
                retainedAudioTracks: local.projectAudioTracks, durationSeconds: 1.25, outputParent: scratch)
            defer { try? output.cleanup() }
            let data = try decode(output)
            try check(data[0].count == 60_000 && data[1].count == 60_000, "command mix duration")
            for n in 0..<48_000 {
                let gain = min(1, Double(n) / 12_000, Double(47_999 - n) / 12_000)
                try check(abs(Double(data[0][n]) - 0.05 * gain) < 0.00001
                          && abs(Double(data[1][n]) + 0.1 * gain) < 0.00001, "command gain/fade/source PCM at sample \(n)")
            }
            try check(data[0][48_000...].allSatisfy { $0 == 0 } && data[1][48_000...].allSatisfy { $0 == 0 }, "audio outside selected clip")
            let saved = await local.save(); try check(saved, "command audio save")
            let cold = StudioViewModel(storage: store); await cold.loadProjects()
            let opened = await cold.openProject(cold.savedProjects.first { $0.id == local.document.id }!)
            try check(opened && cold.document == local.document && cold.projectAudioTracks.first?.audioData == imported.track.audioData,
                      "command clip or original source changed on cold reopen")
            let muteReceipt = try cold.applyStudioCommands(JSONEncoder().encode(audioRequest(cold, clipID, .init(isMuted: true))))
            let muted = try await StudioAudioMixService().mix(document: cold.document,
                retainedAudioTracks: cold.projectAudioTracks, durationSeconds: 1, outputParent: scratch)
            defer { try? muted.cleanup() }
            try check(muteReceipt.changedAudioClipIDs == [clipID] && (try decode(muted)).flatMap { $0 }.allSatisfy { $0 == 0 }, "command mute not real silence")
            try check(cold.audioClips[0].fadeEnvelope == edited.audioClips[0].fadeEnvelope && cold.audioClips[0].volume == 0.4,
                      "mute command overwrote omitted settings")
            await cold.flush(); await local.flush()
        }
        try await test("manual controls and assistant clip settings produce identical documents") {
            let (local, _, clipID) = try await audioCommandFixture("command-manual-parity")
            let before = local.document
            _ = try local.applyStudioCommands(audioRequest(local, clipID, .init(volume: 0.2, isMuted: true,
                fades: .init(fadeIn: 0.125, fadeOut: 0.375))))
            let automated = local.document
            local.undo(); try check(content(local.document) == content(before), "command parity Undo")
            try local.setAudioClipVolume(local.prepareAudioClipVolume()!, volume: 0.2)
            try local.editSelectedAudioClip(clipID, expectedRevision: local.document.revision, edit: .mute(true))
            try local.setAudioFades(local.prepareAudioFades()!, fadeIn: 0.125, fadeOut: 0.375)
            try check(content(local.document) == content(automated) && local.projectAudioTracks.first?.audioData == imported.track.audioData,
                      "manual and command settings diverged")
            await local.flush()
        }
        try await test("audio command cancellation and playback reentry retain current document and history") {
            let (local, _, clipID) = try await audioCommandFixture("command-cancellation")
            let before = local.document, undo = local.canUndo, redo = local.canRedo
            let request = audioRequest(local, clipID, .init(volume: 0.3))
            for checkpoint in 1...5 {
                var calls = 0
                do {
                    try local.applyStudioCommands(request, checkCancellation: {
                        calls += 1; if calls == checkpoint { throw CancellationError() }
                    }); throw Failure(message: "cancelled actual VM audio command committed")
                } catch is CancellationError { }
                try check(local.document == before && local.canUndo == undo && local.canRedo == redo, "cancelled command changed history")
            }
            local.displayAudioPlaybackTime(0, playing: true)
            do { try local.applyStudioCommands(request); throw Failure(message: "playing audio command accepted") }
            catch StudioDocumentError.unavailable { }
            local.stopPlayback()
            var calls = 0
            do {
                try local.applyStudioCommands(request, checkCancellation: {
                    calls += 1; if calls == 5 { local.displayAudioPlaybackTime(0, playing: true) }
                }); throw Failure(message: "playback reentry accepted audio command")
            } catch StudioDocumentError.unavailable { }
            try check(local.isPlaying && local.document == before, "reentrant playback/document was overwritten")
            local.stopPlayback(); calls = 0
            do {
                try local.applyStudioCommands(request, checkCancellation: {
                    calls += 1
                    if calls == 5 { try local.setAudioClipVolume(local.prepareAudioClipVolume()!, volume: 0.6) }
                }); throw Failure(message: "stale audio command replaced intervening UI edit")
            } catch StudioCommandError.staleRevision { }
            try check(local.audioClips[0].volume == 0.6 && local.document.revision == before.revision + 1,
                      "intervening UI edit lost")
            local.undo(); try check(content(local.document) == content(before), "intervening edit Undo lost original")
            await local.flush()
        }
        try await test("audio wire rejects missing source bytes and source overrun before editor assignment") {
            let (local, _, clipID) = try await audioCommandFixture("command-asset-preflight")
            for missing in [true, false] {
                let clean = local.document
                var clip = clean.audioClips[0]
                if missing { clip.assetID = UUID() } else { clip.sourceOffset = 1.5 }
                // Deliberately malformed host state reaches the real command gateway;
                // the new command may not claim success or save it as valid audio.
                local.audioClips = [clip]
                let before = local.document, undo = local.canUndo, redo = local.canRedo
                do {
                    try local.applyStudioCommands(JSONEncoder().encode(audioRequest(local, clipID, .init(volume: 0.1))))
                    throw Failure(message: "missing/out-of-range source was accepted")
                } catch is StudioDocumentError { }
                try check(local.document == before && local.canUndo == undo && local.canRedo == redo,
                          "asset preflight changed document/history")
                local.undo(); try check(content(local.document) == content(clean), "invalid fixture could not restore original")
                try check(local.projectAudioTracks.first?.audioData == imported.track.audioData, "rejection lost original bytes")
            }
            await local.flush()
        }
        print("AUDIO_TIMELINE_TESTS_PASSED=\(passed)")
    }
}
