import Foundation
import ImageIO

struct Failure: Error { let message: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(message: message) }
}
actor Calls { var count = 0; func record() { count += 1 } }

final class PackTransportStub: URLProtocol {
    enum Reply { case bytes(Data), redirect(URL), hold }
    enum Mode { case bytes(Data), redirect, routes([String: Reply]) }
    private static let lock = NSLock()
    private static var mode: Mode = .bytes(Data())
    private static var urls: [String] = []
    private static var sensitive: [String] = []
    static func configure(_ value: Mode) { lock.lock(); mode = value; urls = []; sensitive = []; lock.unlock() }
    static var requests: [String] { lock.lock(); defer { lock.unlock() }; return urls }
    static var sensitiveHeaders: [String] { lock.lock(); defer { lock.unlock() }; return sensitive }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let mode = Self.mode; Self.urls.append(request.url!.absoluteString)
        for name in ["Authorization", "Cookie", "Proxy-Authorization"] where request.value(forHTTPHeaderField: name) != nil {
            Self.sensitive.append(name)
        }
        Self.lock.unlock()
        let reply: Reply
        switch mode {
        case .bytes(let data): reply = .bytes(data)
        case .redirect: reply = .redirect(URL(string: "https://example.invalid/disallowed.zip")!)
        case .routes(let routes):
            guard let found = routes[request.url!.absoluteString] else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
            }
            reply = found
        }
        switch reply {
        case .bytes(let bytes):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/octet-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for offset in stride(from: 0, to: bytes.count, by: 8192) {
                client?.urlProtocol(self, didLoad: bytes.subdata(in: offset..<min(offset+8192, bytes.count)))
            }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let destination):
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
            // A refused redirect still completes with its original HTTP response.
            // Creating that response is distinct from notifying a redirect.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .hold: break
        }
    }
    override func stopLoading() { }
}
final class CropCheckpoint: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0; private var stagedCount = 0
    let root: URL
    init(root: URL) { self.root = root }
    var observed: Int { lock.lock(); defer { lock.unlock() }; return stagedCount }
    func check() throws {
        lock.lock(); count += 1; let current = count; lock.unlock()
        if current == 12 {
            let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            guard let stage = children.first(where: { $0.lastPathComponent.hasPrefix("stage-") }) else {
                throw Failure(message: "Cancellation test reached no actual staging")
            }
            let pngs = try FileManager.default.contentsOfDirectory(atPath: stage.path).filter { $0.hasSuffix(".png") }.count
            lock.lock(); stagedCount = pngs; lock.unlock()
            withUnsafeCurrentTask { $0?.cancel() }
            try Task.checkCancellation()
        }
    }
}

/// Deterministic uncooperative transport: cancellation must keep ownership
/// until this held await returns and the real installer finishes cleanup.
actor PackOperationGate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; enteredWaiter?.resume(); enteredWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

