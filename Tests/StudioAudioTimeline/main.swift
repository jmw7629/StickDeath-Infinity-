import Foundation
import AVFoundation

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}
@main @MainActor struct AudioTimelineTests {
    static func main() async throws {
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
        try await test("track mute changes canonical clips in one transaction without erasing gain") {
            let revision = vm.document.revision
            try vm.setAudioTrackMuted(3, muted: false, expectedRevision: revision)
            try check(vm.document.revision == revision + 1 && !vm.audioClips[0].isMuted && vm.audioClips[0].volume == 0.5, "track unmute")
            vm.undo(); try check(vm.audioClips[0].isMuted, "track undo")
            vm.redo(); try check(!vm.audioClips[0].isMuted, "track redo")
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
        print("AUDIO_TIMELINE_TESTS_PASSED=\(passed)")
    }
}
