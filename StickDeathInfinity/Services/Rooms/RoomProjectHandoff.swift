// ═══════════════════════════════════════════════════════════════════
// RoomProjectHandoff — owner-approved project handoff (#234, owner decision
// 2026-10-18; rooms-v2.sql v2.2, `sdi_room_snapshot`).
//
// The room owner may send the shared project, as its portable .sdiproject
// backup bytes, to the room's approved members through temporary server
// storage. The server recomputes the SHA-256, serves it only to approved
// members of that room and deletes it once every current member has recorded a
// receipt, on revocation or replacement, when the shared project changes, when
// the room closes, or after 72 hours. A member verifies the SHA-256 locally,
// imports it as a NEW device project (a fresh identity; an existing project is
// never overwritten) and only then records the receipt. The owner's device
// project is only read. Foundation-only so it is testable on Linux.
// ═══════════════════════════════════════════════════════════════════

import Foundation

/// Bounds mirrored from rooms-v2.sql's handoff block.
enum RoomProjectHandoffPolicy {
    static let chunkBytes = 262_144
    static let maximumBytes = 32 * 1024 * 1024
    static let maximumChunks = 128
    static let pendingLifetime: TimeInterval = 3600
    static let retention: TimeInterval = 72 * 3600
    static let dailyOffers = 20
    /// Header of DeviceStorageManager's portable bundle (`SDIPROJECT000001\n`).
    static let portableMagic = Data("SDIPROJECT000001\n".utf8)

    static func chunkCount(bytes: Int) -> Int { bytes <= 0 ? 0 : (bytes + chunkBytes - 1) / chunkBytes }
    static func chunk(_ data: Data, index: Int) -> Data? {
        let start = index * chunkBytes
        guard index >= 0, start < data.count else { return nil }
        let begin = data.startIndex + start
        return data.subdata(in: begin..<min(begin + chunkBytes, data.endIndex))
    }
    static func expectedChunkLength(index: Int, total: Int, bytes: Int) -> Int {
        index == total - 1 ? bytes - index * chunkBytes : chunkBytes
    }
    /// Problem text for a backup the room cannot carry, or nil when it can.
    static func validate(bundle: Data) -> String? {
        if bundle.isEmpty { return "The project backup is empty." }
        if bundle.count > maximumBytes { return "This project backup is larger than the 32 MB a room can carry. Share it through Files instead." }
        if bundle.prefix(portableMagic.count) != portableMagic { return "This is not a StickDeath project backup." }
        return nil
    }

    /// What the room screen offers a creator for the current snapshot.
    enum MemberState: Equatable {
        /// Owner, or nothing has been sent.
        case nothingToDo
        /// The owner's exact device project is already on this device.
        case ownerProjectOnDevice
        /// A verified copy from this room was already imported as this project.
        case imported(UUID)
        /// A newer copy than the one imported earlier is waiting; downloading
        /// creates another new project and leaves the earlier import untouched.
        case updateAvailable(previous: UUID)
        /// The shared project is waiting and this device has no copy.
        case download
    }
    static func memberState(isOwner: Bool, snapshot: RoomSnapshotRecord?, ownerProjectOnDevice: Bool,
                            link: RoomProjectLink?, linkedProjectExists: Bool) -> MemberState {
        if isOwner { return .nothingToDo }
        if ownerProjectOnDevice { return .ownerProjectOnDevice }
        let usableLink = linkedProjectExists ? link : nil
        guard let snapshot, snapshot.state == "available" else {
            if let usableLink { return .imported(usableLink.localProjectID) }
            return .nothingToDo
        }
        if let usableLink {
            if usableLink.sha256 == snapshot.sha256 || snapshot.received_by_me == true { return .imported(usableLink.localProjectID) }
            return .updateAvailable(previous: usableLink.localProjectID)
        }
        return .download
    }
}

/// `sdi_room_snapshot` request: current, offer, put, finalize, get, receipt, revoke.
struct RoomSnapshotRequest: Encodable, Equatable, Sendable {
    let action: String
    let room: UUID
    var snapshot: UUID? = nil
    var byte_size: Int? = nil
    var sha256: String? = nil
    var chunk_index: Int? = nil
    var data: String? = nil
}
struct RoomSnapshotRecord: Decodable, Equatable {
    let snapshot_id: UUID
    let title: String
    let project_ref: String
    let project_revision: Int
    let byte_size: Int
    let chunk_count: Int
    let sha256: String
    let state: String
    var offered_at: Date? = nil
    let expires_at: Date
    var mine: Bool? = nil
    var received_by_me: Bool? = nil
    /// Owner only: chunk indexes held while uploading, delivery counts.
    var received: [Int]? = nil
    var delivered: Int? = nil
    var awaiting: Int? = nil
}
struct RoomSnapshotResponse: CommunityResponse {
    let error: String?
    let status: String?
    let snapshot_id: UUID?
    let state: String?
    let chunk_size: Int?
    let chunk_count: Int?
    let chunk_index: Int?
    let sha256: String?
    let data: String?
    let expires_at: Date?
    let verified: Bool?
    let awaiting: Int?
    let server_copy: String?
    let snapshot: RoomSnapshotRecord?
    /// A count after `put`, a list of chunk indexes after `offer`/`finalize`.
    let received: CommunityJSONValue?
    var receivedIndexes: Set<Int> {
        guard case .array(let values)? = received else { return [] }
        return Set(values.compactMap { if case .number(let n) = $0 { return Int(n) } else { return nil } })
    }
}

