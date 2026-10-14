import Foundation

/// Storage budgets and least-recently-used eviction for regenerable data (#171).
///
/// The rule this file exists to enforce: automatic eviction may remove only
/// regenerable data (waveform summaries, thumbnails, encoder caches) and
/// abandoned scratch. Project originals, saved revisions, recovery data,
/// Recently Deleted, managed media and user exports are essential and are
/// never selected, whatever the budget pressure. When essential data alone
/// exceeds a budget the plan reports the shortfall instead of deleting work.
///
/// A free-space preflight is advisory. Writes still handle real out-of-space
/// errors (see `DeviceStorageManager.userMessage(for:)`); a passed preflight is
/// never a substitute for that.
struct StudioStorageBudget: Equatable, Sendable {
    /// Free space kept in reserve after a predicted write.
    var reservedHeadroomBytes: Int64 = 256 * 1024 * 1024
    /// Below this the storage screen warns that space is low.
    var lowSpaceWarningBytes: Int64 = 1024 * 1024 * 1024
    /// Ceiling for each regenerable on-disk cache this app owns.
    var regenerableCacheBytes: Int64 = 32 * 1024 * 1024
    /// Scratch younger than this may belong to a running operation.
    var scratchMinimumAge: TimeInterval = 60 * 60

    static let standard = StudioStorageBudget()

    enum Status: Equatable, Sendable {
        /// The volume did not report free space; nothing is inferred.
        case unknown
        case healthy(availableBytes: Int64)
        case low(availableBytes: Int64)
        case critical(availableBytes: Int64)
    }

    func status(availableBytes: Int64?) -> Status {
        guard let available = availableBytes, available >= 0 else { return .unknown }
        if available < reservedHeadroomBytes { return .critical(availableBytes: available) }
        if available < lowSpaceWarningBytes { return .low(availableBytes: available) }
        return .healthy(availableBytes: available)
    }

    enum Admission: Equatable, Sendable {
        case allowed
        /// Free space is unknown; proceed and rely on real write errors.
        case unmeasured
        case refused(neededBytes: Int64, availableBytes: Int64)

        var message: String? {
            guard case .refused(let needed, let available) = self else { return nil }
            let format = { (value: Int64) in ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
            return "Not enough free space to do this safely: about \(format(needed)) is needed and \(format(available)) is available. Nothing was changed; free up space and try again."
        }
    }

    /// `estimatedWriteBytes` is the size of what will be written; staging and
    /// the final copy both exist briefly, so twice that plus headroom is needed.
    func admit(estimatedWriteBytes: Int64, availableBytes: Int64?) -> Admission {
        guard let available = availableBytes, available >= 0 else { return .unmeasured }
        let estimate = max(0, estimatedWriteBytes)
        let (doubled, overflow) = estimate.multipliedReportingOverflow(by: 2)
        let (needed, overflow2) = doubled.addingReportingOverflow(reservedHeadroomBytes)
        if overflow || overflow2 { return .refused(neededBytes: .max, availableBytes: available) }
        return available >= needed ? .allowed : .refused(neededBytes: needed, availableBytes: available)
    }

    /// Free space for important usage on the volume holding `url`, or nil.
    static func availableBytes(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }
}

/// What a stored item is for. Only the last two roles are ever evictable.
enum StudioStorageRole: String, CaseIterable, Sendable {
    case projectOriginal, selectedRevision, previousRevision, recoverableRevision
    case recentlyDeleted, managedMedia, userExport
    case regenerableCache, scratch

    var isEssential: Bool { self != .regenerableCache && self != .scratch }
}

struct StudioStorageItem: Equatable, Sendable {
    let id: String
    let role: StudioStorageRole
    let bytes: Int64
    let lastUsed: Date
    /// In use now: open document, Undo history, an export awaiting its share
    /// sheet, a running import. Pinned items are never evicted.
    var pinned = false
}

struct StudioEvictionPlan: Equatable, Sendable {
    let evict: [StudioStorageItem]
    var reclaimedBytes: Int64 { evict.reduce(0) { $0 + $1.bytes } }
    /// Regenerable bytes left after the plan.
    let remainingRegenerableBytes: Int64
    /// Bytes the plan may never touch (essential or pinned).
    let protectedBytes: Int64
    /// How far regenerable usage stays above budget because what remains is pinned.
    let shortfallBytes: Int64
}

enum StudioEvictionPlanner {
    /// Least-recently-used regenerable items go first until the regenerable
    /// total fits `regenerableBudgetBytes`. Unpinned scratch older than
    /// `scratchMinimumAge` is abandoned and always included. Ties break on id
    /// so the plan is deterministic.
    static func plan(_ items: [StudioStorageItem], regenerableBudgetBytes: Int64,
                     scratchMinimumAge: TimeInterval, now: Date = Date()) -> StudioEvictionPlan {
        var evict: [StudioStorageItem] = []
        var protected: Int64 = 0
        for item in items where item.role.isEssential || item.pinned { protected += max(0, item.bytes) }
        for item in items where item.role == .scratch && !item.pinned
            && now.timeIntervalSince(item.lastUsed) >= scratchMinimumAge {
            evict.append(item)
        }
        let regenerable = items.filter { $0.role == .regenerableCache }
        var remaining = regenerable.reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        let budget = max(0, regenerableBudgetBytes)
        let candidates = regenerable.filter { !$0.pinned }.sorted {
            $0.lastUsed != $1.lastUsed ? $0.lastUsed < $1.lastUsed : $0.id < $1.id
        }
        for item in candidates where remaining > budget {
            evict.append(item)
            remaining -= max(0, item.bytes)
        }
        return StudioEvictionPlan(evict: evict, remainingRegenerableBytes: remaining,
                                  protectedBytes: protected, shortfallBytes: max(0, remaining - budget))
    }
}
