import Foundation

// Compile the complete production DeviceStorageManager and Models sources.
// Fixtures only: no alternative persistence implementation or real Documents.
private struct TestFailure: Error { let message: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(message: message) }
}
private func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw TestFailure(message: "Expected a failure, but the operation succeeded")
}
private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    return try encoder.encode(value)
}

private final class CommitFailureStore: DeviceStorageManager {
    var failCommit = false
    override func commitCurrentRevision(_ data: Data, to pointer: URL) throws {
        if failCommit { throw CocoaError(.fileWriteOutOfSpace) }
        try super.commitCurrentRevision(data, to: pointer)
    }
}

@main struct DeviceStorageTests {
    static let red = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEUlEQVR4nGP8z4AATEhsPBwAM9EBBzDn4UwAAAAASUVORK5CYII=")!
    static let blue = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAE0lEQVR4nGNkYPjPAANMcBZeDgAx0wEH1s7nlgAAAABJRU5ErkJggg==")!
    // Generated 10 ms WAV tone; not a historical/licensed asset or fake export.
    static let tone = Data(base64Encoded: "UklGRsQAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YaAAAAAAAJYK6xPmGrIe3h5iG6oUgQv7AFj22eyd5YHh/+Ao5Jzql/MK/rgIXhLZGUUeHB9HHBkWTg3xAjr4b+645v7h0OBS4zjp0PEV/NEGvxCxGLgdPB8OHXEXDg/jBCX6GPDs55niwOCZ4uznGPAl+uMEDg9xFw4dPB+4HbEYvxDRBhX80PE46VLj0OD+4bjmb+46+PECTg0ZFkccHB9FHtkZ")!

    static func project(id: UUID = UUID(), frames: [Data?] = [red]) -> AnimationProject {
        AnimationProject(id: id, metadata: AnimationMetadata(id: id, title: "Fixture", fps: 12, canvasWidth: 4, canvasHeight: 4, frameCount: frames.count, layerCount: 1, createdAt: Date(timeIntervalSince1970: 100), modifiedAt: Date(timeIntervalSince1970: 200), thumbnailData: blue), frames: frames.map { StoredAnimationFrame(imageData: $0) }, audioTracks: [])
    }

    static func fixture() throws -> (DeviceStorageManager, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-production-storage-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (DeviceStorageManager(documentsDirectory: root, cachesDirectory: root.appendingPathComponent("Caches")), root)
    }