@main struct Main {
    static func main() async {
        do { try await run() } catch { print("STUDIO_IMAGE_PACK_TESTS=FAIL \(error)"); exit(1) }
    }
    static func run() async throws {
        let fm = FileManager.default
        let descriptorDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
        let zip = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let descriptor = try StudioImagePackCache.descriptor(directory: descriptorDirectory)
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-pack-tests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let cache = StudioImagePackCache(root: root)
        let before = try await cache.installed(descriptor)
        try require(before == nil, "Missing pack reported installed")
        let calls = Calls()
        let catalogue = try await cache.download(descriptor, fetch: { _ in await calls.record(); return zip })
        try require(catalogue.images.count == 458 && catalogue.licenses.count == 1, "False asset count")
        try require(Set(catalogue.images.map(\.pixelSHA256)).count == 458, "Duplicate pixels inflated count")
        for image in catalogue.images {
            let png = try catalogue.checkedPNG(image)
            try require(!png.isEmpty && image.width == 16 && image.height == 16, "Real crop validation failed")
            let attribution = try catalogue.attribution(for: image)
            try require(attribution["sourceArchiveSHA256"] == descriptor.archiveSHA256 && image.id.contains(".x"), "Crop provenance lost")
        }
        print("PASS actual publisher ZIP installs458 verified unique PNG crops with original CC0 rights")
        let reopened = StudioImagePackCache(root: root)
        let offline = try await reopened.installed(descriptor)
        try require(offline?.images == catalogue.images, "Offline reload changed catalogue")
        _ = try await reopened.download(descriptor, fetch: { _ in throw Failure(message: "Offline cache invoked network") })
        let count = await calls.count
        try require(count == 1, "Unexpected repeated request")
        print("PASS offline reopen and repeated download reuse verified cache without transport")
        let existingQuota = root.appendingPathComponent("existing-quota-fixture")
        try Data(count: StudioImagePackCache.maximumCacheBytes).write(to: existingQuota)
        do { _ = try await reopened.download(descriptor, fetch: { _ in throw Failure(message: "Existing-cache quota called network") }); throw Failure(message: "Existing cache bypassed quota") }
        catch StudioImagePackCache.PackError.quota { }
        try fm.removeItem(at: existingQuota)
        print("PASS already-installed download applies same bytequota preflight as offline reopen")
        let copiedSource = try catalogue.checkedPNG(catalogue.images[0])
        let retained = root.deletingLastPathComponent().appendingPathComponent("sdi-retained-" + UUID().uuidString + ".png")
        defer { try? fm.removeItem(at: retained) }
        try copiedSource.write(to: retained)
        try await reopened.remove(descriptor)
        let removed = try await reopened.installed(descriptor)
        let retainedBytes = try Data(contentsOf: retained)
        try require(removed == nil && retainedBytes == copiedSource, "Cache removal touched independently owned media")
        print("PASS explicit removal only removes library copy; separate retained source unchanged")
        var corrupt = zip; corrupt[100] ^= 1
        let corruptBytes = corrupt
        do { _ = try await cache.download(descriptor, fetch: { _ in corruptBytes }); throw Failure(message: "Corrupt ZIP accepted") }
        catch is StudioImagePackCache.PackError { }
        let afterCorruption = try await cache.installed(descriptor)
        try require(afterCorruption == nil, "Checksum failure published pack")
        print("PASS archive checksum rejects corruption before ZIP parsing and publication")
        let cancelled = Task { try await cache.download(descriptor, fetch: { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000); return zip
        }) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw Failure(message: "Cancelled request published pack") }
        catch is CancellationError { }
        _ = try await cache.download(descriptor, fetch: { _ in zip })
        let children = try fm.contentsOfDirectory(atPath: root.path)
        try require(children.allSatisfy { !$0.hasPrefix("stage-") }, "Staging leaked")
        print("PASS cancellation leaves no staging and next real install succeeds")
        guard let actual = try await cache.installed(descriptor) else { throw Failure(message: "Installed pack missing") }
        try Data([0,1,2]).write(to: actual.sourceURL(for: actual.images[0]))
        do { _ = try await cache.installed(descriptor); throw Failure(message: "Tampered cached PNG accepted") }
        catch is StudioImageCatalogue.CatalogueError { }
        try await cache.remove(descriptor)
        _ = try await cache.download(descriptor, fetch: { _ in zip })
        print("PASS actual PNG corruption fails closed and explicit removal permits verified retry")
        try await cache.remove(descriptor)
        let quotaFile = root.appendingPathComponent("quota-fixture")
        try Data(count: StudioImagePackCache.maximumCacheBytes).write(to: quotaFile)
        do { _ = try await cache.download(descriptor, fetch: { _ in throw Failure(message: "Quota called transport") }); throw Failure(message: "Quota ignored") }
        catch StudioImagePackCache.PackError.quota { }
        try fm.removeItem(at: quotaFile)
        print("PASS real cache byte quota rejects before transport")
        var forged = try JSONSerialization.jsonObject(with: Data(contentsOf: descriptorDirectory.appendingPathComponent("remote-pack.json"))) as! [String: Any]
        forged["archiveURL"] = "https://example.invalid/asset.zip"
        let injected = try JSONDecoder().decode(StudioImagePackCache.Descriptor.self, from: JSONSerialization.data(withJSONObject: forged))
        do { _ = try await cache.download(injected, fetch: { _ in throw Failure(message: "Unapproved descriptor reached transport") }); throw Failure(message: "Unapproved URL accepted") }
        catch StudioImagePackCache.PackError.invalid { }
        print("PASS exact approved descriptor rejects caller-supplied URLs before transport")
        let outside = root.appendingPathComponent("external-sentinel")
        let linked = root.appendingPathComponent("linked-root")
        let outsidePack = outside.appendingPathComponent(descriptor.id)
        let outsideStage = outside.appendingPathComponent("stage-" + UUID().uuidString)
        try fm.createDirectory(at: outsidePack, withIntermediateDirectories: true)
        try fm.createDirectory(at: outsideStage, withIntermediateDirectories: false)
        let sentinel = outsidePack.appendingPathComponent("keep.txt")
        try Data("preserve".utf8).write(to: sentinel)
        try fm.createSymbolicLink(at: linked, withDestinationURL: outside)
        let linkedCache = StudioImagePackCache(root: linked)
        do { _ = try await linkedCache.installed(descriptor); throw Failure(message: "Symlink root read accepted") }
        catch StudioImagePackCache.PackError.invalid { }
        do { try await linkedCache.remove(descriptor); throw Failure(message: "Symlink root delete accepted") }
        catch StudioImagePackCache.PackError.invalid { }
        do { _ = try await linkedCache.download(descriptor, fetch: { _ in zip }); throw Failure(message: "Symlink root install accepted") }
        catch StudioImagePackCache.PackError.invalid { }
        let sentinelBytes = try Data(contentsOf: sentinel)
        try require(sentinelBytes == Data("preserve".utf8) && fm.fileExists(atPath: outsideStage.path), "External files were removed")
        try fm.removeItem(at: linked)
        let targetLink = root.appendingPathComponent(descriptor.id)
        try fm.createSymbolicLink(at: targetLink, withDestinationURL: outsidePack)
        do { try await cache.remove(descriptor); throw Failure(message: "Symlink target delete accepted") }
        catch StudioImagePackCache.PackError.invalid { }
        try require(fm.fileExists(atPath: sentinel.path), "External target deleted")
        try fm.removeItem(at: targetLink); try fm.removeItem(at: outside)
        print("PASS root and target symlinks rejected without touching outside sentinel or staging")
        let checkpoint = CropCheckpoint(root: root)
        let cropTask = Task { try await cache.download(descriptor, fetch: { _ in zip }, checkpoint: { try checkpoint.check() }) }
        do { _ = try await cropTask.value; throw Failure(message: "Mid-crop cancellation installed pack") }
        catch is CancellationError { }
        let afterCrop = try await cache.installed(descriptor)
        let residue = try fm.contentsOfDirectory(atPath: root.path)
        try require(checkpoint.observed == 11 && afterCrop == nil && residue.isEmpty, "Mid-crop cancellation did not clean partial PNGs")
        print("PASS actual task cancellation after11 PNG crops removes partial staging and publishes nothing")
        PackTransportStub.configure(.bytes(zip))
        let transportBytes = try await StudioImagePackCache.fetch(descriptor, protocolClasses: [PackTransportStub.self])
        try require(transportBytes == zip && PackTransportStub.requests == [descriptor.archiveURL], "Actual URLSession transport changed bytes or URL")
        print("PASS real URLSession AsyncBytes reads approved URL through isolated local stub only")
        PackTransportStub.configure(.bytes(zip + Data([0])))
        do { _ = try await StudioImagePackCache.fetch(descriptor, protocolClasses: [PackTransportStub.self]); throw Failure(message: "Transport exceeded pinned byte count") }
        catch StudioImagePackCache.PackError.invalid { }
        print("PASS real URLSession chunked stream rejects byte beyond pinned archive length")
        PackTransportStub.configure(.redirect)
        do { _ = try await StudioImagePackCache.fetch(descriptor, protocolClasses: [PackTransportStub.self]); throw Failure(message: "Redirect accepted") }
        catch is StudioImagePackCache.PackError { }
        catch is URLError { }
        try require(PackTransportStub.requests == [descriptor.archiveURL], "URLSession followed unapproved redirect")
        let asset = Data("assets/1-bit-pack".utf8).map { String(format: "%02x", $0) }.joined()
        let page = URL(string: "https://kenney.nl/assets/1-bit-pack")!
        let endpoint = "https://kenney.nl/download-link/" + asset
        let expiry = Int(Date().timeIntervalSince1970) + 300
        let signed = "https://kenney.nl/download/" + asset + "/" + String(repeating: "a", count: 64) + "?expires=\(expiry)"
        func metadata(_ url: Any) throws -> Data { try JSONSerialization.data(withJSONObject: ["url": url]) }
        func routes(_ data: Data, final: PackTransportStub.Reply? = nil) -> [String: PackTransportStub.Reply] {
            [descriptor.archiveURL: .redirect(page), endpoint: .bytes(data), signed: final ?? .bytes(zip)]
        }
        PackTransportStub.configure(.routes(try routes(metadata(signed))))
        let resolved = try await StudioImagePackCache.fetch(descriptor, protocolClasses: [PackTransportStub.self])
        try require(resolved == zip && PackTransportStub.requests == [descriptor.archiveURL, endpoint, signed] &&
                    PackTransportStub.sensitiveHeaders.isEmpty, "Known publisher flow changed bytes, headers or request scope")
        let invalidURLs = [
            signed.replacingOccurrences(of: "https://kenney.nl", with: "http://kenney.nl"),
            signed.replacingOccurrences(of: "https://kenney.nl", with: "https://example.invalid"),
            signed.replacingOccurrences(of: "https://kenney.nl", with: "https://user@kenney.nl"),
            signed.replacingOccurrences(of: "https://kenney.nl", with: "https://kenney.nl:443"),
            signed.replacingOccurrences(of: asset + "/", with: "wrong-asset/"),
            signed + "&extra=1", signed + "#fragment",
            signed.replacingOccurrences(of: "?expires=\(expiry)", with: "?expires=1"),
            signed.replacingOccurrences(of: "?expires=\(expiry)", with: "?expires=\(expiry + 3600)")
        ]
        for value in invalidURLs {
            PackTransportStub.configure(.routes(try routes(metadata(value))))
            do { _ = try await StudioImagePackCache.fetch(descriptor, protocolClasses: [PackTransportStub.self]); throw Failure(message: "Unsafe resolved route accepted") }
            catch is StudioImagePackCache.PackError { }
            try require(PackTransportStub.requests == [descriptor.archiveURL, endpoint], "Unsafe download reached a destination")
        }
        for data in [Data("{bad".utf8), try metadata(7), Data(repeating: 32, count: 16 * 1024 + 1)] {
            PackTransportStub.configure(.routes(routes(data)))
            do { _ = try await StudioImagePackCache.fetch(descriptor, protocolClasses: [PackTransportStub.self]); throw Failure(message: "Invalid metadata accepted") }
            catch is StudioImagePackCache.PackError { }
            try require(PackTransportStub.requests == [descriptor.archiveURL, endpoint], "Invalid metadata issued archive request")
        }
        PackTransportStub.configure(.routes([
            descriptor.archiveURL: .redirect(page), endpoint: .redirect(URL(string: signed)!)
        ]))
        do { _ = try await StudioImagePackCache.fetch(descriptor, protocolClasses: [PackTransportStub.self]); throw Failure(message: "Metadata redirect accepted") }
        catch is StudioImagePackCache.PackError { } catch is URLError { }
        try require(PackTransportStub.requests == [descriptor.archiveURL, endpoint], "Metadata redirect was followed")
        PackTransportStub.configure(.routes(try routes(metadata(signed), final: .redirect(page))))
        do { _ = try await StudioImagePackCache.fetch(descriptor, protocolClasses: [PackTransportStub.self]); throw Failure(message: "Resolved archive redirect accepted") }
        catch is StudioImagePackCache.PackError { } catch is URLError { }
        try require(PackTransportStub.requests == [descriptor.archiveURL, endpoint, signed], "Resolved archive redirected onward")
        var resolvedCorrupt = zip; resolvedCorrupt[resolvedCorrupt.count - 1] ^= 1
        for payload in [resolvedCorrupt, zip.dropLast(), zip + Data([0])] {
            PackTransportStub.configure(.routes(try routes(metadata(signed), final: .bytes(Data(payload)))))
            do { _ = try await StudioImagePackCache.fetch(descriptor, protocolClasses: [PackTransportStub.self]); throw Failure(message: "Resolution widened archive pins") }
            catch is StudioImagePackCache.PackError { }
        }
        PackTransportStub.configure(.routes([descriptor.archiveURL: .redirect(page), endpoint: .hold]))
        let pendingResolution = Task { try await StudioImagePackCache.fetch(descriptor, protocolClasses: [PackTransportStub.self]) }
        defer { pendingResolution.cancel() }
        for _ in 0..<200 {
            if PackTransportStub.requests.contains(endpoint) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try require(PackTransportStub.requests == [descriptor.archiveURL, endpoint], "Cancellation fixture never held the metadata request")
        pendingResolution.cancel()
        do { _ = try await pendingResolution.value; throw Failure(message: "Cancelled metadata resolution returned") }
        catch is CancellationError { }
        try require(PackTransportStub.requests == [descriptor.archiveURL, endpoint], "Cancelled resolution issued an archive request")
        print("PASS actual session delegate refuses redirect before destination request")
        try await sharedOperationOwnership(descriptor: descriptor, archive: zip)
        if CommandLine.arguments.count > 3 {
            try await expandedPacks(directory: descriptorDirectory, legacyZIP: zip,
                                    mappingURL: URL(fileURLWithPath: CommandLine.arguments[3]))
            print("STUDIO_IMAGE_PACK_TESTS=PASS groups=20 expandedPictures=2061")
        } else {
            print("STUDIO_IMAGE_PACK_TESTS=PASS groups=15 expandedPacks=NOT_RUN")
        }
    }
    static func sharedOperationOwnership(descriptor: StudioImagePackCache.Descriptor, archive: Data) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-pack-owner-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let cache = StudioImagePackCache(root: root)
        let operations = StudioImagePackOperations(cache: cache)
        let ownerA = UUID(), ownerB = UUID(), calls = Calls(), gateA = PackOperationGate()
        let initial = try await operations.installed(descriptor)
        let initialStatus = await operations.status()
        try require(initial == nil && initialStatus == nil, "Owner invented initial installed/running state")
        let first = try await operations.start(descriptor, action: .install, ownerID: ownerA, fetch: { _ in
            await calls.record(); await gateA.pause(); return archive
        })
        await gateA.waitUntilEntered()
        let running = await operations.status()
        let wrongCancel = await operations.cancel(first.request, ownerID: ownerB)
        try require(running?.request == first.request && running?.phase == .running && !wrongCancel,
            "Running receipt or wrong-owner cancellation changed the actual operation")
        let requested = await operations.cancel(first.request, ownerID: ownerA)
        let cancelling = await operations.status()
        try require(requested && cancelling?.phase == .cancelling, "Owned cancellation was not represented as pending")
        do {
            _ = try await operations.start(descriptor, action: .install, ownerID: ownerB,
                fetch: { _ in throw Failure(message: "Busy takeover reached transport") })
            throw Failure(message: "Cancelled but still unwinding operation released its lease early")
        } catch StudioImagePackCache.PackError.busy { }
        await gateA.release()
        let cancelled = try await operations.wait(for: first, ownerID: ownerA)
        let absent = try await operations.installed(descriptor)
        let terminalCancelled = await operations.status()
        try require(cancelled.receipt.request == first.request && cancelled.receipt.outcome == .cancelled
            && cancelled.catalogue == nil && absent == nil && terminalCancelled?.phase == .finished(cancelled.receipt),
            "Cancelled operation claimed installation or lost its factual terminal receipt")
        let residue = try fm.contentsOfDirectory(atPath: root.path)
        try require(residue.isEmpty, "Owned cancelled download retained a staging/published directory")

