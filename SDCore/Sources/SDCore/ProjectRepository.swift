// ═══════════════════════════════════════════════════════════════════
// ProjectRepository — Local persistence for studio projects
// All save/load is local-first. Remote is optional.
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Repository Protocol

public protocol ProjectRepository {
    func save(_ snapshot: ProjectSnapshot) throws
    func load(id: String) throws -> ProjectSnapshot?
    func listAll() throws -> [ProjectSnapshot]
    func delete(id: String) throws
}

// MARK: - File-Based Repository

/// Concrete repository that persists to the documents directory.
public final class FileProjectRepository: ProjectRepository {
    private let baseDir: URL

    public init(baseDir: URL) {
        self.baseDir = baseDir
    }

    private func projectDir(id: String) -> URL {
        baseDir.appendingPathComponent(id, isDirectory: true)
    }

    private func projectFile(id: String) -> URL {
        projectDir(id: id).appendingPathComponent("project.json")
    }

    public func save(_ snapshot: ProjectSnapshot) throws {
        let dir = projectDir(id: snapshot.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: projectFile(id: snapshot.id))
    }

    public func load(id: String) throws -> ProjectSnapshot? {
        let file = projectFile(id: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }

        let data = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProjectSnapshot.self, from: data)
    }

    public func listAll() throws -> [ProjectSnapshot] {
        guard FileManager.default.fileExists(atPath: baseDir.path) else { return [] }

        let contents = try FileManager.default.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var projects: [ProjectSnapshot] = []
        for dir in contents {
            let file = dir.appendingPathComponent("project.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let data = try Data(contentsOf: file)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let snapshot = try? decoder.decode(ProjectSnapshot.self, from: data) {
                projects.append(snapshot)
            }
        }

        return projects.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func delete(id: String) throws {
        let dir = projectDir(id: id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }
}
