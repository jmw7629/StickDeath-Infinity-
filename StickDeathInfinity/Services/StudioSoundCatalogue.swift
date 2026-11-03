import Foundation
import CryptoKit
import Darwin

/// Offline, licensed application resources. Only an explicitly added sound is
/// copied into a project's canonical AudioTrack/document history.
struct StudioSoundCatalogue: Sendable {
    struct Sound: Codable, Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let category: String
        let author: String
        let sourceURL: String
        let license: String
        let licenseURL: String
        let originalSHA256: String
        let filename: String
        let sha256: String
        let byteCount: Int
        let duration: Double
        let sampleRate: Double
        let channels: Int
        let waveformPeaks: [Float]
        /// Optional for older catalogues; tags describe curated sound families, not inferred rights.
        let tags: [String]?
        /// Optional measured RMS per peak bin (#192). Absent in catalogues
        /// generated before RMS was recorded; never synthesized from peaks.
        var waveformRMS: [Float]? = nil

        /// Attribution that follows this sound into project exports (#191).
        var attribution: StudioSoundAttribution {
            StudioSoundAttribution(title: title, author: author, sourceURL: sourceURL, license: license,
                                   licenseURL: licenseURL, catalogueSoundID: sha256, originalSHA256: originalSHA256)
        }
    }
    private struct Manifest: Decodable { let schemaVersion: Int; let sounds: [Sound] }
    let sounds: [Sound]
    private let resourceDirectories: [String: URL]
    /// Computed once at load: the text each sound is searched by, the sorted
    /// categories and their sizes. The library re-renders on every timeline
    /// tick while audio plays, so none of this may be rebuilt per render.
    private let searchText: [String]
    let categories: [String]
    let categoryCounts: [String: Int]
    /// Distinguishes reloaded catalogues for result memoization.
    let loadID = UUID()
    static let maximumManifestBytes = 16 * 1024 * 1024

    init(directory: URL) throws {
        guard directory.isFileURL else { throw CatalogueError.unavailable }
        let url = directory.appendingPathComponent("catalogue.json")
        let data = try Self.readRegularFile(url, maximumBytes: Self.maximumManifestBytes)
        let sounds = try Self.decodeManifest(data)
        self.init(validatedSounds: sounds, directories: Dictionary(uniqueKeysWithValues: sounds.map { ($0.id, directory.standardizedFileURL) }))
    }
    fileprivate static func decodeManifest(_ data: Data) throws -> [Sound] {
        guard (1...maximumManifestBytes).contains(data.count) else { throw CatalogueError.invalid }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schemaVersion == 1, (1...5000).contains(manifest.sounds.count),
              Set(manifest.sounds.map(\.id)).count == manifest.sounds.count,
              Set(manifest.sounds.map(\.filename)).count == manifest.sounds.count,
              Set(manifest.sounds.map(\.originalSHA256)).count == manifest.sounds.count else { throw CatalogueError.invalid }
        for sound in manifest.sounds {
            guard Self.hash(sound.sha256), Self.hash(sound.originalSHA256), sound.id == sound.sha256,
                  ["wav", "aiff", "aifc", "caf", "m4a", "mp3", "aac"].contains((sound.filename as NSString).pathExtension),
                  sound.filename == sound.sha256 + "." + (sound.filename as NSString).pathExtension,
                  (1...StudioAudioImportService.maximumEncodedBytes).contains(sound.byteCount),
                  sound.duration.isFinite, sound.duration > 0, sound.duration <= 300,
                  sound.sampleRate.isFinite, (8000...192000).contains(sound.sampleRate), (1...2).contains(sound.channels),
                  sound.waveformPeaks.count == 256, sound.waveformPeaks.contains(where: { $0 > 0 }),
                  sound.waveformPeaks.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  Self.validRMS(sound.waveformRMS, peaks: sound.waveformPeaks),
                  [sound.title, sound.category, sound.author].allSatisfy(Self.label),
                  Self.validTags(sound.tags),
                  sound.license == "CC0-1.0", sound.licenseURL == "https://creativecommons.org/publicdomain/zero/1.0/",
                  let source = URL(string: sound.sourceURL), source.scheme == "https", source.user == nil,
                  source.password == nil, let host = source.host, ["kenney.nl", "opengameart.org"].contains(host) else { throw CatalogueError.invalid }
        }
        return manifest.sounds
    }
    private init(validatedSounds: [Sound], directories: [String: URL]) {
        sounds = validatedSounds; resourceDirectories = directories
        searchText = sounds.map { $0.title + " " + $0.category + " " + $0.author + " " + ($0.tags ?? []).joined(separator: " ") }
        categoryCounts = Dictionary(sounds.map { ($0.category, 1) }, uniquingKeysWith: +)
        categories = categoryCounts.keys.sorted()
    }
    fileprivate func relocated(to directory: URL) -> Self {
        Self(validatedSounds: sounds, directories: Dictionary(uniqueKeysWithValues: sounds.map { ($0.id, directory) }))
    }
    /// Bundled entries win collisions, followed by the stable pack order. Both
    /// shipped and publisher digests participate, so a transcoded duplicate is
    /// never counted as another usable sound. Each entry retains its own root.
    static func merging(_ catalogues: [Self]) -> Self {
        var ids = Set<String>(), originals = Set<String>(), sounds: [Sound] = [], directories: [String: URL] = [:]
        for catalogue in catalogues {
            for sound in catalogue.sounds where !ids.contains(sound.id) && !originals.contains(sound.originalSHA256) {
                ids.insert(sound.id); originals.insert(sound.originalSHA256); sounds.append(sound)
                directories[sound.id] = catalogue.resourceDirectories[sound.id]
            }
        }
        return Self(validatedSounds: sounds, directories: directories)
    }
    fileprivate static func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CatalogueError.invalid }; defer { _ = Darwin.close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_size > 0, metadata.st_size <= maximumBytes else { throw CatalogueError.invalid }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var bytes = Data()
        while bytes.count <= maximumBytes {
            try Task.checkCancellation()
            let next = try file.read(upToCount: min(65_536, maximumBytes + 1 - bytes.count)) ?? Data()
            if next.isEmpty { break }; bytes.append(next)
        }
        guard bytes.count == metadata.st_size, bytes.count <= maximumBytes else { throw CatalogueError.invalid }
        return bytes
    }

    static func bundled(in bundle: Bundle = .main) throws -> Self {
        guard let directory = bundle.url(forResource: "StudioSounds", withExtension: nil) else { throw CatalogueError.unavailable }
        return try Self(directory: directory)
    }
    /// Decode and validate the sizeable offline manifest away from the UI actor.
    /// A disappearing library cancels its own task; no late result is published.
    static func load(directory: URL) async throws -> Self {
        try Task.checkCancellation()
        let loading = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let catalogue = try Self(directory: directory)
            try Task.checkCancellation()
            return catalogue
        }
        return try await withTaskCancellationHandler {
            let catalogue = try await loading.value
            try Task.checkCancellation()
            return catalogue
        } onCancel: {
            loading.cancel()
        }
    }
    static func loadBundled(in bundle: Bundle = .main) async throws -> Self {
        try Task.checkCancellation()
        guard let directory = bundle.url(forResource: "StudioSounds", withExtension: nil) else { throw CatalogueError.unavailable }
        return try await load(directory: directory)
    }
    static func loadAvailable(in bundle: Bundle = .main) async throws -> Self {
        let bundled = try await loadBundled(in: bundle)
        return try await StudioSoundPackCache.shared.loadAvailable(bundled: bundled, descriptors: StudioSoundPackCache.descriptors(in: bundle))
    }
    /// Shipped metadata also credits optional sounds received in a project on
    /// a device that never installed their pack. Metadata never enables audio
    /// availability. Retained install receipts remain a legacy fallback.
    static func loadAvailableAttributions(in bundle: Bundle = .main) async throws -> [String: StudioSoundAttribution] {
        let bundled = try await loadBundled(in: bundle)
        guard let directory = bundle.url(forResource: "StudioSounds", withExtension: nil) else { throw CatalogueError.unavailable }
        return try await StudioSoundPackCache.shared.attributions(bundled: bundled,
            descriptors: StudioSoundPackCache.descriptors(in: bundle), metadataDirectory: directory)
    }
    /// Library attribution for the shipped file with this SHA-256, or nil for
    /// audio that did not come from the catalogue (#191).
    func attribution(forSHA256 digest: String) -> StudioSoundAttribution? {
        sounds.first { $0.sha256 == digest }?.attribution
    }
    /// Digest → attribution table for bulk credit resolution without repeated scans.
    var attributionsByDigest: [String: StudioSoundAttribution] {
        Dictionary(uniqueKeysWithValues: sounds.map { ($0.sha256, $0.attribution) })
    }
    enum DurationFilter: String, CaseIterable, Identifiable {
        case any = "Any duration", short = "Under 1 second", medium = "1–5 seconds", long = "Over 5 seconds"
        var id: String { rawValue }
        func includes(_ duration: Double) -> Bool {
            switch self {
            case .any: return true
            case .short: return duration < 1
            case .medium: return (1...5).contains(duration)
            case .long: return duration > 5
            }
        }
    }
    enum Sort: String, CaseIterable, Identifiable {
        case catalogue = "Library order", name = "Name", shortest = "Shortest first", longest = "Longest first"
        var id: String { rawValue }
    }
    func search(_ query: String, category: String?, duration: DurationFilter = .any, sort: Sort = .catalogue) -> [Sound] {
        let terms = query.prefix(256).split(whereSeparator: \.isWhitespace).map(String.init)
        let matches = sounds.indices.filter { index in
            let sound = sounds[index]
            return duration.includes(sound.duration) && (category == nil || sound.category == category) && terms.allSatisfy {
                searchText[index].localizedCaseInsensitiveContains($0)
            }
        }.map { sounds[$0] }
        guard sort != .catalogue else { return matches }
        return matches.sorted { first, second in
            if sort == .shortest && first.duration != second.duration { return first.duration < second.duration }
            if sort == .longest && first.duration != second.duration { return first.duration > second.duration }
            let order = first.title.localizedStandardCompare(second.title)
            return order == .orderedSame ? first.id < second.id : order == .orderedAscending
        }
    }

    /// Pin the resource bytes before invoking the same real importer as Files.
    /// Unknown metadata objects, symlinks, corrupt bytes and missing files fail.
    func checkedResource(_ sound: Sound, checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> (url: URL, data: Data) {
        try checkCancellation()
        guard sounds.contains(sound) else { throw CatalogueError.invalid }
        guard let directory = resourceDirectories[sound.id] else { throw CatalogueError.invalid }
        let url = directory.appendingPathComponent(sound.filename)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CatalogueError.invalid }
        defer { _ = Darwin.close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_size == sound.byteCount else { throw CatalogueError.invalid }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data(); data.reserveCapacity(sound.byteCount)
        var digest = SHA256()
        while data.count <= sound.byteCount {
            try checkCancellation()
            let chunk = try file.read(upToCount: min(65_536, sound.byteCount + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk); digest.update(data: chunk)
        }
        try checkCancellation()
        guard data.count == sound.byteCount, digest.finalize().map({ String(format: "%02x", $0) }).joined() == sound.sha256 else { throw CatalogueError.invalid }
        return (url, data)
    }
    /// Own one cancellable read/hash task; never publish unchecked resource bytes.
    func loadResource(_ sound: Sound) async throws -> Data {
        let loading = Task.detached(priority: .userInitiated) { try self.checkedResource(sound).data }
        return try await withTaskCancellationHandler {
            let data = try await loading.value
            try Task.checkCancellation()
            return data
        } onCancel: { loading.cancel() }
    }
    func previewTrack(_ sound: Sound) throws -> AudioTrack {
        let checked = try checkedResource(sound)
        return AudioTrack(id: UUID(), name: sound.title, format: (sound.filename as NSString).pathExtension,
                          audioData: checked.data, startTime: 0, duration: sound.duration)
    }
    private static func validRMS(_ rms: [Float]?, peaks: [Float]) -> Bool {
        guard let rms else { return true }
        return rms.count == peaks.count && zip(rms, peaks).allSatisfy { value, peak in
            value.isFinite && (0...1).contains(value) && value <= peak + 0.000001
        }
    }
    private static func validTags(_ tags: [String]?) -> Bool {
        guard let tags else { return true }
        return tags.count <= 16 && Set(tags).count == tags.count && tags.allSatisfy { tag in
            !tag.isEmpty && tag.utf8.count <= 32 && tag.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            } && tag.first != "-" && tag.last != "-"
        }
    }
    private static func hash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func label(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 120 && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    enum CatalogueError: LocalizedError {
        case unavailable, invalid
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The sound library is not installed in this build. You can still import audio from Files."
            case .invalid: return "This sound library could not be verified. No audio was added or played."
            }
        }
    }
}

