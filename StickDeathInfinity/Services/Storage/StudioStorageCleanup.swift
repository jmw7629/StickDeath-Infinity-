import Foundation
import Darwin

/// Disk-side executors for `StudioEvictionPlanner` (#171). Each one works on
/// one directory this app owns and only on entry names its producer is known
/// to create. Anything else in that directory is measured, reported as
/// unclassified and left untouched. Links are never followed; every entry is
/// re-checked (same inode, type, size and modification time) immediately
/// before it is removed, so a file replaced after review survives.
struct StudioStorageEntry: Equatable, Sendable {
    let name: String
    let bytes: Int64
    let modified: Date
    let isDirectory: Bool
    fileprivate let device: UInt64
    fileprivate let inode: UInt64
    fileprivate let modifiedNanoseconds: Int64
}

struct StudioStorageRemovalReceipt: Equatable, Sendable {
    var removedEntries = 0
    var removedBytes: Int64 = 0
    /// Entries that changed or vanished after review; they were left alone.
    var skippedChanged = 0
    var failed = 0
}

enum StudioStorageDirectory {
    static let maximumEntries = 10_000

    /// Lists depth-one entries without following links. Symbolic links and
    /// special files are returned in `ignored`, never as removable entries.
    static func entries(in directory: URL) throws -> (entries: [StudioStorageEntry], ignored: Int) {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            if errno == ENOENT { return ([], 0) }
            throw CocoaError(.fileReadUnknown)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileReadUnknown) }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.count <= maximumEntries else { throw StudioStorageScanRequest.Failure.limit }
        var result: [StudioStorageEntry] = [], ignored = 0
        for name in names.sorted() {
            guard let entry = try? Self.entry(named: name, in: directory) else { ignored += 1; continue }
            result.append(entry)
        }
        return (result, ignored)
    }

    static func entry(named name: String, in directory: URL) throws -> StudioStorageEntry {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw CocoaError(.fileReadInvalidFileName) }
        let url = directory.appendingPathComponent(name)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileNoSuchFile) }
        let type = info.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { throw CocoaError(.fileReadUnknown) }
        let bytes = type == S_IFREG ? Int64(info.st_size) : try regularBytes(under: url)
        let seconds = Int64(info.st_mtimespec.tv_sec), nanos = Int64(info.st_mtimespec.tv_nsec)
        return StudioStorageEntry(name: name, bytes: bytes,
                                  modified: Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000),
                                  isDirectory: type == S_IFDIR, device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino),
                                  modifiedNanoseconds: seconds &* 1_000_000_000 &+ nanos)
    }

    /// Logical bytes of regular files below a directory; links are not followed.
    static func regularBytes(under url: URL) throws -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                                                         options: [], errorHandler: { _, _ in false }) else { return 0 }
        var total: Int64 = 0, visited = 0
        for case let child as URL in walker {
            visited += 1
            guard visited <= maximumEntries else { throw StudioStorageScanRequest.Failure.limit }
            let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    /// Removes `entry` only if it is still the same item that was reviewed.
    static func remove(_ entry: StudioStorageEntry, in directory: URL, receipt: inout StudioStorageRemovalReceipt) {
        guard let current = try? Self.entry(named: entry.name, in: directory),
              current.device == entry.device, current.inode == entry.inode, current.isDirectory == entry.isDirectory,
              current.modifiedNanoseconds == entry.modifiedNanoseconds,
              entry.isDirectory || current.bytes == entry.bytes else {
            receipt.skippedChanged += 1; return
        }
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(entry.name))
            receipt.removedEntries += 1; receipt.removedBytes += current.bytes
        } catch { receipt.failed += 1 }
    }
}

/// One regenerable on-disk cache with a known producer, trimmed least recently
/// used first. Today this is the waveform summary cache: each record is
/// re-measured from the project's own audio when it is next shown.
struct StudioRegenerableCacheTrimmer {
    let directory: URL
    let isOwnedName: @Sendable (String) -> Bool

    static var waveforms: StudioRegenerableCacheTrimmer {
        StudioRegenerableCacheTrimmer(directory: StudioWaveformCache.defaultDirectory) { name in
            name.hasSuffix(".json") && StudioWaveformCache.isDigest(String(name.dropLast(5)))
        }
    }

