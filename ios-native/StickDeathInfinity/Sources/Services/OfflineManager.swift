// OfflineManager.swift
// Handles offline detection, local caching, and sync queue
// Uses UserDefaults + FileManager for persistence (no extra dependencies)

import Foundation
import SwiftUI
import Network
import Combine

@MainActor
class OfflineManager: ObservableObject {
    static let shared = OfflineManager()

    // MARK: - State
    @Published var isOnline = true
    @Published var pendingActions: Int = 0
    @Published var isSyncing = false

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "net.stickdeath.netmonitor")
    private let cacheDir: URL
    private let queueFile: URL

    // MARK: - Sync Queue (persisted to disk)
    struct QueuedAction: Codable, Identifiable {
        let id: UUID
        let type: ActionType
        let payload: Data
        let createdAt: Date

        enum ActionType: String, Codable {
            case saveProject
            case publishVideo
            case updateProfile
            case sendMessage
        }
    }

    private var queue: [QueuedAction] = []

    private init() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        cacheDir = docs.appendingPathComponent("StickDeathCache", isDirectory: true)
        queueFile = cacheDir.appendingPathComponent("sync_queue.json")
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        loadQueue()
    }

    // MARK: - Network Monitoring
    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                let wasOffline = self?.isOnline == false
                self?.isOnline = path.status == .satisfied
                // Auto-sync when coming back online
                if wasOffline && path.status == .satisfied {
                    await self?.syncAll()
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    // MARK: - Cache: Projects
    func cacheProject(_ data: Data, projectId: Int) {
        let file = cacheDir.appendingPathComponent("project_\(projectId).json")
        try? data.write(to: file)
    }

    func loadCachedProject(projectId: Int) -> Data? {
        let file = cacheDir.appendingPathComponent("project_\(projectId).json")
        return try? Data(contentsOf: file)
    }

    // MARK: - Cache: Project List
    func cacheProjectList(_ data: Data) {
        let file = cacheDir.appendingPathComponent("project_list_cache.json")
        try? data.write(to: file)
    }

    func loadCachedProjectList() -> Data? {
        let file = cacheDir.appendingPathComponent("project_list_cache.json")
        return try? Data(contentsOf: file)
    }

    // MARK: - Cache: Feed
    func cacheFeed(_ data: Data) {
        let file = cacheDir.appendingPathComponent("feed_cache.json")
        try? data.write(to: file)
    }

    func loadCachedFeed() -> Data? {
        let file = cacheDir.appendingPathComponent("feed_cache.json")
        return try? Data(contentsOf: file)
    }

    // MARK: - Cache: Profile
    func cacheProfile(_ data: Data) {
        let file = cacheDir.appendingPathComponent("profile_cache.json")
        try? data.write(to: file)
    }

    func loadCachedProfile() -> Data? {
        let file = cacheDir.appendingPathComponent("profile_cache.json")
        return try? Data(contentsOf: file)
    }

    // MARK: - Sync Queue
    func enqueue(type: QueuedAction.ActionType, payload: Data) {
        let action = QueuedAction(id: UUID(), type: type, payload: payload, createdAt: Date())
        queue.append(action)
        pendingActions = queue.count
        saveQueue()

        // Try to sync immediately if online
        if isOnline {
            Task { await syncAll() }
        }
    }

    func syncAll() async {
        guard isOnline, !isSyncing, !queue.isEmpty else { return }
        isSyncing = true

        var remaining: [QueuedAction] = []

        for action in queue {
            let success = await processAction(action)
            if !success {
                remaining.append(action)
            }
        }

        queue = remaining
        pendingActions = queue.count
        saveQueue()
        isSyncing = false
    }

    private func processAction(_ action: QueuedAction) async -> Bool {
        do {
            switch action.type {
            case .saveProject:
                struct SavePayload: Decodable { let projectId: Int; let data: Data }
                let payload = try JSONDecoder().decode(SavePayload.self, from: action.payload)
                // Re-upload project data via Supabase
                let jsonStr = String(data: payload.data, encoding: .utf8) ?? "{}"
                try await supabase
                    .from("studio_project_versions")
                    .insert(["project_id": "\(payload.projectId)", "data": jsonStr])
                    .execute()
                return true

            case .publishVideo:
                // Re-trigger publish edge function
                guard let accessToken = AuthManager.shared.session?.accessToken else { return false }
                var request = URLRequest(url: AppConfig.edgeFunction("publish-video"))
                request.httpMethod = "POST"
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = action.payload
                let (_, response) = try await URLSession.shared.data(for: request)
                return (response as? HTTPURLResponse)?.statusCode == 200

            case .updateProfile:
                guard let userId = AuthManager.shared.session?.user.id else { return false }
                let updates = try JSONDecoder().decode([String: String].self, from: action.payload)
                try await supabase.from("users").update(updates).eq("id", value: userId.uuidString).execute()
                return true

            case .sendMessage:
                let msg = try JSONSerialization.jsonObject(with: action.payload) as? [String: Any] ?? [:]
                try await supabase.from("messages").insert(msg).execute()
                return true
            }
        } catch {
            print("⚠️ Sync failed for \(action.type): \(error)")
            return false
        }
    }

    // MARK: - Queue Persistence
    private func saveQueue() {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: queueFile)
    }

    private func loadQueue() {
        guard let data = try? Data(contentsOf: queueFile),
              let loaded = try? JSONDecoder().decode([QueuedAction].self, from: data) else { return }
        queue = loaded
        pendingActions = queue.count
    }

    // MARK: - Cache Cleanup
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        queue.removeAll()
        pendingActions = 0
    }
}
