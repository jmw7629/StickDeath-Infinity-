// ═══════════════════════════════════════════════════════════════════
// ProjectService — Studio project CRUD
// Matches: src/services/ProjectService.ts
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase

@MainActor
final class ProjectService {
    static let shared = ProjectService()
    private let supabase = SupabaseManager.shared.client

    // MARK: - List Projects
    func listProjects() async throws -> [StudioProject] {
        guard let userId = AuthService.shared.userId else { return [] }
        return try await supabase.from("studio_projects")
            .select()
            .eq("user_id", value: userId)
            .order("updated_at", ascending: false)
            .execute()
            .value
    }

    // MARK: - Create Project
    func createProject(name: String, width: Int = 1920, height: Int = 1080, fps: Int = 12) async throws -> StudioProject {
        guard let userId = AuthService.shared.userId else {
            throw ProjectError.notAuthenticated
        }

        let result: StudioProject = try await supabase.from("studio_projects").insert([
            "user_id": AnyJSON.string(userId),
            "name": .string(name),
            "width": .integer(width),
            "height": .integer(height),
            "fps": .integer(fps),
        ]).select().single().execute().value

        return result
    }

    // MARK: - Save Project (frames)
    func saveProject(projectID: String, frames: [AnimationFrame]) async throws {
        let encoder = JSONEncoder()
        let frameData = try encoder.encode(frames)
        let frameJSON = String(data: frameData, encoding: .utf8) ?? "[]"

        try await supabase.from("studio_projects").update([
            "frame_data": AnyJSON.string(frameJSON),
            "frame_count": .integer(frames.count),
            "updated_at": .string(ISO8601DateFormatter().string(from: Date())),
        ]).eq("id", value: projectID).execute()
    }

    // MARK: - Load Project Frames
    func loadFrames(projectID: String) async throws -> [AnimationFrame] {
        struct ProjectRow: Codable {
            let frame_data: String?
        }

        let row: ProjectRow = try await supabase.from("studio_projects")
            .select("frame_data")
            .eq("id", value: projectID)
            .single()
            .execute()
            .value

        guard let frameJSON = row.frame_data,
              let data = frameJSON.data(using: .utf8) else {
            return [AnimationFrame(id: UUID().uuidString, elements: [])]
        }

        return try JSONDecoder().decode([AnimationFrame].self, from: data)
    }

    // MARK: - Delete Project
    func deleteProject(projectID: String) async throws {
        try await supabase.from("studio_projects").delete().eq("id", value: projectID).execute()
    }

    // MARK: - Export Project (GIF/MP4)
    func exportProject(projectID: String, format: ExportFormat) async throws -> Data {
        // TODO: Server-side rendering via Supabase edge function
        // For now, client-side rendering using Core Graphics
        throw ProjectError.exportNotImplemented
    }

    enum ExportFormat {
        case gif, mp4, png_sequence
    }

    enum ProjectError: Error {
        case notAuthenticated
        case exportNotImplemented
        case projectNotFound
    }
}