    @discardableResult static func legacy(_ store: DeviceStorageManager, _ project: AnimationProject, files: [String: Data]) throws -> URL {
        let directory = store.animationsDir.appendingPathComponent(project.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoded(project.metadata).write(to: directory.appendingPathComponent("metadata.json"))
        for (name, data) in files { try data.write(to: directory.appendingPathComponent(name)) }
        return directory
    }

    static func main() throws {
        var passed = 0
        var failed = 0
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        test("complete production snapshot preserves layers audio IDs metadata and opaque editable bytes") {
            let (store, root) = try fixture()
            var p = project(frames: [red, nil, blue])
            p.frames[0].layerData = [LayerData(id: UUID(), name: "Hidden", opacity: 0.4, blendMode: "multiply", locked: true, visible: false)]
            p.frames[1].layerData = []
            p.frames[2].legacyFrameIndex = 7
            p.audioTracks = [AudioTrack(id: UUID(), name: "Tone", format: "wav", audioData: tone, startTime: 0.25, duration: 0.01)]
            p.editableDocumentData = Data("{\"schemaVersion\":1,\"untouched\":true}".utf8)
            try store.saveAnimation(p)
            let fresh = DeviceStorageManager(documentsDirectory: root)
            try require(try encoded(fresh.loadAnimation(id: p.id)!) == encoded(p), "Full production document changed")
            try require(fresh.listAnimations().map(\.id) == [p.id], "List did not use committed metadata")
        }
        test("same ID saves preserve every original legacy byte and unknown file") {
            let (store, _) = try fixture(); let p = project()
            let original = ["frame_0.png": red, "audio_0.wav": tone, "keep.txt": Data("Uninterpreted original".utf8)]
            let dir = try legacy(store, p, files: original)
            let metadata = try Data(contentsOf: dir.appendingPathComponent("metadata.json"))
            try store.saveAnimation(project(id: p.id, frames: [blue]))
            for (name, bytes) in original { try require(try Data(contentsOf: dir.appendingPathComponent(name)) == bytes, "Legacy asset overwritten") }
            try require(try Data(contentsOf: dir.appendingPathComponent("metadata.json")) == metadata, "Legacy metadata overwritten")
            try require(try store.loadAnimation(id: p.id)!.frames[0].imageData == blue, "New revision was not selected")
        }
        test("legacy numeric enumeration continues beyond gaps and preserves original indices") {
            let (store, _) = try fixture(); var p = project(); p.metadata.frameCount = 11
            try legacy(store, p, files: ["frame_10.png": blue, "frame_2.png": red, "frame_0.png": blue])
            let loaded = try store.loadAnimation(id: p.id)!
            try require(loaded.frames.map(\.legacyFrameIndex) == [0, 2, 10], "Numeric order or gap lost")
            try require(loaded.frames.map(\.imageData) == [blue, red, blue], "Existing PNG bytes lost")
            try require(loaded.metadata.frameCount == 11, "Historical timing metadata rewritten")
        }
        test("new exact frame count never resurrects stale legacy files") {
            let (store, _) = try fixture(); let p = project(frames: [red, blue, red])
            let dir = try legacy(store, p, files: ["frame_0.png": red, "frame_1.png": blue, "frame_2.png": red])
            try store.saveAnimation(project(id: p.id, frames: [blue]))
            try require(try store.loadAnimation(id: p.id)!.frames.count == 1, "Stale frames resurrected")
            try require(try Data(contentsOf: dir.appendingPathComponent("frame_2.png")) == red, "Original stale asset deleted")
            try store.saveAnimation(project(id: p.id, frames: [red, blue]))
            try require(try store.loadAnimation(id: p.id)!.frames.count == 2, "Revision frame count ignored")
        }
        test("new metadata identity mismatch fails before any project write") {
            let (store, _) = try fixture(); let p = project()
            let bad = AnimationProject(id: UUID(), metadata: p.metadata, frames: p.frames, audioTracks: [])
            try rejects { try store.saveAnimation(bad) }
            try require(!FileManager.default.fileExists(atPath: store.animationsDir.path), "Invalid save created files")
        }
        test("legacy metadata identity mismatch surfaces through reporting list") {
            let (store, _) = try fixture(); let p = project()
            let bad = AnimationProject(id: UUID(), metadata: p.metadata, frames: p.frames, audioTracks: [])
            let dir = try legacy(store, bad, files: ["frame_0.png": red])
            try rejects { _ = try store.loadAnimation(id: bad.id) }
            try rejects { try store.saveAnimation(project(id: bad.id)) }
            let listing = try store.listAnimationsReportingFailures()
            try require(listing.animations.isEmpty && listing.failures.map(\.id) == [bad.id], "Mismatch silently listed as available")
            try require(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".sdi").path), "Collision adopted")
        }
        test("duplicate normalized legacy frame numbers fail without mutation") {
            let (store, _) = try fixture(); let p = project()
            let dir = try legacy(store, p, files: ["frame_1.png": red, "frame_01.png": blue])
            try rejects { _ = try store.loadAnimation(id: p.id) }
            try rejects { try store.saveAnimation(p) }
            try require(try Data(contentsOf: dir.appendingPathComponent("frame_01.png")) == blue, "Collision asset changed")
        }
        test("duplicate normalized audio numbers fail instead of picking a format") {
            let (store, _) = try fixture(); let p = project()
            try legacy(store, p, files: ["frame_0.png": red, "audio_0.wav": tone, "audio_00.mp3": tone])
            try rejects { _ = try store.loadAnimation(id: p.id) }
        }
        test("legacy audio bytes and stable derived IDs survive revision save") {
            let (store, _) = try fixture(); let p = project()
            try legacy(store, p, files: ["frame_0.png": red, "audio_3.wav": tone])
            let first = try store.loadAnimation(id: p.id)!, second = try store.loadAnimation(id: p.id)!
            try require(first.audioTracks.count == 1 && first.audioTracks[0].audioData == tone, "Legacy audio lost")
            try require(first.audioTracks[0].id == second.audioTracks[0].id && first.audioTracks[0].legacySourceFilename == "audio_3.wav", "Legacy provenance unstable")
            try store.saveAnimation(first)
            try require(try encoded(store.loadAnimation(id: p.id)!) == encoded(first), "Legacy container changed in snapshot")
        }
        test("commit failure preserves current pointer and previous revision and permits retry") {
            let (_, root) = try fixture(); let store = CommitFailureStore(documentsDirectory: root); let p = project()
            try store.saveAnimation(p)
            let pointer = store.animationsDir.appendingPathComponent(p.id.uuidString + "/.sdi/current.json")
            let before = try Data(contentsOf: pointer)
            store.failCommit = true
            try rejects { try store.saveAnimation(project(id: p.id, frames: [blue])) }
            try require(try Data(contentsOf: pointer) == before, "Failed commit changed current pointer")
            try require(try store.loadAnimation(id: p.id)!.frames[0].imageData == red, "Uncommitted revision selected")
            store.failCommit = false
            try store.saveAnimation(project(id: p.id, frames: [blue]))
            try require(try store.loadAnimation(id: p.id)!.frames[0].imageData == blue, "Retry did not commit")
        }
        test("interrupted first save can retry without deleting staged evidence") {
            let (_, root) = try fixture(); let store = CommitFailureStore(documentsDirectory: root); let p = project()
            store.failCommit = true; try rejects { try store.saveAnimation(p) }
            store.failCommit = false; try store.saveAnimation(p)
            try require(try store.loadAnimation(id: p.id)!.frames[0].imageData == red, "First-save retry failed")
            let revisions = store.animationsDir.appendingPathComponent(p.id.uuidString + "/.sdi/revisions")
            try require(try FileManager.default.contentsOfDirectory(atPath: revisions.path).count == 2, "Unselected revision evidence discarded")
        }
        test("concurrent store instances only read complete committed snapshots") {
            let (store, root) = try fixture(); let initial = project(); try store.saveAnimation(initial)
            let candidates = (0..<24).map { index -> AnimationProject in
                var candidate = project(id: initial.id, frames: index.isMultiple(of: 2) ? [red] : [blue, nil])
                candidate.metadata.title = "Concurrent snapshot \(index)"
                candidate.editableDocumentData = Data("editable \(index)".utf8)
                return candidate
            }
            let accepted = Set(try ([initial] + candidates).map { try encoded($0) })
            let resultLock = NSLock(); var failures: [String] = []
            DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
                do {
                    let instance = DeviceStorageManager(documentsDirectory: root)
                    try instance.saveAnimation(candidates[index])
                    guard let loaded = try instance.loadAnimation(id: initial.id), accepted.contains(try encoded(loaded)) else {
                        throw TestFailure(message: "Read a partial or combined snapshot")
                    }
                } catch {
                    resultLock.lock(); failures.append(String(describing: error)); resultLock.unlock()
                }
            }
            try require(failures.isEmpty, "Concurrent operation failed: \(failures)")
            let revisions = store.animationsDir.appendingPathComponent(initial.id.uuidString + "/.sdi/revisions")
            try require(try FileManager.default.contentsOfDirectory(atPath: revisions.path).count == candidates.count + 1, "A committed immutable revision was lost")
            try require(try accepted.contains(encoded(store.loadAnimation(id: initial.id)!)), "Final current pointer was invalid")
        }
        test("corrupt current pointer surfaces failure without falling back to stale legacy") {
            let (store, _) = try fixture(); let p = project()
            let dir = try legacy(store, p, files: ["frame_0.png": red]); try store.saveAnimation(project(id: p.id, frames: [blue]))
            try Data("broken pointer".utf8).write(to: dir.appendingPathComponent(".sdi/current.json"))
            try rejects { _ = try store.loadAnimation(id: p.id) }
            try require(try store.listAnimationsReportingFailures().failures.count == 1, "Corruption concealed")
            try require(try Data(contentsOf: dir.appendingPathComponent("frame_0.png")) == red, "Legacy changed during failed read")
        }
        test("missing current selector after migration surfaces recovery instead of stale legacy") {
            let (store, root) = try fixture(); let p = project()
            let dir = try legacy(store, p, files: ["frame_0.png": red])
            try store.saveAnimation(project(id: p.id, frames: [blue]))
            let pointer = dir.appendingPathComponent(".sdi/current.json")
            try FileManager.default.moveItem(at: pointer, to: root.appendingPathComponent("preserved-pointer"))
            try rejects { _ = try store.loadAnimation(id: p.id) }
            let listing = try store.listAnimationsReportingFailures()
            try require(listing.animations.isEmpty && listing.failures.map(\.id) == [p.id], "Missing selector was concealed by stale legacy metadata")
            try require(try Data(contentsOf: dir.appendingPathComponent("frame_0.png")) == red, "Legacy recovery evidence changed")
            try require(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(".sdi/revisions").path).count == 1, "Committed revision evidence changed")
        }
        test("failed initial legacy migration can retry complete in-memory snapshot") {
            let (_, root) = try fixture(); let store = CommitFailureStore(documentsDirectory: root); let p = project()
            let dir = try legacy(store, p, files: ["frame_0.png": red, "audio_0.wav": tone])
            let updated = project(id: p.id, frames: [blue])
            store.failCommit = true; try rejects { try store.saveAnimation(updated) }
            try rejects { _ = try store.loadAnimation(id: p.id) }
            store.failCommit = false; try store.saveAnimation(updated)
            try require(try store.loadAnimation(id: p.id)!.frames[0].imageData == blue, "Legacy migration retry failed")
            try require(try Data(contentsOf: dir.appendingPathComponent("frame_0.png")) == red && Data(contentsOf: dir.appendingPathComponent("audio_0.wav")) == tone, "Legacy migration changed originals")
            try require(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(".sdi/revisions").path).count == 2, "Legacy migration discarded failed revision")
        }
        test("unknown reserved storage namespace is not adopted") {
            let (store, _) = try fixture(); let p = project(); let dir = try legacy(store, p, files: ["frame_0.png": red])
            let reserved = dir.appendingPathComponent(".sdi"); try FileManager.default.createDirectory(at: reserved, withIntermediateDirectories: true)
            try Data("someone else's data".utf8).write(to: reserved.appendingPathComponent("format"))
            try rejects { try store.saveAnimation(p) }
            try require(try Data(contentsOf: reserved.appendingPathComponent("format")) == Data("someone else's data".utf8), "Unknown namespace overwritten")
        }
        test("project symlink and dangling symlink cannot escape configured root") {
            let (store, root) = try fixture(); let p = project(); let outside = root.appendingPathComponent("Outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: store.animationsDir, withIntermediateDirectories: true)
            let link = store.animationsDir.appendingPathComponent(p.id.uuidString)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            try rejects { try store.saveAnimation(p) }; try rejects { _ = try store.loadAnimation(id: p.id) }
            try require(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "Wrote outside root")
            let dangling = project(); try FileManager.default.createSymbolicLink(at: store.animationsDir.appendingPathComponent(dangling.id.uuidString), withDestinationURL: root.appendingPathComponent("Missing"))
            try rejects { try store.saveAnimation(dangling) }
        }
        test("legacy frame symlink is rejected without reading or replacing target") {
            let (store, root) = try fixture(); let p = project(); let dir = try legacy(store, p, files: [:])
            let outside = root.appendingPathComponent("outside.png"); try blue.write(to: outside)
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("frame_0.png"), withDestinationURL: outside)
            try rejects { _ = try store.loadAnimation(id: p.id) }; try rejects { try store.saveAnimation(p) }
            try require(try Data(contentsOf: outside) == blue, "Symlink target modified")
        }
        test("root symlink and revision-directory symlink are rejected") {
            let (store, root) = try fixture(); let p = project(); let outside = root.appendingPathComponent("Outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: store.animationsDir, withDestinationURL: outside)
            try rejects { try store.saveAnimation(p) }; try rejects { _ = try store.listAnimationsReportingFailures() }
            let (second, secondRoot) = try fixture(); try second.saveAnimation(p)
            let revisions = second.animationsDir.appendingPathComponent(p.id.uuidString + "/.sdi/revisions")
            try FileManager.default.moveItem(at: revisions, to: secondRoot.appendingPathComponent("preserved-revisions"))
            try FileManager.default.createSymbolicLink(at: revisions, withDestinationURL: outside)
            try rejects { _ = try second.loadAnimation(id: p.id) }; try rejects { try second.saveAnimation(p) }
        }
        test("unsafe pointer symlink never reads an outside revision selector") {
            let (store, root) = try fixture(); let p = project(); try store.saveAnimation(p)
            let pointer = store.animationsDir.appendingPathComponent(p.id.uuidString + "/.sdi/current.json")
            let outside = root.appendingPathComponent("preserved-pointer"); try FileManager.default.moveItem(at: pointer, to: outside)
            try FileManager.default.createSymbolicLink(at: pointer, withDestinationURL: outside)
            try rejects { _ = try store.loadAnimation(id: p.id) }; try rejects { try store.saveAnimation(p) }
        }
        test("invalid document count timing and duplicate stable IDs are rejected") {
            let (store, _) = try fixture(); var p = project(); p.metadata.frameCount = 2
            try rejects { try store.saveAnimation(p) }; p.metadata.frameCount = 1; p.metadata.fps = 0
            try rejects { try store.saveAnimation(p) }; p.metadata.fps = 12
            let layer = LayerData(id: UUID(), name: "Duplicate", opacity: 1, blendMode: "normal", locked: false, visible: true)
            p.frames[0].layerData = [layer, layer]; try rejects { try store.saveAnimation(p) }; p.frames[0].layerData = nil
            let track = AudioTrack(id: UUID(), name: "Duplicate", format: "wav", audioData: tone, startTime: 0, duration: 1)
            p.audioTracks = [track, track]; try rejects { try store.saveAnimation(p) }
        }
        test("opaque data size limit fails before writing project state") {
            let (store, _) = try fixture(); var p = project(); p.editableDocumentData = Data(repeating: 0, count: 32 * 1024 * 1024 + 1)
            try rejects { try store.saveAnimation(p) }
            try require(!FileManager.default.fileExists(atPath: store.animationsDir.path), "Oversized snapshot wrote files")
        }
        test("malformed and overflowing legacy names are surfaced") {
            for name in ["frame_bad.png", "frame_99999999999999999999999999999.png", "audio_bad.wav"] {
                let (store, _) = try fixture(); let p = project(); try legacy(store, p, files: [name: red])
                try rejects { _ = try store.loadAnimation(id: p.id) }
            }
        }
        test("media filenames cannot traverse directories or overwrite existing media") {
            let (store, _) = try fixture()
            for name in ["../escape.wav", "a/b.wav", "a\\b.wav", ".", ".."] { try rejects { _ = try store.saveMedia(data: tone, type: .audio, filename: name) } }
            let saved = try store.saveMedia(data: tone, type: .audio, filename: "tone.wav")
            try rejects { _ = try store.saveMedia(data: red, type: .audio, filename: "tone.wav") }
            try require(try Data(contentsOf: saved) == tone, "Existing media overwritten")
        }
        print("DEVICE_STORAGE_TESTS=\(failed == 0 ? "PASS" : "FAIL") \(passed)/\(passed + failed)")
        if failed > 0 { exit(1) }
    }
}