    struct Usage: Equatable, Sendable {
        var entries: [StudioStorageEntry] = []
        var unclassifiedFiles = 0
        var unclassifiedBytes: Int64 = 0
        var ownedBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    }

    func measure() throws -> Usage {
        let listing = try StudioStorageDirectory.entries(in: directory)
        var usage = Usage()
        usage.unclassifiedFiles = listing.ignored
        for entry in listing.entries {
            if !entry.isDirectory && isOwnedName(entry.name) { usage.entries.append(entry) }
            else { usage.unclassifiedFiles += 1; usage.unclassifiedBytes += entry.bytes }
        }
        return usage
    }

    /// Removes least-recently-used owned records until the cache fits
    /// `budgetBytes` (0 clears every owned record). Unclassified files stay.
    @discardableResult
    func trim(toBudget budgetBytes: Int64, now: Date = Date()) throws -> StudioStorageRemovalReceipt {
        let usage = try measure()
        let items = usage.entries.map { StudioStorageItem(id: $0.name, role: .regenerableCache, bytes: $0.bytes, lastUsed: $0.modified) }
        let plan = StudioEvictionPlanner.plan(items, regenerableBudgetBytes: budgetBytes, scratchMinimumAge: .infinity, now: now)
        let byName = Dictionary(uniqueKeysWithValues: usage.entries.map { ($0.name, $0) })
        var receipt = StudioStorageRemovalReceipt()
        for item in plan.evict {
            guard item.role == .regenerableCache, let entry = byName[item.id] else { continue }
            StudioStorageDirectory.remove(entry, in: directory, receipt: &receipt)
        }
        return receipt
    }
}

/// Leftovers in the app's temporary directory from operations that ended
/// without cleaning up (a crash or force quit mid-import, -export or -record).
/// Working scratch is abandoned once older than the minimum age. Export copies
/// are the user's rendered files, so they are reported separately and removed
/// only when the creator explicitly asks; the project they came from is not
/// affected either way.
struct StudioScratchSweeper {
    let directory: URL
    var minimumAge: TimeInterval = StudioStorageBudget.standard.scratchMinimumAge

    /// Prefixes created by `StudioViewModel` import validation, voice capture
    /// and movie muxing.
    static let scratchPrefixes = ["sdi-project-validation-", "sdi-voice-", ".sdi-mux-"]
    /// Prefixes created by GIF/MP4 export and feed downloads.
    static let exportPrefixes = ["SDI-Movie-", "SDI-", "sdi-export-"]

    static var temporary: StudioScratchSweeper { StudioScratchSweeper(directory: FileManager.default.temporaryDirectory) }

    struct Review: Equatable, Sendable {
        var scratch: [StudioStorageEntry] = []
        var exports: [StudioStorageEntry] = []
        /// Matching entries too recent to be considered abandoned.
        var recent = 0
        var scratchBytes: Int64 { scratch.reduce(0) { $0 + $1.bytes } }
        var exportBytes: Int64 { exports.reduce(0) { $0 + $1.bytes } }
        var isEmpty: Bool { scratch.isEmpty && exports.isEmpty }
    }

    static func role(of name: String) -> StudioStorageRole? {
        if scratchPrefixes.contains(where: { name.hasPrefix($0) }) { return .scratch }
        if exportPrefixes.contains(where: { name.hasPrefix($0) }) { return .userExport }
        return nil
    }

    func review(now: Date = Date()) throws -> Review {
        var review = Review()
        for entry in try StudioStorageDirectory.entries(in: directory).entries {
            guard let role = Self.role(of: entry.name) else { continue }
            guard now.timeIntervalSince(entry.modified) >= minimumAge else { review.recent += 1; continue }
            if role == .scratch { review.scratch.append(entry) } else { review.exports.append(entry) }
        }
        return review
    }

    /// Removes reviewed scratch and, only when `includeExports` is true, the
    /// reviewed export copies. Each entry is re-verified before removal.
    func remove(_ review: Review, includeExports: Bool) -> StudioStorageRemovalReceipt {
        var receipt = StudioStorageRemovalReceipt()
        for entry in review.scratch where Self.role(of: entry.name) == .scratch {
            StudioStorageDirectory.remove(entry, in: directory, receipt: &receipt)
        }
        if includeExports {
            for entry in review.exports where Self.role(of: entry.name) == .userExport {
                StudioStorageDirectory.remove(entry, in: directory, receipt: &receipt)
            }
        }
        return receipt
    }
}
