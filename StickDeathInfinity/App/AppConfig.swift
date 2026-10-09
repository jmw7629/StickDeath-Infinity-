import Foundation
#if canImport(Darwin)
import CryptoKit
#endif

/// Public build configuration only. Provider credentials belong on the backend.
struct AppConfig {
    /// Configure SPATTER_BACKEND_URL in the app's Info.plist/xcconfig.
    /// Read on each use; do not keep a mutable endpoint or cache a missing value.
    static var backendURL: URL? {
        backendURL(from: Bundle.main.infoDictionary ?? [:])
    }

    static func backendURL(from values: [String: Any]) -> URL? {
        guard let value = values["SPATTER_BACKEND_URL"] as? String else { return nil }
        return SpatterEndpoint.url(from: value)
    }

    /// Isolated authenticated render intake, never inferred from the marketing site.
    static var uploadServiceURL: URL? { uploadServiceURL(from: Bundle.main.infoDictionary ?? [:]) }
    static func uploadServiceURL(from values: [String: Any]) -> URL? {
        guard let raw = configuredString(values["SDI_UPLOAD_SERVICE_URL"]),
              let url = serviceURL(raw, scheme: "https"), url.path.isEmpty || url.path == "/" else { return nil }
        return url
    }
    static var renderPreviewOrigin: URL? {
        let values = Bundle.main.infoDictionary ?? [:]
        guard let raw = configuredString(values["SDI_RENDER_PREVIEW_URL"]) else { return uploadServiceURL }
        guard let url = serviceURL(raw, scheme: "https"), url.path.isEmpty || url.path == "/" else { return nil }
        return url
    }

    struct PublishingConsentConfiguration {
        let version: String
        let termsURL: URL
    }
    static var publishingConsent: PublishingConsentConfiguration? {
        let values = Bundle.main.infoDictionary ?? [:]
        guard let version = configuredString(values["SDI_PUBLISHING_CONSENT_VERSION"]), version.count <= 100,
              let raw = configuredString(values["SDI_PUBLISHING_TERMS_URL"]),
              let url = serviceURL(raw, scheme: "https") else { return nil }
        return .init(version: version, termsURL: url)
    }

    struct SupabaseConfiguration: Equatable {
        let url: URL
        let publishableKey: String
    }

    static var supabaseConfiguration: SupabaseConfiguration? {
        supabaseConfiguration(from: Bundle.main.infoDictionary ?? [:])
    }

    /// Build configuration accepts public keys only. Decoding a legacy JWT here
    /// classifies its role; the server still verifies its signature and authority.
    static func supabaseConfiguration(from values: [String: Any]) -> SupabaseConfiguration? {
        guard let endpoint = configuredString(values["SUPABASE_URL"]),
              let url = serviceURL(endpoint, scheme: "https"),
              url.path.isEmpty || url.path == "/",
              let key = configuredString(values["SUPABASE_PUBLISHABLE_KEY"])
                ?? configuredString(values["SUPABASE_ANON_KEY"]),
              isPublicSupabaseKey(key) else { return nil }
        return SupabaseConfiguration(url: url, publishableKey: key)
    }

    enum OAuthProvider: String, CaseIterable, Hashable, Sendable {
        case google, github, microsoft
        var title: String {
            switch self { case .google: return "Google"; case .github: return "GitHub"; case .microsoft: return "Microsoft" }
        }
    }
    struct OAuthConfiguration: Equatable, Sendable {
        let enabledProviders: Set<OAuthProvider>
        /// Public deployment contract only. The configured Supabase Azure
        /// provider must enforce this same tenant policy server-side.
        let microsoftTenant: String?
    }
    static var oauthConfiguration: OAuthConfiguration {
        oauthConfiguration(from: Bundle.main.infoDictionary ?? [:])
    }
    static func oauthConfiguration(from values: [String: Any]) -> OAuthConfiguration {
        let raw = configuredString(values["SDI_OAUTH_PROVIDERS"]) ?? ""
        let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        // Unknown/unexpanded deployment values fail closed, not partially on.
        guard names.allSatisfy({ OAuthProvider(rawValue: $0) != nil }) else {
            return .init(enabledProviders: [], microsoftTenant: nil)
        }
        var enabled = Set(names.compactMap(OAuthProvider.init(rawValue:)))
        let tenant = configuredString(values["SDI_MICROSOFT_TENANT"])
        let validTenant = tenant.map { ["common", "organizations", "consumers"].contains($0) || UUID(uuidString: $0) != nil } ?? false
        if !validTenant { enabled.remove(.microsoft) }
        return .init(enabledProviders: enabled, microsoftTenant: validTenant ? tenant : nil)
    }

