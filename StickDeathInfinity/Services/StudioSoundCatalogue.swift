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
    }
    private struct Manifest: Decodable { let schemaVersion: Int; let sounds: [Sound] }
    let sounds: [Sound]
    private let directory: URL
    static let maximumManifestBytes = 16 * 1024 * 1024

    init(directory: URL) throws {
        guard directory.isFileURL else { throw CatalogueError.unavailable }
        self.directory = directory.standardizedFileURL
        let url = directory.appendingPathComponent("catalogue.json")
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...Self.maximumManifestBytes).contains(size) else { throw CatalogueError.invalid }
        let data = try Data(contentsOf: url)
        guard data.count == size else { throw CatalogueError.invalid }
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
                  [sound.title, sound.category, sound.author].allSatisfy(Self.label),
                  Self.validTags(sound.tags),
                  sound.license == "CC0-1.0", sound.licenseURL == "https://creativecommons.org/publicdomain/zero/1.0/",
                  let source = URL(string: sound.sourceURL), source.scheme == "https", source.user == nil,
                  source.password == nil, let host = source.host, ["kenney.nl", "opengameart.org"].contains(host) else { throw CatalogueError.invalid }
        }
        sounds = manifest.sounds
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
    var categories: [String] { Array(Set(sounds.map(\.category))).sorted() }
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
        let matches = sounds.filter { sound in
            duration.includes(sound.duration) && (category == nil || sound.category == category) && terms.allSatisfy {
                (sound.title + " " + sound.category + " " + sound.author + " " + (sound.tags ?? []).joined(separator: " ")).localizedCaseInsensitiveContains($0)
            }
        }
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
