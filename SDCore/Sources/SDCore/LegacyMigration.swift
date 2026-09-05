import Foundation

public struct MigrationResult: Sendable {
    public let migratedFrameIndices: [Int]
    public let preservedUnrelatedFiles: [String]

    public init(migratedFrameIndices: [Int] = [], preservedUnrelatedFiles: [String] = []) {
        self.migratedFrameIndices = migratedFrameIndices
        self.preservedUnrelatedFiles = preservedUnrelatedFiles
    }
}

public struct LegacyMigration {
    public let legacyRoot: URL
    public let persistence: ProjectPersistence

    public init(legacyRoot: URL, persistence: ProjectPersistence) {
        self.legacyRoot = legacyRoot
        self.persistence = persistence
    }

    public var legacyAnimationsDir: URL {
        legacyRoot.appendingPathComponent("Animations", isDirectory: true)
    }

    // MARK: - Discover Legacy Frames

    public func legacyProjectDir(for projectID: String) -> URL {
        legacyAnimationsDir.appendingPathComponent(projectID, isDirectory: true)
    }

    public func discoverLegacyFrameIndices(for projectID: String) -> [Int] {
        let dir = legacyProjectDir(for: projectID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }

        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }

        return contents
            .compactMap { url -> Int? in
                let name = url.lastPathComponent
                guard name.hasPrefix("frame_"), name.hasSuffix(".png") else { return nil }
                let indexStr = name.replacingOccurrences(of: "frame_", with: "").replacingOccurrences(of: ".png", with: "")
                return Int(indexStr)
            }
            .sorted()
    }

    public func legacyRasterURL(for projectID: String, frameIndex: Int) -> URL {
        legacyProjectDir(for: projectID).appendingPathComponent("frame_\(frameIndex).png")
    }

    public func legacyUnrelatedFiles(for projectID: String) -> [URL] {
        let dir = legacyProjectDir(for: projectID)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return contents.filter { url in
            let name = url.lastPathComponent
            return !(name.hasPrefix("frame_") && name.hasSuffix(".png"))
        }
    }

    // MARK: - Migrate

    @discardableResult
    public func migrate(projectID: String) throws -> MigrationResult {
        let legacyIndices = discoverLegacyFrameIndices(for: projectID)
        var migratedIndices: [Int] = []

        for index in legacyIndices {
            let sourceURL = legacyRasterURL(for: projectID, frameIndex: index)
            let destURL = persistence.rasterURL(for: projectID, frameIndex: index)

            // Only copy if destination doesn't exist or source is newer
            if !FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.createDirectory(
                    at: persistence.rasterDir(for: projectID),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
            }
            migratedIndices.append(index)
        }

        // Preserve unrelated files reference (non-destructive)
        let unrelatedFiles = legacyUnrelatedFiles(for: projectID)
        let unrelatedNames = unrelatedFiles.map { $0.lastPathComponent }

        return MigrationResult(
            migratedFrameIndices: migratedIndices,
            preservedUnrelatedFiles: unrelatedNames
        )
    }

    // MARK: - Verify Integrity

    public func verifyByteIdentity(source: URL, destination: URL) -> Bool {
        guard let srcData = try? Data(contentsOf: source),
              let dstData = try? Data(contentsOf: destination) else {
            return false
        }
        return srcData == dstData
    }

    public func verifyMigrationIntegrity(projectID: String, indices: [Int]) -> Bool {
        for index in indices {
            let source = legacyRasterURL(for: projectID, frameIndex: index)
            let dest = persistence.rasterURL(for: projectID, frameIndex: index)
            guard verifyByteIdentity(source: source, destination: dest) else { return false }
        }
        return true
    }
}
