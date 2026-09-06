import Foundation

/// Legacy sibling migration from <Documents>/Animations/<id>/frame_N.png
/// to canonical <Documents>/StudioProjects/<id>/...
///
/// Rules:
/// - Destination missing → copy/preserve byte-identically
/// - Identical destination bytes → treat/report already migrated, no destructive rewrite
/// - Different destination bytes → preserve both and report conflict; never overwrite/delete source
/// - Preserve sparse frame indices, unrelated legacy files, vector data, non-default layer metadata
/// - Normal canonical saves must not delete raster assets
public struct LegacyMigration {
    public struct MigrationResult: Equatable, Sendable {
        public let projectID: String
        public let copiedFiles: Int
        public let skippedIdentical: Int
        public let conflicts: [String]
        public let alreadyMigrated: Bool

        public init(
            projectID: String,
            copiedFiles: Int,
            skippedIdentical: Int,
            conflicts: [String],
            alreadyMigrated: Bool
        ) {
            self.projectID = projectID
            self.copiedFiles = copiedFiles
            self.skippedIdentical = skippedIdentical
            self.conflicts = conflicts
            self.alreadyMigrated = alreadyMigrated
        }
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Migrate a legacy animation directory to the canonical project directory.
    ///
    /// - Parameters:
    ///   - projectID: The project identifier (used as directory name in both locations)
    ///   - documentsDirectory: The ~/Documents directory
    /// - Returns: MigrationResult describing what happened
    public func migrate(projectID: String, documentsDirectory: URL) throws -> MigrationResult {
        let legacyDir = documentsDirectory
            .appendingPathComponent("Animations", isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)
        let canonicalDir = documentsDirectory
            .appendingPathComponent("StudioProjects", isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)

        guard fileManager.fileExists(atPath: legacyDir.path) else {
            return MigrationResult(
                projectID: projectID,
                copiedFiles: 0,
                skippedIdentical: 0,
                conflicts: [],
                alreadyMigrated: false
            )
        }

        try fileManager.createDirectory(at: canonicalDir, withIntermediateDirectories: true)

        let legacyContents = try fileManager.contentsOfDirectory(
            at: legacyDir,
            includingPropertiesForKeys: [.fileSizeKey]
        )

        var copiedFiles = 0
        var skippedIdentical = 0
        var conflicts: [String] = []

        for legacyFile in legacyContents {
            let fileName = legacyFile.lastPathComponent
            let destFile = canonicalDir.appendingPathComponent(fileName)

            if !fileManager.fileExists(atPath: destFile.path) {
                // Destination missing → copy byte-identically
                try fileManager.copyItem(at: legacyFile, to: destFile)
                copiedFiles += 1
            } else {
                // Both exist — compare bytes
                let legacyData = try Data(contentsOf: legacyFile)
                let destData = try Data(contentsOf: destFile)

                if legacyData == destData {
                    // Identical → skip, report already migrated
                    skippedIdentical += 1
                } else {
                    // Different → preserve both, report conflict
                    conflicts.append(fileName)
                }
            }
        }

        let alreadyMigrated = copiedFiles == 0 && !conflicts.isEmpty == false && skippedIdentical > 0

        return MigrationResult(
            projectID: projectID,
            copiedFiles: copiedFiles,
            skippedIdentical: skippedIdentical,
            conflicts: conflicts,
            alreadyMigrated: alreadyMigrated
        )
    }
}
