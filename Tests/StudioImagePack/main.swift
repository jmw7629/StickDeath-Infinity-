import Foundation
import ImageIO

struct Failure: Error { let message: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(message: message) }
}
actor Calls { var count = 0; func record() { count += 1 } }

final class PackTransportStub: URLProtocol {
    enum Mode { case bytes(Data), redirect }
    private static let lock = NSLock()
    private static var mode: Mode = .bytes(Data())
    private static var urls: [String] = []
    static func configure(_ value: Mode) { lock.lock(); mode = value; urls = []; lock.unlock() }
    static var requests: [String] { lock.lock(); defer { lock.unlock() }; return urls }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let mode = Self.mode; Self.urls.append(request.url!.absoluteString); Self.lock.unlock()
        switch mode {
        case .bytes(let bytes):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/zip"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Separate chunks exercise AsyncBytes' actual streaming bound.
            for offset in stride(from: 0, to: bytes.count, by: 8192) {
                client?.urlProtocol(self, didLoad: bytes.subdata(in: offset..<min(offset+8192, bytes.count)))
            }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect:
            let destination = URL(string: "https://example.invalid/disallowed.zip")!
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
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
        print("PASS actual session delegate refuses redirect before destination request")
        print("STUDIO_IMAGE_PACK_TESTS=PASS groups=14")
    }
}
