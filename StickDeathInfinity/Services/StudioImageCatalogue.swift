import Foundation
import CryptoKit
import ImageIO
import Darwin
import Compression

/// Bundled, curated artwork only. Loading or searching this catalogue never
/// changes a project or fetches a URL. Additions must use the Studio importer.
struct StudioImageCatalogue: Sendable {
    /// Trusted application-release policy. Never decoded from a downloaded catalogue,
    /// user defaults, project, or provider response. Updates cannot roll back a revision.
    final class ReleasePolicy: @unchecked Sendable {
        struct Quarantine: Equatable, Sendable {
            let assetID: String
            let sha256: String
            let reason: String
        }
        private let lock = NSLock()
        private var revision: Int
        private var records: [Quarantine]
        static let bundled = ReleasePolicy()
        private init() { revision = 1; records = [] }
        init(revision: Int, quarantined: [Quarantine]) throws {
            try Self.validate(revision, quarantined)
            self.revision = revision; self.records = quarantined
        }
        private static func validate(_ revision: Int, _ records: [Quarantine]) throws {
            guard (1...1_000_000).contains(revision), records.count <= 5000,
                  Set(records.map { $0.assetID + ":" + $0.sha256 }).count == records.count,
                  records.allSatisfy({ StudioImageCatalogue.identifier($0.assetID)
                    && StudioImageCatalogue.hash($0.sha256)
                    && StudioImageCatalogue.label($0.reason, limit: 240)
                    && $0.reason.utf8.count <= 960 }) else { throw CatalogueError.invalid }
        }
        // Updates share the editor's executor. No await occurs between its
        // final availability check and the synchronous document commit.
        @MainActor func advance(revision next: Int, quarantined: [Quarantine]) throws {
            try Self.validate(next, quarantined)
            lock.lock(); defer { lock.unlock() }
            guard next > revision else { throw CatalogueError.invalid }
            revision = next; records = quarantined
        }
        var currentRevision: Int { lock.lock(); defer { lock.unlock() }; return revision }
        func permits(_ image: Image) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return !records.contains { $0.assetID == image.id && $0.sha256 == image.sha256 }
        }
    }
    enum Category: String, Codable, CaseIterable, Sendable { case props, scenery, effects }
    enum ContentAdvisory: String, Codable, Sendable { case none, cartoonWeapons }
    struct License: Codable, Equatable, Sendable {
        let id: String
        let author: String
        let sourceURL: String
        let license: String
        let licenseURL: String
        let attribution: String
        let licenseFilename: String
        let licenseSHA256: String
        let licenseByteCount: Int
        let sourceArchiveSHA256: String
    }
    struct Image: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let category: Category
        let tags: [String]
        let contentAdvisory: ContentAdvisory
        let licenseID: String
        let originalSHA256: String
        let sha256: String
        let pixelSHA256: String
        let filename: String
        let byteCount: Int
        let width: Int
        let height: Int
    }
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let catalogueRevision: Int?
        let licenses: [License]
        let images: [Image]
    }
    static let maximumManifestBytes = 16 * 1024 * 1024
    static let maximumImageBytes = 16 * 1024 * 1024
    let catalogueRevision: Int
    private let releasePolicy: ReleasePolicy
    var availableImages: [Image] { images.filter { releasePolicy.permits($0) } }
    func requireAvailable(_ image: Image) throws {
        guard images.contains(image) else { throw CatalogueError.invalid }
        guard releasePolicy.permits(image) else { throw CatalogueError.quarantined }
    }
    let images: [Image]
    let licenses: [License]
    private let directory: URL

    init(directory: URL, releasePolicy: ReleasePolicy = .bundled) throws {
        self.releasePolicy = releasePolicy
        guard directory.isFileURL else { throw CatalogueError.unavailable }
        self.directory = directory.standardizedFileURL
        let data = try Self.readFile(directory.appendingPathComponent("catalogue.json"), limit:Self.maximumManifestBytes)
        let manifest = try JSONDecoder().decode(Manifest.self,from:data)
        catalogueRevision = manifest.catalogueRevision ?? 1
        guard (1...1_000_000).contains(catalogueRevision), manifest.schemaVersion == 1, (1...5000).contains(manifest.images.count),
              (1...100).contains(manifest.licenses.count),
              Set(manifest.licenses.map(\.id)).count == manifest.licenses.count,
              Set(manifest.images.map(\.id)).count == manifest.images.count,
              Set(manifest.images.map(\.sha256)).count == manifest.images.count,
              Set(manifest.images.map { "\($0.width):\($0.height):\($0.pixelSHA256)" }).count == manifest.images.count
        else { throw CatalogueError.invalid }
        for item in manifest.licenses {
            try Task.checkCancellation()
            guard Self.identifier(item.id), Self.label(item.author), Self.label(item.attribution,limit:500),
                  item.license == "CC0-1.0", item.licenseURL == "https://creativecommons.org/publicdomain/zero/1.0/",
                  Self.hash(item.licenseSHA256), Self.hash(item.sourceArchiveSHA256),
                  item.licenseFilename == item.licenseSHA256+".txt", (1...65536).contains(item.licenseByteCount),
                  let url=URL(string:item.sourceURL),url.scheme=="https",url.host=="kenney.nl",
                  url.user==nil,url.password==nil,url.port==nil,url.query==nil,url.fragment==nil,
                  url.path.hasPrefix("/assets/"),url.path.count>8
            else { throw CatalogueError.invalid }
            let text=try Self.readFile(directory.appendingPathComponent(item.licenseFilename),limit:65536)
            guard text.count==item.licenseByteCount,Self.digest(text)==item.licenseSHA256,
                  let license=String(data:text,encoding:.utf8),license.contains("CC0"),license.contains("Kenney")
            else { throw CatalogueError.invalid }
        }
        let licenses=Set(manifest.licenses.map(\.id))
        for item in manifest.images {
            try Task.checkCancellation()
            guard Self.identifier(item.id), Self.label(item.title),licenses.contains(item.licenseID),
                  item.tags.count<=20,Set(item.tags).count==item.tags.count,item.tags.allSatisfy({Self.label($0,limit:60)}),
                  Self.hash(item.sha256),Self.hash(item.originalSHA256),Self.hash(item.pixelSHA256),
                  item.filename==item.sha256+".png",(1...Self.maximumImageBytes).contains(item.byteCount),
                  (1...4096).contains(item.width),(1...4096).contains(item.height),item.width*item.height<=16_777_216
            else { throw CatalogueError.invalid }
        }
        images=manifest.images;self.licenses=manifest.licenses
    }
    private init(verifiedImages: [Image], verifiedLicenses: [License], directory: URL, revision: Int, releasePolicy: ReleasePolicy) {
        images = verifiedImages; licenses = verifiedLicenses; self.directory = directory
        catalogueRevision = revision; self.releasePolicy = releasePolicy
    }
    /// Only the verified installer uses this after an atomic directory rename.
    fileprivate func relocated(to directory: URL) -> Self {
        Self(verifiedImages: images, verifiedLicenses: licenses, directory: directory, revision: catalogueRevision, releasePolicy: releasePolicy)
    }
    static func bundled(in bundle: Bundle = .main) throws -> Self {
        guard let url=bundle.url(forResource:"StudioImages",withExtension:nil) else { throw CatalogueError.unavailable }
        return try Self(directory:url)
    }
    static func loadBundled(in bundle: Bundle = .main) async throws -> Self {
        guard let directory = bundle.url(forResource: "StudioImages", withExtension: nil) else {
            throw CatalogueError.unavailable
        }
        return try await load(directory: directory)
    }
    /// This URL is only an input to the existing importer. The import session
    /// compares its copied original bytes with checkedPNG before showing preview.
    func sourceURL(for image: Image) throws -> URL {
        try requireAvailable(image)
        guard images.contains(image) else { throw CatalogueError.invalid }
        return directory.appendingPathComponent(image.filename)
    }
    func attribution(for image: Image) throws -> [String: String] {
        try requireAvailable(image)
        guard images.contains(image), let license = licenses.first(where: { $0.id == image.licenseID }) else {
            throw CatalogueError.invalid
        }
        return ["assetID": image.id, "author": license.author, "sourceURL": license.sourceURL,
                "license": license.license, "licenseURL": license.licenseURL,
                "attribution": license.attribution, "originalSHA256": image.sha256,
                "sourceArchiveSHA256": license.sourceArchiveSHA256]
    }
    static func load(directory: URL) async throws -> Self {
        try Task.checkCancellation()
        let task=Task.detached(priority:.userInitiated) {
            try Task.checkCancellation();let result=try Self(directory:directory)
            try Task.checkCancellation();return result
        }
        return try await withTaskCancellationHandler {
            let result=try await task.value;try Task.checkCancellation();return result
        } onCancel: { task.cancel() }
    }
    func search(_ query: String,category: Category? = nil,includeCartoonWeapons: Bool = true) -> [Image] {
        let terms=query.split(whereSeparator:\.isWhitespace).map(String.init)
        return availableImages.filter { item in
            (category==nil || item.category==category) && (includeCartoonWeapons || item.contentAdvisory == .none) &&
            terms.allSatisfy { (item.title+" "+item.category.rawValue+" "+item.tags.joined(separator:" ")).localizedCaseInsensitiveContains($0) }
        }
    }
    /// Pin, hash and decode the actual immutable bytes before any Studio import.
    /// Reject symlinks/FIFOs, mismatched metadata and aliases outside this list.
    func checkedPNG(_ item: Image) throws -> Data {
        try requireAvailable(item)
        return try integrityCheckedPNG(item)
    }
    /// Cache verification must remain possible after quarantine, including removal.
    fileprivate func integrityCheckedPNG(_ item: Image) throws -> Data {
        try Task.checkCancellation()
        guard images.contains(item) else { throw CatalogueError.invalid }
        let data=try Self.readFile(directory.appendingPathComponent(item.filename),limit:Self.maximumImageBytes)
        guard data.count==item.byteCount,Self.digest(data)==item.sha256,
              let source=CGImageSourceCreateWithData(data as CFData,nil),CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetCount(source)==1,
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue==item.width,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue==item.height,
              let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
              image.width==item.width,image.height==item.height,
              let bitmap=CGContext(data:nil,width:item.width,height:item.height,bitsPerComponent:8,bytesPerRow:item.width*4,
                  space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw CatalogueError.invalid }
        bitmap.draw(image,in:CGRect(x:0,y:0,width:item.width,height:item.height))
        guard let bytes=bitmap.data else { throw CatalogueError.invalid }
        let rgba=Data(bytes:bytes,count:item.width*item.height*4)
        guard Self.digest(rgba)==item.pixelSHA256 else { throw CatalogueError.invalid }
        try Task.checkCancellation()
        return data
    }
    private static func readFile(_ url: URL,limit: Int) throws -> Data {
        let fd=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else { throw CatalogueError.invalid };defer { _=Darwin.close(fd) }
        var s=stat()
        guard fstat(fd,&s)==0,s.st_mode & mode_t(S_IFMT)==mode_t(S_IFREG),s.st_size>0,s.st_size<=limit else { throw CatalogueError.invalid }
        let file=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        let data=try file.read(upToCount:Int(s.st_size)+1) ?? Data()
        guard data.count==Int(s.st_size) else { throw CatalogueError.invalid };return data
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private static func hash(_ text: String) -> Bool { text.utf8.count==64 && text.utf8.allSatisfy { (48...57).contains($0)||(97...102).contains($0) } }
    private static func identifier(_ text: String) -> Bool {
        (1...180).contains(text.utf8.count) && text.utf8.allSatisfy { (48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||[45,46,95].contains($0) }
    }
    private static func label(_ text: String,limit: Int = 120) -> Bool {
        !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && text.count<=limit && !text.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)
    }
    enum CatalogueError: LocalizedError {
        case unavailable,invalid,quarantined
        var errorDescription: String? {
            switch self {
            case .quarantined:return "This picture is unavailable for new use. Existing project originals are kept."
            case .unavailable:return "The image library is not installed in this build. You can still import your own pictures."
            case .invalid:return "The image library could not be verified. No artwork was added."
            }
        }
    }
}

