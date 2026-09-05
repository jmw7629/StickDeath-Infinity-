import Foundation

public enum StudioStorageError: LocalizedError, Sendable {
    case projectNotFound(String)
    case saveFailed(String)
    case loadFailed(String)
    case directoryCreationFailed(String)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .projectNotFound(let id): return "Project not found: \(id)"
        case .saveFailed(let msg): return "Save failed: \(msg)"
        case .loadFailed(let msg): return "Load failed: \(msg)"
        case .directoryCreationFailed(let msg): return "Directory creation failed: \(msg)"
        case .encodingFailed(let msg): return "Encoding failed: \(msg)"
        }
    }
}

public final class StudioStorage: @unchecked Sendable {
    private let fileManager: FileManager
    private let baseDir: URL

    public init(fileManager: FileManager = .default, baseDir: URL? = nil) {
        self.fileManager = fileManager
        if let baseDir {
            self.baseDir = baseDir
        } else {
            self.baseDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent("StudioProjects", isDirectory: true)
        }
    }

    public var projectsRoot: URL { baseDir }

    private func projectDir(for id: String) -> URL {
        baseDir.appendingPathComponent(id, isDirectory: true)
    }

    private func metadataURL(for id: String) -> URL {
        projectDir(for: id).appendingPathComponent("metadata.json")
    }

    private func framesURL(for id: String) -> URL {
        projectDir(for: id).appendingPathComponent("frames.json")
    }

    private func layersURL(for id: String) -> URL {
        projectDir(for: id).appendingPathComponent("layers.json")
    }

    // MARK: - Create

    @discardableResult
    public func createProject(
        id: String = UUID().uuidString,
        name: String = "Untitled Animation",
        width: Int = 1080,
        height: Int = 1080,
        fps: Int = 12,
        userID: String? = nil
    ) throws -> ProjectMetadata {
        let dir = projectDir(for: id)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw StudioStorageError.directoryCreationFailed(error.localizedDescription)
        }

        let now = Date()
        var meta = ProjectMetadata(
            id: id, name: name, width: width, height: height, fps: fps,
            frameCount: 1, layerCount: 1, createdAt: now, updatedAt: now, userID: userID
        )

        let defaultLayer = CanvasLayer(id: "layer_default", name: "Layer 1")
        let defaultFrame = AnimationFrame(id: UUID().uuidString, elements: [])

        try saveMetadata(meta, for: id)
        try saveFrames([defaultFrame], for: id)
        try saveLayers([defaultLayer], for: id)

        return meta
    }

    // MARK: - Save

    public func saveMetadata(_ meta: ProjectMetadata, for id: String) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(meta)
        } catch {
            throw StudioStorageError.encodingFailed(error.localizedDescription)
        }
        do {
            try data.write(to: metadataURL(for: id), options: .atomic)
        } catch {
            throw StudioStorageError.saveFailed(error.localizedDescription)
        }
    }

    public func saveFrames(_ frames: [AnimationFrame], for id: String) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(frames)
        } catch {
            throw StudioStorageError.encodingFailed(error.localizedDescription)
        }
        do {
            try data.write(to: framesURL(for: id), options: .atomic)
        } catch {
            throw StudioStorageError.saveFailed(error.localizedDescription)
        }
    }

    public func saveLayers(_ layers: [CanvasLayer], for id: String) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(layers)
        } catch {
            throw StudioStorageError.encodingFailed(error.localizedDescription)
        }
        do {
            try data.write(to: layersURL(for: id), options: .atomic)
        } catch {
            throw StudioStorageError.saveFailed(error.localizedDescription)
        }
    }

    public func save(
        frames: [AnimationFrame],
        layers: [CanvasLayer],
        activeLayerID: String,
        currentFrameIndex: Int,
        for id: String
    ) throws {
        var meta = try loadMetadata(for: id)
        meta.frameCount = frames.count
        meta.layerCount = layers.count
        meta.updatedAt = Date()

        try saveMetadata(meta, for: id)
        try saveFrames(frames, for: id)
        try saveLayers(layers, for: id)

        let stateFile = projectDir(for: id).appendingPathComponent("state.json")
        let state = SessionState(activeLayerID: activeLayerID, currentFrameIndex: currentFrameIndex)
        let stateData = try JSONEncoder().encode(state)
        try stateData.write(to: stateFile, options: .atomic)
    }

    // MARK: - Load

    public func loadMetadata(for id: String) throws -> ProjectMetadata {
        let url = metadataURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw StudioStorageError.projectNotFound(id)
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ProjectMetadata.self, from: data)
        } catch {
            throw StudioStorageError.loadFailed(error.localizedDescription)
        }
    }

    public func loadFrames(for id: String) throws -> [AnimationFrame] {
        let url = framesURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([AnimationFrame].self, from: data)
        } catch {
            throw StudioStorageError.loadFailed(error.localizedDescription)
        }
    }

    public func loadLayers(for id: String) throws -> [CanvasLayer] {
        let url = layersURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([CanvasLayer].self, from: data)
        } catch {
            throw StudioStorageError.loadFailed(error.localizedDescription)
        }
    }

    public func loadState(for id: String) -> SessionState {
        let stateFile = projectDir(for: id).appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(SessionState.self, from: data) else {
            return SessionState(activeLayerID: "layer_default", currentFrameIndex: 0)
        }
        return state
    }

    public func load(
        for id: String
    ) throws -> (meta: ProjectMetadata, frames: [AnimationFrame], layers: [CanvasLayer], state: SessionState) {
        let meta = try loadMetadata(for: id)
        let frames = try loadFrames(for: id)
        let layers = try loadLayers(for: id)
        let state = loadState(for: id)
        return (meta, frames, layers, state)
    }

    // MARK: - List

    public func listProjects() -> [ProjectMetadata] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return contents.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("metadata.json")) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(ProjectMetadata.self, from: data)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Delete

    public func deleteProject(id: String) throws {
        let dir = projectDir(for: id)
        guard fileManager.fileExists(atPath: dir.path) else {
            throw StudioStorageError.projectNotFound(id)
        }
        try fileManager.removeItem(at: dir)
    }

    // MARK: - Raster asset management

    public func saveRasterAsset(data: Data, projectID: String, filename: String) throws -> URL {
        let assetsDir = projectDir(for: projectID).appendingPathComponent("assets", isDirectory: true)
        try fileManager.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let fileURL = assetsDir.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    public func loadRasterAsset(projectID: String, filename: String) throws -> Data? {
        let fileURL = projectDir(for: projectID).appendingPathComponent("assets").appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    public func rasterAssetExists(projectID: String, filename: String) -> Bool {
        let fileURL = projectDir(for: projectID).appendingPathComponent("assets").appendingPathComponent(filename)
        return fileManager.fileExists(atPath: fileURL.path)
    }

    public func listRasterAssets(projectID: String) -> [String] {
        let assetsDir = projectDir(for: projectID).appendingPathComponent("assets")
        guard let contents = try? fileManager.contentsOfDirectory(
            at: assetsDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents.map { $0.lastPathComponent }.sorted()
    }
}

public struct SessionState: Codable, Sendable {
    public var activeLayerID: String
    public var currentFrameIndex: Int

    public init(activeLayerID: String = "layer_default", currentFrameIndex: Int = 0) {
        self.activeLayerID = activeLayerID
        self.currentFrameIndex = currentFrameIndex
    }
}
