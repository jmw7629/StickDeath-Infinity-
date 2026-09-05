import Foundation

public enum ProjectPersistenceError: LocalizedError, Equatable {
    case directoryNotFound
    case encodingFailed(String)
    case decodingFailed(String)
    case fileOperationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .directoryNotFound: return "Project directory not found"
        case .encodingFailed(let msg): return "Encoding failed: \(msg)"
        case .decodingFailed(let msg): return "Decoding failed: \(msg)"
        case .fileOperationFailed(let msg): return "File operation failed: \(msg)"
        }
    }
}

public struct ProjectPersistence: Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Directory Helpers

    public func projectDirectory(root: URL, projectID: String) -> URL {
        root.appendingPathComponent(projectID, isDirectory: true)
    }

    public func bundleFileURL(root: URL, projectID: String) -> URL {
        projectDirectory(root: root, projectID: projectID)
            .appendingPathComponent("project_bundle.json")
    }

    public func rasterDirectory(root: URL, projectID: String) -> URL {
        projectDirectory(root: root, projectID: projectID)
            .appendingPathComponent("frames", isDirectory: true)
    }

    // MARK: - Save

    @discardableResult
    public func save(
        bundle: StudioProjectBundle,
        root: URL
    ) throws -> URL {
        let projectDir = projectDirectory(root: root, projectID: bundle.projectID)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let bundleURL = bundleFileURL(root: root, projectID: bundle.projectID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(bundle)
        } catch {
            throw ProjectPersistenceError.encodingFailed(error.localizedDescription)
        }
        try data.write(to: bundleURL, options: .atomic)

        return projectDir
    }

    // MARK: - Load

    public func load(root: URL, projectID: String) throws -> StudioProjectBundle {
        let bundleURL = bundleFileURL(root: root, projectID: projectID)
        guard fileManager.fileExists(atPath: bundleURL.path) else {
            throw ProjectPersistenceError.directoryNotFound
        }
        let data: Data
        do {
            data = try Data(contentsOf: bundleURL)
        } catch {
            throw ProjectPersistenceError.fileOperationFailed(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(StudioProjectBundle.self, from: data)
        } catch {
            throw ProjectPersistenceError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - List

    public func listProjects(root: URL) -> [StudioProjectBundle] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { url in
            let bundleURL = url.appendingPathComponent("project_bundle.json")
            guard fileManager.fileExists(atPath: bundleURL.path),
                  let data = try? Data(contentsOf: bundleURL) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(StudioProjectBundle.self, from: data)
        }
    }

    // MARK: - Delete

    public func deleteProject(root: URL, projectID: String) throws {
        let projectDir = projectDirectory(root: root, projectID: projectID)
        guard fileManager.fileExists(atPath: projectDir.path) else { return }
        do {
            try fileManager.removeItem(at: projectDir)
        } catch {
            throw ProjectPersistenceError.fileOperationFailed(error.localizedDescription)
        }
    }

    // MARK: - Legacy Raster Discovery

    public func discoverLegacyRasters(root: URL, projectID: String) -> [LegacyRasterReference] {
        let framesDir = rasterDirectory(root: root, projectID: projectID)
        guard fileManager.fileExists(atPath: framesDir.path) else { return [] }

        let fm = fileManager
        guard let contents = try? fm.contentsOfDirectory(
            at: framesDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var refs: [LegacyRasterReference] = []
        for fileURL in contents {
            let filename = fileURL.lastPathComponent
            guard filename.hasPrefix("frame_") && filename.hasSuffix(".png") else { continue }
            let indexStr = filename.replacingOccurrences(of: "frame_", with: "")
                .replacingOccurrences(of: ".png", with: "")
            guard let index = Int(indexStr) else { continue }
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            refs.append(LegacyRasterReference(
                frameIndex: index,
                fileName: filename,
                byteCount: size
            ))
        }
        return refs.sorted { $0.frameIndex < $1.frameIndex }
    }

    // MARK: - Migration / Non-destructive Discovery

    public func migrateAndDiscover(
        root: URL,
        projectID: String,
        existingBundle: StudioProjectBundle?
    ) throws -> StudioProjectBundle {
        let discoveredRasters = discoverLegacyRasters(root: root, projectID: projectID)

        var bundle = existingBundle ?? StudioProjectBundle(projectID: projectID)
        let existingFrameIndices = Set(bundle.legacyRasterReferences.map(\.frameIndex))
        for ref in discoveredRasters where !existingFrameIndices.contains(ref.frameIndex) {
            bundle.legacyRasterReferences.append(ref)
        }
        bundle.legacyRasterReferences.sort { $0.frameIndex < $1.frameIndex }

        return bundle
    }

    // MARK: - Preserve Raster Bytes

    public func preserveRasterBytes(
        from sourceDir: URL,
        to destDir: URL,
        fileManager: FileManager? = nil
    ) throws {
        let fm = fileManager ?? self.fileManager
        guard fm.fileExists(atPath: sourceDir.path) else { return }
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let contents = try fm.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for fileURL in contents {
            let dest = destDir.appendingPathComponent(fileURL.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try fm.copyItem(at: fileURL, to: dest)
            }
        }
    }
}
