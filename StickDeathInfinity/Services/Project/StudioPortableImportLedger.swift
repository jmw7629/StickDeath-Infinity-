import Foundation

/// On-device record of which backup files were imported as which projects
/// (#170 import conflict handling). Each entry is a backup's SHA-256 and the
/// fresh project identity it was imported as. It holds no project content,
/// title, path or account data and never leaves the device.
///
/// The ledger only informs: importing the same backup twice, or a backup of a
/// project that is still in the library, asks the creator first. Every import
/// still gets a fresh identity, so nothing is ever overwritten or merged.
final class StudioPortableImportLedger {
    struct Entry: Codable, Equatable, Sendable {
        let bundleSHA256: String
        let projectID: UUID
        let importedAt: Date
    }
    private struct File: Codable { let version: Int; let entries: [Entry] }

    static let maximumEntries = 256
    static let maximumFileBytes = 128 * 1024
    let fileURL: URL
    private let lock = NSLock()

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("StickDeathInfinity", isDirectory: true)
            .appendingPathComponent("portable-import-ledger.json", isDirectory: false)
    }
    static let shared = StudioPortableImportLedger()

    init(fileURL: URL = StudioPortableImportLedger.defaultFileURL) { self.fileURL = fileURL }

    /// A missing, oversized, linked or damaged ledger reads as empty: the
    /// ledger is advisory and is never a reason to refuse or alter an import.
    func entries() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return unlockedEntries()
    }

    func entries(forBundleSHA256 digest: String) -> [Entry] {
        entries().filter { $0.bundleSHA256 == digest }
    }

    /// Appends one entry, keeping the newest `maximumEntries`. Trimming loses
    /// only duplicate detection for very old imports, never a project.
    func record(bundleSHA256 digest: String, projectID: UUID, at date: Date = Date()) throws {
        guard Self.isDigest(digest) else { throw CocoaError(.fileWriteInvalidFileName) }
        lock.lock(); defer { lock.unlock() }
        var current = unlockedEntries().filter { $0.projectID != projectID }
        current.append(Entry(bundleSHA256: digest, projectID: projectID, importedAt: date))
        if current.count > Self.maximumEntries { current.removeFirst(current.count - Self.maximumEntries) }
        let data = try JSONEncoder().encode(File(version: 1, entries: current))
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DeviceStorageManager.applyFileProtection(directory)
        try data.write(to: fileURL, options: DeviceStorageManager.protectedWriteOptions(.atomic))
    }

    private func unlockedEntries() -> [Entry] {
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: fileURL), data.count == size,
              let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 else { return [] }
        return file.entries.filter { Self.isDigest($0.bundleSHA256) }
    }

    static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// What the creator should know before a backup becomes another project.
enum StudioPortableImportConflict: Equatable, Sendable {
    case none
    /// This exact backup file was imported before and that copy still exists.
    case alreadyImported(title: String, inRecentlyDeleted: Bool)
    /// The project this backup was made from is still on this device.
    case originalOnDevice(title: String, inRecentlyDeleted: Bool)

    var needsConfirmation: Bool { self != .none }

    var message: String {
        switch self {
        case .none:
            return ""
        case .alreadyImported(let title, let deleted):
            return "This backup was already imported as \"\(title)\"\(deleted ? ", now in Recently Deleted" : ""). Importing again makes another separate copy; nothing is replaced."
        case .originalOnDevice(let title, let deleted):
            return "The project this backup was made from, \"\(title)\", is still on this device\(deleted ? " in Recently Deleted" : ""). Importing makes a separate copy; the original is not replaced."
        }
    }

    /// `sourceProjectID` is the identity stored inside the backup. Imports
    /// always receive a new identity, so a match is informational only.
    static func detect(bundleSHA256: String, sourceProjectID: UUID,
                       ledger: [StudioPortableImportLedger.Entry],
                       library: [AnimationMetadata], recentlyDeleted: [AnimationMetadata]) -> StudioPortableImportConflict {
        func find(_ id: UUID) -> (AnimationMetadata, Bool)? {
            if let live = library.first(where: { $0.id == id }) { return (live, false) }
            if let deleted = recentlyDeleted.first(where: { $0.id == id }) { return (deleted, true) }
            return nil
        }
        // Newest surviving copy first; stale entries for projects gone from the
        // device are not conflicts.
        for entry in ledger.reversed() where entry.bundleSHA256 == bundleSHA256 {
            if case let (project, deleted)? = find(entry.projectID) {
                return .alreadyImported(title: project.title, inRecentlyDeleted: deleted)
            }
        }
        if case let (project, deleted)? = find(sourceProjectID) {
            return .originalOnDevice(title: project.title, inRecentlyDeleted: deleted)
        }
        return .none
    }
}
