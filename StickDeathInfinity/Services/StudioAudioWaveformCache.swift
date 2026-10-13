import Foundation

/// Measured waveform summary of one decoded audio asset (#192). `peaks` and
/// `rms` each hold `binCount` values in 0...1 over equal time intervals of the
/// whole source. Both come from the actual PCM samples: the peak is the largest
/// absolute sample in the bin across channels, the RMS is the root mean square
/// of every sample in the bin across channels. Silence is exactly zero.
struct StudioWaveformAccumulator {
    static let binCount = 256
    let binCount: Int
    let totalFrames: Int64
    let channels: Int
    private(set) var peaks: [Float]
    private var energy: [Double]
    private var frames: [Int64]
    private(set) var clipped = false

    init(totalFrames: Int64, channels: Int, binCount: Int = StudioWaveformAccumulator.binCount) {
        self.binCount = max(1, binCount)
        self.totalFrames = max(1, totalFrames)
        self.channels = max(1, channels)
        peaks = Array(repeating: 0, count: self.binCount)
        energy = Array(repeating: 0, count: self.binCount)
        frames = Array(repeating: 0, count: self.binCount)
    }

    /// `samples` holds one value per channel for frame `frame`.
    mutating func add(frame: Int64, samples: [Float]) {
        guard frame >= 0, frame < totalFrames else { return }
        let bin = Int(frame * Int64(binCount) / totalFrames)
        var peak: Float = 0, sum = 0.0
        for value in samples {
            let magnitude = abs(value)
            peak = max(peak, magnitude)
            sum += Double(value) * Double(value)
        }
        if peak > 1 { clipped = true }
        peaks[bin] = max(peaks[bin], min(1, peak))
        energy[bin] += sum
        frames[bin] += 1
    }

    /// RMS per bin, capped at 1 for display like the peaks. Empty bins are 0.
    var rms: [Float] {
        (0..<binCount).map { bin in
            guard frames[bin] > 0 else { return 0 }
            let mean = energy[bin] / Double(frames[bin] * Int64(channels))
            return Float(min(1, mean.squareRoot()))
        }
    }
}

/// One persisted analysis result keyed by the SHA-256 of the encoded bytes.
/// A record is valid only for exactly those bytes; a changed asset has a new
/// digest and therefore never reuses a stale waveform (#192, #193).
struct StudioWaveformRecord: Codable, Equatable {
    static let currentVersion = 1
    var version = StudioWaveformRecord.currentVersion
    let sha256: String
    let byteCount: Int
    let duration: Double
    let sampleRate: Double
    let channels: Int
    let peaks: [Float]
    let rms: [Float]
    let clipped: Bool

    enum Failure: Error, Equatable { case invalid }

    func validate() throws {
        guard version == Self.currentVersion, StudioWaveformCache.isDigest(sha256),
              byteCount > 0, byteCount <= 64 * 1024 * 1024,
              duration.isFinite, duration > 0, duration <= 3600,
              sampleRate.isFinite, (8000...192_000).contains(sampleRate), (1...2).contains(channels),
              peaks.count == StudioWaveformAccumulator.binCount, rms.count == peaks.count,
              peaks.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              rms.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              zip(peaks, rms).allSatisfy({ $0.1 <= $0.0 + 0.000001 }) else { throw Failure.invalid }
    }
}

/// Small on-disk cache of waveform records in the app's Caches directory.
/// Entries are plain JSON files named by digest; the directory is bounded by
/// entry count (oldest modification date evicted first). Every read validates
/// the record and its digest/filename agreement, so a damaged or foreign file
/// yields `nil` rather than a wrong waveform. No audio bytes are stored.
final class StudioWaveformCache {
    static let defaultMaximumEntries = 512
    static let maximumRecordBytes = 64 * 1024
    let directory: URL
    let maximumEntries: Int
    private let lock = NSLock()

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("StudioWaveforms", isDirectory: true)
    }
    static let shared = StudioWaveformCache()

    init(directory: URL = StudioWaveformCache.defaultDirectory, maximumEntries: Int = StudioWaveformCache.defaultMaximumEntries) {
        self.directory = directory.standardizedFileURL
        self.maximumEntries = max(1, maximumEntries)
    }

    static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func fileURL(_ sha256: String) -> URL { directory.appendingPathComponent(sha256 + ".json", isDirectory: false) }

    /// The cached record for exactly these bytes, or nil when absent/invalid.
    func record(forSHA256 sha256: String, byteCount: Int) -> StudioWaveformRecord? {
        guard Self.isDigest(sha256) else { return nil }
        lock.lock(); defer { lock.unlock() }
        let url = fileURL(sha256)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= Self.maximumRecordBytes,
              let data = try? Data(contentsOf: url), data.count == size,
              let record = try? JSONDecoder().decode(StudioWaveformRecord.self, from: data),
              record.sha256 == sha256, record.byteCount == byteCount,
              (try? record.validate()) != nil else {
            // A damaged file for this digest is removed so the next analysis can replace it.
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        // Touch for least-recently-used eviction; failure to touch is harmless.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return record
    }

    /// Persist a validated record atomically and evict the oldest entries.
    func store(_ record: StudioWaveformRecord) throws {
        try record.validate()
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maximumRecordBytes else { throw StudioWaveformRecord.Failure.invalid }
        try data.write(to: fileURL(record.sha256), options: .atomic)
        try evictIfNeeded()
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
    }

    var entryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return (try? entries().count) ?? 0
    }

    private func entries() throws -> [(url: URL, modified: Date)] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles])
        return urls.compactMap { url in
            guard url.pathExtension == "json", Self.isDigest(url.deletingPathExtension().lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
    }
    private func evictIfNeeded() throws {
        var current = try entries()
        guard current.count > maximumEntries else { return }
        current.sort { $0.modified < $1.modified }
        for entry in current.prefix(current.count - maximumEntries) {
            try FileManager.default.removeItem(at: entry.url)
        }
    }
}
