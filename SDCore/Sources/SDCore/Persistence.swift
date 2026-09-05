// ═══════════════════════════════════════════════════════════════════
// Persistence — Real file-system persistence for Studio projects
// Writes to: ~/Documents/Animations/{projectID}/
//   project.json  — metadata, frames, layers
//   frame_N.png   — legacy raster references (preserved, never silently deleted)
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Project Bundle (serialized to project.json)

public struct ProjectBundle: Codable, Equatable, Sendable {
    public var project: StudioProjectRecord
    public var frames: [AnimationFrame]
    public var layers: [CanvasLayer]
    public var legacyRasterFiles: [String]  // filenames like "frame_0.png", "frame_1.png"

    public init(
        project: StudioProjectRecord,
        frames: [AnimationFrame],
        layers: [CanvasLayer],
        legacyRasterFiles: [String] = []
    ) {
        self.project = project
        self.frames = frames
        self.layers = layers
        self.legacyRasterFiles = legacyRasterFiles
    }
}

// MARK: - Persistence Errors

public enum PersistenceError: Error, CustomStringConvertible {
    case directoryCreationFailed(String)
    case encodingFailed(String)
    case decodingFailed(String)
    case fileNotFound(String)
    case saveFailed(String)

    public var description: String {
        switch self {
        case .directoryCreationFailed(let msg): return "Directory creation failed: \(msg)"
        case .encodingFailed(let msg): return "Encoding failed: \(msg)"
        case .decodingFailed(let msg): return "Decoding failed: \(msg)"
        case .fileNotFound(let msg): return "File not found: \(msg)"
        case .saveFailed(let msg): return "Save failed: \(msg)"
        }
    }
}

// MARK: - Project Persistence

public struct ProjectPersistence {

    /// Base directory for all projects (e.g. ~/Documents/Animations/)
    public let baseDir: URL

    public init(baseDir: URL) {
        self.baseDir = baseDir
    }

    /// Convenience: default base dir under ~/Documents/Animations/
    public static var defaultBaseDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Animations", isDirectory: true)
    }

    // MARK: - Project directory

    public func projectDir(for projectID: String) -> URL {
        baseDir.appendingPathComponent(projectID, isDirectory: true)
    }

    // MARK: - Save

    public func save(_ bundle: ProjectBundle) throws {
        let dir = projectDir(for: bundle.project.id)
        let fm = FileManager.default

        // Create project directory
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw PersistenceError.directoryCreationFailed(error.localizedDescription)
        }

        // Encode and write project.json
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(bundle)
        } catch {
            throw PersistenceError.encodingFailed(error.localizedDescription)
        }
        do {
            try data.write(to: dir.appendingPathComponent("project.json"))
        } catch {
            throw PersistenceError.saveFailed(error.localizedDescription)
        }
    }

    // MARK: - Load

    public func load(projectID: String) throws -> ProjectBundle {
        let dir = projectDir(for: projectID)
        let jsonURL = dir.appendingPathComponent("project.json")

        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw PersistenceError.fileNotFound("project.json for \(projectID)")
        }

        let data: Data
        do {
            data = try Data(contentsOf: jsonURL)
        } catch {
            throw PersistenceError.decodingFailed(error.localizedDescription)
        }

        let bundle: ProjectBundle
        do {
            bundle = try JSONDecoder().decode(ProjectBundle.self, from: data)
        } catch {
            throw PersistenceError.decodingFailed(error.localizedDescription)
        }

        return bundle
    }

    // MARK: - Legacy Raster Files

    /// Load legacy raster file bytes from the project directory.
    /// These are frame_0.png, frame_1.png, etc. that were created before
    /// the vector drawing system existed.
    public func loadLegacyRasterFiles(projectID: String) throws -> [String: Data] {
        let dir = projectDir(for: projectID)
        let fm = FileManager.default

        guard fm.fileExists(atPath: dir.path) else { return [:] }

        var result: [String: Data] = [:]
        let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        for fileURL in contents ?? [] {
            let name = fileURL.lastPathComponent
            if name.hasPrefix("frame_") && name.hasSuffix(".png") {
                if let data = try? Data(contentsOf: fileURL) {
                    result[name] = data
                }
            }
        }
        return result
    }

    /// Save legacy raster files back to the project directory.
    /// Does NOT delete files that are not in the provided dictionary.
    public func saveLegacyRasterFiles(_ files: [String: Data], projectID: String) throws {
        let dir = projectDir(for: projectID)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw PersistenceError.directoryCreationFailed(error.localizedDescription)
        }

        for (name, data) in files {
            let fileURL = dir.appendingPathComponent(name)
            do {
                try data.write(to: fileURL)
            } catch {
                throw PersistenceError.saveFailed("Failed to write \(name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Full Save (bundle + raster + preserve existing raster files)

    /// Save a complete project bundle, preserving any existing legacy raster files
    /// that are not explicitly replaced.
    public func saveComplete(
        bundle: ProjectBundle,
        rasterFiles: [String: Data] = [:]
    ) throws {
        // 1. Load existing raster files so we can preserve them
        var existingRaster = (try? loadLegacyRasterFiles(projectID: bundle.project.id)) ?? [:]

        // 2. Merge: new raster files override existing ones
        for (name, data) in rasterFiles {
            existingRaster[name] = data
        }

        // 3. Save the project bundle (project.json)
        try save(bundle)

        // 4. Save all raster files (existing + new)
        if !existingRaster.isEmpty {
            try saveLegacyRasterFiles(existingRaster, projectID: bundle.project.id)
        }
    }

    // MARK: - List Projects

    public func listProjects() -> [StudioProjectRecord] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) else {
            return []
        }

        return contents.compactMap { dir in
            let jsonURL = dir.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: jsonURL),
                  let bundle = try? JSONDecoder().decode(ProjectBundle.self, from: data) else {
                return nil
            }
            return bundle.project
        }
    }

    // MARK: - Delete

    public func delete(projectID: String) throws {
        let dir = projectDir(for: projectID)
        try FileManager.default.removeItem(at: dir)
    }
}
