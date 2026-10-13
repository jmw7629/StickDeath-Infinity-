import Foundation

// Foundation-only production logic for the audio workspace and media exports:
// measured peak/RMS waveform bins, the persistent digest-keyed waveform cache,
// same-track clip overlap, the 120-second preview window and library sound
// credits. Compiles and runs on the Linux CI job; no stand-in types are used.

struct TestFailure: Error { let message: String }
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(message: message) }
}
func near(_ a: Float, _ b: Float, _ tolerance: Float = 0.01) -> Bool { abs(a - b) <= tolerance }

@main struct StudioAudioLogicTests {
    static var groups = 0
    static func pass(_ name: String) { groups += 1; print("PASS " + name) }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-audio-logic-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let digestA = String(repeating: "a", count: 64), digestB = String(repeating: "b", count: 64), digestC = String(repeating: "c", count: 64)

        // 1. Accumulator: a full-scale sine has peak 1 and RMS 1/sqrt(2); silence stays zero.
        do {
            let frames: Int64 = 48_000
            var accumulator = StudioWaveformAccumulator(totalFrames: frames, channels: 2)
            for frame in 0..<frames {
                let phase = Double(frame) * 2 * Double.pi * 512 / 48_000 // exactly two cycles per 187.5-frame bin
                let value = Float(sin(phase))
                accumulator.add(frame: frame, samples: frame < frames / 2 ? [value, value] : [0, 0])
            }
            let peaks = accumulator.peaks, rms = accumulator.rms
            try require(peaks.count == 256 && rms.count == 256, "Bin counts")
            try require(peaks[0...127].allSatisfy { near($0, 1, 0.02) }, "Sine peaks are full scale")
            try require(rms[0...127].allSatisfy { near($0, 0.7071, 0.02) }, "Sine RMS is 1/sqrt(2): \(rms[0])")
            try require(peaks[128...255].allSatisfy { $0 == 0 } && rms[128...255].allSatisfy { $0 == 0 }, "Silent half is exactly zero")
            try require(zip(peaks, rms).allSatisfy { $0.1 <= $0.0 + 0.000001 }, "RMS never exceeds peak")
            try require(!accumulator.clipped, "Full-scale sine is not clipped")
            var hot = StudioWaveformAccumulator(totalFrames: 4, channels: 1)
            hot.add(frame: 0, samples: [1.5]); hot.add(frame: 9, samples: [1])
            try require(hot.clipped && hot.peaks[0] == 1 && hot.rms[0] <= 1, "Over-range sample flags clipping and caps display at 1; out-of-range frame ignored")
            pass("waveform accumulator measures peak and RMS per bin from actual samples")
        }

        // 2. Record validation and the persistent cache round trip.
        let cache = StudioWaveformCache(directory: root.appendingPathComponent("waveforms"), maximumEntries: 3)
        func record(_ digest: String, bytes: Int = 1234, duration: Double = 1.5) -> StudioWaveformRecord {
            StudioWaveformRecord(sha256: digest, byteCount: bytes, duration: duration, sampleRate: 48_000, channels: 2,
                                 peaks: Array(repeating: 0.5, count: 256), rms: Array(repeating: 0.25, count: 256), clipped: false)
        }
        do {
            try record(digestA).validate()
            let good = record(digestA)
            try require(cache.record(forSHA256: digestA, byteCount: 1234) == nil, "Empty cache returns nil")
            try cache.store(good)
            try require(cache.record(forSHA256: digestA, byteCount: 1234) == good, "Stored record reads back")
            try require(cache.record(forSHA256: digestA, byteCount: 1235) == nil, "Byte count mismatch is a miss")
            try require(cache.record(forSHA256: "not-a-digest", byteCount: 1234) == nil, "Invalid digest key is a miss")
            var bad = record(digestB); bad = StudioWaveformRecord(sha256: digestB, byteCount: 10, duration: 1, sampleRate: 48_000, channels: 2,
                peaks: Array(repeating: 0.1, count: 256), rms: Array(repeating: 0.5, count: 256), clipped: false)
            do { try bad.validate(); throw TestFailure(message: "RMS above peak accepted") } catch StudioWaveformRecord.Failure.invalid {}
            do { try cache.store(bad); throw TestFailure(message: "Invalid record stored") } catch StudioWaveformRecord.Failure.invalid {}
            do { try StudioWaveformRecord(sha256: digestB, byteCount: 10, duration: 1, sampleRate: 48_000, channels: 2,
                peaks: Array(repeating: 0.1, count: 255), rms: Array(repeating: 0.1, count: 255), clipped: false).validate()
                throw TestFailure(message: "Wrong bin count accepted") } catch StudioWaveformRecord.Failure.invalid {}
            // A damaged file is a miss and is removed; a foreign-named file is ignored.
            let damaged = cache.directory.appendingPathComponent(digestB + ".json")
            try Data("{not json".utf8).write(to: damaged)
            try require(cache.record(forSHA256: digestB, byteCount: 10) == nil, "Damaged record is a miss")
            try require(!FileManager.default.fileExists(atPath: damaged.path), "Damaged record removed")
            // A record whose body digest disagrees with its filename is a miss.
            try JSONEncoder().encode(record(digestA)).write(to: cache.directory.appendingPathComponent(digestC + ".json"))
            try require(cache.record(forSHA256: digestC, byteCount: 1234) == nil, "Digest/filename disagreement is a miss")
            pass("persistent waveform cache validates digest byte count bins and damaged files")
        }
        do {
            // Eviction keeps the newest `maximumEntries` by modification date.
            let old = Date(timeIntervalSinceNow: -3600)
            for (index, digest) in ["1", "2", "3", "4"].enumerated() {
                let key = String(repeating: digest, count: 64)
                try cache.store(record(key))
                try FileManager.default.setAttributes([.modificationDate: old.addingTimeInterval(Double(index))], ofItemAtPath: cache.directory.appendingPathComponent(key + ".json").path)
            }
            try cache.store(record(String(repeating: "5", count: 64)))
            try require(cache.entryCount == 3, "Cache bounded to 3 entries: \(cache.entryCount)")
            try require(cache.record(forSHA256: String(repeating: "1", count: 64), byteCount: 1234) == nil, "Oldest evicted")
            try require(cache.record(forSHA256: String(repeating: "5", count: 64), byteCount: 1234) != nil, "Newest kept")
            cache.removeAll()
            try require(cache.entryCount == 0, "removeAll clears")
            pass("waveform cache evicts the oldest entries and clears completely")
        }