        let gateB = PackOperationGate()
        let second = try await operations.start(descriptor, action: .install, ownerID: ownerB, fetch: { _ in
            await calls.record(); await gateB.pause(); return archive
        })
        await gateB.waitUntilEntered()
        let staleCancel = await operations.cancel(first.request, ownerID: ownerA)
        let foreignCancel = await operations.cancel(second.request, ownerID: ownerA)
        try require(second.request.id != first.request.id && !staleCancel && !foreignCancel,
            "Old run token or wrong owner cancelled a newer user's run")
        await gateB.release()
        let installed = try await operations.wait(for: second, ownerID: ownerB)
        guard let catalogue = installed.catalogue, let image = catalogue.images.first else {
            throw Failure(message: "Owned real archive install returned no verified catalogue")
        }
        let actualPNG = try catalogue.checkedPNG(image)
        try require(installed.receipt.request == second.request && installed.receipt.outcome == .installed(availablePictures: 458)
            && catalogue.availableImages.count == 458 && !actualPNG.isEmpty,
            "Owner reported success without actual pinned install/verified PNGs")
        let lateCancel = await operations.cancel(second.request, ownerID: ownerB)
        let offline = try await operations.installed(descriptor)
        try require(!lateCancel && offline?.images.count == 458, "Postcommit cancellation claimed rollback or removed installed pictures")
        do {
            _ = try await operations.wait(for: second, ownerID: ownerA)
            throw Failure(message: "Wrong owner consumed another operation's completion")
        } catch StudioImagePackOperations.OwnershipError.wrongOwner { }
        let reuse = try await operations.start(descriptor, action: .install, ownerID: ownerA,
            fetch: { _ in throw Failure(message: "Verified cached install unnecessarily requested HTTP") })
        let reused = try await operations.wait(for: reuse, ownerID: ownerA)
        let transports = await calls.count
        try require(reused.receipt.outcome == .installed(availablePictures: 458) && transports == 2,
            "Shared owner bypassed the actual offline/cache reuse path")
        let retained = fm.temporaryDirectory.appendingPathComponent("sdi-pack-retained-" + UUID().uuidString + ".png")
        defer { try? fm.removeItem(at: retained) }
        try actualPNG.write(to: retained)
        let remove = try await operations.start(descriptor, action: .remove, ownerID: ownerA)
        let removed = try await operations.wait(for: remove, ownerID: ownerA)
        let afterRemoval = try await operations.installed(descriptor)
        let retainedPNG = try Data(contentsOf: retained)
        try require(removed.receipt.outcome == .removed && removed.catalogue == nil && afterRemoval == nil && retainedPNG == actualPNG,
            "Owned removal changed user-retained media or fabricated absence")
        let corrupt = try await operations.start(descriptor, action: .install, ownerID: ownerB, fetch: { _ in Data([1,2,3]) })
        let failed = try await operations.wait(for: corrupt, ownerID: ownerB)
        guard case .failed = failed.receipt.outcome else { throw Failure(message: "Corrupt owned install did not report failure") }
        let afterFailure = try await operations.installed(descriptor)
        try require(failed.catalogue == nil && afterFailure == nil, "Failed owned install fabricated available pictures")
        print("PASS shared pack owner retains cancellation lease, fences owner/run IDs, and reports real install/offline/remove/failure receipts")
    }

    static func expandedPacks(directory: URL, legacyZIP: Data, mappingURL: URL) async throws {
        let mapping = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: mappingURL))
        let descriptors = try StudioImagePackCache.descriptors(directory: directory)
        try require(descriptors.count == 6 && descriptors.map(\.imageCount) == [458, 615, 391, 135, 160, 59], "Expanded descriptor counts changed")
        try require(Set(mapping.keys) == Set(descriptors.dropFirst().map(\.id)), "Expanded fixture mapping is incomplete or contains unexpected packs")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-expanded-packs-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = StudioImagePackCache(root: root)
        let bundled = try StudioImageCatalogue(directory: directory)
        var images = bundled.images
        var retained: [(StudioImagePackCache.Descriptor, StudioImageCatalogue, Data)] = []
        for descriptor in descriptors {
            let archive: Data
            if descriptor.additional == nil { archive = legacyZIP }
            else { archive = try Data(contentsOf: URL(fileURLWithPath: mapping[descriptor.id]!)) }
            let installed = try await cache.download(descriptor, fetch: { _ in archive })
            try require(installed.images.count == descriptor.imageCount, "Actual pack count differs from descriptor")
            for image in installed.images { _ = try installed.checkedPNG(image) }
            let representative = try installed.checkedPNG(installed.images[0])
            retained.append((descriptor, installed, representative)); images += installed.images
        }
        try require(images.count == 2061 && Set(images.map(\.id)).count == 2061, "False combined ID count")
        try require(Set(images.map { "\($0.width):\($0.height):\($0.pixelSHA256)" }).count == 2061, "Duplicate decoded pictures inflated combined count")
        print("PASS all six actual publisher packs and bundled originals yield2061 distinct ImageIO-verified pictures")
        let reopened = StudioImagePackCache(root: root)
        for (descriptor, installed, _) in retained {
            let offline = try await reopened.installed(descriptor)
            try require(offline?.images == installed.images, "Cold cache reopen changed artwork")
            _ = try await reopened.download(descriptor, fetch: { _ in throw Failure(message: "Offline expansion used transport") })
            if descriptor.mayContainWeapons {
                try require(installed.search("", includeCartoonWeapons: false).isEmpty, "Uncurated mixed pack bypassed weapons filter")
            }
            if descriptor.id == "kenney.smoke-particles.v1" {
                try require(installed.search("smoke", category: .effects, includeCartoonWeapons: false).count == 59, "Actual effect category/tag routing failed")
            }
        }
        print("PASS all optional packs cold reopen offline with actual categories and conservative advisory filtering")
        for (descriptor, installed, representative) in retained where descriptor.additional != nil {
            let exportedOriginal = root.deletingLastPathComponent().appendingPathComponent("sdi-kept-original-" + UUID().uuidString + ".png")
            try representative.write(to: exportedOriginal)
            defer { try? FileManager.default.removeItem(at: exportedOriginal) }
            let attribution = try installed.attribution(for: installed.images[0])
            try require(attribution["sourceArchiveSHA256"] == descriptor.archiveSHA256 && attribution["license"] == "CC0-1.0", "Pack original lost provenance")
            try await reopened.remove(descriptor)
            let absent = try await reopened.installed(descriptor)
            let kept = try Data(contentsOf: exportedOriginal)
            try require(absent == nil && kept == representative, "Pack removal deleted separately retained original")
            let legacy = try await reopened.installed(descriptors[0])
            try require(legacy?.images.count == 458, "Removing new pack disturbed original scenery")
        }
        print("PASS independent pack removal preserves legacy pack and separately owned originals/attribution")
        for descriptor in descriptors.dropFirst() {
            let archive = try Data(contentsOf: URL(fileURLWithPath: mapping[descriptor.id]!))
            var corrupted = archive; corrupted[100] ^= 1
            let bad = corrupted
            do { _ = try await reopened.download(descriptor, fetch: { _ in bad }); throw Failure(message: "Corrupt expanded ZIP accepted") }
            catch StudioImagePackCache.PackError.invalid { }
            let after = try await reopened.installed(descriptor)
            try require(after == nil, "Corruption published expanded pack")
            let checkpoint = CropCheckpoint(root: root)
            let task = Task { try await reopened.download(descriptor, fetch: { _ in archive }, checkpoint: { try checkpoint.check() }) }
            do { _ = try await task.value; throw Failure(message: "Expanded install ignored cancellation") }
            catch is CancellationError { }
            try require(checkpoint.observed > 0, "Expanded cancellation never reached real PNG writes")
            let cancelled = try await reopened.installed(descriptor)
            try require(cancelled == nil, "Cancelled expanded pack published")
        }
        print("PASS each expanded original ZIP rejects corruption and cancels during real staged PNG installation")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptors[1])) as! [String: Any]
        var extra = object["additional"] as! [String: Any]
        var rows = extra["entries"] as! [[String: Any]]
        rows[0]["path"] = "../unapproved.png"; extra["entries"] = rows; object["additional"] = extra
        let forged = try JSONDecoder().decode(StudioImagePackCache.Descriptor.self, from: JSONSerialization.data(withJSONObject: object))
        do { _ = try await reopened.download(forged, fetch: { _ in throw Failure(message: "Forged entry reached transport") }); throw Failure(message: "Forged entry accepted") }
        catch StudioImagePackCache.PackError.invalid { }
        var tagObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptors[1])) as! [String: Any]
        var tagExtra = tagObject["additional"] as! [String: Any]
        var tagRows = tagExtra["entries"] as! [[String: Any]]
        let originalTags = tagRows[0]["tags"] as! [String]
        try require(originalTags.count > 1, "Tag-boundary fixture requires multiple tags")
        tagRows[0]["tags"] = [originalTags.joined(separator: "|")]
        tagExtra["entries"] = tagRows; tagObject["additional"] = tagExtra
        let forgedTags = try JSONDecoder().decode(StudioImagePackCache.Descriptor.self, from: JSONSerialization.data(withJSONObject: tagObject))
        do { _ = try await reopened.download(forgedTags, fetch: { _ in throw Failure(message: "Forged tag boundaries reached transport") }); throw Failure(message: "Tag boundary collision accepted") }
        catch StudioImagePackCache.PackError.invalid { }
        let modifiedDirectory = root.appendingPathComponent("modified-descriptors")
        try FileManager.default.createDirectory(at: modifiedDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: directory.appendingPathComponent("remote-pack.json"), to: modifiedDirectory.appendingPathComponent("remote-pack.json"))
        try Data("[]".utf8).write(to: modifiedDirectory.appendingPathComponent("additional-packs.json"))
        do { _ = try StudioImagePackCache.descriptors(directory: modifiedDirectory); throw Failure(message: "Unpinned descriptor resource accepted") }
        catch StudioImagePackCache.PackError.invalid { }
        print("PASS expanded resource and entry metadata cannot redirect or widen trusted archive paths")
    }

}