/// Optional licensed sounds are downloaded file-by-file into a disposable
/// device cache, never a project folder. The app ships the descriptor pin; the
/// pinned manifest in turn pins every audio byte and all attribution metadata.
actor StudioSoundPackCache {
    struct Descriptor: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let manifestURL: String
        let manifestBytes: Int
        let manifestSHA256: String
        let baseURL: String
        let soundCount: Int
        let totalAudioBytes: Int
    }
    enum Status: Equatable, Sendable {
        case notInstalled
        case installed(soundCount: Int, bytes: Int)
        case corrupt
    }
    struct Inspection: Equatable, Sendable {
        let bytes: Int
        let soundCount: Int
        let packs: [String: Status]
    }
    struct Limits: Sendable {
        var cacheBytes = 128 * 1024 * 1024
        var cacheClips = 512
        var reserveBytes = 16 * 1024 * 1024
        static let production = Self()
    }
    enum PackError: LocalizedError {
        case invalid, busy, quota, network
        var errorDescription: String? {
            switch self {
            case .invalid: return "This sound pack could not be verified. Remove it and try downloading again."
            case .busy: return "Another sound-pack operation is still finishing."
            case .quota: return "There is not enough cache space for this sound pack."
            case .network: return "The sound pack could not be downloaded. Your existing sounds remain available."
            }
        }
    }
    static let shared = StudioSoundPackCache()
    static let maximumManifestBytes = 512 * 1024
    static let maximumPackSounds = 128
    static let maximumPackBytes = 64 * 1024 * 1024
    static let maximumFileBytes = 16 * 1024 * 1024
    private let root: URL
    private let trustedDescriptors: [Descriptor]?
    private let limits: Limits
    private var busy = false
    /// Explicit descriptors are for an isolated trusted fixture. Product calls
    /// use the compiled descriptor-file pin, with no user preferences/URLs.
    init(root: URL? = nil, trustedDescriptors: [Descriptor]? = nil, limits: Limits = .production) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudioOptionalSoundPacks", isDirectory: true)
        self.trustedDescriptors = trustedDescriptors; self.limits = limits
    }
    static func descriptors(in bundle: Bundle = .main) throws -> [Descriptor] {
        guard let directory = bundle.url(forResource: "StudioSounds", withExtension: nil) else { throw PackError.invalid }
        return try descriptors(directory: directory)
    }
    static func descriptors(directory: URL) throws -> [Descriptor] {
        let url = directory.appendingPathComponent("sound-packs.json")
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 { guard errno == ENOENT else { throw PackError.invalid }; return [] }
        let data = try StudioSoundCatalogue.readRegularFile(url, maximumBytes: 32 * 1024)
        guard digest(data) == descriptorSHA256 else { throw PackError.invalid }
        let result = try JSONDecoder().decode([Descriptor].self, from: data)
        guard result.count == 2, Set(result.map(\.id)).count == result.count else { throw PackError.invalid }
        for descriptor in result { try validateDescriptor(descriptor) }
        return result
    }
    private static let descriptorSHA256 = "e5a58b24d84d1112481f54676f55b2cdb48ecc8929bb32e691dd1ea823bbbf66"
    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validateDescriptor(_ item: Descriptor) throws {
        guard !item.id.isEmpty, item.id.utf8.count <= 80,
              item.id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              item.id.first != ".", item.id.last != ".", !item.id.contains(".."),
              !item.title.isEmpty, item.title.count <= 120,
              !item.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (1...maximumManifestBytes).contains(item.manifestBytes), isDigest(item.manifestSHA256),
              (1...maximumPackSounds).contains(item.soundCount),
              (1...maximumPackBytes).contains(item.totalAudioBytes),
              let manifest = URL(string: item.manifestURL), let base = URL(string: item.baseURL),
              allowedURL(manifest), allowedURL(base), base.absoluteString.hasSuffix("/"),
              manifest.absoluteString == base.appendingPathComponent("catalogue.json").absoluteString else { throw PackError.invalid }
    }
    /// Strict canonical HTTPS routes only. Redirect requests are rebuilt below,
    /// stripping credentials, cookies and untrusted request headers entirely.
    fileprivate static func allowedURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil,
              let host = parts.host, host == host.lowercased(),
              !parts.percentEncodedPath.contains("%"), !parts.path.contains("\\"),
              !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              url.absoluteString == parts.string else { return false }
        if host == "raw.githubusercontent.com" {
            return parts.path.hasPrefix("/jmw7629/StickDeath-Infinity-/") && parts.path.split(separator: "/").count >= 5
        }
        return ["kenney.nl", "opengameart.org"].contains(host) && parts.path.hasPrefix("/")
    }
    private func authorize(_ descriptor: Descriptor) throws {
        try Self.validateDescriptor(descriptor)
        let approved = try trustedDescriptors ?? Self.descriptors()
        guard approved.contains(descriptor) else { throw PackError.invalid }
    }
    private final class DirectoryIdentity {
        let url: URL; let fd: Int32; let device: dev_t; let inode: ino_t
        init(_ url: URL) throws {
            var before = stat()
            guard lstat(url.path, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw PackError.invalid }
            let opened = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard opened >= 0 else { throw PackError.invalid }
            var after = stat()
            guard fstat(opened, &after) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino else {
                _ = Darwin.close(opened); throw PackError.invalid
            }
            self.url = url; fd = opened; device = after.st_dev; inode = after.st_ino
        }
        deinit { _ = Darwin.close(fd) }
        func check() throws {
            var current = stat()
            guard lstat(url.path, &current) == 0, current.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  current.st_dev == device, current.st_ino == inode else { throw PackError.invalid }
        }
    }
    private func identity(_ url: URL, create: Bool = false) throws -> DirectoryIdentity? {
        guard url.isFileURL else { throw PackError.invalid }
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            guard errno == ENOENT else { throw PackError.invalid }
            guard create else { return nil }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return try DirectoryIdentity(url)
    }
    private func location(_ descriptor: Descriptor) -> URL { root.appendingPathComponent(descriptor.id, isDirectory: true) }
    private func receiptLocation(_ descriptor: Descriptor) -> URL { root.appendingPathComponent("credit-" + descriptor.id + ".json") }
    private func checkedManifest(_ descriptor: Descriptor, bytes: Data) throws -> [StudioSoundCatalogue.Sound] {
        guard bytes.count == descriptor.manifestBytes, Self.digest(bytes) == descriptor.manifestSHA256 else { throw PackError.invalid }
        let sounds = try StudioSoundCatalogue.decodeManifest(bytes)
        guard sounds.count == descriptor.soundCount,
              sounds.allSatisfy({ $0.byteCount <= Self.maximumFileBytes }),
              sounds.reduce(0, { $0 + $1.byteCount }) == descriptor.totalAudioBytes else { throw PackError.invalid }
        return sounds
    }
    private func verify(_ descriptor: Descriptor, at directory: URL) throws -> StudioSoundCatalogue {
        let pinned = try DirectoryIdentity(directory)
        let manifest = try StudioSoundCatalogue.readRegularFile(directory.appendingPathComponent("catalogue.json"), maximumBytes: Self.maximumManifestBytes)
        let sounds = try checkedManifest(descriptor, bytes: manifest)
        let expected = Set(["catalogue.json"] + sounds.map(\.filename))
        guard Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == expected else { throw PackError.invalid }
        let catalogue = try StudioSoundCatalogue(directory: directory)
        guard catalogue.sounds == sounds else { throw PackError.invalid }
        for sound in sounds {
            try Task.checkCancellation(); try pinned.check()
            _ = try catalogue.checkedResource(sound)
        }
        try pinned.check()
        return catalogue
    }
    /// Counts actual storage, rejects links/unknown file types and bounds even
    /// stale staging data. Never follows a cache link into project documents.
    private func usage(_ directory: URL) throws -> Int {
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0 else { throw PackError.invalid }
        if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
            guard metadata.st_nlink == 1, metadata.st_size >= 0, metadata.st_size <= limits.cacheBytes else { throw PackError.invalid }
            return Int(metadata.st_size)
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw PackError.invalid }
        let owned = try DirectoryIdentity(directory)
        var total = 0
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard children.count <= 1024 else { throw PackError.quota }
        for child in children {
            try owned.check()
            // There are only two levels: the root and each installed/stage pack.
            var childStat = stat()
            guard lstat(child.path, &childStat) == 0 else { throw PackError.invalid }
            if childStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                guard directory.standardizedFileURL == root.standardizedFileURL else { throw PackError.invalid }
            }
            let bytes = try usage(child)
            guard total <= limits.cacheBytes - bytes else { throw PackError.quota }; total += bytes
        }
        try owned.check(); return total
    }
    private func checkSpace(additional: Int, current: Int) throws {
        guard additional >= 0, current <= limits.cacheBytes - additional else { throw PackError.quota }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        guard let free = attributes[.systemFreeSize] as? NSNumber,
              free.int64Value >= Int64(additional) + Int64(limits.reserveBytes) else { throw PackError.quota }
    }
    private func cleanStages(_ owned: DirectoryIdentity) throws {
        for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard child.lastPathComponent.hasPrefix("stage-"), UUID(uuidString: String(child.lastPathComponent.dropFirst(6))) != nil else { continue }
            try owned.check()
            let stage = try DirectoryIdentity(child); try stage.check()
            _ = try usage(child)
            try FileManager.default.removeItem(at: child)
        }
    }
    func installed(_ descriptor: Descriptor) throws -> StudioSoundCatalogue? {
        try authorize(descriptor); try Task.checkCancellation()
        guard !busy else { throw PackError.busy }
        guard let owned = try identity(root), let target = try identity(location(descriptor)) else { return nil }
        _ = try usage(root); try owned.check(); try target.check()
        let catalogue = try verify(descriptor, at: target.url)
        try owned.check(); try target.check(); return catalogue
    }
    func status(_ descriptor: Descriptor) throws -> Status {
        do {
            guard let catalogue = try installed(descriptor) else { return .notInstalled }
            return .installed(soundCount: catalogue.sounds.count, bytes: descriptor.totalAudioBytes + descriptor.manifestBytes)
        } catch is CancellationError { throw CancellationError() }
        catch PackError.busy { throw PackError.busy }
        catch { try authorize(descriptor); return .corrupt }
    }
    func inspect(descriptors: [Descriptor]) throws -> Inspection {
        guard !busy else { throw PackError.busy }
        var packs: [String: Status] = [:], ids = Set<String>(), originals = Set<String>()
        for descriptor in descriptors {
            let state = try status(descriptor); packs[descriptor.id] = state
            if case .installed = state, let catalogue = try installed(descriptor) {
                for sound in catalogue.sounds where !ids.contains(sound.id) && !originals.contains(sound.originalSHA256) {
                    ids.insert(sound.id); originals.insert(sound.originalSHA256)
                }
            }
        }
        let bytes: Int
        if try identity(root) == nil { bytes = 0 } else { bytes = try usage(root) }
        return Inspection(bytes: bytes, soundCount: ids.count, packs: packs)
    }
    func loadAvailable(bundled: StudioSoundCatalogue, descriptors: [Descriptor]) throws -> StudioSoundCatalogue {
        var catalogues = [bundled]
        for descriptor in descriptors.sorted(by: { $0.id < $1.id }) {
            // Corrupt optional content is unavailable; the bundled library and
            // other verified packs remain usable until that pack is removed.
            do { if let catalogue = try installed(descriptor) { catalogues.append(catalogue) } }
            catch is CancellationError { throw CancellationError() }
            catch PackError.busy { throw PackError.busy }
            catch { try authorize(descriptor) }
        }
        return StudioSoundCatalogue.merging(catalogues)
    }
    /// The two app-shipped metadata copies have the same manifest pins as the
    /// installer. Open/check each directory component without following links;
    /// only bounded JSON is read, never optional audio or project documents.
    private func shippedAttributions(descriptors: [Descriptor], directory: URL) throws -> [String: StudioSoundAttribution] {
        guard directory.isFileURL else { throw PackError.invalid }
        let bundleRoot = try DirectoryIdentity(directory)
        guard let metadataRoot = try identity(directory.appendingPathComponent("pack-catalogues", isDirectory: true)) else { return [:] }
        let approved = try Self.descriptors(directory: directory)
        guard descriptors.count <= 2, Set(descriptors.map(\.id)).count == descriptors.count else { throw PackError.invalid }
        var result: [String: StudioSoundAttribution] = [:]
        for descriptor in descriptors.sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation(); try authorize(descriptor)
            guard approved.contains(descriptor) else { throw PackError.invalid }
            try bundleRoot.check(); try metadataRoot.check()
            let target = metadataRoot.url.appendingPathComponent(descriptor.id, isDirectory: true)
            guard let packRoot = try identity(target) else { continue }
            let manifest = target.appendingPathComponent("catalogue.json")
            var metadata = stat()
            if lstat(manifest.path, &metadata) != 0 { guard errno == ENOENT else { throw PackError.invalid }; continue }
            let data = try StudioSoundCatalogue.readRegularFile(manifest, maximumBytes: Self.maximumManifestBytes)
            for sound in try checkedManifest(descriptor, bytes: data) where result[sound.sha256] == nil { result[sound.sha256] = sound.attribution }
            try bundleRoot.check(); try metadataRoot.check(); try packRoot.check()
        }
        try bundleRoot.check(); try metadataRoot.check()
        return result
    }
    func attributions(bundled: StudioSoundCatalogue, descriptors: [Descriptor], metadataDirectory: URL? = nil) throws -> [String: StudioSoundAttribution] {
        guard !busy else { throw PackError.busy }
        var result = bundled.attributionsByDigest
        if let metadataDirectory {
            for (digest, attribution) in try shippedAttributions(descriptors: descriptors, directory: metadataDirectory) where result[digest] == nil {
                result[digest] = attribution
            }
        }
        guard let owned = try identity(root) else { return result }
        for descriptor in descriptors.sorted(by: { $0.id < $1.id }) {
            try authorize(descriptor); try Task.checkCancellation(); try owned.check()
            let receipt = receiptLocation(descriptor)
            var metadata = stat()
            if lstat(receipt.path, &metadata) != 0 { guard errno == ENOENT else { throw PackError.invalid }; continue }
            let data = try StudioSoundCatalogue.readRegularFile(receipt, maximumBytes: Self.maximumManifestBytes)
            for sound in try checkedManifest(descriptor, bytes: data) where result[sound.sha256] == nil { result[sound.sha256] = sound.attribution }
        }
        try owned.check(); return result
    }
    /// Cache removal owns no AudioTrack/document URL. Checked metadata receipts
    /// remain solely to credit bytes that were already copied into a project.
    func remove(_ descriptor: Descriptor) throws {
        try authorize(descriptor); try Task.checkCancellation()
        guard !busy else { throw PackError.busy }; busy = true; defer { busy = false }
        guard let owned = try identity(root), let target = try identity(location(descriptor)) else { return }
        try owned.check(); try target.check()
        // Reject symlinks before recursive removal, even for a corrupt pack.
        _ = try usage(target.url)
        let trash = root.appendingPathComponent("stage-" + UUID().uuidString, isDirectory: true)
        guard Darwin.rename(target.url.path, trash.path) == 0 else { throw PackError.invalid }
        try owned.check()
        try FileManager.default.removeItem(at: trash)
    }
    func install(_ descriptor: Descriptor, protocolClasses: [AnyClass] = []) async throws -> StudioSoundCatalogue {
        try authorize(descriptor); try Task.checkCancellation()
        guard !busy else { throw PackError.busy }; busy = true; defer { busy = false }
        guard limits.cacheBytes > 0, limits.cacheClips > 0, limits.reserveBytes >= 0,
              let owned = try identity(root, create: true) else { throw PackError.invalid }
        try cleanStages(owned)
        if let target = try identity(location(descriptor)) {
            _ = try usage(root)
            let result = try verify(descriptor, at: target.url)
            try owned.check(); try target.check(); return result
        }
        let approved = try trustedDescriptors ?? Self.descriptors()
        var cachedClips = 0
        for item in approved where item.id != descriptor.id {
            if try identity(location(item)) != nil { cachedClips += item.soundCount }
        }
        guard cachedClips <= limits.cacheClips - descriptor.soundCount else { throw PackError.quota }
        let before = try usage(root)
        // Include the retained manifest receipt in disk/cache accounting.
        let required = descriptor.totalAudioBytes + descriptor.manifestBytes * 2
        try checkSpace(additional: required, current: before)
        var rootURL = root, values = URLResourceValues(); values.isExcludedFromBackup = true
        try rootURL.setResourceValues(values)
        let stageURL = root.appendingPathComponent("stage-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stageURL, withIntermediateDirectories: false)
        let stage = try DirectoryIdentity(stageURL)
        defer {
            // A suspended request cannot trick cleanup into deleting a replaced
            // root or stage. Interrupted owned stages recover next install.
            if (try? owned.check()) != nil, (try? stage.check()) != nil { try? FileManager.default.removeItem(at: stageURL) }
        }
        let config = URLSessionConfiguration.ephemeral
        if !protocolClasses.isEmpty { config.protocolClasses = protocolClasses }
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.urlCache = nil; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 120
        let delegate = StudioSoundPackRedirectPolicy()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var transferred = 0
        do {
            let manifestURL = stageURL.appendingPathComponent("catalogue.json")
            try await transfer(URL(string: descriptor.manifestURL)!, to: manifestURL, bytes: descriptor.manifestBytes,
                               sha256: descriptor.manifestSHA256, session: session, owned: owned, stage: stage,
                               currentBytes: before, transferred: &transferred)
            let manifest = try StudioSoundCatalogue.readRegularFile(manifestURL, maximumBytes: Self.maximumManifestBytes)
            let sounds = try checkedManifest(descriptor, bytes: manifest)
            for sound in sounds {
                try Task.checkCancellation(); try owned.check(); try stage.check()
                let remote = URL(string: descriptor.baseURL)!.appendingPathComponent(sound.filename)
                try await transfer(remote, to: stageURL.appendingPathComponent(sound.filename), bytes: sound.byteCount,
                                   sha256: sound.sha256, session: session, owned: owned, stage: stage,
                                   currentBytes: before, transferred: &transferred)
            }
            try Task.checkCancellation(); try owned.check(); try stage.check()
            let catalogue = try verify(descriptor, at: stageURL)
            guard transferred == descriptor.manifestBytes + descriptor.totalAudioBytes else { throw PackError.invalid }
            try checkSpace(additional: descriptor.manifestBytes, current: before + transferred)
            // Metadata is published before audio. A failure can retain only a
            // checked credit receipt, never a partially visible sound library.
            try manifest.write(to: receiptLocation(descriptor), options: .atomic)
            try Task.checkCancellation(); try owned.check(); try stage.check()
            guard try identity(location(descriptor)) == nil,
                  Darwin.rename(stageURL.path, location(descriptor).path) == 0 else { throw PackError.invalid }
            // Re-root resource URLs after the one atomic directory publication.
            return catalogue.relocated(to: location(descriptor))
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if error is PackError || error is StudioSoundCatalogue.CatalogueError { throw error }
            throw PackError.network
        }
    }
    private func transfer(_ url: URL, to target: URL, bytes: Int, sha256: String,
                          session: URLSession, owned: DirectoryIdentity, stage: DirectoryIdentity,
                          currentBytes: Int, transferred: inout Int) async throws {
        guard Self.allowedURL(url), bytes > 0, bytes <= max(Self.maximumFileBytes, Self.maximumManifestBytes) else { throw PackError.invalid }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (stream, response) = try await session.bytes(for: request)
        try Task.checkCancellation(); try owned.check(); try stage.check()
        guard let http = response as? HTTPURLResponse, let final = http.url, Self.allowedURL(final),
              http.statusCode == 200, http.value(forHTTPHeaderField: "Content-Encoding") == nil || http.value(forHTTPHeaderField: "Content-Encoding") == "identity",
              http.expectedContentLength == -1 || http.expectedContentLength == bytes else { throw PackError.network }
        let fd = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PackError.invalid }
        defer { _ = Darwin.close(fd) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var digest = SHA256(), chunk = Data(), received = 0
        chunk.reserveCapacity(65_536)
        for try await byte in stream {
            try Task.checkCancellation()
            guard received < bytes else { throw PackError.invalid }
            received += 1; chunk.append(byte)
            if chunk.count == 65_536 {
                try owned.check(); try stage.check()
                try checkSpace(additional: chunk.count, current: currentBytes + transferred)
                try file.write(contentsOf: chunk); digest.update(data: chunk)
                transferred += chunk.count; chunk.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation(); try owned.check(); try stage.check()
        guard received == bytes else { throw PackError.invalid }
        if !chunk.isEmpty {
            try checkSpace(additional: chunk.count, current: currentBytes + transferred)
            try file.write(contentsOf: chunk); digest.update(data: chunk); transferred += chunk.count
        }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else { throw PackError.invalid }
        try file.synchronize()
    }
}

private final class StudioSoundPackRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirects: [Int: Int] = [:]
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); let count = (redirects[task.taskIdentifier] ?? 0) + 1; redirects[task.taskIdentifier] = count; lock.unlock()
        guard let url = request.url, StudioSoundPackCache.allowedURL(url), task.countOfBytesReceived == 0,
              (task.currentRequest?.url?.host == url.host), (task.countOfBytesSent == 0),
              (task.originalRequest?.url?.host == url.host), count <= 3 else { completionHandler(nil); return }
        var sanitized = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        sanitized.httpMethod = "GET"; sanitized.httpShouldHandleCookies = false
        sanitized.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        sanitized.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(sanitized)
    }
}

