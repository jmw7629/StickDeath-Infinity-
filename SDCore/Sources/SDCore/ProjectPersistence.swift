import Foundation

public struct ProjectDocument: Codable, Sendable {
    public var projectName: String
    public var canvasWidth: Int
    public var canvasHeight: Int
    public var fps: Int
    public var frames: [AnimationFrame]
    public var layers: [CanvasLayer]
    public var activeLayerID: String
    public var currentFrameIndex: Int

    public init(
        projectName: String = "Untitled Animation",
        canvasWidth: Int = 1080,
        canvasHeight: Int = 1080,
        fps: Int = 12,
        frames: [AnimationFrame] = [AnimationFrame()],
        layers: [CanvasLayer] = [CanvasLayer()],
        activeLayerID: String = "",
        currentFrameIndex: Int = 0
    ) {
        self.projectName = projectName
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.fps = fps
        self.frames = frames
        self.layers = layers
        self.activeLayerID = activeLayerID
        self.currentFrameIndex = currentFrameIndex
    }
}

public enum ProjectPersistenceError: Error, CustomStringConvertible {
    case directoryCreationFailed(String)
    case encodingFailed(String)
    case decodingFailed(String)
    case fileOperationFailed(String)

    public var description: String {
        switch self {
        case .directoryCreationFailed(let msg): return "Directory creation failed: \(msg)"
        case .encodingFailed(let msg): return "Encoding failed: \(msg)"
        case .decodingFailed(let msg): return "Decoding failed: \(msg)"
        case .fileOperationFailed(let msg): return "File operation failed: \(msg)"
        }
    }
}

public struct ProjectPersistence {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public var projectsRoot: URL {
        rootURL.appendingPathComponent("StudioProjects", isDirectory: true)
    }

    public func projectDir(for projectID: String) -> URL {
        projectsRoot.appendingPathComponent(projectID, isDirectory: true)
    }

    public func documentURL(for projectID: String) -> URL {
        projectDir(for: projectID).appendingPathComponent("project.json")
    }

    public func rasterDir(for projectID: String) -> URL {
        projectDir(for: projectID).appendingPathComponent("frames", isDirectory: true)
    }

    // MARK: - Save

    @discardableResult
    public func save(_ document: ProjectDocument, projectID: String) throws -> URL {
        let dir = projectDir(for: projectID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw ProjectPersistenceError.encodingFailed(error.localizedDescription)
        }

        let docURL = documentURL(for: projectID)
        do {
            try data.write(to: docURL, options: .atomic)
        } catch {
            throw ProjectPersistenceError.fileOperationFailed(error.localizedDescription)
        }

        return docURL
    }

    // MARK: - Load

    public func load(projectID: String) throws -> ProjectDocument {
        let docURL = documentURL(for: projectID)
        guard FileManager.default.fileExists(atPath: docURL.path) else {
            throw ProjectPersistenceError.decodingFailed("Project document not found at \(docURL.path)")
        }

        let data: Data
        do {
            data = try Data(contentsOf: docURL)
        } catch {
            throw ProjectPersistenceError.fileOperationFailed(error.localizedDescription)
        }

        do {
            return try JSONDecoder().decode(ProjectDocument.self, from: data)
        } catch {
            throw ProjectPersistenceError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Raster Frame Operations

    public func rasterURL(for projectID: String, frameIndex: Int) -> URL {
        rasterDir(for: projectID).appendingPathComponent("frame_\(frameIndex).png")
    }

    public func saveRaster(_ data: Data, projectID: String, frameIndex: Int) throws {
        let dir = rasterDir(for: projectID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = rasterURL(for: projectID, frameIndex: frameIndex)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ProjectPersistenceError.fileOperationFailed(error.localizedDescription)
        }
    }

    public func loadRaster(projectID: String, frameIndex: Int) -> Data? {
        let url = rasterURL(for: projectID, frameIndex: frameIndex)
        return try? Data(contentsOf: url)
    }

    public func discoverRasterIndices(projectID: String) -> [Int] {
        let dir = rasterDir(for: projectID)
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

    // MARK: - Delete

    public func deleteProject(projectID: String) throws {
        let dir = projectDir(for: projectID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            throw ProjectPersistenceError.fileOperationFailed(error.localizedDescription)
        }
    }

    // MARK: - List

    public func listProjects() -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        return contents
            .filter { $0.hasDirectoryPath }
            .map { $0.lastPathComponent }
            .sorted()
    }
}