/// Device-local catalogue IDs only; never artwork, project data or network state.
struct StudioImageLibraryPreferences {
    private let defaults: UserDefaults
    private let allowed: Set<String>
    private let prefix = "studio.image-library.v1."
    init(defaults: UserDefaults = .standard, allowedIDs: Set<String>) {
        self.defaults = defaults; allowed = allowedIDs
    }
    private func read(_ key: String, limit: Int) -> [String] {
        guard let data = defaults.data(forKey: prefix + key), data.count <= 65536,
              let ids = try? JSONDecoder().decode([String].self, from: data), ids.count <= 512 else { return [] }
        var seen = Set<String>()
        return Array(ids.filter { allowed.contains($0) && seen.insert($0).inserted }.prefix(limit))
    }
    var favorites: [String] { read("favorites", limit: 256) }
    var recent: [String] { read("recent", limit: 50) }
    @discardableResult func toggleFavorite(_ id: String) -> Bool {
        guard allowed.contains(id) else { return false }
        var ids = favorites
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) }
        else { guard ids.count < 256 else { return false }; ids.append(id) }
        guard let data = try? JSONEncoder().encode(ids) else { return false }
        defaults.set(data, forKey: prefix + "favorites"); return true
    }
    func recordPreview(_ id: String) {
        guard allowed.contains(id) else { return }
        let ids = [id] + recent.filter { $0 != id }
        if let data = try? JSONEncoder().encode(Array(ids.prefix(50))) { defaults.set(data, forKey: prefix + "recent") }
    }
    func clearRecent() { defaults.removeObject(forKey: prefix + "recent") }
}

