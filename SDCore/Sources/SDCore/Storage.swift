// ═══════════════════════════════════════════════════════════════════
// Storage — Local project persistence coordinator
// Reads/writes canonical SDProject as project.json in
// <Documents>/StudioProjects/<id>/project.json
// Linux-testable via Foundation FileManager.
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Storage Errors

public enum StorageError: Error, Sendable, Equatable {
    case directoryCreationFailed(String)
    case encodingFailed
    case decodingFailed
    case fileNotFound(String)
    case writeFailed(String)
    case deleteFailed(String)
}

// MARK: - Project Storage Protocol

public protocol ProjectStorage: Sendable {
    func saveProject(_ project: SDProject) throws
    func loadProject(id: String) throws -> SDProject?
    func listProjects() -> [SDProject]
    func deleteProject(id: String) throws
    func projectDirectory(for id: String) -> URL
}

// MARK: - Local Project Storage (FileManager-based)

public final class LocalProjectStorage: ProjectStorage, @unchecked Sendable {
    private let baseDir: URL
    private let fileManager: FileManager

    public init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDir = baseDirectory
        self.fileManager = fileManager
    }

    // MARK: - Paths

    public func projectDirectory(for id: String) -> URL {
        baseDir.appendingPathComponent("StudioProjects", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    private func projectJSONPath(for id: String) -> URL {
        projectDirectory(for: id).appendingPathComponent("project.json")
    }

    // MARK: - Save

    public func saveProject(_ project: SDProject) throws {
        let dir = projectDirectory(for: project.projectID)
        try ensureDirectory(dir)
        let data = try JSONEncoder().encode(project)
        try data.write(to: projectJSONPath(for: project.projectID), options: .atomic)
    }

    // MARK: - Load

    public func loadProject(id: String) throws -> SDProject? {
        let path = projectJSONPath(for: id)
        guard fileManager.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(SDProject.self, from: data)
    }

    // MARK: - List

    public func listProjects() -> [SDProject] {
        let projectsDir = baseDir.appendingPathComponent("StudioProjects", isDirectory: true)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents.compactMap { dir in
            let jsonPath = dir.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: jsonPath),
                  let project = try? JSONDecoder().decode(SDProject.self, from: data) else {
                return nil
            }
            return project
        }
    }

    // MARK: - Delete

    public func deleteProject(id: String) throws {
        let dir = projectDirectory(for: id)
        guard fileManager.fileExists(atPath: dir.path) else { return }
        try fileManager.removeItem(at: dir)
    }

    // MARK: - Helpers

    private func ensureDirectory(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw StorageError.directoryCreationFailed(url.path)
            }
        }
    }
}
