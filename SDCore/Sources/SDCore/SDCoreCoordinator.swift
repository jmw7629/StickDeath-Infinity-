import Foundation

public final class SDCoreCoordinator {
    public let repository: ProjectRepository
    public let layerCommands: LayerCommands
    public let migration: MigrationService

    private var currentProject: Project?

    public init(store: ProjectStore, remoteStore: RemoteStore? = nil) {
        self.repository = ProjectRepository(store: store, remoteStore: remoteStore)
        self.migration = MigrationService()
        self.layerCommands = LayerCommands(
            project: { [weak self] in self?.currentProject },
            save: { [weak self] project in
                try self?.repository.save(project) ?? project
            }
        )
    }

    public func loadProjects() throws -> [Project] {
        try repository.listProjects()
    }

    @discardableResult
    public func createProject(
        name: String,
        width: Int = 1080,
        height: Int = 1080,
        fps: Int = 12
    ) throws -> Project {
        let project = try repository.createProject(name: name, width: width, height: height, fps: fps)
        currentProject = project
        return project
    }

    @discardableResult
    public func openProject(id: String) throws -> Project? {
        guard let project = try repository.loadProject(id: id) else { return nil }
        currentProject = project
        return project
    }

    @discardableResult
    public func save() throws -> Project {
        guard var project = currentProject else { throw ProjectError.noProject }
        project.updatedAt = Date()
        let saved = try repository.save(project)
        currentProject = saved
        return saved
    }

    @discardableResult
    public func reopenProject(id: String, legacyDir: URL? = nil) throws -> (project: Project, migrationResult: MigrationResult?) {
        guard var project = try repository.loadProject(id: id) else {
            throw ProjectError.notFound
        }

        var migrationResult: MigrationResult?
        if let legacy = legacyDir {
            let canonicalDir = migration.canonicalDir(for: id, baseDir: legacy.deletingLastPathComponent().deletingLastPathComponent())
            migrationResult = try migration.migrateLegacyAnimation(
                legacyID: id,
                legacyDir: legacy,
                canonicalDir: canonicalDir,
                project: project
            )
            if let migrated = try repository.loadProject(id: id) {
                project = migrated
            }
        }

        currentProject = project
        return (project, migrationResult)
    }

    public var activeProject: Project? { currentProject }
}
