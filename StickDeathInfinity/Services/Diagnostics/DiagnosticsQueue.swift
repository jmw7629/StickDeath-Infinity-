// ═══════════════════════════════════════════════════════════════════
// DiagnosticsQueue — bounded on-device queue plus the opt-in switch (#291).
//
// Foundation only. Nothing is recorded while the creator has not opted in;
// turning diagnostics off deletes everything queued. The queue keeps at most
// 14 day-buckets and nothing older than 30 days, and the creator can read the
// exact JSON that would be sent and delete it at any time.
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Combine

/// Pure queue rules, separate from storage so they are testable.
struct DiagnosticsQueue: Codable, Equatable {
    private(set) var reports: [DiagnosticsReport] = []

    /// Adds `amount` to `counter` in the bucket for `date`'s UTC day and `context`.
    /// `now` is the device clock: events outside the retention window or in the
    /// future are pruned straight away.
    mutating func record(_ counter: DiagnosticsCounter, amount: Int = 1, at date: Date, now: Date, context: DiagnosticsContext) {
        let amount = DiagnosticsSanitizer.count(amount)
        guard amount > 0 else { return }
        let day = DiagnosticsSanitizer.day(date)
        let candidate = DiagnosticsReport(platform: context.platform, appVersion: context.appVersion, build: context.build,
                                          osMajor: context.osMajor, day: day, counters: [:])
        if let index = reports.firstIndex(where: { $0.bucket == candidate.bucket && $0.platform == candidate.platform }) {
            let current = reports[index].counters[counter.rawValue] ?? 0
            reports[index].counters[counter.rawValue] = DiagnosticsSanitizer.count(current + amount)
        } else {
            var report = candidate
            report.counters[counter.rawValue] = amount
            reports.append(report)
        }
        prune(now: now)
    }

    /// Drops expired, future-dated (clock skew) and invalid buckets, then the
    /// oldest beyond the cap. Reports stay sorted oldest first.
    mutating func prune(now: Date) {
        let today = DiagnosticsSanitizer.day(now)
        let oldest = DiagnosticsSanitizer.day(now.addingTimeInterval(-Double(DiagnosticsLimits.maxAgeDays) * 86_400))
        reports = reports.compactMap(DiagnosticsSanitizer.sanitized)
            .filter { $0.day >= oldest && $0.day <= today }
            .sorted { ($0.day, $0.bucket) < ($1.day, $1.bucket) }
        if reports.count > DiagnosticsLimits.maxQueuedReports {
            reports.removeFirst(reports.count - DiagnosticsLimits.maxQueuedReports)
        }
    }

    /// Completed days only: today's bucket is still accumulating.
    func uploadable(now: Date) -> [DiagnosticsReport] {
        let today = DiagnosticsSanitizer.day(now)
        return reports.filter { $0.day < today }
    }

    /// Removes the buckets the server acknowledged.
    mutating func remove(_ sent: [DiagnosticsReport]) {
        let keys = Set(sent.map { $0.platform.rawValue + "|" + $0.bucket })
        reports.removeAll { keys.contains($0.platform.rawValue + "|" + $0.bucket) }
    }
    mutating func removeAll() { reports.removeAll() }

    /// The exact JSON array the uploader would send, pretty-printed.
    func previewJSON() -> String {
        guard !reports.isEmpty, let data = try? DiagnosticsCoding.encode(reports, pretty: true),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}

/// Opt-in flag. Off by default; a missing or unreadable value means off.
struct DiagnosticsConsent {
    static let key = "sdi.diagnostics.optIn.v1"
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var isOptedIn: Bool { defaults.object(forKey: Self.key) as? Bool ?? false }
    func set(_ value: Bool) { defaults.set(value, forKey: Self.key) }
}

/// Atomic JSON file in Application Support (excluded from iCloud backup).
struct DiagnosticsQueueFile {
    let url: URL

    static func standard(fileManager: FileManager = .default) throws -> DiagnosticsQueueFile {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return DiagnosticsQueueFile(url: base.appendingPathComponent("Diagnostics", isDirectory: true).appendingPathComponent("queue.json"))
    }

    /// Missing or damaged files read as an empty queue; nothing user-made lives here.
    func load(now: Date) -> DiagnosticsQueue {
        guard let data = try? Data(contentsOf: url), data.count <= 256 * 1024,
              var queue = try? DiagnosticsCoding.decode(DiagnosticsQueue.self, from: data) else { return DiagnosticsQueue() }
        queue.prune(now: now)
        return queue
    }
    func save(_ queue: DiagnosticsQueue) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        var mutableFolder = folder
        try? mutableFolder.setResourceValues(resource)
        try DiagnosticsCoding.encode(queue).write(to: url, options: .atomic)
    }
    func delete() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

/// The one object the app talks to. Main-actor isolated; MetricKit callbacks
/// hop here before recording.
@MainActor
final class DiagnosticsCenter: ObservableObject {
    @Published private(set) var isOptedIn: Bool
    @Published private(set) var queue: DiagnosticsQueue
    @Published private(set) var lastError: String?

    let consent: DiagnosticsConsent
    let file: DiagnosticsQueueFile?
    let context: DiagnosticsContext
    private let now: () -> Date

    init(consent: DiagnosticsConsent = DiagnosticsConsent(), file: DiagnosticsQueueFile? = try? DiagnosticsQueueFile.standard(),
         context: DiagnosticsContext = .current(), now: @escaping () -> Date = Date.init) {
        self.consent = consent; self.file = file; self.context = context; self.now = now
        let optedIn = consent.isOptedIn
        isOptedIn = optedIn
        // A queue left behind by an earlier opt-out (or a crash mid-delete) is discarded.
        if optedIn { queue = file?.load(now: now()) ?? DiagnosticsQueue() }
        else { queue = DiagnosticsQueue(); try? file?.delete() }
    }

    /// Turning diagnostics off deletes the queue immediately.
    func setOptedIn(_ value: Bool) {
        consent.set(value)
        isOptedIn = value
        if !value { deleteQueued() }
    }

    /// No-op unless opted in.
    func record(_ counter: DiagnosticsCounter, amount: Int = 1, at date: Date? = nil) {
        guard consent.isOptedIn else { return }
        let current = now()
        queue.record(counter, amount: amount, at: date ?? current, now: current, context: context)
        persist()
    }

    func deleteQueued() {
        queue.removeAll()
        do { try file?.delete(); lastError = nil }
        catch { lastError = "Queued diagnostics could not be deleted. Try again." }
    }

    func acknowledge(_ sent: [DiagnosticsReport]) {
        queue.remove(sent)
        persist()
    }

    var previewJSON: String { queue.previewJSON() }
    var currentDate: Date { now() }

    private func persist() {
        guard let file else { return }
        do { try file.save(queue); lastError = nil }
        catch { lastError = "Diagnostics could not be saved on this device." }
    }
}
