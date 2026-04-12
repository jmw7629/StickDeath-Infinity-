// ProjectService.swift
// CRUD for animation projects — talks to live Supabase DB

import Foundation

class ProjectService {
    static let shared = ProjectService()

    // MARK: - Fetch user's projects
    func fetchMyProjects() async throws -> [StudioProject] {
        guard let userId = AuthManager.shared.session?.user.id else { return [] }
        let projects: [StudioProject] = try await supabase
            .from("studio_projects")
            .select()
            .eq("user_id", value: userId.uuidString)
            .order("updated_at", ascending: false)
            .execute()
            .value
        return projects
    }

    // MARK: - Create project
    func createProject(title: String, width: Int = 1920, height: Int = 1080, fps: Int = 24) async throws -> StudioProject {
        guard let userId = AuthManager.shared.session?.user.id else {
            throw AppError.notAuthenticated
        }
        let newProject = StudioProjectInsert(
            userId: userId.uuidString,
            title: title,
            canvasWidth: width,
            canvasHeight: height,
            fps: fps
        )
        let project: StudioProject = try await supabase
            .from("studio_projects")
            .insert(newProject)
            .select()
            .single()
            .execute()
            .value
        return project
    }

    // MARK: - Save project data (frames/figures)
    func saveVersion(projectId: Int, data: AnimationData) async throws {
        let jsonData = try JSONEncoder().encode(data)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        try await supabase
            .from("studio_project_versions")
            .insert([
                "project_id": "\(projectId)",
                "frame_data": jsonString
            ])
            .execute()
    }

    // MARK: - Load latest version
    func loadLatestVersion(projectId: Int) async throws -> AnimationData? {
        struct VersionRow: Decodable {
            let frame_data: String?
        }
        let version: VersionRow? = try? await supabase
            .from("studio_project_versions")
            .select("frame_data")
            .eq("project_id", value: projectId)
            .order("created_at", ascending: false)
            .limit(1)
            .single()
            .execute()
            .value

        guard let jsonString = version?.frame_data,
              let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnimationData.self, from: data)
    }

    // MARK: - Delete project
    func deleteProject(projectId: Int) async throws {
        try await supabase
            .from("studio_projects")
            .delete()
            .eq("id", value: projectId)
            .execute()
    }

    // MARK: - Fetch feed (published projects)
    func fetchFeed(page: Int = 1, limit: Int = 20) async throws -> [FeedItem] {
        let items: [FeedItem] = try await supabase
            .from("studio_projects")
            .select("*, users(username, avatar_url)")
            .eq("status", value: "published")
            .order("created_at", ascending: false)
            .range(from: (page - 1) * limit, to: page * limit - 1)
            .execute()
            .value
        return items
    }

    // MARK: - Publish project
    func publishProject(projectId: Int) async throws {
        try await supabase
            .from("studio_projects")
            .update(["status": "published"])
            .eq("id", value: projectId)
            .execute()
    }
}

enum AppError: Error, LocalizedError {
    case notAuthenticated
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Please sign in to continue"
        case .serverError(let msg): return msg
        }
    }
}
