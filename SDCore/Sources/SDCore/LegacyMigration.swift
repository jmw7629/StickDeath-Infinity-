// ═══════════════════════════════════════════════════════════════════
// LegacyMigration — Automatic sibling migration in normal open path
// Discovers <Documents>/Animations/<id> and migrates beside
// existing canonical project.json
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - LegacyMigration Protocol

public protocol LegacyMigration {
    /// Check if legacy sibling exists and migrate if needed.
    func migrateIfNeeded(projectID: String, existing: ProjectSnapshot) throws -> ProjectSnapshot

    /// Attempt to migrate from legacy-only (no canonical project exists).
    func migrateFromLegacy(projectID: String) throws -> ProjectSnapshot?
}

// MARK: - DefaultLegacyMigration

public final class DefaultLegacyMigration: LegacyMigration {
    private let animationsDir: URL

    public init(animationsDir: URL) {
        self.animationsDir = animationsDir
    }

    // MARK: - Migrate If Needed

    public func migrateIfNeeded(projectID: String, existing: ProjectSnapshot) throws -> ProjectSnapshot {
        let legacyDir = animationsDir.appendingPathComponent(projectID, isDirectory: true)
        let canonicalDir = animationsDir.appendingPathComponent(projectID, isDirectory: true)

        guard FileManager.default.fileExists(atPath: legacyDir.path) else {
            return existing
        }

        // Look for legacy assets (PNGs, audio) alongside canonical project.json
        let legacyAssets = try findLegacyAssets(in: legacyDir)
        guard !legacyAssets.isEmpty else { return existing }

        // Migration destination: same directory, canonical naming
        let migratedDir = canonicalDir.appendingPathComponent("migrated_legacy", isDirectory: true)

        var migratedSnapshot = existing
        var didMigrate = false

        for asset in legacyAssets {
            let dest = migratedDir.appendingPathComponent(asset.lastPathComponent)

            if FileManager.default.fileExists(atPath: dest.path) {
                // Identical destination => no rewrite
                let existingData = try Data(contentsOf: dest)
                let assetData = try Data(contentsOf: asset)
                if existingData == assetData {
                    continue
                }
                // Different bytes => preserve both, skip (never overwrite)
                print("[Migration] Conflict: \(asset.lastPathComponent) differs, preserving both")
                continue
            }

            // Byte-identical copy
            try? FileManager.default.createDirectory(
                at: migratedDir,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: asset, to: dest)
            didMigrate = true
        }

        // Sparse frames, audio, and unrelated legacy files remain intact.
        // Canonical vector state, layers, activeLayerID, and project.json remain intact.
        if didMigrate {
            migratedSnapshot.updatedAt = Date()
        }

        return migratedSnapshot
    }

    // MARK: - Migrate From Legacy

    public func migrateFromLegacy(projectID: String) throws -> ProjectSnapshot? {
        let legacyDir = animationsDir.appendingPathComponent(projectID, isDirectory: true)

        guard FileManager.default.fileExists(atPath: legacyDir.path) else {
            return nil
        }

        let legacyAssets = try findLegacyAssets(in: legacyDir)
        guard !legacyAssets.isEmpty else { return nil }

        // Create a minimal project snapshot from legacy assets
        let snapshot = ProjectSnapshot(
            id: projectID,
            name: "Migrated Project",
            updatedAt: Date()
        )

        return snapshot
    }

    // MARK: - Private Helpers

    private func findLegacyAssets(in dir: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var assets: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "mp3", "wav", "m4a"].contains(ext) {
                assets.append(fileURL)
            }
        }
        return assets
    }
}
