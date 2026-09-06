import Foundation

public protocol RemoteStore {
    func uploadProject(_ project: Project) async throws
    func fetchProject(id: String) async throws -> Project?
    func listProjects() async throws -> [Project]
    func deleteProject(id: String) async throws
}
