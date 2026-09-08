import Foundation
import AVFoundation

private struct Failure: Error { let message: String }
private final class NetworkTrap: URLProtocol {
    private static let lock = NSLock()
    private static var attempts = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    override class func canInit(with request: URLRequest) -> Bool {
        guard ["http", "https"].contains(request.url?.scheme ?? "") else { return false }
        lock.lock(); attempts += 1; lock.unlock(); return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}

@main @MainActor struct StudioAudioIntegrationTests {
    static let fm = FileManager.default
    static func put<T: FixedWidthInteger>(_ value: T, in data: inout Data) {
        var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    // Explicit synthetic PCM fixture; actual production AVFoundation parses it.
    static func wave(frames: Int = 8192, sample: (Int) -> Int16 = { $0 < 4096 ? 0 : 16384 }) -> Data {
        var data = Data("RIFF".utf8); put(UInt32(36 + frames * 2), in: &data)
        data.append(Data("WAVEfmt ".utf8)); put(UInt32(16), in: &data)
        put(UInt16(1), in: &data); put(UInt16(1), in: &data)
        put(UInt32(8192), in: &data); put(UInt32(16384), in: &data)
        put(UInt16(2), in: &data); put(UInt16(16), in: &data)
        data.append(Data("data".utf8)); put(UInt32(frames * 2), in: &data)
        for i in 0..<frames { put(sample(i), in: &data) }
        return data
    }
    static func idle(_ session: StudioAudioPreviewSession) async throws {
        for _ in 0..<2000 {
            if !session.isBusy { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw Failure(message: "Audio session failed to reach a terminal state")
    }
    static func clean(_ scratch: URL) throws {
        try require(try fm.contentsOfDirectory(atPath: scratch.path) == ["sentinel"], "Audio operation leaked scratch or removed unrelated data")
    }
    static func requireAsync(_ value: Bool, _ message: String) throws { try require(value, message) }
    static func requireAsyncFalse(_ value: Bool, _ message: String) throws { try require(!value, message) }
    static func main() async {
        URLProtocol.registerClass(NetworkTrap.self)
        defer { URLProtocol.unregisterClass(NetworkTrap.self) }
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-audio-integration-\(UUID().uuidString)")
        var passed = 0
        func test(_ name: String, _ body: () async throws -> Void) async throws {
            try await body(); passed += 1; print("PASS \(name)")
        }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let scratch = root.appendingPathComponent("scratch"); try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
            try Data("unrelated".utf8).write(to: scratch.appendingPathComponent("sentinel"))
            let source = root.appendingPathComponent("Known signal.wav"), original = wave()
            try original.write(to: source)
            let session = StudioAudioPreviewSession(scratchParent: scratch)
            var attached: AudioTrack?
            try await test("real import callback receives measured bytes and fresh identity") {
                try require(session.importFile(source, stillCurrent: { true }, attach: { track in attached = track; return "selected-clip" }), "Import refused")
                try await idle(session)
                guard let track = attached, let measured = session.measurements[track.id] else { throw Failure(message: "Actual import failed") }
                try require(session.state == .ready && session.lastImportedClipID == "selected-clip", "Import claimed no actual receipt")
                try require(track.audioData == original && track.duration == 1 && measured.duration == 1, "Imported bytes or duration changed")
                try require(measured.peaks.prefix(128).allSatisfy { $0 == 0 } && measured.peaks.suffix(128).allSatisfy { $0 == 0.5 }, "Waveform was not measured from actual samples")
                try clean(scratch)
            }
            try await test("cancel before async completion never invokes attachment and allows retry") {
                var callbacks = 0
                try require(session.importFile(source, stillCurrent: { true }, attach: { _ in callbacks += 1; return "wrong" }), "Import refused")
                session.cancel(); try await idle(session)
                try require(callbacks == 0 && session.state == .cancelled, "Cancelled import edited a project")
                try clean(scratch)
                try require(session.importFile(source, stillCurrent: { true }, attach: { _ in callbacks += 1; return "retry" }), "Retry refused")
                try await idle(session)
                try require(callbacks == 1 && session.state == .ready, "Retry did not attach exactly once")
                try clean(scratch)
            }
            try await test("changed project and thrown attachment reject without success cache or receipt") {
                let fresh = StudioAudioPreviewSession(scratchParent: scratch)
                var current = true, callbacks = 0
                try require(fresh.importFile(source, stillCurrent: { current }, attach: { _ in callbacks += 1; return "wrong" }), "Import refused")
                current = false; try await idle(fresh)
                try require(callbacks == 0 && fresh.measurements.isEmpty && fresh.lastImportedClipID == nil && fresh.notice != nil, "Stale result was attached")
                try require(fresh.importFile(source, stillCurrent: { true }, attach: { _ in throw StudioDocumentError.invalid("Rejected transaction") }), "Import refused")
                try await idle(fresh)
                try require(fresh.notice == "Rejected transaction" && fresh.measurements.isEmpty && fresh.lastImportedClipID == nil, "Failed attachment claimed success")
                try clean(scratch)
            }
            try await test("saved bytes reanalysis preserves asset ID and rejects altered cache data") {
                let track = attached!, reopened = StudioAudioPreviewSession(scratchParent: scratch)
                try require(reopened.analyze(track, stillCurrent: { true }), "Saved bytes analysis refused")
                try await idle(reopened)
                try require(Set(reopened.measurements.keys) == [track.id], "Unexpected cache identity")
                try require(reopened.measurements[track.id]?.peaks == session.measurements[track.id]?.peaks, "Saved waveform changed")
                var changed = track; changed.audioData = wave(sample: { _ in 0 })
                try require(!reopened.play(clipID: "changed", track: changed, volume: 0), "Different bytes used stale measurement")
                try require(!reopened.actualPlayerIsPlaying && reopened.notice != nil, "Invalid playback reported success")
                reopened.close(); try require(reopened.measurements.isEmpty, "Close retained cache")
                try clean(scratch)
            }
            try await test("real AVAudioPlayer accepts measured saved data and real volume changes") {
                let track = attached!
                // Zero initial gain avoids emitting the fixture signal during this
                // automated check. This is a real player, not a silent file substitute.
                guard session.play(clipID: "preview", track: track, volume: 0) else { throw Failure(message: session.notice ?? "Player refused actual fixture") }
                try require(session.actualPlayerIsPlaying && session.playingClipID == "preview" && session.playbackDuration == 1, "Player did not start")
                session.setVolume(0.25, clipID: "other"); try require(session.actualPlayerVolume == 0, "Wrong clip changed active volume")
                session.setVolume(0.25, clipID: "preview"); try require(session.actualPlayerVolume == 0.25, "Actual player gain unchanged")
                session.setVolume(0, clipID: "preview")
                session.stop(); try require(!session.actualPlayerIsPlaying && session.playingClipID == nil && session.state == .stopped, "Stop left active player")
            }
            try await test("malformed audio close and bounded waveform cache keep ownership honest") {
                let fresh = StudioAudioPreviewSession(scratchParent: scratch)
                let malformed = root.appendingPathComponent("bad.wav"); try Data("not audio".utf8).write(to: malformed)
                var callbacks = 0
                try require(fresh.importFile(malformed, stillCurrent: { true }, attach: { _ in callbacks += 1; return "bad" }), "Malformed operation not accepted for validation")
                try await idle(fresh)
                try require(callbacks == 0 && fresh.notice != nil && fresh.lastImportedClipID == nil, "Malformed audio attached")
                for _ in 0..<34 {
                    try require(fresh.importFile(source, stillCurrent: { true }, attach: { _ in "cache" }), "Cache import refused")
                    try await idle(fresh)
                }
                try require(fresh.measurements.count == StudioAudioPreviewSession.maximumCachedMeasurements, "Waveform cache unbounded")
                try require(fresh.importFile(source, stillCurrent: { true }, attach: { _ in callbacks += 1; return "closed" }), "Close operation refused")
                fresh.close(); try await idle(fresh)
                try require(callbacks == 0 && fresh.measurements.isEmpty && fresh.lastImportedClipID == nil, "Dismissed panel accepted late import")
                try clean(scratch)
            }
            try await test("actual VM import is one undoable edit and same-snapshot bytes survive save reopen") {
                let docs = root.appendingPathComponent("documents"), storage = DeviceStorageManager(documentsDirectory: docs, cachesDirectory: docs)
                let vm = StudioViewModel(storage: storage)
                try requireAsync(await vm.createProject(name: "Imported audio", width: 64, height: 64, fps: 8), "Project creation failed")
                vm.addFrame(); vm.addFrame()
                let id = vm.document.id, revision = vm.document.revision, frame = vm.document.activeFrameID
                let importer = StudioAudioPreviewSession(scratchParent: scratch)
                try require(importer.importFile(source, stillCurrent: { vm.document.id == id && vm.document.revision == revision }, attach: {
                    try vm.attachImportedAudio($0, expectedProjectID: id, expectedRevision: revision, frameID: frame, trackNumber: 2)
                }), "Actual VM import refused")
                try await idle(importer)
                guard let clip = vm.audioClips.first, let assetID = clip.assetID else { throw Failure(message: "No canonical imported clip") }
                try require(clip.track == 2 && clip.startTime == 0.25 && clip.duration == 1 && vm.document.revision == revision + 1, "Wrong frame placement or multiple edits")
                try require(vm.managedAudioByteCount == original.count && vm.audioTrack(forAssetID: assetID)?.audioData == original, "Asset not owned with document")
                try requireAsync(await vm.save(), "Actual save failed")
                var saved = try storage.loadAnimation(id: id)!
                try require(saved.audioTracks.count == 1 && saved.audioTracks[0].id == assetID && saved.audioTracks[0].audioData == original, "Saved asset differs")
                try require(try StudioDocumentArchive.decode(saved.editableDocumentData!).document.audioClips == vm.audioClips, "Clip and bytes not same snapshot")
                vm.undo(); try require(vm.audioClips.isEmpty && vm.managedAudioByteCount == original.count, "Undo lost redo bytes or left clip")
                try requireAsync(await vm.save(), "Undo snapshot save failed")
                saved = try storage.loadAnimation(id: id)!
                try require(saved.audioTracks.isEmpty, "Undo saved unused new bytes")
                vm.redo(); try require(vm.audioClips.first?.assetID == assetID, "Redo lost stable asset identity")
                vm.selectedAudioClip = vm.audioClips.first; vm.setAudioClipVolume(clip.id, volume: 0.3)
                try require(vm.audioClips.first?.volume == 0.3, "Canonical volume unchanged")
                try requireAsync(await vm.save(), "Redo save failed")
                await vm.backToProjects()
                let reopened = StudioViewModel(storage: storage)
                try requireAsync(await reopened.openProject(saved.metadata), "Saved project failed reopen")
                guard let reopenedClip = reopened.audioClips.first, let reopenedTrack = reopened.audioTrack(forAssetID: assetID) else { throw Failure(message: "Reopened clip or bytes missing") }
                try require(reopenedClip.assetID == assetID && reopenedClip.startTime == 0.25 && reopenedClip.volume == 0.3 && reopenedTrack.audioData == original, "Reopen lost audio metadata")
                let preview = StudioAudioPreviewSession(scratchParent: scratch)
                var silent = reopenedClip; silent.volume = 0
                try require(preview.preview(silent, track: reopenedTrack, stillCurrent: { true }), "Reopened preview refused")
                try await idle(preview)
                try require(preview.actualPlayerIsPlaying && preview.measurements[assetID]?.duration == 1, "Saved actual bytes did not preview")
                preview.close(); await reopened.backToProjects(); try clean(scratch)
            }
            try await test("VM cancellation stale revision and duplicate asset never partially attach") {
                let docs = root.appendingPathComponent("atomic"), storage = DeviceStorageManager(documentsDirectory: docs, cachesDirectory: docs)
                let vm = StudioViewModel(storage: storage)
                try requireAsync(await vm.createProject(name: "Atomic", width: 64, height: 64, fps: 12), "Create failed")
                let imported = try await StudioAudioImportService.shared.importAudio(from: source, scratchParent: scratch)
                let before = vm.document
                for mode in 0..<3 {
                    var checks = 0
                    do {
                        _ = try vm.attachImportedAudio(imported.track, expectedProjectID: mode == 0 ? UUID() : before.id,
                            expectedRevision: mode == 1 ? before.revision + 1 : before.revision,
                            frameID: before.activeFrameID, trackNumber: 1, checkCancellation: {
                                checks += 1; if mode == 2 && checks == 2 { throw CancellationError() }
                            })
                        throw Failure(message: "Invalid lease/cancelled attachment succeeded")
                    } catch is StudioDocumentError { } catch is CancellationError { }
                    try require(vm.document == before && vm.managedAudioByteCount == 0 && vm.projectAudioTracks.isEmpty, "Rejected attachment mutated document/bytes")
                }
                _ = try vm.attachImportedAudio(imported.track, expectedProjectID: before.id, expectedRevision: before.revision, frameID: before.activeFrameID, trackNumber: 1)
                let once = vm.document
                do {
                    _ = try vm.attachImportedAudio(imported.track, expectedProjectID: once.id, expectedRevision: once.revision, frameID: once.activeFrameID, trackNumber: 1)
                    throw Failure(message: "Collision overwrote asset")
                } catch is StudioDocumentError { }
                try require(vm.document == once && vm.managedAudioByteCount == original.count, "Collision changed original")
                let pending = StudioAudioPreviewSession(scratchParent: scratch)
                let expected = vm.document
                try require(pending.importFile(source, stillCurrent: { vm.document.revision == expected.revision }, attach: {
                    try vm.attachImportedAudio($0, expectedProjectID: expected.id, expectedRevision: expected.revision, frameID: expected.activeFrameID, trackNumber: 1)
                }), "Pending import refused")
                vm.addFrame(); try await idle(pending)
                try require(vm.audioClips.count == 1 && pending.notice != nil, "Stale decode attached to revised document")
                try await Task.sleep(nanoseconds: 900_000_000)
                try require(!vm.isDirty && (try storage.loadAnimation(id: before.id))?.metadata.frameCount == 2, "Stale import cancelled prior legitimate autosave")
                await vm.backToProjects(); try clean(scratch)
            }
            try await test("legacy audio bytes remain unchanged and missing new references fail closed") {
                let docs = root.appendingPathComponent("legacy"), storage = DeviceStorageManager(documentsDirectory: docs, cachesDirectory: docs)
                let doc = try StudioDocument.new(name: "Legacy retained", width: 64, height: 64, fps: 12)
                let legacy = AudioTrack(id: UUID(), name: "Original opaque audio", format: "wav", audioData: Data([1, 2, 3, 4]), startTime: 0, duration: 0, legacySourceFilename: "audio_7.wav")
                let metadata = AnimationMetadata(id: doc.id, title: doc.name, fps: doc.fps, canvasWidth: doc.width, canvasHeight: doc.height,
                    frameCount: 1, layerCount: 1, createdAt: doc.createdAt, modifiedAt: doc.modifiedAt, thumbnailData: nil)
                try storage.saveAnimation(AnimationProject(id: doc.id, metadata: metadata,
                    frames: [StoredAnimationFrame(imageData: nil, layerData: nil)], audioTracks: [legacy],
                    editableDocumentData: try StudioDocumentArchive(document: doc, rasterFrameIndices: [:]).encoded()))
                let vm = StudioViewModel(storage: storage); try requireAsync(await vm.openProject(metadata), "Legacy open failed")
                let imported = try await StudioAudioImportService.shared.importAudio(from: source, scratchParent: scratch)
                _ = try vm.attachImportedAudio(imported.track, expectedProjectID: doc.id, expectedRevision: vm.document.revision, frameID: vm.document.activeFrameID, trackNumber: 1)
                try requireAsync(await vm.save(), "Import beside legacy failed")
                let saved = try storage.loadAnimation(id: doc.id)!
                try require(saved.audioTracks.first { $0.id == legacy.id }?.audioData == legacy.audioData && saved.audioTracks.first { $0.id == legacy.id }?.legacySourceFilename == "audio_7.wav", "Historical original lost")
                vm.audioClips.append(AudioClip(id: UUID().uuidString, soundName: "Missing", track: 1, startTime: 0, duration: 1, assetID: UUID()))
                try requireAsyncFalse(await vm.save(), "Missing asset became saved success")
                try require(vm.isDirty && vm.message?.contains("Save failed") == true, "Missing asset failure was hidden")
                try require((try storage.loadAnimation(id: doc.id))?.audioTracks.count == 2, "Failed save replaced good audio")
                vm.undo(); try requireAsync(await vm.save(), "Undo did not restore saveable document")
                await vm.backToProjects(); try clean(scratch)
            }
            try await test("actual editor history prunes orphan import bytes after branching and remains bounded") {
                let docs = root.appendingPathComponent("history"), storage = DeviceStorageManager(documentsDirectory: docs, cachesDirectory: docs)
                let vm = StudioViewModel(storage: storage)
                try requireAsync(await vm.createProject(name: "History", width: 64, height: 64, fps: 12), "Create failed")
                let first = try await StudioAudioImportService.shared.importAudio(from: source, scratchParent: scratch)
                _ = try vm.attachImportedAudio(first.track, expectedProjectID: vm.document.id, expectedRevision: vm.document.revision, frameID: vm.document.activeFrameID, trackNumber: 1)
                vm.undo(); try require(vm.managedAudioByteCount == original.count && vm.canRedo, "Undo discarded needed bytes")
                vm.addFrame(); try require(vm.managedAudioByteCount == 0 && !vm.canRedo && vm.audioTrack(forAssetID: first.id) == nil, "Abandoned redo retained orphan bytes")
                let old = Data(#"{"id":"old","soundName":"Legacy","track":0,"startTime":0,"duration":0,"volume":0.8}"#.utf8)
                try require(try JSONDecoder().decode(AudioClip.self, from: old).assetID == nil, "Old clip decoding invented an asset")
                try require(SoundEffect(name: "Unavailable", duration: "4s", tag: "legacy").waveform.isEmpty, "Catalog created a fake waveform")
                await vm.backToProjects()
            }
            try await test("production storage capacity failure preserves last good snapshot and undo restores saveability") {
                let docs = root.appendingPathComponent("capacity"), storage = DeviceStorageManager(documentsDirectory: docs, cachesDirectory: docs)
                let doc = try StudioDocument.new(name: "Capacity", width: 64, height: 64, fps: 12)
                let legacy = AudioTrack(id: UUID(), name: "Original opaque capacity fixture", format: "wav", audioData: Data(repeating: 17, count: 20 * 1024 * 1024), startTime: 0, duration: 0, legacySourceFilename: "audio_1.wav")
                let metadata = AnimationMetadata(id: doc.id, title: doc.name, fps: doc.fps, canvasWidth: doc.width, canvasHeight: doc.height,
                    frameCount: 1, layerCount: 1, createdAt: doc.createdAt, modifiedAt: doc.modifiedAt, thumbnailData: nil)
                try storage.saveAnimation(.init(id: doc.id, metadata: metadata, frames: [.init(imageData: nil, layerData: nil)], audioTracks: [legacy],
                    editableDocumentData: try StudioDocumentArchive(document: doc, rasterFrameIndices: [:]).encoded()))
                // Real PCM silence fixture at 44.1 kHz, about 143 seconds, 12 MB.
                let count = 12 * 1024 * 1024
                var big = wave(frames: 0)
                var size = Data(); put(UInt32(36 + count), in: &size); big.replaceSubrange(4..<8, with: size)
                size.removeAll(); put(UInt32(count), in: &size); big.replaceSubrange(40..<44, with: size)
                size.removeAll(); put(UInt32(44100), in: &size); big.replaceSubrange(24..<28, with: size)
                size.removeAll(); put(UInt32(88200), in: &size); big.replaceSubrange(28..<32, with: size)
                big.append(Data(repeating: 0, count: count))
                let url = root.appendingPathComponent("capacity.wav"); try big.write(to: url)
                let first = try await StudioAudioImportService.shared.importAudio(from: url, scratchParent: scratch)
                let second = try await StudioAudioImportService.shared.importAudio(from: url, scratchParent: scratch)
                let third = try await StudioAudioImportService.shared.importAudio(from: url, scratchParent: scratch)
                let vm = StudioViewModel(storage: storage); try requireAsync(await vm.openProject(metadata), "Capacity open failed")
                _ = try vm.attachImportedAudio(first.track, expectedProjectID: doc.id, expectedRevision: vm.document.revision, frameID: vm.document.activeFrameID, trackNumber: 1)
                try requireAsync(await vm.save(), "Last-good capacity save failed")
                _ = try vm.attachImportedAudio(second.track, expectedProjectID: doc.id, expectedRevision: vm.document.revision, frameID: vm.document.activeFrameID, trackNumber: 2)
                try requireAsyncFalse(await vm.save(), "Over-capacity production storage claimed success")
                try require(vm.isDirty && vm.audioClips.count == 2, "Failed save discarded in-memory edits")
                let lastGood = try storage.loadAnimation(id: doc.id)!
                try require(lastGood.audioTracks.count == 2 && lastGood.audioTracks.first { $0.id == legacy.id }?.audioData == legacy.audioData, "Failed save damaged last good or original bytes")
                let before = vm.document, bytes = vm.managedAudioByteCount
                do {
                    _ = try vm.attachImportedAudio(third.track, expectedProjectID: doc.id, expectedRevision: before.revision, frameID: before.activeFrameID, trackNumber: 3)
                    throw Failure(message: "Managed audio exceeded 32 MB")
                } catch is StudioDocumentError { }
                try require(vm.document == before && vm.managedAudioByteCount == bytes, "Memory-bound rejection partially attached")
                vm.undo(); try requireAsync(await vm.save(), "Undo could not restore saveable audio state")
                try require(!vm.isDirty && vm.audioClips.count == 1, "Undo did not preserve remaining imported clip")
                await vm.backToProjects(); try clean(scratch)
            }
            try await test("only explicit current clip selection can delete or change volume") {
                let docs = root.appendingPathComponent("selection"), storage = DeviceStorageManager(documentsDirectory: docs, cachesDirectory: docs)
                let vm = StudioViewModel(storage: storage); try requireAsync(await vm.createProject(name: "Selection", width: 64, height: 64, fps: 12), "Create failed")
                let imported = try await StudioAudioImportService.shared.importAudio(from: source, scratchParent: scratch)
                let id = try vm.attachImportedAudio(imported.track, expectedProjectID: vm.document.id, expectedRevision: vm.document.revision, frameID: vm.document.activeFrameID, trackNumber: 1)
                vm.selectedAudioClip = nil; let before = vm.document
                vm.deleteAudioClip(id); vm.setAudioClipVolume(id, volume: 0.1)
                try require(vm.document == before, "Unselected controls edited audio")
                vm.selectedAudioClip = vm.audioClips.first
                vm.setAudioClipVolume(id, volume: .nan); try require(vm.document == before, "Nonfinite volume mutated project")
                vm.deleteAudioClip(id); try require(vm.audioClips.isEmpty, "Explicit selected deletion failed")
                vm.undo(); try require(vm.audioClips.first?.assetID == imported.id && vm.audioTrack(forAssetID: imported.id)?.audioData == original, "Delete undo lost actual bytes")
                await vm.backToProjects()
            }
            try await test("cancellation during actual measured decoding leaves no late attachment or scratch") {
                let active = StudioAudioPreviewSession(scratchParent: scratch)
                let large = root.appendingPathComponent("capacity.wav")
                var callbacks = 0
                try require(active.importFile(large, stillCurrent: { true }, attach: { _ in callbacks += 1; return "unexpected" }), "Large import refused")
                for _ in 0..<2000 {
                    if active.progress >= 0.35 { break }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                try require(active.isBusy && active.progress >= 0.35 && active.progress < 1, "Did not observe actual in-progress decoder")
                active.cancel(); try await idle(active)
                try require(callbacks == 0 && active.state == .cancelled && active.measurements.isEmpty, "Cancelled decoder published result")
                try clean(scratch)
                active.pickerFailed(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                try require(active.state == .cancelled, "Files cancel became a new failure")
                active.pickerFailed(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError))
                try require(active.notice?.contains("Files could not provide") == true, "Permission failure was hidden")
            }
            try await test("audio operations issue no real HTTP requests") {
                try require(NetworkTrap.count == 0, "Audio integration unexpectedly requested cloud/network data")
            }
            try require(try Data(contentsOf: source) == original, "Source original changed")
            try fm.removeItem(at: root)
            print("\(passed) Studio audio integration tests passed")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