@MainActor
final class RoomProjectHandoff {
    enum SendOutcome: Equatable { case available(UUID, awaiting: Int), alreadyAvailable(UUID) }
    enum ReceiptOutcome: Equatable { case serverCopyDeleted(verified: Bool), serverCopyRetained }
    enum HandoffError: Error, Equatable, LocalizedError {
        case invalid(String), refused(String), corrupt, unavailable(String), cancelled
        var errorDescription: String? {
            switch self {
            case .invalid(let text), .refused(let text), .unavailable(let text): return text
            case .corrupt: return "The shared project did not match its SHA-256 and was discarded. No project was created."
            case .cancelled: return "Cancelled. No project on this device was changed."
            }
        }
    }
    /// Download progress kept by the caller so an interrupted download resumes.
    struct Download: Equatable {
        let snapshot: RoomSnapshotRecord
        var chunks: [Data] = []
        var complete: Bool { chunks.count == snapshot.chunk_count }
    }

    let gateway: CommunityGateway
    init(gateway: CommunityGateway) { self.gateway = gateway }

    /// The room's live snapshot, if any (members see only an available one).
    func current(room: UUID) async throws -> RoomSnapshotRecord? {
        let response = try await call(RoomSnapshotRequest(action: "current", room: room))
        guard response.chunk_size == RoomProjectHandoffPolicy.chunkBytes else {
            throw HandoffError.unavailable("Project handoff is unavailable from this service version.")
        }
        return response.snapshot
    }

    /// Owner: send the portable backup bytes. Resumes from chunks the server holds.
    func send(room: UUID, bundle: Data, progress: (Int, Int) -> Void = { _, _ in }) async throws -> SendOutcome {
        if let problem = RoomProjectHandoffPolicy.validate(bundle: bundle) { throw HandoffError.invalid(problem) }
        guard let digest = RoomAssetPolicy.sha256Hex(bundle) else { throw HandoffError.unavailable("File hashing is unavailable on this device.") }
        let total = RoomProjectHandoffPolicy.chunkCount(bytes: bundle.count)
        let declared = try await call(RoomSnapshotRequest(action: "offer", room: room, byte_size: bundle.count, sha256: digest))
        guard let snapshot = declared.snapshot_id, declared.chunk_count == total, declared.chunk_size == RoomProjectHandoffPolicy.chunkBytes else {
            throw HandoffError.refused("Sending the project was not confirmed.")
        }
        if declared.status == "existing" && declared.state == "available" { return .alreadyAvailable(snapshot) }
        guard declared.status == "declared" || declared.status == "existing" else { throw HandoffError.refused("Sending the project was not confirmed.") }
        var held = declared.status == "existing" ? declared.receivedIndexes : []
        for attempt in 0..<2 {
            for index in 0..<total where !held.contains(index) {
                if Task.isCancelled { throw HandoffError.cancelled }
                guard let chunk = RoomProjectHandoffPolicy.chunk(bundle, index: index) else { throw HandoffError.invalid("The backup changed while sending.") }
                let stored = try await call(RoomSnapshotRequest(action: "put", room: room, snapshot: snapshot, chunk_index: index, data: chunk.base64EncodedString()))
                guard stored.status == "stored" else { throw HandoffError.refused("A part of the project was not confirmed.") }
                held.insert(index); progress(held.count, total)
            }
            let finished = try await gateway.callKeepingServerError("sdi_room_snapshot",
                params: RoomSnapshotRequest(action: "finalize", room: room, snapshot: snapshot), as: RoomSnapshotResponse.self)
            if finished.error == "incomplete", attempt == 0 { held = finished.receivedIndexes; continue }
            if let error = finished.error, !error.isEmpty { throw error.contains("corrupt") ? HandoffError.corrupt : HandoffError.refused(error) }
            guard finished.status == "available", finished.snapshot_id == snapshot else { throw HandoffError.refused("Sending the project was not confirmed.") }
            return .available(snapshot, awaiting: finished.awaiting ?? 0)
        }
        throw HandoffError.refused("The server is still missing parts of the project. Try again.")
    }

