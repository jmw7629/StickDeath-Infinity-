// ═══════════════════════════════════════════════════════════════════
// DiagnosticsReport — the coarse, first-party diagnostics payload (#291).
//
// Foundation only, so the standalone Tests/Diagnostics suite compiles it on
// macOS without the app. A report is one UTC day of allowlisted counters for
// one app version/build/OS major. It never holds free text, stack frames,
// identifiers, file names, project contents, prompts or precise times; the
// server (backend/sql/diagnostics.sql) re-validates the same contract and
// stores only these fields. Collection is opt-in and off by default.
// ═══════════════════════════════════════════════════════════════════

import Foundation

/// Every counter a client may send. Adding one requires the same change in
/// backend/sql/diagnostics.sql and the Android `DiagnosticsCounter`.
enum DiagnosticsCounter: String, CaseIterable, Codable, Comparable {
    case appLaunch = "app_launch"
    case crash
    case hang
    case cpuException = "cpu_exception"
    case diskWriteException = "disk_write_exception"
    case memoryLimitExit = "memory_limit_exit"
    case watchdogExit = "watchdog_exit"
    case uncaughtException = "uncaught_exception"

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Plain-language label for the "what will be sent" view.
    var label: String {
        switch self {
        case .appLaunch: return "App launches"
        case .crash: return "Crashes"
        case .hang: return "Hangs"
        case .cpuException: return "CPU limit exceptions"
        case .diskWriteException: return "Disk write limit exceptions"
        case .memoryLimitExit: return "Memory limit terminations"
        case .watchdogExit: return "Watchdog terminations"
        case .uncaughtException: return "Uncaught exceptions"
        }
    }
}

enum DiagnosticsPlatform: String, Codable, Sendable { case ios, android }

/// Bounds shared with the server contract.
enum DiagnosticsLimits {
    static let contractVersion = 1
    static let maxCount = 10_000
    static let maxQueuedReports = 14
    static let maxAgeDays = 30
}

struct DiagnosticsReport: Codable, Equatable, Sendable {
    var v: Int = DiagnosticsLimits.contractVersion
    var platform: DiagnosticsPlatform
    var appVersion: String
    var build: String
    var osMajor: Int
    /// UTC calendar day, `yyyy-MM-dd`; the only time information sent.
    var day: String
    /// Allowlisted counter → count (1…10 000). Zero counts are omitted.
    var counters: [String: Int]

    enum CodingKeys: String, CodingKey {
        case v, platform, appVersion = "app_version", build, osMajor = "os_major", day, counters
    }

    var isEmpty: Bool { counters.values.allSatisfy { $0 <= 0 } }
    func count(_ counter: DiagnosticsCounter) -> Int { counters[counter.rawValue] ?? 0 }
    /// Identity of the bucket a new event merges into.
    var bucket: String { "\(day)|\(appVersion)|\(build)|\(osMajor)" }
}

/// The release context a report is tagged with. Values are normalized so a
/// malformed bundle string can never smuggle free text into the payload.
struct DiagnosticsContext: Equatable {
    var platform: DiagnosticsPlatform
    var appVersion: String
    var build: String
    var osMajor: Int

    init(platform: DiagnosticsPlatform = .ios, appVersion: String?, build: String?, osMajor: Int) {
        self.platform = platform
        self.appVersion = DiagnosticsSanitizer.appVersion(appVersion)
        self.build = DiagnosticsSanitizer.build(build)
        self.osMajor = DiagnosticsSanitizer.osMajor(osMajor)
    }

    /// The running app's bundle values and OS major version.
    static func current(bundle: Bundle = .main) -> DiagnosticsContext {
        let info = bundle.infoDictionary
        return DiagnosticsContext(appVersion: info?["CFBundleShortVersionString"] as? String,
                                  build: info?["CFBundleVersion"] as? String,
                                  osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
}

enum DiagnosticsSanitizer {
    static let unknown = "unknown"

    /// `1`, `1.2` or `1.2.3` with 1–4 digit parts; anything else becomes "unknown".
    static func appVersion(_ raw: String?) -> String {
        guard let raw, raw.range(of: #"^[0-9]{1,4}(\.[0-9]{1,4}){0,2}$"#, options: .regularExpression) != nil else { return unknown }
        return raw
    }
    /// 1–9 digits; anything else becomes "unknown".
    static func build(_ raw: String?) -> String {
        guard let raw, raw.range(of: #"^[0-9]{1,9}$"#, options: .regularExpression) != nil else { return unknown }
        return raw
    }
    static func osMajor(_ raw: Int) -> Int { min(max(raw, 0), 99) }
    static func count(_ raw: Int) -> Int { min(max(raw, 0), DiagnosticsLimits.maxCount) }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Rounds a moment down to its UTC day.
    static func day(_ date: Date) -> String {
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        func padded(_ value: Int, _ width: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return padded(parts.year ?? 1970, 4) + "-" + padded(parts.month ?? 1, 2) + "-" + padded(parts.day ?? 1, 2)
    }
    static func date(ofDay day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, day.count == 10 else { return nil }
        return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Drops unknown counters, clamps counts and omits zeros. Returns nil when
    /// the report breaks the contract and must not be queued or sent.
    static func sanitized(_ report: DiagnosticsReport) -> DiagnosticsReport? {
        guard report.v == DiagnosticsLimits.contractVersion,
              appVersion(report.appVersion) == report.appVersion,
              build(report.build) == report.build,
              (0...99).contains(report.osMajor),
              let parsed = date(ofDay: report.day), day(parsed) == report.day else { return nil }
        var copy = report
        copy.counters = [:]
        for (key, value) in report.counters where DiagnosticsCounter(rawValue: key) != nil {
            let clamped = count(value)
            if clamped > 0 { copy.counters[key] = clamped }
        }
        return copy.isEmpty ? nil : copy
    }
}

enum DiagnosticsCoding {
    /// Deterministic JSON (sorted keys) used both for storage and for the
    /// "view what will be sent" screen, so the preview is the exact payload.
    static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
