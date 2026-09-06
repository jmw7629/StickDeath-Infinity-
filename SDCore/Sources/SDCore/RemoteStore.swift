// ═══════════════════════════════════════════════════════════════════
// RemoteStore — Remote sync contract via tested Transport seam
// Only called after successful local persistence.
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - RemoteStore Protocol

public protocol RemoteStore {
    /// Upload a project version to the remote backend.
    /// Returns the remote version ID on success.
    func uploadVersion(projectID: String, frameData: String) async throws -> String

    /// List remote versions for a project.
    func listVersions(projectID: String) async throws -> [RemoteVersion]

    /// List all projects accessible to the current user.
    func listProjects() async throws -> [RemoteVersion]
}

// MARK: - HTTP RemoteStore

/// Production RemoteStore that communicates through the tested Transport seam.
public final class HTTPRemoteStore: RemoteStore {
    private let transport: Transport

    public init(transport: Transport) {
        self.transport = transport
    }

    public func uploadVersion(projectID: String, frameData: String) async throws -> String {
        guard !projectID.isEmpty else {
            throw RemoteStoreError.emptyProjectID
        }

        var request = URLRequest(url: URL(string: "/studio_project_versions")!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "project_id": projectID,
            "frame_data": frameData,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport.send(request)

        guard (200..<300).contains(response.statusCode) else {
            throw RemoteStoreError.uploadFailed(response.statusCode)
        }

        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let versionID = result?["id"] as? String ?? UUID().uuidString
        return versionID
    }

    public func listVersions(projectID: String) async throws -> [RemoteVersion] {
        var request = URLRequest(url: URL(string: "/studio_project_versions?project_id=\(projectID)")!)
        request.httpMethod = "GET"

        let (data, response) = try await transport.send(request)

        guard (200..<300).contains(response.statusCode) else {
            throw RemoteStoreError.fetchFailed(response.statusCode)
        }

        return try JSONDecoder().decode([RemoteVersion].self, from: data)
    }

    public func listProjects() async throws -> [RemoteVersion] {
        var request = URLRequest(url: URL(string: "/studio_project_versions")!)
        request.httpMethod = "GET"

        let (data, response) = try await transport.send(request)

        guard (200..<300).contains(response.statusCode) else {
            throw RemoteStoreError.fetchFailed(response.statusCode)
        }

        return try JSONDecoder().decode([RemoteVersion].self, from: data)
    }
}

// MARK: - RemoteStore Errors

public enum RemoteStoreError: Error, LocalizedError {
    case emptyProjectID
    case uploadFailed(Int)
    case fetchFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyProjectID:
            return "Project ID is empty"
        case .uploadFailed(let code):
            return "Upload failed with status \(code)"
        case .fetchFailed(let code):
            return "Fetch failed with status \(code)"
        }
    }
}
