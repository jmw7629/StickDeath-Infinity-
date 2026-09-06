import Foundation

public enum StudioStorageError: Error, Equatable {
    case projectNotFound(String)
    case encodingFailed(String)
    case decodingFailed(String)
    case filesystemError(String)
}

public final class StudioStorage {
    public static let shared = StudioStorage()

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public var baseDirectory: URL

    public init(baseDirectory: URL? = nil) {
        if let dir = baseDirectory {
            self.baseDirectory = dir
        } else {
            self.baseDirectory = Self.defaultBaseDirectory()
        }
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultBaseDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("StudioProjects", isDirectory: true)
    }

    private func projectDir(for id: String) -> URL {
        baseDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private func projectFile(for id: String) -> URL {
        projectDir(for: id).appendingPathComponent("project.json")
    }

    // MARK: - Create

    @discardableResult
    public func createProject(_ project: SDProject) throws -> SDProject {
        let dir = projectDir(for: project.id)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(project)
        try data.write(to: projectFile(for: project.id))
        return project
    }

    // MARK: - Save (overwrite)

    public func saveProject(_ project: SDProject) throws {
        var updated = project
        updated.updatedAt = Date()
        let dir = projectDir(for: project.id)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let data = try encoder.encode(updated)
        try data.write(to: projectFile(for: project.id))
    }

    // MARK: - Load

    public func loadProject(id: String) throws -> SDProject {
        let file = projectFile(for: id)
        guard fileManager.fileExists(atPath: file.path) else {
            throw StudioStorageError.projectNotFound(id)
        }
        let data = try Data(contentsOf: file)
        return try decoder.decode(SDProject.self, from: data)
    }

    // MARK: - List

    public func listProjects() -> [SDProject] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return contents.compactMap { dir in
            let file = dir.appendingPathComponent("project.json")
            guard fileManager.fileExists(atPath: file.path),
                  let data = try? Data(contentsOf: file),
                  let project = try? decoder.decode(SDProject.self, from: data)
            else { return nil }
            return project
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
}
