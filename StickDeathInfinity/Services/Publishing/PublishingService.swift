// ═══════════════════════════════════════════════════════════════════
// PublishingService — Official SDI YouTube publishing pipeline
// Provider-neutral protocol + YouTube server-endpoint client
// No YouTube credentials ever enter the iOS client.
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase

// MARK: - Publish Request (sent to server)
struct PublishRequest: Codable, Sendable {
    let idempotencyKey: String
    let exportAssetURL: String
    let exportFormat: String
    let title: String
    let description: String
    let tags: [String]
    let thumbnailDataURL: Data?
    let visibility: String
    let audience: String
    let userSessionToken: String

    enum CodingKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
        case exportAssetURL = "export_asset_url"
        case exportFormat = "export_format"
        case title, description, tags
        case thumbnailDataURL = "thumbnail_data"
        case visibility, audience
        case userSessionToken = "user_session_token"
    }
}

// MARK: - Publish Response (returned from server)
struct PublishResponse: Codable, Sendable {
    let serverJobID: String
    let status: String
    let videoID: String?
    let videoURL: String?
    let estimatedProcessingTimeSeconds: Int?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case serverJobID = "server_job_id"
        case status
        case videoID = "video_id"
        case videoURL = "video_url"
        case estimatedProcessingTimeSeconds = "estimated_processing_time_seconds"
        case errorMessage = "error_message"
    }
}

// MARK: - Publish Status Poll Response
struct PublishStatusResponse: Codable, Sendable {
    let serverJobID: String
    let status: String
    let videoID: String?
    let videoURL: String?
    let errorMessage: String?
    let progressPercent: Int?

    enum CodingKeys: String, CodingKey {
        case serverJobID = "server_job_id"
        case status
        case videoID = "video_id"
        case videoURL = "video_url"
        case errorMessage = "error_message"
        case progressPercent = "progress_percent"
    }
}

// MARK: - Official Publishing Service Protocol
@MainActor
protocol OfficialPublishingService: AnyObject {
    /// Submit an exported asset for publishing to the official SDI YouTube channel.
    /// Must be idempotent — calling with the same idempotencyKey returns the same job.
    func publish(request: PublishRequest) async throws -> PublishResponse

    /// Check the status of an in-flight publish job.
    func status(serverJobID: String) async throws -> PublishStatusResponse

    /// Cancel a publish job before server acceptance (upload/queued states).
    func cancel(serverJobID: String) async throws
}

// MARK: - YouTube Publishing Client
/// Concrete implementation that calls a configurable server endpoint.
/// The server owns all YouTube OAuth credentials — the iOS client never sees them.
@MainActor
final class YouTubePublishingClient: OfficialPublishingService {
    static let shared = YouTubePublishingClient()

    private let baseURL: URL
    private let session: URLSession

    private init() {
        let urlString = AppConfig.publishingEndpointURL
            ?? "https://api.stickdeathinfinity.com/v1/publish"
        self.baseURL = URL(string: urlString)!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    func publish(request: PublishRequest) async throws -> PublishResponse {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("youtube"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("sdi-ios/1.0", forHTTPHeaderField: "User-Agent")

        // Inject the current Supabase access token into the request
        let supabase = SupabaseManager.shared.client
        let session = try await supabase.auth.session
        var enrichedRequest = request
        enrichedRequest = PublishRequest(
            idempotencyKey: request.idempotencyKey,
            exportAssetURL: request.exportAssetURL,
            exportFormat: request.exportFormat,
            title: request.title,
            description: request.description,
            tags: request.tags,
            thumbnailDataURL: request.thumbnailDataURL,
            visibility: request.visibility,
            audience: request.audience,
            userSessionToken: session.accessToken
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        urlRequest.httpBody = try encoder.encode(enrichedRequest)

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PublishingError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PublishResponse.self, from: data)
        case 401:
            throw PublishingError.unauthorized
        case 409:
            // Idempotent duplicate — decode existing job
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PublishResponse.self, from: data)
        case 422:
            throw PublishingError.invalidMetadata
        case 503:
            throw PublishingError.serverUnavailable
        default:
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw PublishingError.serverError(statusCode: httpResponse.statusCode, message: body)
        }
    }

    func status(serverJobID: String) async throws -> PublishStatusResponse {
        let url = baseURL
            .appendingPathComponent("youtube")
            .appendingPathComponent(serverJobID)
            .appendingPathComponent("status")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("sdi-ios/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PublishingError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw PublishingError.serverError(
                statusCode: httpResponse.statusCode,
                message: String(data: data, encoding: .utf8) ?? "unknown"
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PublishStatusResponse.self, from: data)
    }

    func cancel(serverJobID: String) async throws {
        let url = baseURL
            .appendingPathComponent("youtube")
            .appendingPathComponent(serverJobID)
            .appendingPathComponent("cancel")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("sdi-ios/1.0", forHTTPHeaderField: "User-Agent")

        let (_, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PublishingError.cancelFailed
        }
    }
}

// MARK: - Publishing Errors
enum PublishingError: LocalizedError {
    case invalidResponse
    case unauthorized
    case invalidMetadata
    case serverUnavailable
    case cancelFailed
    case serverError(statusCode: Int, message: String)
    case backendUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid server response."
        case .unauthorized:
            return "Authentication required. Please sign in again."
        case .invalidMetadata:
            return "Invalid publish metadata. Please check title and description."
        case .serverUnavailable:
            return "Publishing server is temporarily unavailable. Try again later."
        case .cancelFailed:
            return "Could not cancel the publish job."
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .backendUnavailable:
            return "Publishing backend is not configured. Contact support."
        }
    }
}

// MARK: - Publish Job Store (local persistence via UserDefaults)
/// Lightweight durable store for publish jobs.
/// In production this would use SwiftData or CoreData; UserDefaults is sufficient
/// for the bridge implementation scope.
@MainActor
final class PublishJobStore: ObservableObject {
    static let shared = PublishJobStore()

    @Published var activeJobs: [PublishJob] = []

    private let storageKey = "com.stickdeathinfinity.publish_jobs"

    private init() {
        loadJobs()
    }

    func addJob(_ job: PublishJob) {
        activeJobs.append(job)
        persistJobs()
    }

    func updateJob(_ job: PublishJob) {
        guard let idx = activeJobs.firstIndex(where: { $0.id == job.id }) else { return }
        activeJobs[idx] = job
        persistJobs()
    }

    func job(forExportResultID id: String) -> PublishJob? {
        activeJobs.first { $0.exportResultID == id }
    }

    func removeJob(id: String) {
        activeJobs.removeAll { $0.id == id }
        persistJobs()
    }

    private func loadJobs() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let jobs = try? JSONDecoder().decode([PublishJob].self, from: data) else {
            return
        }
        activeJobs = jobs
    }

    private func persistJobs() {
        guard let data = try? JSONEncoder().encode(activeJobs) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
