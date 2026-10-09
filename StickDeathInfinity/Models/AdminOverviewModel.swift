import Foundation
import Combine

/// Read-only overview boundary. This DTO is not an endpoint or a role grant.
struct AdminOverviewSnapshot: Decodable, Equatable {
    let totalUsers: Int
    let activeToday: Int
    let totalAnimations: Int
    let revenueMinorUnits: Int
    let currency: String
    let pendingReports: Int
    let aiQueriesDay: Int
    let measuredAt: Date

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 else { throw Failure.invalid }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(Self.self, from: data)
        guard [value.totalUsers, value.activeToday, value.totalAnimations, value.revenueMinorUnits,
               value.pendingReports, value.aiQueriesDay].allSatisfy({ (0...1_000_000_000_000).contains($0) }),
              value.activeToday <= value.totalUsers, value.currency == "USD",
              value.measuredAt.timeIntervalSince1970.isFinite else { throw Failure.invalid }
        return value
    }
    enum Failure: Error { case invalid }
}

@MainActor final class AdminOverviewModel: ObservableObject {
    /// Supplied only by an adapter that has verified server-side authorization.
    /// The app's cached profile/email/isSuperAdmin display hint is insufficient.
    /// No bearer token or provider credential belongs in this value.
    struct AuthorizedSession: Equatable {
        let accountID: String
        let sessionID: UUID
        let expiresAt: Date
    }
    enum State: Equatable {
        case unavailable(String), loading, failed(String), data(AdminOverviewSnapshot)
    }
    typealias Transport = @MainActor (AuthorizedSession) async throws -> Data
    @Published private(set) var state: State = .unavailable("Admin data is not connected.")
    private let currentSession: @MainActor () -> AuthorizedSession?
    private let transport: Transport?
    private let now: () -> Date
    private var generation = UUID()
    private var worker: Task<Data, Error>?
    private var workerID: UUID?
    private var watcher: Task<Void, Never>?
    private var authorizedSession: AuthorizedSession?
    private var deadline: TimeInterval?
    private var lastUptime: TimeInterval?
    private let uptime: () -> TimeInterval

    init(currentSession: @escaping @MainActor () -> AuthorizedSession? = { nil },
         transport: Transport? = nil, now: @escaping () -> Date = Date.init,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.currentSession = currentSession; self.transport = transport; self.now = now; self.uptime = uptime
    }
    func invalidate() {
        generation = UUID(); worker?.cancel()
        // A cancellation-ignoring transport still owns its lease until it returns.
        watcher?.cancel(); watcher = nil; authorizedSession = nil; deadline = nil; lastUptime = nil
        state = .unavailable("Admin data is not connected.")
    }
    /// The same production check is used by the one local timer and lifecycle tests.
    /// It never sends a request or refreshes credentials.
    @discardableResult func revalidateAuthorization() -> Bool {
        guard let session = authorizedSession else { return false }
        let instant = now(), tick = uptime()
        guard instant.timeIntervalSince1970.isFinite, tick.isFinite,
              lastUptime.map({ tick >= $0 }) ?? true,
              session.expiresAt > instant, currentSession() == session else { invalidate(); return false }
        lastUptime = tick
        if let deadline, tick >= deadline {
            invalidate()
            state = .failed("Admin request timed out. Waiting for the previous request to finish before another can start.")
            return false
        }
        return true
    }
    private func watchAuthorization() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.revalidateAuthorization() else { return }
            }
        }
    }
    func refresh(accountID: String?) async {
        invalidate()
        guard worker == nil else {
            state = .unavailable("The previous admin request is still finishing. No new request was started."); return
        }
        let instant = now(), tick = uptime()
        guard instant.timeIntervalSince1970.isFinite, tick.isFinite,
              let accountID, !accountID.isEmpty, let session = currentSession(),
              session.accountID == accountID, session.expiresAt.timeIntervalSince1970.isFinite,
              session.expiresAt > instant else {
            state = .unavailable("A current server-authorized admin session is required."); return
        }
        guard let transport else {
            state = .unavailable("The verified admin data connection is not configured."); return
        }
        let request = generation, owner = UUID()
        authorizedSession = session; lastUptime = tick; deadline = tick + 15
        state = .loading
        let task = Task {
            try Task.checkCancellation()
            guard self.generation == request, self.revalidateAuthorization() else { throw CancellationError() }
            return try await transport(session)
        }
        worker = task; workerID = owner; watchAuthorization()
        defer { if workerID == owner { worker = nil; workerID = nil } }
        do {
            let bytes = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard generation == request, revalidateAuthorization() else { return }
            let snapshot = try AdminOverviewSnapshot.decode(bytes)
            guard snapshot.measuredAt <= now().addingTimeInterval(60) else { throw AdminOverviewSnapshot.Failure.invalid }
            deadline = nil
            state = .data(snapshot)
        } catch {
            guard generation == request else { return }
            guard !Task.isCancelled, revalidateAuthorization() else { invalidate(); return }
            watcher?.cancel(); watcher = nil; authorizedSession = nil; deadline = nil; lastUptime = nil
            // Server response bodies and credential-bearing errors are never UI text.
            state = .failed("Admin data could not be loaded.")
        }
    }
}
