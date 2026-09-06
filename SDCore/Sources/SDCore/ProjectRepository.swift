import Foundation

public protocol ProjectStore {
    func loadProject(id: String) throws -> Project?
    func saveProject(_ project: Project) throws
    func listProjects() throws -> [Project]
    func deleteProject(id: String) throws
    func projectExists(id: String) throws -> Bool
}

public final class LocalProjectStore: ProjectStore {
    private let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    private func projectDir(id: String) -> URL {
        baseDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private func projectFile(id: String) -> URL {
        projectDir(id: id).appendingPathComponent("project.json")
    }

    public func projectExists(id: String) throws -> Bool {
        FileManager.default.fileExists(atPath: projectFile(id: id).path)
    }

    public func loadProject(id: String) throws -> Project? {
        let file = projectFile(id: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        return try JSONDecoder().decode(Project.self, from: data)
    }

    public func saveProject(_ project: Project) throws {
        let dir = projectDir(id: project.id)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        try data.write(to: projectFile(id: project.id), options: .atomic)
    }

    public func listProjects() throws -> [Project] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDirectory.path) else { return [] }
        let contents = try fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)
        var projects: [Project] = []
        for dir in contents {
            let file = dir.appendingPathComponent("project.json")
            guard fm.fileExists(atPath: file.path) else { continue }
            let data = try Data(contentsOf: file)
            if let project = try? JSONDecoder().decode(Project.self, from: data) {
                projects.append(project)
            }
        }
        return projects.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func deleteProject(id: String) throws {
        let dir = projectDir(id: id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}

public final class ProjectRepository {
    private let store: ProjectStore
    private let remoteStore: RemoteStore?
    private var cachedProjects: [Project] = []
    private var cachedCurrent: Project?

    public init(store: ProjectStore, remoteStore: RemoteStore? = nil) {
        self.store = store
        self.remoteStore = remoteStore
    }

    public var currentProject: Project? { cachedCurrent }

    @discardableResult
    public func createProject(
        name: String,
        width: Int = 1080,
        height: Int = 1080,
        fps: Int = 12
    ) throws -> Project {
        let id = UUID().uuidString
        let now = Date()
        let firstLayer = CanvasLayer(id: UUID().uuidString, name: "Layer 1")
        var project = Project(
            id: id,
            name: name,
            width: width,
            height: height,
            fps: fps,
            frames: [AnimationFrame()],
            layers: [firstLayer],
            activeLayerID: firstLayer.id,
            activeFrameIndex: 0,
            createdAt: now,
            updatedAt: now
        )
        try store.saveProject(project)
        cachedCurrent = project
        cachedProjects.insert(project, at: 0)
        return project
    }

    public func loadProject(id: String) throws -> Project? {
        guard let project = try store.loadProject(id: id) else { return nil }
        cachedCurrent = project
        return project
    }

    @discardableResult
    public func save(_ project: Project) throws -> Project {
        var updated = project
        updated.updatedAt = Date()
        try store.saveProject(updated)
        cachedCurrent = updated
        if let idx = cachedProjects.firstIndex(where: { $0.id == updated.id }) {
            cachedProjects[idx] = updated
        }
        return updated
    }

    public func listProjects() throws -> [Project] {
        cachedProjects = try store.listProjects()
        return cachedProjects
    }

    public func deleteProject(id: String) throws {
        try store.deleteProject(id: id)
        cachedProjects.removeAll { $0.id == id }
        if cachedCurrent?.id == id { cachedCurrent = nil }
    }
}