    static var liveKitWSURL: URL? {
        liveKitWSURL(from: Bundle.main.infoDictionary ?? [:])
    }

    static func liveKitWSURL(from values: [String: Any]) -> URL? {
        guard let value = configuredString(values["LIVEKIT_WS_URL"]) else { return nil }
        return serviceURL(value, scheme: "wss")
    }

    private static func configuredString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$("), !trimmed.contains("${") else { return nil }
        return trimmed
    }

    private static func serviceURL(_ value: String, scheme: String) -> URL? {
        guard value.utf8.count <= 2048,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == scheme,
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port == nil || components.port == 443 else { return nil }
        return components.url
    }

    private static func isPublicSupabaseKey(_ key: String) -> Bool {
        guard key.utf8.count <= 8192 else { return false }
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        if key.hasPrefix("sb_publishable_") {
            let suffix = key.dropFirst("sb_publishable_".count)
            return !suffix.isEmpty && suffix.unicodeScalars.allSatisfy(alphabet.contains)
        }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(alphabet.contains) }),
              let header = jwtObject(parts[0]), header["alg"] as? String == "HS256",
              let payload = jwtObject(parts[1]), payload["role"] as? String == "anon",
              payload["iss"] as? String == "supabase" else { return false }
        return true
    }

    private static func jwtObject(_ part: Substring) -> [String: Any]? {
        var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    /// Ordering of existing StoreKit product families, not a price or entitlement policy.
    enum SubscriptionTier: String, CaseIterable {
        case free, creator, pro, studio

        var rank: Int {
            switch self {
            case .free: return 0
            case .creator: return 1
            case .pro: return 2
            case .studio: return 3
            }
        }
    }

    /// Existing display rates; actual billing authorization remains server-side.
    enum CallRateTier: String, CaseIterable {
        case standard, creator, pro, studio

        var ratePerMinute: Double {
            switch self {
            case .standard: return 0.05
            case .creator: return 0.10
            case .pro: return 0.15
            case .studio: return 0.25
            }
        }

        var displayName: String { rawValue.capitalized }
    }
}

enum AppConfigurationError: Error, LocalizedError {
    case supabaseUnavailable, liveKitUnavailable

    var errorDescription: String? {
        switch self {
        case .supabaseUnavailable:
            return "Cloud services are unavailable because their public configuration is missing or invalid."
        case .liveKitUnavailable:
            return "Calls are unavailable because their secure server configuration is missing or invalid."
        }
    }
}

