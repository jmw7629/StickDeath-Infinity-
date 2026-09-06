import Foundation

public enum MigrationResult: Equatable {
    case migrated
    case alreadyMigrated
    case conflict(sourceRetained: Bool, destinationRetained: Bool)
    case error(String)
}

public final class LegacyMigrationManager {
    public static let shared = LegacyMigrationManager()

    private let fileManager = FileManager.default

    public init() {}

    private func legacyAnimDir(documentsDir: URL, id: String) -> URL {
        documentsDir.appendingPathComponent("Animations", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    private func canonicalDir(documentsDir: URL, id: String) -> URL {
        documentsDir.appendingPathComponent("StudioProjects", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    /// List all legacy animation IDs found in Documents/Animations/
    public func discoverLegacyIDs(documentsDir: URL) -> [String] {
        let animDir = documentsDir.appendingPathComponent("Animations", isDirectory: true)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: animDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return contents.filter { $0.hasDirectoryPath }.map { $0.lastPathComponent }
    }

    /// Migrate one legacy animation directory to canonical location.
    /// Returns the migration result without deleting the source.
    public func migrateLegacyAnimation(
        id: String,
        documentsDir: URL
    ) -> MigrationResult {
        let source = legacyAnimDir(documentsDir: documentsDir, id: id)
        let dest = canonicalDir(documentsDir: documentsDir, id: id)

        guard fileManager.fileExists(atPath: source.path) else {
            return .error("Legacy source not found: \(source.path)")
        }

        if fileManager.fileExists(atPath: dest.path) {
            // Destination already exists — compare contents
            if directoriesMatch(source: source, dest: dest) {
                return .alreadyMigrated
            } else {
                // Conflict: both exist with different content — preserve both
                return .conflict(sourceRetained: true, destinationRetained: true)
            }
        }

        // Destination missing — byte-identical copy
        do {
            try fileManager.copyItem(at: source, to: dest)
            return .migrated
        } catch {
            return .error("Copy failed: \(error.localizedDescription)")
        }
    }

    /// Migrate all discoverable legacy animations
    public func migrateAll(documentsDir: URL) -> [String: MigrationResult] {
        let ids = discoverLegacyIDs(documentsDir: documentsDir)
        var results: [String: MigrationResult] = [:]
        for id in ids {
            results[id] = migrateLegacyAnimation(id: id, documentsDir: documentsDir)
        }
        return results
    }

    private func directoriesMatch(source: URL, dest: URL) -> Bool {
        let srcFiles = (try? fileManager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let dstFiles = (try? fileManager.contentsOfDirectory(
            at: dest, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []

        guard srcFiles.count == dstFiles.count else { return false }

        for srcFile in srcFiles {
            let fileName = srcFile.lastPathComponent
            let dstFile = dest.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: dstFile.path) else { return false }

            guard let srcData = try? Data(contentsOf: srcFile),
                  let dstData = try? Data(contentsOf: dstFile) else { return false }

            if srcData != dstData { return false }
        }
        return true
    }
}
