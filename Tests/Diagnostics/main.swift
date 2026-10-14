import Foundation

// Compiles the production Foundation diagnostics sources (#291):
// DiagnosticsReport.swift, DiagnosticsQueue.swift, DiagnosticsUploader.swift and
// DiagnosticsMetricKit.swift (its MetricKit half is iOS-only and excluded here).
// Scripted submitters only; no network, no MetricKit delivery.
private struct Failure: Error { let message: String }

@MainActor
private final class ScriptedSubmitter: DiagnosticsSubmitting {
    var replies: [Result<String, Error>]
    private(set) var sent: [Data] = []
    init(_ replies: [Result<String, Error>]) { self.replies = replies }
    func submit(_ report: DiagnosticsReport) async throws -> Data {
        sent.append(try DiagnosticsCoding.encode(report))
        let next = replies.isEmpty ? .success(#"{"status":"accepted"}"#) : replies.removeFirst()
        return Data(try next.get().utf8)
    }
}

@main @MainActor struct DiagnosticsTests {
    static var passed = 0
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message: message) }
    }
    static func pass(_ name: String) { passed += 1; print("PASS " + name) }

    static let day: TimeInterval = 86_400
    static let now = Date(timeIntervalSince1970: 1_760_000_000) // 2025-10-09 08:53:20 UTC
    static let context = DiagnosticsContext(appVersion: "1.4.2", build: "317", osMajor: 17)

    static func sandbox() throws -> (DiagnosticsConsent, DiagnosticsQueueFile, URL) {
        let suite = "sdi.diagnostics.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        return (DiagnosticsConsent(defaults: defaults), DiagnosticsQueueFile(url: folder.appendingPathComponent("queue.json")), folder)
    }

    static func main() async {
        do {
            try sanitizer()
            try queueRules()
            try consentGate()
            try previewIsExactPayload()
            try metricSummary()
            try await uploads()
            print("DIAGNOSTICS_TESTS=PASS (\(passed) checks)")
        } catch let failure as Failure {
            print("FAIL " + failure.message); exit(1)
        } catch {
            print("FAIL \(error)"); exit(1)
        }
    }

    static func sanitizer() throws {
        try require(DiagnosticsSanitizer.appVersion("1.4.2") == "1.4.2", "plain version kept")
        for bad in ["1.4.2-beta", "joe@example.com", "", "1.2.3.4", "../../etc", "12345.1"] {
            try require(DiagnosticsSanitizer.appVersion(bad) == "unknown", "free text version rejected: \(bad)")
        }
        try require(DiagnosticsSanitizer.build("317") == "317" && DiagnosticsSanitizer.build("317a") == "unknown", "build digits only")
        try require(DiagnosticsSanitizer.osMajor(140) == 99 && DiagnosticsSanitizer.osMajor(-3) == 0, "os major clamped")
        try require(DiagnosticsSanitizer.day(now) == "2025-10-09", "day rounded in UTC")
        try require(DiagnosticsSanitizer.day(Date(timeIntervalSince1970: 1_760_054_399)) == "2025-10-09", "end of UTC day")
        let raw = DiagnosticsReport(platform: .ios, appVersion: "1.4.2", build: "317", osMajor: 17, day: "2025-10-09",
                                    counters: ["crash": 3, "free_text": 9, "hang": 0, "app_launch": 99_999])
        let clean = try DiagnosticsSanitizer.sanitized(raw).orThrow("valid report kept")
        try require(clean.counters == ["crash": 3, "app_launch": DiagnosticsLimits.maxCount], "unknown dropped, zero omitted, count clamped")
        var badDay = raw; badDay.day = "2025-13-40"
        try require(DiagnosticsSanitizer.sanitized(badDay) == nil, "invalid day refused")
        var badVersion = raw; badVersion.appVersion = "Joe's build"
        try require(DiagnosticsSanitizer.sanitized(badVersion) == nil, "invalid version refused")
        var empty = raw; empty.counters = ["free_text": 1]
        try require(DiagnosticsSanitizer.sanitized(empty) == nil, "report with no allowlisted counter refused")
        let json = String(decoding: try DiagnosticsCoding.encode(clean), as: UTF8.self)
        try require(json == #"{"app_version":"1.4.2","build":"317","counters":{"app_launch":10000,"crash":3},"day":"2025-10-09","os_major":17,"platform":"ios","v":1}"#,
                    "exact wire payload: \(json)")
        pass("sanitizer and wire contract")
    }

    static func queueRules() throws {
        var queue = DiagnosticsQueue()
        queue.record(.crash, at: now, now: now, context: context)
        queue.record(.crash, amount: 2, at: now.addingTimeInterval(60), now: now, context: context)
        queue.record(.hang, at: now, now: now, context: context)
        try require(queue.reports.count == 1 && queue.reports[0].count(.crash) == 3 && queue.reports[0].count(.hang) == 1, "same day merges")
        queue.record(.crash, at: now, now: now, context: DiagnosticsContext(appVersion: "1.4.3", build: "318", osMajor: 17))
        try require(queue.reports.count == 2, "new build gets its own bucket")
        queue.record(.crash, amount: 0, at: now, now: now, context: context)
        try require(queue.reports.count == 2, "zero amount ignored")
        for offset in 1...20 { queue.record(.appLaunch, at: now.addingTimeInterval(-Double(offset) * day), now: now, context: context) }
        try require(queue.reports.count == DiagnosticsLimits.maxQueuedReports, "queue bounded to 14 buckets")
        try require(queue.reports.last?.day == "2025-10-09", "newest kept")
        try require(queue.reports.first?.day == DiagnosticsSanitizer.day(now.addingTimeInterval(-12 * day)), "oldest dropped first")
        queue.prune(now: now.addingTimeInterval(40 * day))
        try require(queue.reports.isEmpty, "buckets older than 30 days expire")
        var skewed = DiagnosticsQueue()
        skewed.record(.crash, at: now.addingTimeInterval(3 * day), now: now, context: context)
        try require(skewed.reports.isEmpty, "future-dated bucket dropped")
        var uploadable = DiagnosticsQueue()
        uploadable.record(.crash, at: now.addingTimeInterval(-day), now: now, context: context)
        uploadable.record(.crash, at: now, now: now, context: context)
        try require(uploadable.uploadable(now: now).map(\.day) == ["2025-10-08"], "only completed days upload")
        pass("bounded queue, merging, expiry and completed-day upload")
    }

    static func consentGate() throws {
        let (consent, file, folder) = try sandbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let center = DiagnosticsCenter(consent: consent, file: file, context: context, now: { now })
        try require(!center.isOptedIn, "off by default")
        center.record(.crash)
        try require(center.queue.reports.isEmpty && !FileManager.default.fileExists(atPath: file.url.path), "nothing recorded while off")
        center.setOptedIn(true)
        center.record(.crash); center.record(.appLaunch)
        try require(center.queue.reports.count == 1 && FileManager.default.fileExists(atPath: file.url.path), "recorded and persisted when on")
        let reloaded = DiagnosticsCenter(consent: consent, file: file, context: context, now: { now })
        try require(reloaded.queue == center.queue, "queue survives relaunch")
        let stored = String(decoding: try Data(contentsOf: file.url), as: UTF8.self)
        try require(!stored.contains("317a") && stored.contains(#""crash":1"#), "stored file holds the coarse payload only")
        center.deleteQueued()
        try require(center.queue.reports.isEmpty && !FileManager.default.fileExists(atPath: file.url.path), "delete removes queue and file")
        center.record(.crash)
        center.setOptedIn(false)
        try require(center.queue.reports.isEmpty && !FileManager.default.fileExists(atPath: file.url.path), "opt-out deletes everything")
        center.record(.crash)
        try require(center.queue.reports.isEmpty, "nothing recorded after opt-out")
        try file.save({ var q = DiagnosticsQueue(); q.record(.crash, at: now, now: now, context: context); return q }())
        let relaunchedOff = DiagnosticsCenter(consent: consent, file: file, context: context, now: { now })
        try require(relaunchedOff.queue.reports.isEmpty && !FileManager.default.fileExists(atPath: file.url.path), "stale file discarded when off at launch")
        try Data("not json".utf8).write(to: file.url)
        consent.set(true)
        try require(DiagnosticsCenter(consent: consent, file: file, context: context, now: { now }).queue.reports.isEmpty, "damaged file reads as empty")
        pass("opt-in gate, persistence, delete and opt-out")
    }

    static func previewIsExactPayload() throws {
        var queue = DiagnosticsQueue()
        try require(queue.previewJSON() == "[]", "empty preview")
        queue.record(.crash, at: now, now: now, context: context)
        let preview = queue.previewJSON()
        let decoded = try DiagnosticsCoding.decode([DiagnosticsReport].self, from: Data(preview.utf8))
        try require(decoded == queue.reports, "preview decodes to the queued reports")
        for forbidden in ["user", "email", "device", "project", "time\"", "stack", "frame"] {
            try require(!preview.lowercased().contains(forbidden), "preview has no \(forbidden) field")
        }
        pass("view-what-will-be-sent preview")
    }

    static func metricSummary() throws {
        let (consent, file, folder) = try sandbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let center = DiagnosticsCenter(consent: consent, file: file, context: context, now: { now })
        let summary = DiagnosticsPayloadSummary(crashes: 2, hangs: 1, memoryLimitExits: 4, end: now.addingTimeInterval(-day))
        try require(summary.counts.map { $0.0 } == [.crash, .hang, .memoryLimitExit], "only nonzero kinds")
        center.apply(summary)
        try require(center.queue.reports.isEmpty, "OS payload ignored while off")
        center.setOptedIn(true)
        center.apply(summary)
        let report = try center.queue.reports.first.orThrow("summary recorded")
        try require(report.day == "2025-10-08" && report.count(.crash) == 2 && report.count(.memoryLimitExit) == 4, "summary on its own day")
        pass("MetricKit summary mapping")
    }

    static func uploads() async throws {
        let (consent, file, folder) = try sandbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let center = DiagnosticsCenter(consent: consent, file: file, context: context, now: { now })
        func upload(_ submitter: DiagnosticsSubmitting?) async -> DiagnosticsUploadOutcome {
            await DiagnosticsUploader(center: center, submitter: submitter).uploadPending()
        }
        var outcome = await upload(ScriptedSubmitter([]))
        try require(outcome == .disabled, "off: disabled")
        center.setOptedIn(true)
        outcome = await upload(nil)
        try require(outcome == .notConfigured, "no backend: truthful state")
        center.record(.crash)
        outcome = await upload(ScriptedSubmitter([]))
        try require(outcome == .nothingToSend, "today is not sent")
        for offset in 1...3 { center.record(.crash, at: now.addingTimeInterval(-Double(offset) * day)) }
        outcome = await upload(nil)
        try require(outcome == .notConfigured && center.queue.reports.count == 4, "unconfigured keeps the queue")

        let failing = ScriptedSubmitter([.success(#"{"status":"accepted"}"#), .failure(URLError(.notConnectedToInternet))])
        outcome = await upload(failing)
        guard case .partial(sent: 1, _) = outcome else { throw Failure(message: "network failure is partial: \(outcome)") }
        try require(center.queue.reports.count == 3, "only the acknowledged day removed")
        let body = String(decoding: try failing.sent.first.orThrow("sent body"), as: UTF8.self)
        try require(body.contains(#""day":"2025-10-06""#) && body.contains(#""platform":"ios""#), "oldest completed day sent first, coarse body")

        outcome = await upload(ScriptedSubmitter([.success(#"{"error":"Daily diagnostics limit reached.","code":"rate_limited"}"#)]))
        try require(outcome == .failed("The diagnostics service asked to wait; the rest will be sent later."), "rate limit reported")
        try require(center.queue.reports.count == 3, "nothing removed on rate limit")
        outcome = await upload(ScriptedSubmitter([.success(#"{"error":"Diagnostics consent is required."}"#)]))
        try require(outcome == .failed("Diagnostics consent is required."), "server refusal surfaced")
        outcome = await upload(ScriptedSubmitter([.success(#"{"status":"duplicate"}"#), .success(#"{"status":"accepted"}"#)]))
        try require(outcome == .sent(2), "duplicate counts as delivered")
        try require(center.queue.reports.map(\.day) == ["2025-10-09"], "today remains queued")
        center.record(.hang, at: now.addingTimeInterval(-day))
        outcome = await upload(ScriptedSubmitter([.success("<html>")]))
        guard case .failed = outcome else { throw Failure(message: "unreadable reply fails") }
        try require(center.queue.reports.count == 2, "unreadable reply keeps queue")
        pass("upload outcomes, acknowledgement and truthful unavailable state")
    }
}

private extension Optional {
    func orThrow(_ message: String) throws -> Wrapped {
        guard let value = self else { throw Failure(message: message) }
        return value
    }
}
