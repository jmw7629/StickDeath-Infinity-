import Foundation
import AVFoundation
import CryptoKit

/// Every request is intercepted, including unexpected hosts. These real-byte
/// fixtures exercise the production URLSession streaming installer offline.
final class SoundPackTransport: URLProtocol {
    enum Reply { case bytes(Data), redirect(URL), hold }
    private static let lock = NSLock()
    private static var routes: [String: Reply] = [:]
    private static var recorded: [String] = []
    private static var sensitive: [String] = []
    static func configure(_ value: [String: Reply]) {
        lock.lock(); routes = value; recorded = []; sensitive = []; lock.unlock()
    }
    static var requests: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    static var sensitiveHeaders: [String] { lock.lock(); defer { lock.unlock() }; return sensitive }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let reply = Self.routes[request.url!.absoluteString]
        Self.recorded.append(request.url!.absoluteString)
        for name in ["Authorization", "Cookie", "Proxy-Authorization"] where request.value(forHTTPHeaderField: name) != nil { Self.sensitive.append(name) }
        Self.lock.unlock()
        switch reply {
        case .bytes(let bytes):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/octet-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for offset in stride(from: 0, to: bytes.count, by: 8192) {
                client?.urlProtocol(self, didLoad: bytes.subdata(in: offset..<min(offset + 8192, bytes.count)))
            }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let destination):
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": destination.absoluteString])!
            var next = URLRequest(url: destination)
            // An untrusted redirect must never carry these to its next hop.
            next.setValue("fixture-secret", forHTTPHeaderField: "Authorization")
            next.setValue("fixture-cookie", forHTTPHeaderField: "Cookie")
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        case .hold: break
        case nil: client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }
    override func stopLoading() { }
}