/// A single explicitly requested, publisher-pinned optional pack. Downloaded
/// media is a disposable library copy; Studio imports retain their own originals.
actor StudioImagePackCache {
    struct Tile: Codable, Sendable { let x: Int; let y: Int; let pixelSHA256: String }
    struct Entry: Codable, Sendable {
        let id: String; let title: String; let category: StudioImageCatalogue.Category
        let tags: [String]; let contentAdvisory: StudioImageCatalogue.ContentAdvisory
        let path: String; let sourceSHA256: String; let crop: [Int]?
        let pixelSHA256: String; let width: Int; let height: Int
    }
    struct Additional: Codable, Sendable {
        let sourceURL: String; let licensePath: String; let entries: [Entry]
    }
    struct Descriptor: Codable, Sendable {
        let id: String; let title: String; let archiveURL: String
        let archiveBytes: Int; let archiveSHA256: String; let sheetSHA256: String
        let licenseSHA256: String; let licenseBytes: Int; let tiles: [Tile]
        var additional: Additional? = nil
        var imageIDs: [String] {
            additional?.entries.map(\.id) ?? tiles.map { "kenney.1-bit-scenery.x\($0.x).y\($0.y)" }
        }
        var imageCount: Int { imageIDs.count }
        var mayContainWeapons: Bool { additional?.entries.contains { $0.contentAdvisory == .cartoonWeapons } ?? false }
    }
    enum PackError: LocalizedError {
        case invalid, busy, quota, network
        var errorDescription: String? {
            switch self {
            case .invalid: return "This picture pack could not be verified. No pictures were installed."
            case .busy: return "Another picture-pack operation is still finishing."
            case .quota: return "There is not enough free space for this picture pack."
            case .network: return "The picture pack could not be downloaded. Existing pictures are still available."
            }
        }
    }
    static let shared = StudioImagePackCache()
    static let maximumCacheBytes = 32 * 1024 * 1024
    private let root: URL
    private let releasePolicy: StudioImageCatalogue.ReleasePolicy
    private var busy = false
    init(root: URL? = nil, releasePolicy: StudioImageCatalogue.ReleasePolicy = .bundled) {
        self.releasePolicy = releasePolicy
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudioOptionalImagePacks", isDirectory: true)
    }
    static func descriptor(in bundle: Bundle = .main) throws -> Descriptor {
        guard let dir = bundle.url(forResource: "StudioImages", withExtension: nil) else { throw PackError.invalid }
        return try descriptor(directory: dir)
    }
    static func descriptor(directory: URL) throws -> Descriptor {
        let bytes = try Data(contentsOf: directory.appendingPathComponent("remote-pack.json"))
        guard bytes.count < 128 * 1024,
              digest(bytes) == "6978b7eb815f122b9d1afd9c37de457d523177ae35a3adcd86e7d8a619156c3b" else { throw PackError.invalid }
        return try JSONDecoder().decode(Descriptor.self, from: bytes)
    }
    /// Descriptors ship with the app; downloaded archives cannot add entries or URLs.
    static func descriptors(in bundle: Bundle = .main) throws -> [Descriptor] {
        guard let directory = bundle.url(forResource: "StudioImages", withExtension: nil) else { throw PackError.invalid }
        return try descriptors(directory: directory)
    }
    static func descriptors(directory: URL) throws -> [Descriptor] {
        let legacy = try descriptor(directory: directory)
        let url = directory.appendingPathComponent("additional-packs.json")
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 2 * 1024 * 1024, digest(bytes) == "1dd09bdc3deedc749a0a82900238f353b1c7febadc9a4112feba138ae40ef967" else { throw PackError.invalid }
        let additional = try JSONDecoder().decode([Descriptor].self, from: bytes)
        guard additional.count == 5 else { throw PackError.invalid }
        let all = [legacy] + additional
        for item in all { try validateDescriptor(item) }
        let ids = all.flatMap(\.imageIDs)
        guard Set(all.map(\.id)).count == all.count, Set(ids).count == ids.count,
              ids.count == 1818 else { throw PackError.invalid }
        return all
    }
    private static let additionalPins: [String: String] = [
        "kenney.1-bit-expansion.v1": "854ddf1ce62093add3f5d8d29129d03269acff9d197e64d4cc807fe5c2111731",
        "kenney.1-bit-platformer.v1": "443ced81e47baa84b669eb76a160e55e27e7b26fb4c90867f56948aad29714a8",
        "kenney.monochrome-rpg.v1": "0f9bc8d5ee3cbf4202017055812ba3d31e6ffa74b0744045d69904f4bda74a5d",
        "kenney.micro-roguelike.v1": "d83b113b261a44e5e652f9cf5f076ff8b6a40493c7e9827be048ec3e5932cb55",
        "kenney.smoke-particles.v1": "2721f1036c63f17b89046cfd5a05ae7b3504cd1f0672cbd2f4f57db29dd2c70f"
    ]
    private static func additionalFingerprint(_ descriptor: Descriptor) -> String {
        guard let additional = descriptor.additional else { return "" }
        var values = [descriptor.id, descriptor.title, descriptor.archiveURL, String(descriptor.archiveBytes),
                      descriptor.archiveSHA256, descriptor.sheetSHA256, descriptor.licenseSHA256,
                      String(descriptor.licenseBytes), additional.sourceURL, additional.licensePath]
        for entry in additional.entries {
            values += [entry.id, entry.title, entry.category.rawValue, String(entry.tags.count)]
            values += entry.tags
            values += [entry.contentAdvisory.rawValue, entry.path, entry.sourceSHA256,
                       entry.crop?.map(String.init).joined(separator: ",") ?? "", entry.pixelSHA256,
                       String(entry.width), String(entry.height)]
        }
        return digest(Data(values.map { "\($0.utf8.count):\($0)" }.joined().utf8))
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func validateDescriptor(_ descriptor: Descriptor) throws {
        if let additional = descriptor.additional {
            guard descriptor.tiles.isEmpty, !additional.entries.isEmpty, additional.entries.count <= 2000,
                  additionalPins[descriptor.id] == additionalFingerprint(descriptor) else { throw PackError.invalid }
            return
        }
        guard descriptor.tiles.count == 458 else { throw PackError.invalid }
        let coordinates = descriptor.tiles.map { "\($0.x),\($0.y),\($0.pixelSHA256)\n" }.joined()
        guard descriptor.id == "kenney.1-bit-scenery.v1", descriptor.title == "1-Bit Scenery",
              descriptor.archiveURL == "https://kenney.nl/media/pages/assets/1-bit-pack/aa867a1f37-1677578516/kenney_1-bit-pack.zip", descriptor.archiveBytes == 657579,
              descriptor.archiveSHA256 == "129a0e74e1dc9091a769d5118be5c88780484c7a3771ee33ac9ef0df02583a9a",
              descriptor.sheetSHA256 == "888b96cef0777ce03e9a9f3eb2c7afc02b2eed9c8f4e9e36e9871f8b624d2d00", descriptor.licenseSHA256 == "d861f208cd550a54e6e59be553ef6ac93a84f4a2966d0371d21331b70e54f33d",
              descriptor.licenseBytes == 569, descriptor.tiles.count == 458,
              digest(Data(coordinates.utf8)) == "5ac454a1bf57d2d308f9cff83878dcab25b52aaa8de087bcce8bc14a4f483c7a" else { throw PackError.invalid }
    }
    /// Pin the directory inode without following a final-component symlink.
    /// Recheck after awaits and before traversal/deletion/publication; callbacks
    /// cannot substitute an external directory while a download is suspended.
    private final class DirectoryIdentity {
        let url: URL; let fd: Int32; let device: dev_t; let inode: ino_t
        init(_ url: URL) throws {
            var before = stat()
            guard lstat(url.path, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw PackError.invalid }
            let handle = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard handle >= 0 else { throw PackError.invalid }
            var opened = stat()
            guard fstat(handle, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino else {
                _ = Darwin.close(handle); throw PackError.invalid
            }
            self.url = url; fd = handle; device = opened.st_dev; inode = opened.st_ino
        }
        deinit { _ = Darwin.close(fd) }
        func check() throws {
            var current = stat()
            guard lstat(url.path, &current) == 0, current.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  current.st_dev == device, current.st_ino == inode else { throw PackError.invalid }
        }
    }
    private func rootIdentity(create: Bool) throws -> DirectoryIdentity? {
        guard root.isFileURL else { throw PackError.invalid }
        var metadata = stat()
        if lstat(root.path, &metadata) != 0 {
            guard errno == ENOENT else { throw PackError.invalid }
            guard create else { return nil }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return try DirectoryIdentity(root)
    }
    private func targetIdentity(_ target: URL) throws -> DirectoryIdentity? {
        var metadata = stat()
        if lstat(target.path, &metadata) != 0 {
            guard errno == ENOENT else { throw PackError.invalid }; return nil
        }
        return try DirectoryIdentity(target)
    }
    private func location(_ descriptor: Descriptor) -> URL { root.appendingPathComponent(descriptor.id, isDirectory: true) }
    private func verify(_ descriptor: Descriptor, at directory: URL) throws -> StudioImageCatalogue {
        let catalogue = try StudioImageCatalogue(directory: directory, releasePolicy: releasePolicy)
        if let additional = descriptor.additional {
            guard catalogue.images.count == additional.entries.count, catalogue.licenses.count == 1,
                  catalogue.licenses[0].id == descriptor.id + ".cc0",
                  catalogue.licenses[0].sourceURL == additional.sourceURL,
                  catalogue.licenses[0].author == "Kenney",
                  catalogue.licenses[0].licenseByteCount == descriptor.licenseBytes,
                  catalogue.licenses[0].licenseSHA256 == descriptor.licenseSHA256,
                  catalogue.licenses[0].sourceArchiveSHA256 == descriptor.archiveSHA256 else { throw PackError.invalid }
            for (item, entry) in zip(catalogue.images, additional.entries) {
                try Task.checkCancellation()
                guard item.id == entry.id, item.title == entry.title, item.category == entry.category,
                      item.tags == entry.tags, item.contentAdvisory == entry.contentAdvisory,
                      item.width == entry.width, item.height == entry.height,
                      item.pixelSHA256 == entry.pixelSHA256, item.originalSHA256 == item.sha256,
                      item.licenseID == descriptor.id + ".cc0",
                      entry.crop != nil || item.sha256 == entry.sourceSHA256 else { throw PackError.invalid }
                _ = try catalogue.integrityCheckedPNG(item)
            }
            return catalogue
        }
        guard catalogue.images.count == descriptor.tiles.count, catalogue.licenses.count == 1,
              catalogue.licenses[0].id == "kenney.1-bit-pack.cc0",
              catalogue.licenses[0].author == "Kenney",
              catalogue.licenses[0].sourceURL == "https://kenney.nl/assets/1-bit-pack",
              catalogue.licenses[0].licenseByteCount == descriptor.licenseBytes,
              catalogue.licenses[0].sourceArchiveSHA256 == descriptor.archiveSHA256,
              catalogue.licenses[0].licenseSHA256 == descriptor.licenseSHA256 else { throw PackError.invalid }
        for (item, tile) in zip(catalogue.images, descriptor.tiles) {
            try Task.checkCancellation()
            guard item.id == "kenney.1-bit-scenery.x\(tile.x).y\(tile.y)",
                  item.licenseID == "kenney.1-bit-pack.cc0", item.originalSHA256 == item.sha256,
                  item.category == .scenery, item.contentAdvisory == .none,
                  item.pixelSHA256 == tile.pixelSHA256, item.width == 16, item.height == 16 else { throw PackError.invalid }
            _ = try catalogue.integrityCheckedPNG(item)
        }
        return catalogue
    }
    func installed(_ descriptor: Descriptor) throws -> StudioImageCatalogue? {
        try Self.validateDescriptor(descriptor)
        try Task.checkCancellation()
        guard !busy else { throw PackError.busy }
        guard let ownedRoot = try rootIdentity(create: false) else { return nil }
        let target = location(descriptor)
        guard let ownedTarget = try targetIdentity(target) else { return nil }
        try ownedRoot.check(); try ownedTarget.check()
        _ = try cacheByteCount()
        let verified = try verify(descriptor, at: target)
        try ownedRoot.check(); try ownedTarget.check()
        return verified
    }
    func remove(_ descriptor: Descriptor) throws {
        try Self.validateDescriptor(descriptor)
        guard !busy else { throw PackError.busy }
        try Task.checkCancellation()
        guard let ownedRoot = try rootIdentity(create: false) else { return }
        let target = location(descriptor)
        if let ownedTarget = try targetIdentity(target) {
            try ownedRoot.check(); try ownedTarget.check()
            try FileManager.default.removeItem(at: target)
        }
    }
    /// Closure injection exercises the same installer with local, real publisher
    /// archive fixtures. The UI always uses the bounded pinned network transport.
    func download(_ descriptor: Descriptor,
                  fetch: (@Sendable (Descriptor) async throws -> Data)? = nil,
                  checkpoint: @Sendable () throws -> Void = { try Task.checkCancellation() }) async throws -> StudioImageCatalogue {
        try Self.validateDescriptor(descriptor)
        guard !busy else { throw PackError.busy }; busy = true; defer { busy = false }
        try Task.checkCancellation()
        let fm = FileManager.default
        guard let ownedRoot = try rootIdentity(create: true) else { throw PackError.invalid }
        try ownedRoot.check()
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var rootURL = root; try rootURL.setResourceValues(values)
        // Only disposable staging directories owned by this installer are
        // recovered after interruption. Published packs/projects are untouched.
        for child in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
            let metadata = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if child.lastPathComponent.hasPrefix("stage-"),
               UUID(uuidString: String(child.lastPathComponent.dropFirst(6))) != nil,
               metadata.isDirectory == true, metadata.isSymbolicLink != true {
                let ownedChild = try DirectoryIdentity(child)
                try ownedRoot.check(); try ownedChild.check()
                try fm.removeItem(at: child)
            }
        }
        let attributes = try fm.attributesOfFileSystem(forPath: root.path)
        guard let free = attributes[.systemFreeSize] as? NSNumber,
              free.int64Value >= Int64(Self.maximumCacheBytes * 2) else { throw PackError.quota }
        let target = location(descriptor)
        if let ownedTarget = try targetIdentity(target) {
            try ownedRoot.check(); try ownedTarget.check()
            _ = try cacheByteCount()
            let verified = try verify(descriptor, at: target)
            try ownedRoot.check(); try ownedTarget.check()
            return verified
        }
        guard try cacheByteCount() <= Self.maximumCacheBytes - 8 * 1024 * 1024 else { throw PackError.quota }
        let bytes: Data
        if let fetch { bytes = try await fetch(descriptor) }
        else { bytes = try await Self.fetch(descriptor) }
        try Task.checkCancellation(); try ownedRoot.check()
        guard bytes.count == descriptor.archiveBytes, Self.digest(bytes) == descriptor.archiveSHA256 else { throw PackError.invalid }
        let stage = root.appendingPathComponent("stage-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        let ownedStage = try DirectoryIdentity(stage)
        defer {
            // A substituted root/stage is not ours to remove.
            if (try? ownedRoot.check()) != nil, (try? ownedStage.check()) != nil { try? fm.removeItem(at: stage) }
        }
        try Self.install(bytes, descriptor: descriptor, directory: stage) {
            try checkpoint(); try Task.checkCancellation()
            try ownedRoot.check(); try ownedStage.check()
        }
        let result = try verify(descriptor, at: stage)
        let files = try fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: [.fileSizeKey])
        let size = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        guard size <= 8 * 1024 * 1024, try cacheByteCount() <= Self.maximumCacheBytes else { throw PackError.quota }
        try Task.checkCancellation(); try ownedRoot.check(); try ownedStage.check()
        guard try targetIdentity(target) == nil else { throw PackError.invalid }
        try fm.moveItem(at: stage, to: target)
        // No throwing/cancellation checkpoint after atomic publication.
        return result.relocated(to: target)
    }
    private func cacheByteCount() throws -> Int {
        guard let identity = try rootIdentity(create: false) else { return 0 }
        try identity.check()
        guard let files = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) else { throw PackError.invalid }
        var count = 0, bytes = 0
        for case let file as URL in files {
            try Task.checkCancellation(); count += 1
            guard count <= 5000 else { throw PackError.quota }
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw PackError.invalid }
            if values.isRegularFile == true { bytes += values.fileSize ?? 0 }
            guard bytes <= Self.maximumCacheBytes else { throw PackError.quota }
        }
        try identity.check()
        return bytes
    }
    static func fetch(_ descriptor: Descriptor, protocolClasses: [AnyClass] = []) async throws -> Data {
        try validateDescriptor(descriptor)
        guard let url = URL(string: descriptor.archiveURL), url.scheme == "https", url.host == "kenney.nl",
              descriptor.archiveBytes <= 32 * 1024 * 1024 else { throw PackError.invalid }
        let delegate = StudioImagePackRedirectPolicy()
        let config = URLSessionConfiguration.ephemeral
        if !protocolClasses.isEmpty { config.protocolClasses = protocolClasses }
        config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.cachePolicy = .reloadIgnoringLocalCacheData
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == url,
              response.expectedContentLength == -1 || response.expectedContentLength == descriptor.archiveBytes else { throw PackError.network }
        var bytes = Data(); bytes.reserveCapacity(descriptor.archiveBytes)
        for try await byte in stream {
            try Task.checkCancellation()
            guard bytes.count < descriptor.archiveBytes else { throw PackError.invalid }
            bytes.append(byte)
        }
        return bytes
    }
    private static func install(_ archive: Data, descriptor: Descriptor, directory: URL,
                                checkpoint: () throws -> Void) throws {
        // Only this exact hash-pinned publisher archive is parsed. Central/local
        // entries are never filesystem paths; exactly two known entries are used.
        if descriptor.additional != nil {
            try installAdditional(archive, descriptor: descriptor, directory: directory, checkpoint: checkpoint)
            return
        }
        let entries = try zipEntries(archive)
        guard let license = entries["License.txt"], let sheet = entries["Tilesheet/monochrome-transparent.png"],
              license.count == descriptor.licenseBytes, digest(license) == descriptor.licenseSHA256,
              digest(sheet) == descriptor.sheetSHA256,
              let source = CGImageSourceCreateWithData(sheet as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == 832, image.height == 373 else { throw PackError.invalid }
        let licenseFilename = descriptor.licenseSHA256 + ".txt"
        try license.write(to: directory.appendingPathComponent(licenseFilename), options: .atomic)
        var images: [[String: Any]] = []
        for tile in descriptor.tiles {
            try checkpoint(); try Task.checkCancellation()
            guard let crop = image.cropping(to: CGRect(x: CGFloat(tile.x * 17), y: CGFloat(tile.y * 17), width: 16, height: 16)) else { throw PackError.invalid }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw PackError.invalid }
            CGImageDestinationAddImage(destination, crop, nil)
            guard CGImageDestinationFinalize(destination) else { throw PackError.invalid }
            let png = data as Data, hash = digest(png), filename = hash + ".png"
            try png.write(to: directory.appendingPathComponent(filename), options: .atomic)
            images.append(["id": "kenney.1-bit-scenery.x\(tile.x).y\(tile.y)",
                "title": "1-Bit scenery \(tile.y + 1)–\(tile.x + 1)", "category": "scenery",
                "tags": ["monochrome", "pixel", "scenery", "terrain", "furniture", "1-bit"],
                "contentAdvisory": "none", "licenseID": "kenney.1-bit-pack.cc0",
                "originalSHA256": hash, "sha256": hash, "pixelSHA256": tile.pixelSHA256,
                "filename": filename, "byteCount": png.count, "width": 16, "height": 16])
        }
        let licenseRow: [String: Any] = ["id": "kenney.1-bit-pack.cc0", "author": "Kenney",
            "sourceURL": "https://kenney.nl/assets/1-bit-pack", "license": "CC0-1.0",
            "licenseURL": "https://creativecommons.org/publicdomain/zero/1.0/",
            "attribution": "Art by Kenney (kenney.nl), CC0. Tiles cropped from the original monochrome sheet; x/y tile coordinates are retained in each asset ID.",
            "licenseFilename": licenseFilename, "licenseSHA256": descriptor.licenseSHA256,
            "licenseByteCount": license.count, "sourceArchiveSHA256": descriptor.archiveSHA256]
        let manifest = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "licenses": [licenseRow], "images": images], options: [.sortedKeys])
        try manifest.write(to: directory.appendingPathComponent("catalogue.json"), options: .atomic)
    }
    private static func installAdditional(_ archive: Data, descriptor: Descriptor, directory: URL,
                                          checkpoint: () throws -> Void) throws {
        guard let additional = descriptor.additional else { throw PackError.invalid }
        let allowed = Set(additional.entries.map(\.path) + [additional.licensePath])
        let files = try zipEntries(archive, allowed: allowed)
        guard let license = files[additional.licensePath], license.count == descriptor.licenseBytes,
              digest(license) == descriptor.licenseSHA256 else { throw PackError.invalid }
        let licenseFilename = descriptor.licenseSHA256 + ".txt"
        try license.write(to: directory.appendingPathComponent(licenseFilename), options: .atomic)
        var images: [[String: Any]] = []
        var outputBytes = license.count
        for entry in additional.entries {
            try checkpoint(); try Task.checkCancellation()
            guard let sourceBytes = files[entry.path], digest(sourceBytes) == entry.sourceSHA256,
                  let source = CGImageSourceCreateWithData(sourceBytes as CFData, nil),
                  CGImageSourceGetCount(source) == 1,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PackError.invalid }
            let png: Data
            if let crop = entry.crop {
                guard crop.count == 4, crop[0] >= 0, crop[1] >= 0, crop[2] == entry.width,
                      crop[3] == entry.height, crop[0] + crop[2] <= image.width,
                      crop[1] + crop[3] <= image.height,
                      let cropped = image.cropping(to: CGRect(x: crop[0], y: crop[1], width: crop[2], height: crop[3])) else { throw PackError.invalid }
                let encoded = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else { throw PackError.invalid }
                CGImageDestinationAddImage(destination, cropped, nil)
                guard CGImageDestinationFinalize(destination) else { throw PackError.invalid }
                png = encoded as Data
            } else {
                guard image.width == entry.width, image.height == entry.height else { throw PackError.invalid }
                png = sourceBytes
            }
            outputBytes += png.count
            guard outputBytes <= 8 * 1024 * 1024 else { throw PackError.quota }
            let hash = digest(png), filename = hash + ".png"
            try png.write(to: directory.appendingPathComponent(filename), options: .atomic)
            images.append(["id": entry.id, "title": entry.title, "category": entry.category.rawValue,
                "tags": entry.tags, "contentAdvisory": entry.contentAdvisory.rawValue,
                "licenseID": descriptor.id + ".cc0", "originalSHA256": hash, "sha256": hash,
                "pixelSHA256": entry.pixelSHA256, "filename": filename, "byteCount": png.count,
                "width": entry.width, "height": entry.height])
        }
        let licenseRow: [String: Any] = ["id": descriptor.id + ".cc0", "author": "Kenney",
            "sourceURL": additional.sourceURL, "license": "CC0-1.0",
            "licenseURL": "https://creativecommons.org/publicdomain/zero/1.0/",
            "attribution": "Art by Kenney (kenney.nl), CC0. Original source archive and selected file or tile identity are retained.",
            "licenseFilename": licenseFilename, "licenseSHA256": descriptor.licenseSHA256,
            "licenseByteCount": descriptor.licenseBytes, "sourceArchiveSHA256": descriptor.archiveSHA256]
        let manifest = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "licenses": [licenseRow], "images": images], options: [.sortedKeys])
        guard outputBytes + manifest.count <= 8 * 1024 * 1024 else { throw PackError.quota }
        try checkpoint(); try Task.checkCancellation()
        try manifest.write(to: directory.appendingPathComponent("catalogue.json"), options: .atomic)
    }
    private static func zipEntries(_ bytes: Data, allowed: Set<String> = ["License.txt", "Tilesheet/monochrome-transparent.png"]) throws -> [String: Data] {
        func u16(_ p: Int) throws -> Int { guard p >= 0, p + 2 <= bytes.count else { throw PackError.invalid }; return Int(bytes[p]) | Int(bytes[p+1]) << 8 }
        func u32(_ p: Int) throws -> Int { try u16(p) | u16(p+2) << 16 }
        var offset = 0, result: [String: Data] = [:], count = 0
        while try u32(offset) == 0x04034b50 {
            try Task.checkCancellation(); count += 1
            guard count <= 5000, try u16(offset+6) == 0 else { throw PackError.invalid }
            let method = try u16(offset+8), compressed = try u32(offset+18), expanded = try u32(offset+22)
            let nameLength = try u16(offset+26), extraLength = try u16(offset+28)
            let nameStart = offset+30, start = nameStart+nameLength+extraLength, end = start+compressed
            guard start <= bytes.count, end <= bytes.count, expanded <= 8*1024*1024,
                  let name = String(data: bytes.subdata(in: nameStart..<(nameStart+nameLength)), encoding: .utf8),
                  !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { throw PackError.invalid }
            if allowed.contains(name) {
                guard result[name] == nil, expanded > 0 else { throw PackError.invalid }
                let source = bytes.subdata(in: start..<end)
                let decoded: Data
                if method == 0 { decoded = source }
                else if method == 8 {
                    var output = Data(count: expanded)
                    let decodedCount = output.withUnsafeMutableBytes { destination in
                        source.withUnsafeBytes { source in
                            compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, expanded,
                                source.bindMemory(to: UInt8.self).baseAddress!, compressed, nil, COMPRESSION_ZLIB)
                        }
                    }
                    guard decodedCount == expanded else { throw PackError.invalid }; decoded = output
                } else { throw PackError.invalid }
                guard decoded.count == expanded, result.values.reduce(0, { $0 + $1.count }) + decoded.count <= 8 * 1024 * 1024 else { throw PackError.invalid }; result[name] = decoded
            }
            offset = end
        }
        guard try u32(offset) == 0x02014b50, Set(result.keys) == allowed else { throw PackError.invalid }
        return result
    }
}

private final class StudioImagePackRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
