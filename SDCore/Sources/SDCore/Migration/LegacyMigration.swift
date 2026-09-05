import Foundation

public struct MigrationResult: Sendable, Equatable {
    public var migratedProjectIDs: [String]
    public var migratedFrameCount: Int
    public var skippedFiles: [String]
    public var conflicts: [MigrationConflict]
    public var discoveredLegacyProjects: [String]

    public init(
        migratedProjectIDs: [String] = [],
        migratedFrameCount: Int = 0,
        skippedFiles: [String] = [],
        conflicts: [MigrationConflict] = [],
        discoveredLegacyProjects: [String] = []
    ) {
        self.migratedProjectIDs = migratedProjectIDs
        self.migratedFrameCount = migratedFrameCount
        self.skippedFiles = skippedFiles
        self.conflicts = conflicts
        self.discoveredLegacyProjects = discoveredLegacyProjects
    }
}

public struct MigrationConflict: Sendable, Equatable {
    public var projectID: String
    public var filename: String
    public var legacyBytes: Int
    public var canonicalBytes: Int

    public init(projectID: String, filename: String, legacyBytes: Int, canonicalBytes: Int) {
        self.projectID = projectID
        self.filename = filename
        self.legacyBytes = legacyBytes
        self.canonicalBytes = canonicalBytes
    }
}

open class LegacyMigration: @unchecked Sendable {
    private let fileManager: FileManager
    private let documentsDir: URL

    public init(fileManager: FileManager = .default, documentsDir: URL? = nil) {
        self.fileManager = fileManager
        self.documentsDir = documentsDir
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    public var legacyAnimationsDir: URL {
        documentsDir.appendingPathComponent("Animations", isDirectory: true)
    }

    public var canonicalProjectsDir: URL {
        documentsDir.appendingPathComponent("StudioProjects", isDirectory: true)
    }

    // MARK: - Discovery

    public func discoverLegacyProjects() -> [String] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: legacyAnimationsDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .sorted()
    }

    // MARK: - Migration

    public func migrateLegacyProject(
        projectID: String,
        storage: StudioStorage
    ) throws -> MigrationResult {
        let legacyDir = legacyAnimationsDir.appendingPathComponent(projectID, isDirectory: true)
        let canonicalDir = storage.projectsRoot.appendingPathComponent(projectID, isDirectory: true)

        var result = MigrationResult(discoveredLegacyProjects: [projectID])

        guard fileManager.fileExists(atPath: legacyDir.path) else {
            return result
        }

        try fileManager.createDirectory(at: canonicalDir, withIntermediateDirectories: true)

        let assetsDir = canonicalDir.appendingPathComponent("assets", isDirectory: true)
        try fileManager.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        let contents = (try? fileManager.contentsOfDirectory(
            at: legacyDir, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []

        for fileURL in contents {
            let filename = fileURL.lastPathComponent

            if filename == "metadata.json" {
                continue
            }

            let isFrame = filename.hasPrefix("frame_") && filename.hasSuffix(".png")
            let destinationURL: URL

            if isFrame {
                destinationURL = canonicalDir.appendingPathComponent(filename)
            } else {
                destinationURL = assetsDir.appendingPathComponent(filename)
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                let legacyData = try Data(contentsOf: fileURL)
                let canonicalData = try Data(contentsOf: destinationURL)

                if legacyData == canonicalData {
                    result.skippedFiles.append(filename)
                    continue
                } else {
                    result.conflicts.append(MigrationConflict(
                        projectID: projectID,
                        filename: filename,
                        legacyBytes: legacyData.count,
                        canonicalBytes: canonicalData.count
                    ))
                    let conflictName = "\(projectID)_\(filename).legacy"
                    let conflictURL = canonicalDir.appendingPathComponent(conflictName)
                    try legacyData.write(to: conflictURL, options: .atomic)
                    result.skippedFiles.append(filename)
                    continue
                }
            }

            let data = try Data(contentsOf: fileURL)
            try data.write(to: destinationURL, options: .atomic)

            if isFrame {
                result.migratedFrameCount += 1
            }
        }

        let metadata = ProjectMetadata(
            id: projectID,
            name: "Migrated Project",
            width: 1080,
            height: 1080,
            fps: 12,
            frameCount: result.migratedFrameCount,
            layerCount: 1
        )
        try storage.saveMetadata(metadata, for: projectID)

        result.migratedProjectIDs.append(projectID)

        return result
    }

    public func migrateAll(storage: StudioStorage) throws -> MigrationResult {
        let projectIDs = discoverLegacyProjects()
        var combined = MigrationResult(discoveredLegacyProjects: projectIDs)

        for pid in projectIDs {
            let singleResult = try migrateLegacyProject(projectID: pid, storage: storage)
            combined.migratedProjectIDs.append(contentsOf: singleResult.migratedProjectIDs)
            combined.migratedFrameCount += singleResult.migratedFrameCount
            combined.skippedFiles.append(contentsOf: singleResult.skippedFiles)
            combined.conflicts.append(contentsOf: singleResult.conflicts)
        }

        return combined
    }

    // MARK: - Preservation checks

    public func legacyFilePreserved(projectID: String, filename: String) -> Bool {
        let fileURL = legacyAnimationsDir
            .appendingPathComponent(projectID)
            .appendingPathComponent(filename)
        return fileManager.fileExists(atPath: fileURL.path)
    }

    public func legacyFileBytes(projectID: String, filename: String) throws -> Data? {
        let fileURL = legacyAnimationsDir
            .appendingPathComponent(projectID)
            .appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }
}
