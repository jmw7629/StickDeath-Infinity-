// ═══════════════════════════════════════════════════════════════════
// ProjectCoordinator — Local-first + optional remote lifecycle
// Single canonical coordinator owned by StudioViewModel.
// Local persistence is mandatory; remote is optional and only
// runs after successful local save.
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - ProjectCoordinator Protocol

public protocol ProjectCoordinator {
    /// Save project locally, then optionally sync to remote.
    /// Local failure => throws, zero remote calls.
    /// Remote failure => local state preserved, returns success.
    func save(_ snapshot: ProjectSnapshot) async throws

    /// Open a project by ID. Discovers and migrates legacy assets automatically.
    func openProject(id: String) async throws -> ProjectSnapshot?

    /// Load all projects. Local first, then optional remote reconciliation.
    func loadProjects() async throws -> [ProjectSnapshot]

    /// Create a new project locally, then optionally push to remote.
    func createProject(_ snapshot: ProjectSnapshot) async throws
}

// MARK: - DefaultProjectCoordinator

/// The exact coordinator used by StudioViewModel. Owns local-first
/// + optional remote behavior through the tested seams.
public final class DefaultProjectCoordinator: ProjectCoordinator {
    private let localRepository: ProjectRepository
    private let remoteStore: RemoteStore?
    private let migration: LegacyMigration?

    public init(
        localRepository: ProjectRepository,
        remoteStore: RemoteStore? = nil,
        migration: LegacyMigration? = nil
    ) {
        self.localRepository = localRepository
        self.remoteStore = remoteStore
        self.migration = migration
    }

    // MARK: - Save

    public func save(_ snapshot: ProjectSnapshot) async throws {
        // 1. Canonical local persistence — must succeed
        try localRepository.save(snapshot)

        // 2. Remote sync — only if configured and local succeeded
        guard let remote = remoteStore else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let frameData = try encoder.encode(snapshot.frames)
        let frameJSON = String(data: frameData, encoding: .utf8) ?? "[]"

        do {
            _ = try await remote.uploadVersion(
                projectID: snapshot.id,
                frameData: frameJSON
            )
        } catch {
            // Remote failure => local state preserved, no throw
        }
    }

    // MARK: - Open Project

    public func openProject(id: String) async throws -> ProjectSnapshot? {
        // 1. Try loading canonical local project
        if var snapshot = try localRepository.load(id: id) {
            // 2. Run legacy sibling migration if applicable
            if let migrator = migration {
                snapshot = try migrator.migrateIfNeeded(
                    projectID: id,
                    existing: snapshot
                )
            }
            return snapshot
        }

        // 3. If no canonical project exists, check for legacy-only migration
        if let migrator = migration {
            let migrated = try migrator.migrateFromLegacy(projectID: id)
            if let snapshot = migrated {
                // Save migrated project locally
                try localRepository.save(snapshot)
                return snapshot
            }
        }

        return nil
    }

    // MARK: - Load Projects

    public func loadProjects() async throws -> [ProjectSnapshot] {
        // 1. Local projects first (offline/signed-out)
        var projects = try localRepository.listAll()

        // 2. Optional remote reconciliation through the same production seam
        if let remote = remoteStore {
            do {
                let remoteVersions = try await remote.listProjects()
                // Merge remote projects that don't exist locally
                let localIDs = Set(projects.map(\.id))
                for version in remoteVersions {
                    if !localIDs.contains(version.projectID) {
                        // Create a minimal local snapshot from remote metadata
                        let snapshot = ProjectSnapshot(
                            id: version.projectID,
                            updatedAt: ISO8601DateFormatter().date(from: version.createdAt) ?? Date()
                        )
                        try? localRepository.save(snapshot)
                        projects.append(snapshot)
                    }
                }
            } catch {
                // Remote failure never hides local projects
            }
        }

        return projects
    }

    // MARK: - Create Project

    public func createProject(_ snapshot: ProjectSnapshot) async throws {
        // 1. Local persistence first
        try localRepository.save(snapshot)

        // 2. Optional remote push
        guard let remote = remoteStore else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let frameData = try encoder.encode(snapshot.frames)
        let frameJSON = String(data: frameData, encoding: .utf8) ?? "[]"

        do {
            _ = try await remote.uploadVersion(
                projectID: snapshot.id,
                frameData: frameJSON
            )
        } catch {
            // Remote failure => local state preserved
        }
    }
}
