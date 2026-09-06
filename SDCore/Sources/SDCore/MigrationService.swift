import Foundation

public struct MigrationResult: Equatable {
    public var migratedAssetCount: Int
    public var conflicts: [String]
    public var skipped: [String]

    public init(migratedAssetCount: Int = 0, conflicts: [String] = [], skipped: [String] = []) {
        self.migratedAssetCount = migratedAssetCount
        self.conflicts = conflicts
        self.skipped = skipped
    }
}

public final class MigrationService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func migrateLegacyAnimation(
        legacyID: String,
        legacyDir: URL,
        canonicalDir: URL,
        project: Project
    ) throws -> MigrationResult {
        var result = MigrationResult()

        if !fileManager.fileExists(atPath: canonicalDir.path) {
            try fileManager.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
        }

        let enumerator = fileManager.enumerator(at: legacyDir, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            let fileName = fileURL.lastPathComponent
            let destURL = canonicalDir.appendingPathComponent(fileName)

            if fileManager.fileExists(atPath: destURL.path) {
                let srcData = try Data(contentsOf: fileURL)
                let destData = try Data(contentsOf: destURL)
                if srcData == destData {
                    result.skipped.append(fileName)
                } else {
                    result.conflicts.append(fileName)
                }
            } else {
                try fileManager.copyItem(at: fileURL, to: destURL)
                result.migratedAssetCount += 1
            }
        }

        let projectFile = canonicalDir.appendingPathComponent("project.json")
        if !fileManager.fileExists(atPath: projectFile.path) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(project)
            try data.write(to: projectFile, options: .atomic)
            result.migratedAssetCount += 1
        }

        return result
    }

    public func findLegacyAnimations(in documentsDir: URL) -> [(id: String, dir: URL)] {
        let animationsDir = documentsDir.appendingPathComponent("Animations", isDirectory: true)
        guard fileManager.fileExists(atPath: animationsDir.path) else { return [] }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: animationsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { dir in
            guard dir.hasDirectoryPath else { return nil }
            return (id: dir.lastPathComponent, dir: dir)
        }
    }

    public func canonicalDir(for projectID: String, baseDir: URL) -> URL {
        baseDir.appendingPathComponent("StudioProjects", isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)
    }
}
