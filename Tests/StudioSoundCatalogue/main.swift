import Foundation
import AVFoundation

struct CatalogueFailure: Error { let message: String }
func require(_ test: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !test() { throw CatalogueFailure(message: message) }
}
@main @MainActor struct CatalogueTests {
    static func idle(_ session: StudioAudioPreviewSession) async throws {
        for _ in 0..<2000 {
            if !session.isBusy { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw CatalogueFailure(message: "session never completed")
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw CatalogueFailure(message: "actual catalogue resource directory required") }
        let fm = FileManager.default, bundle = URL(fileURLWithPath: CommandLine.arguments[1])
        let catalogue = try StudioSoundCatalogue(directory: bundle)
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-catalogue-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let scratch = root.appendingPathComponent("scratch")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        var count = 0
        func test(_ name: String, _ action: () async throws -> Void) async throws {
            try await action(); count += 1; print("PASS " + name)
        }
        try await test("all bundled bytes decode with exact Apple measured timing and waveforms") {
            try require(catalogue.sounds.count == 88 && catalogue.categories.count == 21, "unexpected starter bundle")
            for sound in catalogue.sounds {
                let resource = try catalogue.checkedResource(sound)
                let decoded = try await StudioAudioImportService.shared.importAudio(from: resource.url, name: sound.title, scratchParent: scratch)
                try require(decoded.originalData == resource.data && abs(decoded.duration - sound.duration) < 0.000001,
                            "actual bundle duration or bytes changed")
                try require(decoded.sampleRate == sound.sampleRate && decoded.channelCount == sound.channels, "actual format differs")
                try require(zip(decoded.waveformPeaks, sound.waveformPeaks).allSatisfy { abs($0 - $1) < 0.00001 }, "display waveform is not measured audio")
            }
            try require(try fm.contentsOfDirectory(atPath: scratch.path).isEmpty, "scratch retained")
        }
        try await test("local multi-term search and category filters return actual files") {
            let item = catalogue.sounds[0]
            try require(catalogue.search(item.title + " " + item.author, category: item.category).contains(item), "search missed metadata")
            try require(catalogue.search("zzzz-no-sound", category: nil).isEmpty, "invented search result")
            try require(catalogue.search("", category: item.category).allSatisfy { $0.category == item.category }, "category leaked")
        }
        let sound = catalogue.sounds.first(where: { $0.duration >= 0.5 })!
        let resource = try catalogue.checkedResource(sound)
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("documents"))
        let vm = StudioViewModel(storage: storage)
        let made = await vm.createProject(name: "Bundled sound journey", width: 64, height: 64, fps: 8)
        try require(made, "create project")
        let session = StudioAudioPreviewSession(scratchParent: scratch)
        defer { session.close() }
        try await test("bundled audition starts a real player and leaves the project unchanged") {
            let before = vm.document, track = try catalogue.previewTrack(sound)
            let clip = AudioClip(id: sound.id, soundName: sound.title, track: 1, startTime: 0, duration: sound.duration, assetID: track.id)
            try require(session.preview(clip, track: track, stillCurrent: { true }), "preview rejected")
            try await idle(session)
            try require(session.actualPlayerIsPlaying && session.playingClipID == sound.id, "no actual player")
            session.stop()
            try require(vm.document == before && !session.actualPlayerIsPlaying, "audition changed document or failed to stop")
        }
        try await test("adding a sound twice creates distinct editable clips and saves owned bytes offline") {
            for track in [1, 3] {
                let before = vm.document
                try require(session.importFile(resource.url, name: sound.title, expectedSHA256: sound.sha256,
                    stillCurrent: { vm.document == before }, attach: { asset in
                        try vm.attachImportedAudio(asset, expectedProjectID: before.id, expectedRevision: before.revision,
                                                   frameID: before.activeFrameID, trackNumber: track)
                    }), "add rejected")
                try await idle(session)
                try require(session.state == .ready, "actual import did not attach")
            }
            try require(vm.audioClips.count == 2 && Set(vm.audioClips.map(\.id)).count == 2 && Set(vm.audioClips.compactMap(\.assetID)).count == 2, "repeated add aliases identity")
            vm.undo(); try require(vm.audioClips.count == 1, "undo did not remove exactly one clip")
            vm.redo(); try require(vm.audioClips.count == 2, "redo lost second clip")
            let saved = await vm.save(); try require(saved, "save failed")
            let fresh = StudioViewModel(storage: storage); await fresh.loadProjects()
            let opened = await fresh.openProject(fresh.savedProjects.first(where: { $0.id == vm.document.id })!)
            try require(opened && fresh.audioClips == vm.audioClips, "cold reopen lost canonical clips")
            for clip in fresh.audioClips {
                try require(fresh.audioTrack(forAssetID: clip.assetID!)?.audioData == resource.data, "saved project depends on catalogue URL")
            }
        }
        try await test("integrity failure cannot call attachment or produce an imported receipt") {
            var calls = 0; let before = vm.document
            try require(session.importFile(resource.url, expectedSHA256: String(repeating: "0", count: 64),
                stillCurrent: { true }, attach: { _ in calls += 1; return "invalid" }), "integrity operation did not start")
            try await idle(session)
            try require(calls == 0 && session.lastImportedClipID == nil && session.notice != nil && vm.document == before, "corrupt asset attached")
        }
        try await test("malformed catalogues corrupt assets and symlinks fail without changing originals") {
            let copy = root.appendingPathComponent("invalid-library")
            try fm.createDirectory(at: copy, withIntermediateDirectories: false)
            let manifest = try Data(contentsOf: bundle.appendingPathComponent("catalogue.json"))
            let manifestURL = copy.appendingPathComponent("catalogue.json")
            try manifest.write(to: manifestURL)
            let file = copy.appendingPathComponent(sound.filename)
            var corrupted = resource.data; corrupted[corrupted.startIndex] ^= 1; try corrupted.write(to: file)
            let bad = try StudioSoundCatalogue(directory: copy)
            do { _ = try bad.checkedResource(sound); throw CatalogueFailure(message: "corrupt resource accepted") }
            catch is StudioSoundCatalogue.CatalogueError { }
            try fm.removeItem(at: file); try fm.createSymbolicLink(at: file, withDestinationURL: resource.url)
            do { _ = try bad.checkedResource(sound); throw CatalogueFailure(message: "symlink accepted") }
            catch is StudioSoundCatalogue.CatalogueError { }
            var object = try JSONSerialization.jsonObject(with: manifest) as! [String: Any]
            var entries = object["sounds"] as! [[String: Any]]; entries[0]["filename"] = "../foreign.wav"; object["sounds"] = entries
            try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
            do { _ = try StudioSoundCatalogue(directory: copy); throw CatalogueFailure(message: "escaping filename accepted") }
            catch is StudioSoundCatalogue.CatalogueError { }
            try require(try Data(contentsOf: resource.url) == resource.data, "original asset changed")
        }
        print("STUDIO_SOUND_CATALOGUE_TESTS=PASS \(count)/\(count) with \(catalogue.sounds.count) real bundled decodes")
    }
}