    /// Member: fetch the remaining chunks, then verify size, header and SHA-256.
    /// Corrupt data is discarded entirely; an interruption keeps verified parts.
    func receive(room: UUID, _ download: inout Download) async throws -> Data {
        let snapshot = download.snapshot
        guard snapshot.state == "available", snapshot.mine != true, (1...RoomProjectHandoffPolicy.maximumChunks).contains(snapshot.chunk_count),
              snapshot.byte_size <= RoomProjectHandoffPolicy.maximumBytes,
              snapshot.chunk_count == RoomProjectHandoffPolicy.chunkCount(bytes: snapshot.byte_size) else {
            throw HandoffError.unavailable("No shared project is waiting in this room.")
        }
        while !download.complete {
            if Task.isCancelled { throw HandoffError.cancelled }
            let index = download.chunks.count
            let reply = try await call(RoomSnapshotRequest(action: "get", room: room, snapshot: snapshot.snapshot_id, chunk_index: index))
            guard reply.snapshot_id == snapshot.snapshot_id, reply.chunk_index == index, reply.sha256 == snapshot.sha256,
                  reply.chunk_count == snapshot.chunk_count, let text = reply.data,
                  let chunk = Data(base64Encoded: text, options: .ignoreUnknownCharacters),
                  chunk.count == RoomProjectHandoffPolicy.expectedChunkLength(index: index, total: snapshot.chunk_count, bytes: snapshot.byte_size) else {
                download.chunks = []
                throw HandoffError.corrupt
            }
            download.chunks.append(chunk)
        }
        let whole = download.chunks.reduce(into: Data()) { $0.append($1) }
        guard whole.count == snapshot.byte_size, let digest = RoomAssetPolicy.sha256Hex(whole), digest == snapshot.sha256,
              RoomProjectHandoffPolicy.validate(bundle: whole) == nil else {
            download.chunks = []
            throw HandoffError.corrupt
        }
        return whole
    }

    /// Member: record that the verified project was imported. The server deletes
    /// its copy once every current member has a receipt.
    func confirmReceipt(room: UUID, snapshot: RoomSnapshotRecord) async throws -> ReceiptOutcome {
        let response = try await call(RoomSnapshotRequest(action: "receipt", room: room, snapshot: snapshot.snapshot_id, sha256: snapshot.sha256))
        guard response.status == "recorded" else { throw HandoffError.refused("The receipt was not confirmed.") }
        return response.server_copy == "deleted" ? .serverCopyDeleted(verified: response.verified ?? false) : .serverCopyRetained
    }

    /// Owner: withdraw the server copy. Copies members already imported stay theirs.
    func revoke(room: UUID, snapshot: UUID) async throws -> Bool {
        let response = try await call(RoomSnapshotRequest(action: "revoke", room: room, snapshot: snapshot))
        guard response.status == "revoked" else { throw HandoffError.refused("Withdrawal was not confirmed.") }
        return response.verified ?? false
    }

    private func call(_ request: RoomSnapshotRequest) async throws -> RoomSnapshotResponse {
        do { return try await gateway.call("sdi_room_snapshot", params: request, as: RoomSnapshotResponse.self) }
        catch CommunityError.server(let message, _) {
            if message.contains("unavailable") || message.hasPrefix("No shared project") { throw HandoffError.unavailable(message) }
            throw HandoffError.refused(message)
        }
    }
}

/// Which local project a room's handed-off copy became. Kept on this device
/// only; the record never names or replaces any other project.
struct RoomProjectLink: Codable, Equatable {
    let room: UUID
    let projectRef: String
    let sha256: String
    let localProjectID: UUID
    let importedAt: Date
}

/// JSON file store of room → imported project links (Application Support).
struct RoomProjectLinkStore {
    let fileURL: URL
    init(directory: URL) { fileURL = directory.appendingPathComponent("room-project-links.json", isDirectory: false) }

    func all() -> [RoomProjectLink] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RoomProjectLink].self, from: data)) ?? []
    }
    /// The latest link for this room's current shared project.
    func link(room: UUID, projectRef: String?) -> RoomProjectLink? {
        guard let projectRef else { return nil }
        return all().filter { $0.room == room && $0.projectRef == projectRef }.max { $0.importedAt < $1.importedAt }
    }
    /// Append a link. Earlier links (and their projects) are kept, never replaced.
    func record(_ link: RoomProjectLink) throws {
        var links = all().filter { $0.localProjectID != link.localProjectID }
        links.append(link)
        if links.count > 200 { links.removeFirst(links.count - 200) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(links).write(to: fileURL, options: .atomic)
    }
}
