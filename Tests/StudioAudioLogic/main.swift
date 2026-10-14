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

        // 7. Transport seconds <-> ticks survive the binary floating-point round trip (#180).
        do {
            typealias T = StudioAudioTransport
            var naiveMisses = 0
            for fps in [1, 8, 12, 15, 23, 24, 25, 29, 30, 48, 50, 59, 60, 120] {
                let total = 216_000
                for tick in 0..<total {
                    let seconds = T.seconds(atTick: tick, fps: fps)
                    if Int((seconds * Double(fps)).rounded(.down)) != tick { naiveMisses += 1 }
                    guard T.tick(atSeconds: seconds, fps: fps, totalTicks: total) == tick else {
                        throw TestFailure(message: "Boundary tick \(tick) at \(fps) FPS mapped to another tick")
                    }
                    if tick > 0, T.tick(atSeconds: seconds - 1.0 / 48_000, fps: fps, totalTicks: total) != tick - 1 {
                        throw TestFailure(message: "One sample before tick \(tick) at \(fps) FPS did not stay in the previous tick")
                    }
                    if T.tick(atSeconds: (Double(tick) + 0.5) / Double(fps), fps: fps, totalTicks: total) != tick {
                        throw TestFailure(message: "Mid-tick time left tick \(tick) at \(fps) FPS")
                    }
                    let safe = T.floorSafeSeconds(seconds, fps: fps)
                    if Int((safe * Double(fps)).rounded(.down)) != tick || safe < seconds || safe - seconds > 1e-9 {
                        throw TestFailure(message: "Floor-safe time for tick \(tick) at \(fps) FPS is wrong or moved too far")
                    }
                }
            }
            try require(naiveMisses > 0, "The floor-only conversion is expected to miss some boundaries (e.g. tick 123 at 15 FPS)")
            try require(Int((T.seconds(atTick: 123, fps: 15) * 15).rounded(.down)) == 122
                        && T.tick(atSeconds: T.seconds(atTick: 123, fps: 15), fps: 15, totalTicks: 1000) == 123,
                        "Known 15 FPS boundary is corrected")
            try require(T.tick(atSeconds: 1e9, fps: 24, totalTicks: 48) == 48 && T.tick(atSeconds: -1, fps: 24, totalTicks: 48) == 0
                        && T.tick(atSeconds: .nan, fps: 24, totalTicks: 48) == 0 && T.tick(atSeconds: 1, fps: 0, totalTicks: 48) == 0,
                        "Out-of-range and invalid times clamp instead of inventing ticks")
            pass("transport seconds and ticks round-trip at every frame boundary for 14 frame rates over 216000 ticks (floor-only misses \(naiveMisses))")
        }

        // 8. Frame clock agrees with the linear exposure walk for every tick.
        do {
            let holds = [1, 2, 3, 6, 1, 12, 24, 1, 1, 60, 5, 7]
            guard let clock = StudioAudioTransport.FrameClock(fps: 24, frameTicks: holds) else { throw TestFailure(message: "Valid clock rejected") }
            func linear(_ tick: Int) -> Int {
                var remaining = max(0, tick)
                for (index, ticks) in holds.enumerated() {
                    if remaining < ticks { return index }
                    remaining -= ticks
                }
                return holds.count - 1
            }
            try require(clock.totalTicks == holds.reduce(0, +) && clock.frameCount == holds.count, "Totals")
            for tick in -2...(clock.totalTicks + 3) {
                try require(clock.frameIndex(atTick: tick) == linear(tick), "Frame clock disagrees at tick \(tick)")
            }
            for index in holds.indices {
                try require(clock.frameIndex(atSeconds: clock.startSeconds(ofFrame: index)) == index, "Frame \(index) start resolves to another frame")
            }
            try require(StudioAudioTransport.FrameClock(fps: 24, frameTicks: []) == nil && StudioAudioTransport.FrameClock(fps: 0, frameTicks: [1]) == nil
                        && StudioAudioTransport.FrameClock(fps: 24, frameTicks: [1, 0]) == nil, "Invalid clocks are refused")
            pass("frame clock binary search matches the canonical exposure walk and every frame start")
        }

        // 9. Audio-clock drift stays bounded over long playback; loops and seeks
        // re-anchor, clock skew is corrected in bounded steps and a stuck output is reported.
        do {
            let bound = StudioAudioDriftMonitor.bound(fps: 24)
            try require(abs(bound - 1.0 / 24) < 1e-12 && StudioAudioDriftMonitor.bound(fps: 1) == 1.0 / 12
                        && StudioAudioDriftMonitor.bound(fps: 240) == 1.0 / 120, "Bound is one frame clamped to 1/120...1/12 s")
            let clock = StudioAudioTransport.FrameClock(fps: 24, frameTicks: Array(repeating: 1, count: 24 * 1200))
            // 20 minutes at a 60 Hz display clock, player position quantized to 10 ms output buffers.
            var long = StudioAudioDriftMonitor(bound: bound, frameClock: clock)
            for step in 0..<72_000 {
                let host = Double(step) / 60
                long.observe(host: host, player: (host * 100).rounded(.down) / 100)
            }
            try require(long.report.samples == 71_999 && long.report.driftCorrections == 0 && long.report.discontinuities == 0
                        && !long.report.stalled && long.report.maximumDrift <= 0.010_001 && long.report.maximumFrameError <= 1,
                        "Long playback drift: \(long.report)")
            // A loop every 7 s re-anchors without counting as drift.
            var loops = StudioAudioDriftMonitor(bound: bound)
            for step in 0..<3600 {
                let host = Double(step) / 60
                loops.observe(host: host, player: host.truncatingRemainder(dividingBy: 7))
            }
            try require(loops.report.discontinuities == 8 && loops.report.driftCorrections == 0 && !loops.report.stalled, "Loops: \(loops.report)")
            // 0.1% clock skew over ten minutes is corrected in bounded steps.
            var skew = StudioAudioDriftMonitor(bound: bound)
            for step in 0..<36_000 {
                let host = Double(step) / 60
                skew.observe(host: host, player: host * 1.001)
            }
            try require((13...15).contains(skew.report.driftCorrections) && skew.report.maximumDrift < bound + 0.000_1, "Skew: \(skew.report)")
            // A player that claims to play but stops advancing is a stall within one second.
            var stuck = StudioAudioDriftMonitor(bound: bound)
            var stalledAt: Double?
            for step in 0..<480 {
                let host = Double(step) / 60
                if stuck.observe(host: host, player: min(host, 5)) == .stalled { stalledAt = host; break }
            }
            try require(stalledAt.map { (6.0...6.02).contains($0) } == true && stuck.report.stalled, "Stall not reported: \(String(describing: stalledAt))")
            stuck.reset()
            try require(stuck.report == StudioAudioDriftMonitor.Report() && stuck.observe(host: 0, player: 0) == .anchored, "Reset")
            pass("audio-clock drift stays within one frame over 20 minutes; loops, skew corrections and stalls are measured")
        }

        // 10. Audible scrub requests coalesce to the newest position and never leave the timeline.
        do {
            var planner = StudioAudioScrubPlanner()
            guard case .start(let first) = planner.request(time: 1, timelineDuration: 10) else { throw TestFailure(message: "First scrub did not start") }
            try require(first.start == 1 && abs(first.end - 1.15) < 1e-9 && planner.inFlight, "Grain range \(first)")
            try require(planner.request(time: 2, timelineDuration: 10) == .queued && planner.request(time: 3, timelineDuration: 10) == .queued
                        && planner.pending == 3, "Requests while preparing keep only the newest")
            guard case .start(let next) = planner.finished(timelineDuration: 10) else { throw TestFailure(message: "Queued scrub did not start") }
            try require(next.start == 3 && planner.pending == nil, "Newest queued position starts next")
            try require(planner.finished(timelineDuration: 10) == .ignored && !planner.inFlight, "Nothing queued")
            guard case .start = planner.request(time: 4, timelineDuration: 10) else { throw TestFailure(message: "Scrub after idle refused") }
            try require(planner.request(time: 5, timelineDuration: 10) == .queued, "Second request queues")
            planner.clearPending()
            try require(planner.inFlight && planner.pending == nil && planner.finished(timelineDuration: 10) == .ignored,
                        "Stopping keeps the in-flight grain accounted for and drops queued positions")
            guard case .start(let tail) = planner.request(time: 9.95, timelineDuration: 10) else { throw TestFailure(message: "Tail scrub refused") }
            try require(tail.end <= 10 && tail.length > 0, "Grain is clipped to the timeline end")
            planner.cancel()
            try require(planner.request(time: 10, timelineDuration: 10) == .ignored && planner.request(time: .nan, timelineDuration: 10) == .ignored
                        && planner.request(time: -0.1, timelineDuration: 10) == .ignored && !planner.inFlight, "Outside positions are ignored")
            try require(StudioAudioScrubPlanner(grainSeconds: 5).grainSeconds == 0.5 && StudioAudioScrubPlanner(grainSeconds: 0).grainSeconds == 0.05, "Grain bounds")
            pass("audible scrub planner coalesces to the newest position inside the timeline")
        }

        print("STUDIO_AUDIO_LOGIC=PASS groups=\(groups)")
    }
    static func require2<T>(_ value: T?) throws -> T {
        guard let value else { throw TestFailure(message: "Unexpected nil") }
        return value
    }
}
