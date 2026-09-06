import Foundation

/// Local-first project storage. SDCore is the sole new animation writer/list/delete owner.
/// Persists canonical project state as JSON files on disk.
public final class StudioStorage: Sendable {
    private let fileManager: FileManager
    private let baseDirectory: URL

    /// Initialize with a base directory (typically ~/Documents/StudioProjects).
    public init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    // MARK: - Directory

    private func projectDirectory(for id: String) -> URL {
        baseDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private func projectFileURL(for id: String) -> URL {
        projectDirectory(for: id).appendingPathComponent("project.json")
    }

    // MARK: - Create

    /// Create a new project with a durable String ID. Persists immediately.
    @discardableResult
    public func createProject(
        id: String,
        name: String,
        canvasWidth: Int = 1080,
        canvasHeight: Int = 1080,
        fps: Int = 12
    ) throws -> StudioProject {
        let now = Date()
        var project = StudioProject(
            id: id,
            name: name,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            fps: fps,
            createdAt: now,
            updatedAt: now
        )
        try saveProject(project)
        return project
    }

    // MARK: - Save

    /// Persist project metadata, frames, elements, layers, and session to disk.
    public func saveProject(_ project: StudioProject) throws {
        let dir = projectDirectory(for: project.id)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        var mutable = project
        mutable.updatedAt = Date()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(mutable)
        try data.write(to: projectFileURL(for: project.id), options: .atomic)
    }

    // MARK: - Load

    /// Load project from local disk.
    public func loadProject(id: String) throws -> StudioProject? {
        let url = projectFileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StudioProject.self, from: data)
    }

    // MARK: - List

    /// List all local projects. Works offline/signed-out.
    public func listProjects() throws -> [StudioProject] {
        guard fileManager.fileExists(atPath: baseDirectory.path) else { return [] }
        let contents = try fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil
        )
        var projects: [StudioProject] = []
        for dir in contents {
            let fileURL = dir.appendingPathComponent("project.json")
            guard fileManager.fileExists(atPath: fileURL.path) else { continue }
            if let project = try? loadProject(id: dir.lastPathComponent) {
                projects.append(project)
            }
        }
        return projects.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Delete

    public func deleteProject(id: String) throws {
        let dir = projectDirectory(for: id)
        guard fileManager.fileExists(atPath: dir.path) else { return }
        try fileManager.removeItem(at: dir)
    }
}
