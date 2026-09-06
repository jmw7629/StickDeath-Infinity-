// ═══════════════════════════════════════════════════════════════════
// LegacyMigration — Per-asset sibling migration
// Legacy: <Documents>/Animations/<id>/frame_N.png + metadata/audio
// Canonical: <Documents>/StudioProjects/<id>/...
// Non-destructive: copies only missing, reports conflicts.
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Migration Result

public struct MigrationResult: Sendable {
    public let migratedAssets: [String]
    public let alreadyMigrated: [String]
    public let conflicts: [MigrationConflict]

    public var hasConflicts: Bool { !conflicts.isEmpty }
}

public struct MigrationConflict: Sendable {
    public let relativePath: String
    public let legacyPath: String
    public let canonicalPath: String
}

// MARK: - Legacy Asset Migration

public enum LegacyAssetMigration {

    /// Migrate a legacy animation directory into the canonical project structure.
    /// Returns nil if no legacy animation exists for the given ID.
    @discardableResult
    public static func migrateLegacyAnimation(
        id: String,
        documentsDir: URL? = nil,
        storage: ProjectStorage? = nil
    ) -> SDProject? {
        let fm = FileManager.default
        let base = documentsDir ?? defaultDocumentsDir()

        let legacyDir = base.appendingPathComponent("Animations", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)

        guard fm.fileExists(atPath: legacyDir.path) else { return nil }

        // Check if canonical project already exists
        let canonicalDir: URL
        if let storage {
            canonicalDir = storage.projectDirectory(for: id)
        } else {
            canonicalDir = base.appendingPathComponent("StudioProjects", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
        }

        let project = migrateSiblings(
            legacyDir: legacyDir,
            canonicalDir: canonicalDir,
            projectID: id
        )

        // Save if we have storage
        if let storage, fm.fileExists(atPath: canonicalDir.path) {
            try? storage.saveProject(project)
        }

        return project
    }

    /// Enumerate and migrate individual legacy assets non-destructively.
    public static func migrateSiblings(
        legacyDir: URL,
        canonicalDir: URL,
        projectID: String
    ) -> SDProject {
        let fm = FileManager.default

        // Ensure canonical directory exists
        try? fm.createDirectory(at: canonicalDir, withIntermediateDirectories: true)

        // Enumerate legacy assets
        guard let legacyContents = try? fm.contentsOfDirectory(
            at: legacyDir,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return SDProject(projectID: projectID)
        }

        var migrated: [String] = []
        var alreadyMigrated: [String] = []
        var conflicts: [MigrationConflict] = []

        for legacyAssetURL in legacyContents {
            let filename = legacyAssetURL.lastPathComponent
            let canonicalAssetURL = canonicalDir.appendingPathComponent(filename)

            if fm.fileExists(atPath: canonicalAssetURL.path) {
                // Compare byte-identical
                if legacyAssetURL.dataRepresentation == canonicalAssetURL.dataRepresentation {
                    alreadyMigrated.append(filename)
                } else {
                    // Conflict: preserve both
                    conflicts.append(MigrationConflict(
                        relativePath: filename,
                        legacyPath: legacyAssetURL.path,
                        canonicalPath: canonicalAssetURL.path
                    ))
                }
            } else {
                // Missing destination => copy byte-identically
                do {
                    try fm.copyItem(at: legacyAssetURL, to: canonicalAssetURL)
                    migrated.append(filename)
                } catch {
                    conflicts.append(MigrationConflict(
                        relativePath: filename,
                        legacyPath: legacyAssetURL.path,
                        canonicalPath: canonicalAssetURL.path
                    ))
                }
            }
        }

        // Load or create project
        var project = SDProject(projectID: projectID)
        if let projectJSONPath = canonicalDir.appendingPathComponent("project.json") as URL?,
           fm.fileExists(atPath: projectJSONPath.path),
           let data = try? Data(contentsOf: projectJSONPath),
           let decoded = try? JSONDecoder().decode(SDProject.self, from: data) {
            project = decoded
        }

        return project
    }

    // MARK: - Helpers

    private static func defaultDocumentsDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
}

// MARK: - Data comparison

private extension Data {
    var dataRepresentation: Data { self }
}
