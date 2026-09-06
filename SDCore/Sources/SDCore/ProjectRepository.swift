// ═══════════════════════════════════════════════════════════════════
// ProjectRepository — Production lifecycle coordinator
// Create → save locally → optionally sync remote.
// Local failure = zero remote calls. Remote failure after local
// success = local data preserved (no rollback).
// Real StudioViewModel delegates to this seam.
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Repository Errors

public enum ProjectRepositoryError: Error, Sendable, Equatable {
    case localSaveFailed(String)
    case remoteSyncFailed(String)
    case projectNotFound(String)
    case notConfigured
}

// MARK: - Project Repository Protocol

public protocol ProjectRepository: Sendable {
    func createProject(name: String, width: Int, height: Int, fps: Int) async throws -> SDProject
    func saveProject(_ project: SDProject) async throws
    func loadProjects() async -> [SDProject]
    func openProject(id: String) async throws -> SDProject
    func reopenProject(id: String) async throws -> SDProject
}

// MARK: - Production Repository

public final class ProductionProjectRepository: ProjectRepository, @unchecked Sendable {
    private let storage: ProjectStorage
    private let transport: BackendTransportCaller

    public init(storage: ProjectStorage, transport: BackendTransportCaller) {
        self.storage = storage
        self.transport = transport
    }

    // MARK: - Create

    public func createProject(
        name: String,
        width: Int,
        height: Int,
        fps: Int
    ) async throws -> SDProject {
        let projectID = UUID().uuidString
        var project = SDProject(
            projectID: projectID,
            name: name,
            width: width,
            height: height,
            fps: fps
        )

        // Local save first — must succeed before remote sync
        do {
            try storage.saveProject(project)
        } catch {
            throw ProjectRepositoryError.localSaveFailed(error.localizedDescription)
        }

        // Remote sync only if local save succeeded and transport is available
        if transport.canMakeTransportCalls {
            do {
                let body: [String: Any] = [
                    "id": projectID,
                    "name": name,
                    "width": width,
                    "height": height,
                    "fps": fps
                ]
                _ = try await transport.call(path: "studio_projects", body: body)
            } catch {
                // Remote failure does not erase local data
                // Log but do not throw — local save is the source of truth
            }
        }

        return project
    }

    // MARK: - Save (overwrite existing)

    public func saveProject(_ project: SDProject) async throws {
        // Local save first — must succeed before remote sync
        do {
            try storage.saveProject(project)
        } catch {
            throw ProjectRepositoryError.localSaveFailed(error.localizedDescription)
        }

        // Remote sync only if local save succeeded and transport is available
        if transport.canMakeTransportCalls {
            do {
                let encoder = JSONEncoder()
                let frameData = try encoder.encode(project.frames)
                let frameJSON = String(data: frameData, encoding: .utf8) ?? "[]"
                let body: [String: Any] = [
                    "project_id": project.projectID,
                    "frame_data": frameJSON
                ]
                _ = try await transport.call(path: "studio_project_versions", body: body)
            } catch {
                // Remote failure does not erase local data
            }
        }
    }

    // MARK: - Load Projects

    public func loadProjects() async -> [SDProject] {
        storage.listProjects()
    }

    // MARK: - Open Project

    public func openProject(id: String) async throws -> SDProject {
        guard let project = try storage.loadProject(id: id) else {
            throw ProjectRepositoryError.projectNotFound(id)
        }
        return project
    }

    // MARK: - Reopen (load + apply legacy migration if needed)

    public func reopenProject(id: String) async throws -> SDProject {
        var project = try storage.loadProject(id: id)

        if project == nil {
            // Check for legacy animation at the old path
            let migrated = LegacyAssetMigration.migrateLegacyAnimation(
                id: id,
                storage: storage
            )
            if let migrated {
                project = migrated
            }
        }

        guard let project else {
            throw ProjectRepositoryError.projectNotFound(id)
        }
        return project
    }
}