        // 3. Overlap indicator.
        do {
            typealias Span = StudioAudioClipOverlap.Span
            let spans = [Span(id: "a", track: 1, start: 0, end: 1), Span(id: "b", track: 1, start: 0.5, end: 1.5),
                         Span(id: "c", track: 1, start: 1.5, end: 2), Span(id: "d", track: 2, start: 0.2, end: 0.8),
                         Span(id: "e", track: 3, start: 0, end: 1), Span(id: "f", track: 3, start: 1, end: 2),
                         Span(id: "g", track: 4, start: 0, end: 1), Span(id: "h", track: 4, start: 0.2, end: 0.3), Span(id: "i", track: 4, start: 0.9, end: 1.1)]
            let overlapping = StudioAudioClipOverlap.overlappingIDs(spans)
            try require(overlapping == ["a", "b", "g", "h", "i"], "Overlap set: \(overlapping.sorted())")
            try require(StudioAudioClipOverlap.overlappingIDs([]).isEmpty, "Empty")
            try require(StudioAudioClipOverlap.overlappingIDs([Span(id: "x", track: 1, start: 0, end: 1), Span(id: "y", track: 1, start: 1 + 1.0 / 96_000, end: 2)]).isEmpty, "Half-sample gap is not an overlap")
            try require(StudioAudioClipOverlap.overlappingIDs([Span(id: "x", track: 1, start: 0, end: .nan), Span(id: "y", track: 1, start: 0, end: 1)]).isEmpty, "Invalid span ignored")
            pass("same-track clip overlap detection ignores touching edges other tracks and invalid spans")
        }

        // 4. Preview window from the playhead.
        do {
            typealias W = StudioAudioPreviewWindow
            try require(!W.needsWindow(timelineDuration: 120) && W.needsWindow(timelineDuration: 120.001), "Window needed only beyond 120 s")
            try require(W.range(playhead: 0, timelineDuration: 0) == nil && W.range(playhead: 300, timelineDuration: 300) == nil && W.range(playhead: -1, timelineDuration: 10) == nil, "Invalid playheads")
            let full = try require2(W.range(playhead: 0, timelineDuration: 300))
            try require(full.start == 0 && full.end == 120 && full.length == 120, "Window from 0: \(full)")
            let late = try require2(W.range(playhead: 250.3, timelineDuration: 300))
            try require(abs(late.start - 250.3) < 1.0 / 48_000 && late.end == 300, "Window near the end is shortened: \(late)")
            try require((late.start * 48_000).rounded() == late.start * 48_000, "Window start is sample aligned")
            let mid = try require2(W.range(playhead: 100.123456789, timelineDuration: 400))
            try require(abs(mid.length - 120) < 1.0 / 48_000, "Mid window length: \(mid.length)")
            // Clipping spans to the window re-bases time and advances source offsets.
            let range = W.Range(start: 100, end: 220)
            try require(W.clipped(.init(start: 10, duration: 20, sourceOffset: 1), to: range) == nil, "Span before window dropped")
            try require(W.clipped(.init(start: 230, duration: 20, sourceOffset: 1), to: range) == nil, "Span after window dropped")
            try require(W.clipped(.init(start: 90, duration: 20, sourceOffset: 1), to: range) == .init(start: 0, duration: 10, sourceOffset: 11), "Head trimmed, source advanced")
            try require(W.clipped(.init(start: 210, duration: 20, sourceOffset: 0), to: range) == .init(start: 110, duration: 10, sourceOffset: 0), "Tail trimmed")
            try require(W.clipped(.init(start: 150, duration: 5, sourceOffset: 2), to: range) == .init(start: 50, duration: 5, sourceOffset: 2), "Inside span re-based only")
            try require(W.clipped(.init(start: 50, duration: 200, sourceOffset: 0), to: range) == .init(start: 0, duration: 120, sourceOffset: 50), "Span covering the window is cut to it")
            try require(W.clipped(.init(start: 100 - 1.0 / 96_000, duration: 1.0 / 96_000 + 0.000001, sourceOffset: 0), to: range) == nil, "Less than one sample inside is dropped")
            try require(W.timelineTime(playerTime: 12.5, range: range) == 112.5 && W.timelineTime(playerTime: 500, range: range) == 220 && W.timelineTime(playerTime: -1, range: range) == 100, "Timeline time mapping clamps to the window")
            pass("120-second preview window is sample aligned and clips spans without inventing audio")
        }