/// Bounded authenticated intake transport shared by upload/review operations.
/// Tokens remain request-local; cookies, caches and redirects are disabled.
// Native transfer services use Apple URLSession streaming, CryptoKit and
// protected application storage. Shared configuration above remains Foundation-
// only so the production backend-boundary checks also compile on Linux.
#if canImport(Darwin)
enum SDIIntakeClient {
    enum Failure: LocalizedError {
        case configuration, authorization, unavailable, response, conflict, expired, rejected
        case retryAfter(Int)
        var errorDescription: String? {
            switch self {
            case .configuration: return "The private upload service is not configured in this build."
            case .authorization: return "Sign in again to authorize this operation. Administrator review actions also require MFA."
            case .unavailable: return "The private render service is unavailable. Retain your local export and try again."
            case .response: return "The service did not confirm a valid response. Refresh before retrying."
            case .conflict: return "The server upload state changed. Resume to read its confirmed offset."
            case .expired: return "The server upload expired. Keep your original export before starting a new submission."
            case .rejected: return "The service rejected this submission. Check the file, metadata and current permissions."
            case .retryAfter: return "The service is temporarily busy. The upload checkpoint has been preserved."
            }
        }
    }
    static func retryDelay(_ error: Error, attempt: Int) -> Int? {
        if let failure = error as? Failure, case .retryAfter(let seconds) = failure { return max(seconds, min(8, 1 << attempt)) }
        if let network = error as? URLError, [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(network.code) {
            return min(8, 1 << attempt)
        }
        return nil
    }
    /// Only use for GET or operations with a stable server idempotency key.
    static func retry<Result>(_ operation: () async throws -> Result) async throws -> Result {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                guard attempt < 2, let delay = retryDelay(error, attempt: attempt) else { throw error }
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
        }
        throw Failure.unavailable
    }
    static func request<Body: Encodable, Result: Decodable>(path: [String], body: Body, token: String) async throws -> Result {
        try await raw(path: path, method: "POST", body: JSONEncoder().encode(body), token: token)
    }
    static func raw<Result: Decodable>(path: [String], method: String, body: Data? = nil,
                                      headers: [String: String] = [:], token: String) async throws -> Result {
        guard ["GET", "POST", "PATCH", "DELETE"].contains(method),
              Set(headers.keys).isSubset(of: ["Idempotency-Key", "Upload-Offset", "Upload-Checksum"]),
              headers.values.allSatisfy({ $0.utf8.count <= 200 && $0.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 } }) else { throw Failure.response }
        guard let base = AppConfig.uploadServiceURL else { throw Failure.configuration }
        guard !token.isEmpty, token.utf8.count <= 16_384,
              token.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { throw Failure.authorization }
        var url = base
        for component in path {
            guard !component.isEmpty, component.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { throw Failure.response }
            url.appendPathComponent(component)
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: SDIIntakeRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(method == "PATCH" ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        guard (body?.count ?? 0) <= (method == "PATCH" ? 4 * 1024 * 1024 : 8192) else { throw Failure.response }
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url == url else { throw Failure.response }
        if http.statusCode == 401 || http.statusCode == 403 { throw Failure.authorization }
        if http.statusCode == 409 { throw Failure.conflict }
        if http.statusCode == 410 { throw Failure.expired }
        if http.statusCode == 429 || (500...599).contains(http.statusCode) {
            let seconds = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
            throw Failure.retryAfter(min(30, max(1, seconds)))
        }
        guard (200...299).contains(http.statusCode) else { throw Failure.rejected }
        guard response.expectedContentLength <= 16_384 else { throw Failure.response }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 16_384 else { throw Failure.response }
            data.append(byte)
        }
        return try JSONDecoder().decode(Result.self, from: data)
    }
}
private final class SDIIntakeRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct SDIRenderUploadMetadata: Codable, Sendable {
    var size: Int64
    var sha256: String
    let title: String
    let source_revision: String
    let destinations: [String]
    let rights_summary: String
    let consent_version: String
    let made_for_kids: Bool
}
struct SDIRenderUploadJournal: Codable, Identifiable, Sendable {
    let id: UUID
    let account: UUID
    let serviceOrigin: String
    let metadata: SDIRenderUploadMetadata
    var serverID: UUID?
    var offset: Int64 = 0
    var state = "staged"
    var reviewID: UUID?
    var retryNotBefore: Double?
    var retryAttempts: Int?
}
struct SDIRenderUploadStatus: Decodable, Sendable {
    let id: UUID
    let size: Int64
    let offset: Int64
    let state: String
    let expires: Double
    let review_id: UUID?
}