/// Device-local catalogue identities only; never stores audio or project data.
struct StudioSoundFavorites {
    private let defaults: UserDefaults
    private let allowed: Set<String>
    private let key = "studio.sound-library.favorites.v1"
    init(allowedIDs: Set<String>, defaults: UserDefaults = .standard) {
        allowed = allowedIDs; self.defaults = defaults
    }
    var ids: Set<String> {
        guard let data = defaults.data(forKey: key), data.count <= 65_536,
              let stored = try? JSONDecoder().decode([String].self, from: data), stored.count <= 256 else { return [] }
        return Set(stored).intersection(allowed)
    }
    @discardableResult func toggle(_ id: String) -> Bool {
        guard allowed.contains(id) else { return false }
        var next = ids
        if next.contains(id) { next.remove(id) }
        else { guard next.count < 256 else { return false }; next.insert(id) }
        guard let data = try? JSONEncoder().encode(next.sorted()), data.count <= 65_536 else { return false }
        defaults.set(data, forKey: key)
        return true
    }
}

/// The last library result list, kept so re-rendering the sound library (for
/// example on every audio-timeline tick) does not search the catalogue again.
@MainActor
final class StudioSoundSearchMemo {
    private struct Key: Equatable {
        let catalogue: UUID, query: String, category: String?
        let duration: StudioSoundCatalogue.DurationFilter, sort: StudioSoundCatalogue.Sort
    }
    private var key: Key?
    private var cached: [StudioSoundCatalogue.Sound] = []

    func results(_ catalogue: StudioSoundCatalogue, query: String, category: String?,
                 duration: StudioSoundCatalogue.DurationFilter, sort: StudioSoundCatalogue.Sort) -> [StudioSoundCatalogue.Sound] {
        let next = Key(catalogue: catalogue.loadID, query: query, category: category, duration: duration, sort: sort)
        if next != key {
            cached = catalogue.search(query, category: category, duration: duration, sort: sort)
            key = next
        }
        return cached
    }
}
