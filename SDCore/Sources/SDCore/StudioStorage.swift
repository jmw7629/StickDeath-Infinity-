// ═══════════════════════════════════════════════════════════════════
// SDCore StudioStorage — One production local persistence owner.
// Directory layout: <Documents>/StudioProjects/<id>/...
//   metadata.json          — project metadata (StudioProjectRecord)
//   frames.json            — canonical [AnimationFrame] array
//   layers.json            — canonical [CanvasLayer] array
//   session.json           — active layer, current frame index
//   frame_N.png            — raster frame images (legacy compat)
// ═══════════════════════════════════════════════════════════════════

import Foundation

public final class StudioStorage: Sendable {
    public static let shared = StudioStorage()

    private let fileManager = FileManager.default

    // MARK: - Directory Layout

    public func baseDirectory(root: URL? = nil) -> URL {
        let docs = root ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("StudioProjects", isDirectory: true)
    }

    public func projectDirectory(id: String, root: URL? = nil) -> URL {
        baseDirectory(root: root).appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - Create Project

    @discardableResult
    public func createProject(
        id: String,
        name: String,
        width: Int = 1080,
        height: Int = 1080,
        fps: Int = 12,
        root: URL? = nil
    ) throws -> StudioProjectRecord {
        let dir = projectDirectory(id: id, root: root)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let now = ISO8601DateFormatter().string(from: Date())
        let project = StudioProjectRecord(
            id: id,
            name: name,
            width: width,
            height: height,
            fps: fps,
            frameCount: 1,
            createdAt: now,
            updatedAt: now
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try data.write(to: dir.appendingPathComponent("metadata.json"))

        let initialFrame = [AnimationFrame(id: UUID().uuidString, elements: [])]
        let frameData = try encoder.encode(initialFrame)
        try frameData.write(to: dir.appendingPathComponent("frames.json"))

        let initialLayer = [CanvasLayer(id: UUID().uuidString, name: "Layer 1")]
        let layerData = try encoder.encode(initialLayer)
        try layerData.write(to: dir.appendingPathComponent("layers.json"))

        let session = SessionState(activeLayerID: initialLayer.first?.id ?? "", currentFrameIndex: 0)
        let sessionData = try encoder.encode(session)
        try sessionData.write(to: dir.appendingPathComponent("session.json"))

        return project
    }

    // MARK: - Save Project

    public func saveProject(
        id: String,
        metadata: StudioProjectRecord? = nil,
        frames: [AnimationFrame]? = nil,
        layers: [CanvasLayer]? = nil,
        session: SessionState? = nil,
        root: URL? = nil
    ) throws {
        let dir = projectDirectory(id: id, root: root)
        guard fileManager.fileExists(atPath: dir.path) else {
            throw StudioStorageError.projectNotFound(id)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let metadata {
            let data = try encoder.encode(metadata)
            try data.write(to: dir.appendingPathComponent("metadata.json"))
        }

        if let frames {
            let data = try encoder.encode(frames)
            try data.write(to: dir.appendingPathComponent("frames.json"))
        }

        if let layers {
            let data = try encoder.encode(layers)
            try data.write(to: dir.appendingPathComponent("layers.json"))
        }

        if let session {
            let data = try encoder.encode(session)
            try data.write(to: dir.appendingPathComponent("session.json"))
        }
    }

    // MARK: - Load Project

    public func loadProject(id: String, root: URL? = nil) throws -> LoadedProject {
        let dir = projectDirectory(id: id, root: root)
        guard fileManager.fileExists(atPath: dir.path) else {
            throw StudioStorageError.projectNotFound(id)
        }

        let decoder = JSONDecoder()

        let metadataData = try Data(contentsOf: dir.appendingPathComponent("metadata.json"))
        let metadata = try decoder.decode(StudioProjectRecord.self, from: metadataData)

        let framesData = try Data(contentsOf: dir.appendingPathComponent("frames.json"))
        let frames = try decoder.decode([AnimationFrame].self, from: framesData)

        let layersData = try Data(contentsOf: dir.appendingPathComponent("layers.json"))
        let layers = try decoder.decode([CanvasLayer].self, from: layersData)

        let session: SessionState
        let sessionURL = dir.appendingPathComponent("session.json")
        if fileManager.fileExists(atPath: sessionURL.path) {
            let sessionData = try Data(contentsOf: sessionURL)
            session = try decoder.decode(SessionState.self, from: sessionData)
        } else {
            session = SessionState(activeLayerID: layers.first?.id ?? "", currentFrameIndex: 0)
        }

        return LoadedProject(
            metadata: metadata,
            frames: frames,
            layers: layers,
            session: session
        )
    }

    // MARK: - List Projects

    public func listProjects(root: URL? = nil) -> [StudioProjectRecord] {
        let base = baseDirectory(root: root)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return contents.compactMap { dir in
            let metaURL = dir.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(StudioProjectRecord.self, from: data) else {
                return nil
            }
            return meta
        }
    }

    // MARK: - Delete Project

    public func deleteProject(id: String, root: URL? = nil) throws {
        let dir = projectDirectory(id: id, root: root)
        guard fileManager.fileExists(atPath: dir.path) else { return }
        try fileManager.removeItem(at: dir)
    }

    // MARK: - Legacy Migration Helpers

    public func legacyAnimationDirectory(root: URL? = nil) -> URL {
        let docs = root ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Animations", isDirectory: true)
    }

    public func discoverLegacyProjects(root: URL? = nil) -> [String] {
        let legacyDir = legacyAnimationDirectory(root: root)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: legacyDir,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return contents.filter { $0.hasDirectoryPath }.map { $0.lastPathComponent }
    }

    public func rasterFrameData(projectID: String, frameIndex: Int, root: URL? = nil) -> Data? {
        let dir = projectDirectory(id: projectID, root: root)
        let frameURL = dir.appendingPathComponent("frame_\(frameIndex).png")
        return try? Data(contentsOf: frameURL)
    }
}

// MARK: - Supporting Types

public struct SessionState: Codable, Equatable, Sendable {
    public var activeLayerID: String
    public var currentFrameIndex: Int

    public init(activeLayerID: String = "", currentFrameIndex: Int = 0) {
        self.activeLayerID = activeLayerID
        self.currentFrameIndex = currentFrameIndex
    }
}

public struct LoadedProject: Sendable {
    public let metadata: StudioProjectRecord
    public let frames: [AnimationFrame]
    public let layers: [CanvasLayer]
    public let session: SessionState

    public init(
        metadata: StudioProjectRecord,
        frames: [AnimationFrame],
        layers: [CanvasLayer],
        session: SessionState
    ) {
        self.metadata = metadata
        self.frames = frames
        self.layers = layers
        self.session = session
    }
}

public enum StudioStorageError: Error, Equatable {
    case projectNotFound(String)
}