/// One serialized transfer per actor; journals contain no bearer tokens. A
/// cancelled task leaves the private staged MP4 and checkpoint for manual resume.
actor SDIRenderUploads {
    static let shared = SDIRenderUploads()
    private var transferring = false
    private let chunkSize = 4 * 1024 * 1024
    private func root(_ account: UUID) throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("PrivateRenderUploads", isDirectory: true).appendingPathComponent(account.uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = base; try mutable.setResourceValues(values)
        return base
    }
    private func path(_ job: SDIRenderUploadJournal, extension ext: String) throws -> URL {
        try root(job.account).appendingPathComponent(job.id.uuidString).appendingPathExtension(ext)
    }
    private func persist(_ job: SDIRenderUploadJournal) throws {
        try JSONEncoder().encode(job).write(to: path(job, extension: "json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func list(account: UUID) throws -> [SDIRenderUploadJournal] {
        let files = try FileManager.default.contentsOfDirectory(at: root(account), includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])
        return try files.filter { $0.pathExtension == "json" }.prefix(50).map { url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= 16_384 else { throw SDIIntakeClient.Failure.response }
            let job = try JSONDecoder().decode(SDIRenderUploadJournal.self, from: Data(contentsOf: url))
            guard job.account == account, url.deletingPathExtension().lastPathComponent == job.id.uuidString else { throw SDIIntakeClient.Failure.response }
            return job
        }
    }
    func stage(source: URL, account: UUID, metadata: SDIRenderUploadMetadata) throws -> SDIRenderUploadJournal {
        guard !transferring, let origin = AppConfig.uploadServiceURL else { throw SDIIntakeClient.Failure.configuration }
        guard try list(account: account).count < 5 else { throw UploadFailure.capacity }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let info = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size > 0, size <= 2_147_483_648 else { throw UploadFailure.file }
        let root = try root(account)
        let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard available >= Int64(size) + 128 * 1024 * 1024 else { throw UploadFailure.capacity }
        var captured = metadata; captured.size = Int64(size)
        var job = SDIRenderUploadJournal(id: UUID(), account: account, serviceOrigin: origin.absoluteString, metadata: captured)
        let output = try path(job, extension: "mp4")
        guard FileManager.default.createFile(atPath: output.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw UploadFailure.file }
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: output) } }
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        let writer = try FileHandle(forWritingTo: output); defer { try? writer.close() }
        var hasher = SHA256(); var count: Int64 = 0
        while let bytes = try input.read(upToCount: chunkSize), !bytes.isEmpty {
            try Task.checkCancellation(); count += Int64(bytes.count)
            guard count <= Int64(size) else { throw UploadFailure.file }
            hasher.update(data: bytes); try writer.write(contentsOf: bytes)
        }
        guard count == Int64(size) else { throw UploadFailure.file }
        try writer.synchronize(); try Task.checkCancellation()
        captured.sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        job = .init(id: job.id, account: account, serviceOrigin: job.serviceOrigin, metadata: captured)
        try persist(job); complete = true; return job
    }
    func resume(_ captured: SDIRenderUploadJournal, token: @Sendable () async throws -> String,
                progress: @Sendable (Int64, Int64) async -> Void) async throws -> SDIRenderUploadJournal {
        guard !transferring else { throw UploadFailure.busy }
        guard AppConfig.uploadServiceURL?.absoluteString == captured.serviceOrigin else { throw SDIIntakeClient.Failure.configuration }
        transferring = true; defer { transferring = false }
        guard var job = try list(account: captured.account).first(where: { $0.id == captured.id }) else { throw UploadFailure.file }
        if job.reviewID != nil { return job }
        let source = try path(job, extension: "mp4")
        let file = try FileHandle(forReadingFrom: source); defer { try? file.close() }
        guard try file.seekToEnd() == UInt64(job.metadata.size) else { throw UploadFailure.file }
        if job.serverID == nil {
            job.state = "starting"; try persist(job)
            let payload = try JSONEncoder().encode(job.metadata)
            let requestID = job.id.uuidString.lowercased()
            let status: SDIRenderUploadStatus = try await SDIIntakeClient.retry {
                try await SDIIntakeClient.raw(path: ["v1", "render-uploads"], method: "POST", body: payload,
                    headers: ["Idempotency-Key": requestID], token: try await token())
            }
            guard status.size == job.metadata.size else { throw SDIIntakeClient.Failure.response }
            job.serverID = status.id; try persist(job)
        }
        guard let upload = job.serverID else { throw SDIIntakeClient.Failure.response }
        let route = ["v1", "render-uploads", upload.uuidString.lowercased()]
        if let until = job.retryNotBefore, until > Date().timeIntervalSince1970 {
            try await Task.sleep(nanoseconds: UInt64(max(0, min(30, until - Date().timeIntervalSince1970))) * 1_000_000_000)
        }
        var status: SDIRenderUploadStatus = try await SDIIntakeClient.retry {
            try await SDIIntakeClient.raw(path: route, method: "GET", token: try await token())
        }
        // Resume is an explicit user action. Each chunk gets at most two automatic
        // recoveries; process/background interruption preserves the recorded delay.
        var recoveryAttempts = 0
        while true {
            try Task.checkCancellation()
            guard status.id == upload, status.size == job.metadata.size, status.offset >= 0, status.offset <= job.metadata.size else { throw SDIIntakeClient.Failure.response }
            job.offset = status.offset; job.state = status.state; job.reviewID = status.review_id; try persist(job)
            await progress(job.offset, job.metadata.size)
            if status.state == "submitted", status.review_id != nil { return job }
            guard status.expires > Date().timeIntervalSince1970, ["receiving", "registering"].contains(status.state) else { throw UploadFailure.expired }
            if job.offset == job.metadata.size { break }
            try file.seek(toOffset: UInt64(job.offset))
            guard let data = try file.read(upToCount: min(chunkSize, Int(job.metadata.size-job.offset))), !data.isEmpty else { throw UploadFailure.file }
            let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            do {
                status = try await SDIIntakeClient.raw(path: route, method: "PATCH", body: data,
                    headers: ["Upload-Offset": String(job.offset), "Upload-Checksum": checksum], token: try await token())
                recoveryAttempts = 0; job.retryAttempts = nil; job.retryNotBefore = nil
            } catch {
                let conflict: Bool
                if let failure = error as? SDIIntakeClient.Failure, case .conflict = failure { conflict = true } else { conflict = false }
                guard recoveryAttempts < 2, conflict || SDIIntakeClient.retryDelay(error, attempt: recoveryAttempts) != nil else { throw error }
                let delay = SDIIntakeClient.retryDelay(error, attempt: recoveryAttempts) ?? 1
                recoveryAttempts += 1; job.retryAttempts = recoveryAttempts
                job.retryNotBefore = Date().timeIntervalSince1970 + Double(delay); try persist(job)
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                // A response may have been lost after commit. Read before resending.
                status = try await SDIIntakeClient.retry {
                    try await SDIIntakeClient.raw(path: route, method: "GET", token: try await token())
                }
                if status.offset > job.offset { recoveryAttempts = 0; job.retryAttempts = nil; job.retryNotBefore = nil }
            }
        }
        let finished: SDIRenderUploadStatus = try await SDIIntakeClient.raw(path: route + ["complete"], method: "POST", token: try await token())
        guard finished.id == upload, finished.size == job.metadata.size, finished.offset == job.metadata.size,
              finished.state == "submitted", let review = finished.review_id else { throw SDIIntakeClient.Failure.response }
        job.reviewID = review; job.state = "submitted"; job.retryAttempts = nil; job.retryNotBefore = nil; try persist(job); return job
    }
    /// Explicit removal of our staged copy only. Registered review originals
    /// remain subject to the separate creator consent-withdrawal workflow.
    func discard(_ captured: SDIRenderUploadJournal, token: @Sendable () async throws -> String) async throws {
        guard !transferring else { throw UploadFailure.busy }
        transferring = true; defer { transferring = false }
        guard var job = try list(account: captured.account).first(where: { $0.id == captured.id }) else { return }
        if job.reviewID == nil {
            guard AppConfig.uploadServiceURL?.absoluteString == job.serviceOrigin else { throw SDIIntakeClient.Failure.configuration }
            if job.serverID == nil && job.state == "starting" {
                let found: SDIRenderUploadStatus = try await SDIIntakeClient.raw(path: ["v1", "render-uploads"], method: "POST",
                    body: JSONEncoder().encode(job.metadata), headers: ["Idempotency-Key": job.id.uuidString.lowercased()], token: try await token())
                job.serverID = found.id; try persist(job)
            }
            if let upload = job.serverID {
                let cancelled: SDIRenderUploadStatus = try await SDIIntakeClient.raw(path: ["v1", "render-uploads", upload.uuidString.lowercased()], method: "DELETE", token: try await token())
                guard cancelled.id == upload, cancelled.state == "cancelled" else { throw SDIIntakeClient.Failure.response }
            }
        }
        let movie = try path(job, extension: "mp4")
        if FileManager.default.fileExists(atPath: movie.path) { try FileManager.default.removeItem(at: movie) }
        try FileManager.default.removeItem(at: path(job, extension: "json"))
    }
    enum UploadFailure: LocalizedError {
        case file, capacity, busy, expired
        var errorDescription: String? {
            switch self {
            case .file: return "The staged MP4 could not be read. Your original export has not been changed."
            case .capacity: return "Not enough private upload capacity. Keep the original export and free space before retrying."
            case .busy: return "Another render transfer is already active."
            case .expired: return "This upload expired or was cancelled. Retain the original export before starting a new submission."
            }
        }
    }
}

#endif