        // 5. Selection memory.
        do {
            let suite = "sdi-audio-logic-" + UUID().uuidString
            let defaults = try require2(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let memory = StudioAudioSelectionMemory(defaults: defaults)
            let project = UUID(), other = UUID()
            try require(memory.selectedClipID(for: project) == nil, "Nothing remembered")
            memory.remember("clip-1", for: project)
            memory.remember("clip-9", for: other)
            try require(memory.selectedClipID(for: project) == "clip-1" && memory.selectedClipID(for: other) == "clip-9", "Per-project memory")
            memory.remember("clip-2", for: project)
            try require(memory.selectedClipID(for: project) == "clip-2", "Replaced")
            memory.remember(nil, for: project)
            try require(memory.selectedClipID(for: project) == nil && memory.selectedClipID(for: other) == "clip-9", "Forget one project only")
            for _ in 0..<80 { memory.remember("c", for: UUID()) }
            try require(memory.selectedClipID(for: other) == nil, "Oldest projects fall out of the bounded list")
            memory.remember(String(repeating: "x", count: 129), for: project)
            try require(memory.selectedClipID(for: project) == nil, "Oversized identifiers are not stored")
            pass("selected audio clip memory is per project bounded and forgets on request")
        }

        // 6. Sound credits resolved by digest.
        do {
            let kenney = StudioSoundAttribution(title: "Card Fan 1", author: "Kenney", sourceURL: "https://kenney.nl/assets/casino-audio",
                license: "CC0-1.0", licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/", catalogueSoundID: digestA, originalSHA256: digestB)
            let table = [digestA: kenney]
            let imported = UUID(), library = UUID()
            let credits = try StudioSoundCreditResolver.credits(for: [.init(id: imported, sha256: digestC), .init(id: library, sha256: digestA)]) { table[$0] }
            try require(credits.count == 1 && credits[0].assetID == library && credits[0].title == "Card Fan 1" && credits[0].catalogueSoundID == digestA, "Only the library asset is credited")
            try require(credits[0].summary == "Card Fan 1 — Kenney (CC0-1.0)", "Summary line")
            let encoded = try JSONEncoder().encode(credits)
            try require(try JSONDecoder().decode([StudioSoundCredit].self, from: encoded) == credits, "Credits round-trip as JSON")
            // A lookup that returns a record for a different file is refused.
            do { _ = try StudioSoundCreditResolver.credits(for: [.init(id: library, sha256: digestB)]) { _ in kenney }; throw TestFailure(message: "Mismatched digest accepted") }
            catch StudioSoundCredit.Failure.invalid {}
            // Untrusted license or host fails validation.
            let foreign = StudioSoundAttribution(title: "x", author: "y", sourceURL: "https://example.invalid/a", license: "CC0-1.0",
                licenseURL: kenney.licenseURL, catalogueSoundID: digestA, originalSHA256: digestB)
            do { _ = try StudioSoundCreditResolver.credits(for: [.init(id: library, sha256: digestA)]) { _ in foreign }; throw TestFailure(message: "Foreign host accepted") }
            catch StudioSoundCredit.Failure.invalid {}
            let wrongLicense = StudioSoundAttribution(title: "x", author: "y", sourceURL: kenney.sourceURL, license: "CC-BY-4.0",
                licenseURL: kenney.licenseURL, catalogueSoundID: digestA, originalSHA256: digestB)
            do { try StudioSoundCredit(assetID: library, attribution: wrongLicense).validate(); throw TestFailure(message: "Non-CC0 accepted") }
            catch StudioSoundCredit.Failure.invalid {}
            do { _ = try StudioSoundCreditResolver.credits(for: [.init(id: library, sha256: digestA), .init(id: library, sha256: digestA)]) { table[$0] }; throw TestFailure(message: "Duplicate asset accepted") }
            catch StudioSoundCredit.Failure.invalid {}
            pass("library sound credits resolve by digest and refuse mismatched or untrusted attribution")
        }

        print("STUDIO_AUDIO_LOGIC=PASS groups=\(groups)")
    }
    static func require2<T>(_ value: T?) throws -> T {
        guard let value else { throw TestFailure(message: "Unexpected nil") }
        return value
    }
}
