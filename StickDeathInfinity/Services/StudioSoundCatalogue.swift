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
              Set(manifest.sounds.map(\.filename)).count == manifest.sounds.count else { throw CatalogueError.invalid }
        for sound in manifest.sounds {
            guard Self.hash(sound.sha256), Self.hash(sound.originalSHA256), sound.id == sound.sha256,
                  ["wav", "aiff", "aifc", "caf", "m4a", "mp3", "aac"].contains((sound.filename as NSString).pathExtension),
                  sound.filename == sound.sha256 + "." + (sound.filename as NSString).pathExtension,
                  (1...StudioAudioImportService.maximumEncodedBytes).contains(sound.byteCount),
                  sound.duration.isFinite, sound.duration > 0, sound.duration <= 300,
                  sound.sampleRate.isFinite, (8000...192000).contains(sound.sampleRate), (1...2).contains(sound.channels),
                  sound.waveformPeaks.count == 256, sound.waveformPeaks.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  [sound.title, sound.category, sound.author].allSatisfy(Self.label),
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
    var categories: [String] { Array(Set(sounds.map(\.category))).sorted() }
    func search(_ query: String, category: String?) -> [Sound] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return sounds.filter { sound in
            (category == nil || sound.category == category) && terms.allSatisfy {
                (sound.title + " " + sound.category + " " + sound.author).localizedCaseInsensitiveContains($0)
            }
        }
    }

    /// Pin the resource bytes before invoking the same real importer as Files.
    /// Unknown metadata objects, symlinks, corrupt bytes and missing files fail.
    func checkedResource(_ sound: Sound) throws -> (url: URL, data: Data) {
        guard sounds.contains(sound) else { throw CatalogueError.invalid }
        let url = directory.appendingPathComponent(sound.filename)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CatalogueError.invalid }
        defer { _ = Darwin.close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_size == sound.byteCount else { throw CatalogueError.invalid }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try file.read(upToCount: sound.byteCount + 1) ?? Data()
        guard data.count == sound.byteCount, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sound.sha256 else { throw CatalogueError.invalid }
        return (url, data)
    }
    func previewTrack(_ sound: Sound) throws -> AudioTrack {
        let checked = try checkedResource(sound)
        return AudioTrack(id: UUID(), name: sound.title, format: (sound.filename as NSString).pathExtension,
                          audioData: checked.data, startTime: 0, duration: sound.duration)
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