private struct SoundPackFixture {
    let descriptor: StudioSoundPackCache.Descriptor
    let manifest: Data
    let sounds: [StudioSoundCatalogue.Sound]
    let routes: [String: SoundPackTransport.Reply]
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    init(id: String, sounds: [StudioSoundCatalogue.Sound], resources: [String: Data]) throws {
        self.sounds = sounds
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let entries = try JSONSerialization.jsonObject(with: encoder.encode(sounds))
        manifest = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "sounds": entries], options: [.sortedKeys])
        let base = "https://raw.githubusercontent.com/jmw7629/StickDeath-Infinity-/main/assets/sound-packs/" + id + "/"
        descriptor = .init(id: id, title: "Real-byte transport fixture", manifestURL: base + "catalogue.json", manifestBytes: manifest.count,
                           manifestSHA256: Self.digest(manifest), baseURL: base, soundCount: sounds.count,
                           totalAudioBytes: sounds.reduce(0) { $0 + $1.byteCount })
        var mapped: [String: SoundPackTransport.Reply] = [base + "catalogue.json": .bytes(manifest)]
        for sound in sounds { mapped[base + sound.filename] = .bytes(resources[sound.id]!) }
        routes = mapped
    }
}

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
        guard (2...3).contains(CommandLine.arguments.count) else { throw CatalogueFailure(message: "actual catalogue resource directory, optional actual pack asset root required") }
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
        try await test("asynchronous production catalogue load preserves contents and cancellation") {
            let loaded = try await StudioSoundCatalogue.load(directory: bundle)
            try require(loaded.sounds == catalogue.sounds && loaded.categories == catalogue.categories,
                        "background loading changed the actual catalogue")
            let cancelled = Task { @MainActor in
                try await StudioSoundCatalogue.load(directory: root.appendingPathComponent("absent-library"))
            }
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                throw CatalogueFailure(message: "cancelled library load returned a result")
            } catch is CancellationError {
                // Cancellation takes precedence over accessing a missing file.
            }
        }
        try await test("all bundled bytes decode with exact Apple measured timing and waveforms") {
            try require(catalogue.sounds.count == 2212 && catalogue.categories.count == 22, "unexpected expanded bundle")
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
        try await test("curated tags search actual families with title and category intersections") {
            try require(catalogue.sounds.allSatisfy { !($0.tags ?? []).isEmpty }, "bundled asset missing tags")
            let impacts = catalogue.search("COLLISION", category: nil)
            try require(impacts.count == 128 && impacts.allSatisfy { $0.category == "Impacts & Crashes" }, "tag search missed real impact family")
            let mining = catalogue.search("collision mining 003", category: "Impacts & Crashes")
            try require(mining.count == 1 && mining.first?.title == "Impact Mining 003", "tag/title intersection incorrect")
            try require(catalogue.search("collision", category: "Space").isEmpty, "tag bypassed category")
            try require(catalogue.search("game-ui", category: nil).count == 151, "shared tag failed across categories")
            try require(catalogue.search("game-ui", category: "Buttons & UI").count == 51, "tag/category filter incorrect")
        }
        try await test("tag metadata remains bounded and old tagless catalogues stay readable") {
            let directory = root.appendingPathComponent("tag-validation")
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            let original = try Data(contentsOf: bundle.appendingPathComponent("catalogue.json"))
            let object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            let first = (object["sounds"] as! [[String: Any]])[0]
            func write(_ tags: [String]?) throws {
                var item = first
                if let tags { item["tags"] = tags } else { item.removeValue(forKey: "tags") }
                try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "sounds": [item]])
                    .write(to: directory.appendingPathComponent("catalogue.json"))
            }
            try write(nil)
            let legacy = try StudioSoundCatalogue(directory: directory)
            try require(legacy.sounds[0].tags == nil && legacy.search("card fan", category: nil).count == 1,
                        "old catalogue lost search support")
            for tags in [[""], ["collision", "collision"], ["bad\nlabel"], ["-edge"], ["edge-"],
                         [String(repeating: "x", count: 33)], (0..<17).map { "tag-\($0)" }] {
                try write(tags)
                do { _ = try StudioSoundCatalogue(directory: directory); throw CatalogueFailure(message: "invalid tags accepted") }
                catch StudioSoundCatalogue.CatalogueError.invalid { }
            }
            try require(try Data(contentsOf: bundle.appendingPathComponent("catalogue.json")) == original,
                        "validation changed bundled metadata")
        }
        try await test("catalogue rejects silent placeholders and reencoded duplicates without touching original assets") {
            let invalid = root.appendingPathComponent("invalid-metadata")
            try fm.createDirectory(at: invalid, withIntermediateDirectories: false)
            let original = try Data(contentsOf: bundle.appendingPathComponent("catalogue.json"))
            for mode in 0..<2 {
                var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
                var entries = object["sounds"] as! [[String: Any]]
                if mode == 0 { entries[0]["waveformPeaks"] = [Float](repeating: 0, count: 256) }
                else { entries[1]["originalSHA256"] = entries[0]["originalSHA256"] }
                object["sounds"] = entries
                try JSONSerialization.data(withJSONObject: object).write(to: invalid.appendingPathComponent("catalogue.json"))
                do {
                    _ = try StudioSoundCatalogue(directory: invalid)
                    throw CatalogueFailure(message: "silent or duplicate original accepted")
                } catch StudioSoundCatalogue.CatalogueError.invalid { }
            }
            try require(try Data(contentsOf: bundle.appendingPathComponent("catalogue.json")) == original,
                        "original catalogue was modified")
        }
        let sound = catalogue.sounds.first(where: { $0.id == "7a6ba4661a10ff06cd0c8c758f671bb4347fa6b4d26e23b6e7cb9165ee9aa24a" })!
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
        try await test("library attribution resolves by shipped digest into verified sound credits") {
            let first = catalogue.sounds[0]
            let attribution = try require2(catalogue.attribution(forSHA256: first.sha256))
            try require(attribution.title == first.title && attribution.author == first.author && attribution.catalogueSoundID == first.sha256
                        && attribution.originalSHA256 == first.originalSHA256 && attribution.license == "CC0-1.0", "attribution fields differ from the catalogue")
            try require(catalogue.attribution(forSHA256: String(repeating: "0", count: 64)) == nil, "unknown digest produced an attribution")
            try require(catalogue.attributionsByDigest.count == catalogue.sounds.count, "digest table lost entries")
            // A project asset made from the checked resource credits exactly that sound; foreign bytes credit nothing.
            let checked = try catalogue.checkedResource(first)
            let foreign = UUID(), library = UUID()
            let credits = try StudioSoundCreditResolver.credits(for: [
                .init(id: library, sha256: first.sha256),
                .init(id: foreign, sha256: String(repeating: "f", count: 64))
            ]) { catalogue.attribution(forSHA256: $0) }
            try require(credits.count == 1 && credits[0].assetID == library && credits[0].title == first.title && checked.data.count == first.byteCount, "credit resolution wrong")
            try credits[0].validate()
            // Optional RMS bins are accepted when consistent and refused when they exceed the peaks.
            let copy = root.appendingPathComponent("rms-library")
            try fm.createDirectory(at: copy, withIntermediateDirectories: false)
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("catalogue.json"))) as! [String: Any]
            var entries = object["sounds"] as! [[String: Any]]
            entries[0]["waveformRMS"] = (entries[0]["waveformPeaks"] as! [Double]).map { $0 / 2 }; object["sounds"] = entries
            try JSONSerialization.data(withJSONObject: object).write(to: copy.appendingPathComponent("catalogue.json"))
            let withRMS = try StudioSoundCatalogue(directory: copy)
            try require(withRMS.sounds[0].waveformRMS?.count == 256 && withRMS.sounds[1].waveformRMS == nil, "optional RMS not decoded")
            entries[0]["waveformRMS"] = (entries[0]["waveformPeaks"] as! [Double]).map { min(1, $0 + 0.5) }; object["sounds"] = entries
            try JSONSerialization.data(withJSONObject: object).write(to: copy.appendingPathComponent("catalogue.json"))
            do { _ = try StudioSoundCatalogue(directory: copy); throw CatalogueFailure(message: "RMS above peak accepted") }
            catch is StudioSoundCatalogue.CatalogueError { }
        }
        let packSounds = Array(catalogue.sounds.filter { $0.filename.hasSuffix(".wav") && $0.byteCount < 1024 * 1024 }.prefix(2))
        try require(packSounds.count == 2, "two actual bundled WAV resources required for production transport fixture")
        let packBytes = try Dictionary(uniqueKeysWithValues: packSounds.map { ($0.id, try catalogue.checkedResource($0).data) })
        let pack = try SoundPackFixture(id: "transport-fixture-v1", sounds: packSounds, resources: packBytes)
        let cacheRoot = root.appendingPathComponent("sound-pack-cache")
        let cache = StudioSoundPackCache(root: cacheRoot, trustedDescriptors: [pack.descriptor])
        var installed: StudioSoundCatalogue?
        try await test("production streamed pack transport installs pinned real bytes and reuses offline cache") {
            SoundPackTransport.configure(pack.routes)
            installed = try await cache.install(pack.descriptor, protocolClasses: [SoundPackTransport.self])
            try require(installed?.sounds == packSounds, "installer changed pinned Sound metadata")
            for item in packSounds { try require(try installed!.checkedResource(item).data == packBytes[item.id], "installed bytes differ") }
            try require(SoundPackTransport.requests.count == 3 && SoundPackTransport.sensitiveHeaders.isEmpty, "unexpected transport or sensitive headers")
            SoundPackTransport.configure([:])
            let reused = try await cache.install(pack.descriptor, protocolClasses: [SoundPackTransport.self])
            try require(reused.sounds == packSounds && SoundPackTransport.requests.isEmpty, "offline cache invoked network")
            let inspection = try await cache.inspect(descriptors: [pack.descriptor])
            try require(inspection.soundCount == 2 && inspection.bytes == pack.descriptor.totalAudioBytes + pack.manifest.count * 2 &&
                        inspection.packs[pack.descriptor.id] == .installed(soundCount: 2, bytes: pack.descriptor.totalAudioBytes + pack.manifest.count), "inspection lost actual byte/count accounting")
        }
        try await test("merged catalogues deduplicate stable and original digests while preserving resource ownership") {
            let merged = try await cache.loadAvailable(bundled: catalogue, descriptors: [pack.descriptor])
            try require(merged.sounds == catalogue.sounds && merged.attributionsByDigest == catalogue.attributionsByDigest, "duplicate pack inflated bundle or replaced provenance")
            try require(try merged.checkedResource(packSounds[0]).data == packBytes[packSounds[0].id], "merge lost resource root")
            let oneDirectory = root.appendingPathComponent("single-bundled")
            try fm.createDirectory(at: oneDirectory, withIntermediateDirectories: false)
            let one = try SoundPackFixture(id: "single-fixture-v1", sounds: [packSounds[0]], resources: packBytes)
            try one.manifest.write(to: oneDirectory.appendingPathComponent("catalogue.json"))
            try packBytes[packSounds[0].id]!.write(to: oneDirectory.appendingPathComponent(packSounds[0].filename))
            let mergedRoots = StudioSoundCatalogue.merging([try StudioSoundCatalogue(directory: oneDirectory), installed!, installed!])
            try require(mergedRoots.sounds == packSounds && mergedRoots.sounds.count == 2, "stable ID duplicate increased usable count")
            for sound in packSounds { try require(try mergedRoots.checkedResource(sound).data == packBytes[sound.id], "entry resolved from another pack root") }
            var object = try JSONSerialization.jsonObject(with: pack.manifest) as! [String: Any]
            var rows = object["sounds"] as! [[String: Any]]
            rows = [rows[1]]; rows[0]["originalSHA256"] = packSounds[0].originalSHA256; object["sounds"] = rows
            let aliases = root.appendingPathComponent("publisher-alias")
            try fm.createDirectory(at: aliases, withIntermediateDirectories: false)
            try JSONSerialization.data(withJSONObject: object).write(to: aliases.appendingPathComponent("catalogue.json"))
            let originalMerged = StudioSoundCatalogue.merging([try StudioSoundCatalogue(directory: oneDirectory), try StudioSoundCatalogue(directory: aliases)])
            try require(originalMerged.sounds.count == 1 && originalMerged.sounds[0] == packSounds[0], "reencoded publisher original inflated count")
        }
        try await test("downloaded Add remove cold reopen and verified credits retain project-owned originals") {
            let before = vm.document, selected = packSounds[0]
            try require(session.useCatalogueSound(selected, catalogue: installed!, stillCurrent: { vm.document == before }, attach: { track in
                try vm.attachImportedAudio(track, expectedProjectID: before.id, expectedRevision: before.revision,
                                           frameID: before.activeFrameID, trackNumber: 4)
            }), "downloaded sound did not enter existing importer")
            try await idle(session)
            try require(session.state == .ready && session.lastImportedClipID != nil, "downloaded sound did not attach")
            let saved = await vm.save(); try require(saved, "downloaded sound save failed")
            let projectID = vm.document.id, importedID = vm.audioClips.last!.assetID!
            try await cache.remove(pack.descriptor)
            let state = try await cache.status(pack.descriptor)
            try require(state == .notInstalled && !fm.fileExists(atPath: cacheRoot.appendingPathComponent(pack.descriptor.id).path), "remove retained cached audio")
            let fresh = StudioViewModel(storage: storage); await fresh.loadProjects()
            let reopened = await fresh.openProject(fresh.savedProjects.first(where: { $0.id == projectID })!)
            try require(reopened && fresh.audioTrack(forAssetID: importedID)?.audioData == packBytes[selected.id], "cache removal destroyed saved project original")
            // An unrelated bundled subset demonstrates that the receipt, rather
            // than a duplicate bundled record, supplies removed-pack credits.
            let unrelated = root.appendingPathComponent("unrelated-library")
            try fm.createDirectory(at: unrelated, withIntermediateDirectories: false)
            let unrelatedSound = catalogue.sounds.first { !packSounds.contains($0) }!
            let subset = try SoundPackFixture(id: "unrelated-v1", sounds: [unrelatedSound], resources: [unrelatedSound.id: try catalogue.checkedResource(unrelatedSound).data])
            try subset.manifest.write(to: unrelated.appendingPathComponent("catalogue.json"))
            let table = try await cache.attributions(bundled: StudioSoundCatalogue(directory: unrelated), descriptors: [pack.descriptor])
            let credits = try StudioSoundCreditResolver.credits(for: [.init(id: importedID, sha256: selected.sha256)]) { table[$0] }
            try require(credits.count == 1 && credits[0].originalSHA256 == selected.originalSHA256 && credits[0].author == selected.author, "removal erased checked attribution")
            try credits[0].validate()
            SoundPackTransport.configure(pack.routes)
            installed = try await cache.install(pack.descriptor, protocolClasses: [SoundPackTransport.self])
        }
        try await test("corrupt installed audio is unavailable and safe removal permits verified reinstall") {
            let target = cacheRoot.appendingPathComponent(pack.descriptor.id).appendingPathComponent(packSounds[0].filename)
            var bad = packBytes[packSounds[0].id]!; bad[0] ^= 1; try bad.write(to: target)
            let state = try await cache.status(pack.descriptor)
            try require(state == .corrupt, "corrupt cache reported installed")
            let available = try await cache.loadAvailable(bundled: catalogue, descriptors: [pack.descriptor])
            try require(available.sounds == catalogue.sounds, "corrupt optional cache disabled bundled sounds")
            do { _ = try await cache.installed(pack.descriptor); throw CatalogueFailure(message: "corrupt pack accepted") }
            catch is StudioSoundCatalogue.CatalogueError { }
            try await cache.remove(pack.descriptor)
            SoundPackTransport.configure(pack.routes)
            installed = try await cache.install(pack.descriptor, protocolClasses: [SoundPackTransport.self])
            try require(try installed!.checkedResource(packSounds[0]).data == packBytes[packSounds[0].id], "verified reinstall kept corruption")
        }
        try await test("byte clip and actual free-space budgets reject before opening a download") {
            let cases: [StudioSoundPackCache.Limits] = [
                .init(cacheBytes: pack.descriptor.totalAudioBytes + pack.manifest.count * 2 - 1, cacheClips: 512, reserveBytes: 0),
                .init(cacheBytes: 128 * 1024 * 1024, cacheClips: 1, reserveBytes: 0),
                .init(cacheBytes: 128 * 1024 * 1024, cacheClips: 512, reserveBytes: Int.max / 4)
            ]
            for (index, limits) in cases.enumerated() {
                let limited = StudioSoundPackCache(root: root.appendingPathComponent("quota-\(index)"), trustedDescriptors: [pack.descriptor], limits: limits)
                SoundPackTransport.configure(pack.routes)
                do { _ = try await limited.install(pack.descriptor, protocolClasses: [SoundPackTransport.self]); throw CatalogueFailure(message: "quota bypass") }
                catch StudioSoundPackCache.PackError.quota { }
                try require(SoundPackTransport.requests.isEmpty, "quota failure made a network request")
            }
        }
        try await test("per-file streamed length checksum and missing transport reject without partial publication") {
            for mode in 0..<4 {
                let failedRoot = root.appendingPathComponent("bad-transport-\(mode)")
                let failed = StudioSoundPackCache(root: failedRoot, trustedDescriptors: [pack.descriptor])
                var routes = pack.routes, data = packBytes[packSounds[0].id]!
                if mode == 0 { data.append(0) }
                if mode == 1 { data[0] ^= 1 }
                if mode == 2 { data.removeLast() }
                routes[pack.descriptor.baseURL + packSounds[0].filename] = mode == 3 ? nil : .bytes(data)
                SoundPackTransport.configure(routes)
                do { _ = try await failed.install(pack.descriptor, protocolClasses: [SoundPackTransport.self]); throw CatalogueFailure(message: "bad transport published") }
                catch is StudioSoundPackCache.PackError { }
                let state = try await failed.status(pack.descriptor)
                try require(state == .notInstalled && (try fm.contentsOfDirectory(atPath: failedRoot.path)).isEmpty, "failed stream retained staged files")
            }
        }
        try await test("unsafe routes forged descriptors and redirects never send secrets or leave partial media") {
            let forged = StudioSoundPackCache.Descriptor(id: pack.descriptor.id, title: "Forged", manifestURL: pack.descriptor.manifestURL,
                manifestBytes: pack.descriptor.manifestBytes, manifestSHA256: pack.descriptor.manifestSHA256, baseURL: pack.descriptor.baseURL,
                soundCount: 2, totalAudioBytes: pack.descriptor.totalAudioBytes)
            SoundPackTransport.configure(pack.routes)
            do { _ = try await cache.install(forged, protocolClasses: [SoundPackTransport.self]); throw CatalogueFailure(message: "forged descriptor accepted") }
            catch StudioSoundPackCache.PackError.invalid { }
            try require(SoundPackTransport.requests.isEmpty, "forged descriptor reached transport")
            for url in ["http://raw.githubusercontent.com/jmw7629/StickDeath-Infinity-/main/assets/catalogue.json", "https://raw.githubusercontent.com/other/repo/main/assets/catalogue.json", "https://kenney.nl/a?token=secret", "https://user:password@kenney.nl/a", "https://kenney.nl:444/a", "https://kenney.nl/%2e%2e/a"] {
                let unsafe = StudioSoundPackCache.Descriptor(id: "unsafe-v1", title: "Unsafe", manifestURL: url,
                    manifestBytes: 1, manifestSHA256: pack.descriptor.manifestSHA256, baseURL: url, soundCount: 1, totalAudioBytes: 1)
                do { try StudioSoundPackCache.validateDescriptor(unsafe); throw CatalogueFailure(message: "unsafe URL accepted") }
                catch StudioSoundPackCache.PackError.invalid { }
            }
            let redirectRoot = root.appendingPathComponent("denied-redirect")
            let redirected = StudioSoundPackCache(root: redirectRoot, trustedDescriptors: [pack.descriptor])
            SoundPackTransport.configure([pack.descriptor.manifestURL: .redirect(URL(string: "https://example.invalid/steal")!)])
            do { _ = try await redirected.install(pack.descriptor, protocolClasses: [SoundPackTransport.self]); throw CatalogueFailure(message: "off-host redirect accepted") }
            catch StudioSoundPackCache.PackError.network { }
            try require(SoundPackTransport.requests == [pack.descriptor.manifestURL] && SoundPackTransport.sensitiveHeaders.isEmpty, "off-host redirect leaked request")
            let safeRoot = root.appendingPathComponent("sanitized-redirect")
            let safeCache = StudioSoundPackCache(root: safeRoot, trustedDescriptors: [pack.descriptor])
            let destination = pack.descriptor.baseURL + "redirected-manifest.json"
            var routes = pack.routes; routes[pack.descriptor.manifestURL] = .redirect(URL(string: destination)!); routes[destination] = .bytes(pack.manifest)
            SoundPackTransport.configure(routes)
            _ = try await safeCache.install(pack.descriptor, protocolClasses: [SoundPackTransport.self])
            try require(SoundPackTransport.requests.contains(destination) && SoundPackTransport.sensitiveHeaders.isEmpty, "same-host redirect retained untrusted headers")
        }
        try await test("cancellation retains mutation ownership until real staged audio is cleaned") {
            let cancelRoot = root.appendingPathComponent("cancelled-pack")
            let cancelCache = StudioSoundPackCache(root: cancelRoot, trustedDescriptors: [pack.descriptor])
            var routes = pack.routes; routes[pack.descriptor.baseURL + packSounds[1].filename] = .hold
            SoundPackTransport.configure(routes)
            let operation = Task { try await cancelCache.install(pack.descriptor, protocolClasses: [SoundPackTransport.self]) }
            for _ in 0..<1000 {
                if SoundPackTransport.requests.count == 3 { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            try require(SoundPackTransport.requests.count == 3, "cancellation never reached second audio request")
            let stage = try require2(try fm.contentsOfDirectory(at: cancelRoot, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("stage-") })
            try require(try Data(contentsOf: stage.appendingPathComponent(packSounds[0].filename)) == packBytes[packSounds[0].id], "cancellation fixture did not write actual first audio")
            do { try await cancelCache.remove(pack.descriptor); throw CatalogueFailure(message: "remove interleaved active install") }
            catch StudioSoundPackCache.PackError.busy { }
            operation.cancel()
            do { _ = try await operation.value; throw CatalogueFailure(message: "cancelled install returned success") }
            catch is CancellationError { }
            let state = try await cancelCache.status(pack.descriptor)
            try require(state == .notInstalled && (try fm.contentsOfDirectory(atPath: cancelRoot.path)).isEmpty, "cancellation leaked staged files")
            SoundPackTransport.configure(pack.routes)
            _ = try await cancelCache.install(pack.descriptor, protocolClasses: [SoundPackTransport.self])
        }
        try await test("pinned manifest metadata corruption and cache symlinks fail without touching source") {
            let manifestRoot = root.appendingPathComponent("corrupt-manifest")
            let manifestCache = StudioSoundPackCache(root: manifestRoot, trustedDescriptors: [pack.descriptor])
            var routes = pack.routes, bad = pack.manifest; bad[0] ^= 1; routes[pack.descriptor.manifestURL] = .bytes(bad)
            SoundPackTransport.configure(routes)
            do { _ = try await manifestCache.install(pack.descriptor, protocolClasses: [SoundPackTransport.self]); throw CatalogueFailure(message: "corrupt pinned manifest accepted") }
            catch StudioSoundPackCache.PackError.invalid { }
            try require(SoundPackTransport.requests.count == 1, "corrupt manifest downloaded audio")
            let linkedRoot = root.appendingPathComponent("linked-cache")
            try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: bundle)
            let linked = StudioSoundPackCache(root: linkedRoot, trustedDescriptors: [pack.descriptor])
            SoundPackTransport.configure(pack.routes)
            do { _ = try await linked.install(pack.descriptor, protocolClasses: [SoundPackTransport.self]); throw CatalogueFailure(message: "symlink root accepted") }
            catch StudioSoundPackCache.PackError.invalid { }
            try require(SoundPackTransport.requests.isEmpty && (try catalogue.checkedResource(packSounds[0]).data) == packBytes[packSounds[0].id], "symlink operation accessed transport or changed source")
        }
        try await test("legacy absent shipped metadata preserves existing install-receipt credit resolution") {
            let legacy = root.appendingPathComponent("legacy-bundle-without-pack-metadata")
            try fm.createDirectory(at: legacy, withIntermediateDirectories: false)
            let unrelated = try StudioSoundCatalogue(directory: root.appendingPathComponent("unrelated-library"))
            let previous = try await cache.attributions(bundled: unrelated, descriptors: [pack.descriptor])
            let unchanged = try await cache.attributions(bundled: unrelated, descriptors: [pack.descriptor], metadataDirectory: legacy)
            try require(unchanged == previous && unchanged[packSounds[0].sha256] == packSounds[0].attribution,
                        "absent metadata changed the receipt fallback")
        }
        if CommandLine.arguments.count == 3 {
            let portableMetadata = root.appendingPathComponent("portable-credit-metadata-only")
            try await test("received optional project audio resolves actual credits on a device with no pack install or receipt") {
                let descriptors = try StudioSoundPackCache.descriptors(directory: bundle)
                try require(descriptors.count == 2, "actual pinned shipped metadata required")
                try fm.createDirectory(at: portableMetadata, withIntermediateDirectories: false)
                try fm.copyItem(at: bundle.appendingPathComponent("sound-packs.json"), to: portableMetadata.appendingPathComponent("sound-packs.json"))
                for descriptor in descriptors {
                    let destination = portableMetadata.appendingPathComponent("pack-catalogues").appendingPathComponent(descriptor.id)
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    try fm.copyItem(at: bundle.appendingPathComponent("pack-catalogues").appendingPathComponent(descriptor.id).appendingPathComponent("catalogue.json"),
                                    to: destination.appendingPathComponent("catalogue.json"))
                }
                let emptyCache = root.appendingPathComponent("never-installed-optional-sounds")
                let receiver = StudioSoundPackCache(root: emptyCache, trustedDescriptors: descriptors)
                SoundPackTransport.configure([:])
                let table = try await receiver.attributions(bundled: catalogue, descriptors: descriptors, metadataDirectory: portableMetadata)
                let assetRoot = URL(fileURLWithPath: CommandLine.arguments[2])
                var credited = 0
                for descriptor in descriptors {
                    let metadata = try StudioSoundCatalogue(directory: portableMetadata.appendingPathComponent("pack-catalogues").appendingPathComponent(descriptor.id))
                    for sound in metadata.sounds {
                        // These are the actual original bytes a shared/imported
                        // project owns; the receiving cache never sees them.
                        let received = try Data(contentsOf: assetRoot.appendingPathComponent(descriptor.id).appendingPathComponent(sound.filename))
                        let track = AudioTrack(id: UUID(), name: sound.title, format: (sound.filename as NSString).pathExtension,
                                               audioData: received, startTime: 0, duration: sound.duration)
                        let digest = SoundPackFixture.digest(track.audioData!)
                        try require(digest == sound.sha256, "received project bytes differ from pinned real optional audio")
                        let credits = try StudioSoundCreditResolver.credits(for: [.init(id: track.id, sha256: digest)]) { table[$0] }
                        try require(credits.count == 1 && credits[0].assetID == track.id && credits[0].title == sound.title &&
                                    credits[0].originalSHA256 == sound.originalSHA256 && credits[0].sourceURL == sound.sourceURL,
                                    "portable project lost known optional sound credit")
                        try credits[0].validate(); credited += 1
                    }
                }
                let available = try await receiver.loadAvailable(bundled: catalogue, descriptors: descriptors)
                try require(credited == 23 && available.sounds == catalogue.sounds && !fm.fileExists(atPath: emptyCache.path) &&
                            SoundPackTransport.requests.isEmpty, "credit metadata installed audio, wrote a receipt or contacted transport")
            }
            try await test("portable credit metadata rejects tampering and linked file or directory components") {
                let descriptors = try StudioSoundPackCache.descriptors(directory: portableMetadata)
                let first = descriptors[0]
                let sourceRoot = portableMetadata.appendingPathComponent("pack-catalogues")
                let sourcePack = sourceRoot.appendingPathComponent(first.id)
                let sourceManifest = sourcePack.appendingPathComponent("catalogue.json")
                let original = try Data(contentsOf: sourceManifest)
                let receiver = StudioSoundPackCache(root: root.appendingPathComponent("metadata-refusal-cache"), trustedDescriptors: descriptors)
                for mode in 0..<6 {
                    let altered = root.appendingPathComponent("portable-metadata-refusal-\(mode)")
                    if mode == 4 {
                        try fm.createSymbolicLink(at: altered, withDestinationURL: portableMetadata)
                    } else {
                        try fm.copyItem(at: portableMetadata, to: altered)
                        let metadataRoot = altered.appendingPathComponent("pack-catalogues")
                        let packRoot = metadataRoot.appendingPathComponent(first.id)
                        let manifest = packRoot.appendingPathComponent("catalogue.json")
                        switch mode {
                        case 0:
                            var corrupted = original; corrupted[0] ^= 1; try corrupted.write(to: manifest)
                        case 1:
                            try fm.removeItem(at: manifest); try fm.createSymbolicLink(at: manifest, withDestinationURL: sourceManifest)
                        case 2:
                            try fm.removeItem(at: packRoot); try fm.createSymbolicLink(at: packRoot, withDestinationURL: sourcePack)
                        case 3:
                            try fm.removeItem(at: metadataRoot); try fm.createSymbolicLink(at: metadataRoot, withDestinationURL: sourceRoot)
                        case 5:
                            let descriptorFile = altered.appendingPathComponent("sound-packs.json")
                            try fm.removeItem(at: descriptorFile)
                            try fm.createSymbolicLink(at: descriptorFile, withDestinationURL: portableMetadata.appendingPathComponent("sound-packs.json"))
                        default: break
                        }
                    }
                    do {
                        _ = try await receiver.attributions(bundled: catalogue, descriptors: descriptors, metadataDirectory: altered)
                        throw CatalogueFailure(message: "tampered or linked portable credit metadata accepted")
                    } catch StudioSoundPackCache.PackError.invalid { }
                    catch StudioSoundCatalogue.CatalogueError.invalid { }
                }
                try require(try Data(contentsOf: sourceManifest) == original, "metadata refusal changed the trusted original")
            }
            try await test("actual curated ambience and comedy packs install decode and retain attribution offline") {
                let assetRoot = URL(fileURLWithPath: CommandLine.arguments[2])
                let descriptors = try StudioSoundPackCache.descriptors(directory: bundle)
                try require(descriptors.count == 2, "actual pinned ambience/comedy descriptor resource required")
                let actualRoot = root.appendingPathComponent("actual-curated-packs")
                let actual = StudioSoundPackCache(root: actualRoot, trustedDescriptors: descriptors)
                var expected = Set(catalogue.sounds.map(\.id)), originals = Set(catalogue.sounds.map(\.originalSHA256))
                var expectedCreditDigests = Set(catalogue.sounds.map(\.sha256))
                for descriptor in descriptors {
                    let source = assetRoot.appendingPathComponent(descriptor.id)
                    let real = try StudioSoundCatalogue(directory: source)
                    var responses: [String: SoundPackTransport.Reply] = [descriptor.manifestURL: .bytes(try Data(contentsOf: source.appendingPathComponent("catalogue.json")))]
                    for sound in real.sounds {
                        try require(expected.insert(sound.id).inserted && originals.insert(sound.originalSHA256).inserted, "curated asset duplicates existing shipped/publisher sound")
                        try require(expectedCreditDigests.insert(sound.sha256).inserted, "curated shipped bytes duplicate an existing library sound")
                        responses[descriptor.baseURL + sound.filename] = .bytes(try real.checkedResource(sound).data)
                    }
                    SoundPackTransport.configure(responses)
                    let downloaded = try await actual.install(descriptor, protocolClasses: [SoundPackTransport.self])
                    for sound in downloaded.sounds {
                        let checked = try downloaded.checkedResource(sound)
                        let decoded = try await StudioAudioImportService.shared.importAudio(from: checked.url, name: sound.title, scratchParent: scratch)
                        try require(decoded.originalData == checked.data && abs(decoded.duration - sound.duration) < 0.000001 && decoded.sampleRate == sound.sampleRate && decoded.channelCount == sound.channels,
                                    "actual curated pack metadata differs from native decode")
                        try require(zip(decoded.waveformPeaks, sound.waveformPeaks).allSatisfy { abs($0 - $1) < 0.00001 }, "curated peaks are not measured audio")
                    }
                }
                let merged = try await actual.loadAvailable(bundled: catalogue, descriptors: descriptors)
                try require(Set(merged.sounds.map(\.id)) == expected && merged.sounds.count == expected.count, "actual curated count lost or inflated")
                for descriptor in descriptors { try await actual.remove(descriptor) }
                let credits = try await actual.attributions(bundled: catalogue, descriptors: descriptors)
                try require(Set(credits.keys) == expectedCreditDigests, "curated attribution lost after removal")
            }
        } else { print("DEFERRED actual curated pack asset-root verification (third argument not supplied)") }
        print("STUDIO_SOUND_CATALOGUE_TESTS=PASS \(count)/\(count) with \(catalogue.sounds.count) real bundled decodes")
    }
    static func require2<T>(_ value: T?) throws -> T {
        guard let value else { throw CatalogueFailure(message: "unexpected nil") }
        return value
    }
}
