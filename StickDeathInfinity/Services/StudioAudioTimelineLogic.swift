import Foundation

/// Pure timeline arithmetic shared by the audio workspace, the mixed preview and
/// their tests. Everything here is Foundation-only so it runs in the Linux CI
/// job; the SwiftUI/AVFoundation adapters live next to their consumers.

/// Clips on the same numbered track whose time ranges intersect (#177). The
/// mixer sums overlapping clips, so this is an indicator, never an error.
enum StudioAudioClipOverlap {
    struct Span: Equatable {
        let id: String
        let track: Int
        let start: Double
        let end: Double
    }
    /// Two spans overlap when they share more than one 48 kHz sample.
    static let tolerance = 1.0 / 48_000

    static func overlappingIDs(_ spans: [Span]) -> Set<String> {
        var result = Set<String>()
        let byTrack = Dictionary(grouping: spans.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }, by: \.track)
        for (_, lane) in byTrack {
            let sorted = lane.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
            var open: [Span] = []
            for span in sorted {
                open.removeAll { $0.end <= span.start + tolerance }
                if !open.isEmpty {
                    result.insert(span.id)
                    for other in open { result.insert(other.id) }
                }
                open.append(span)
            }
        }
        return result
    }
}

/// Mixed-preview playback beyond the 120-second mix limit (#180): the player
/// renders the window that starts at the playhead and reports timeline times.
enum StudioAudioPreviewWindow {
    static let limitSeconds = 120.0
    static let sampleRate = 48_000.0

    struct Range: Equatable {
        let start: Double
        let end: Double
        var length: Double { end - start }
    }
    struct Span: Equatable {
        var start: Double
        var duration: Double
        var sourceOffset: Double
    }

    /// Sample-aligned window beginning at `playhead`. Nil when the timeline is
    /// empty or the playhead is outside it.
    static func range(playhead: Double, timelineDuration: Double, limit: Double = limitSeconds) -> Range? {
        guard playhead.isFinite, timelineDuration.isFinite, timelineDuration > 0, limit.isFinite, limit > 0,
              playhead >= 0, playhead < timelineDuration else { return nil }
        let start = (playhead * sampleRate).rounded(.down) / sampleRate
        let end = min((timelineDuration * sampleRate).rounded(.up) / sampleRate, start + limit)
        guard end > start else { return nil }
        return Range(start: start, end: end)
    }
    /// Whether the whole timeline fits one mix without windowing.
    static func needsWindow(timelineDuration: Double, limit: Double = limitSeconds) -> Bool {
        timelineDuration.isFinite && timelineDuration > limit
    }

    /// The part of `span` inside `range`, re-based so the window starts at 0.
    /// Source offsets advance by the trimmed head so audio keeps its alignment;
    /// spans outside the window, or with less than one sample left, are nil.
    static func clipped(_ span: Span, to range: Range) -> Span? {
        guard span.start.isFinite, span.duration.isFinite, span.sourceOffset.isFinite, span.duration > 0 else { return nil }
        let end = span.start + span.duration
        let first = max(span.start, range.start), last = min(end, range.end)
        guard last - first >= 1 / sampleRate else { return nil }
        let head = first - span.start
        return Span(start: first - range.start, duration: last - first, sourceOffset: span.sourceOffset + head)
    }
    /// Timeline time of a player position inside the window.
    static func timelineTime(playerTime: Double, range: Range) -> Double {
        min(range.end, max(range.start, range.start + max(0, playerTime)))
    }
}

/// Device-local memory of the selected audio clip per project (#177). It stores
/// identifiers only: a clip that no longer exists is simply not restored.
struct StudioAudioSelectionMemory {
    static let maximumProjects = 64
    private let defaults: UserDefaults
    private let key = "studio.audio.selected-clip.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private struct Entry: Codable, Equatable { let project: String; let clip: String }
    private var entries: [Entry] {
        guard let data = defaults.data(forKey: key), data.count <= 32_768,
              let stored = try? JSONDecoder().decode([Entry].self, from: data), stored.count <= Self.maximumProjects else { return [] }
        return stored.filter { $0.clip.count <= 128 && $0.project.count <= 64 }
    }
    func selectedClipID(for projectID: UUID) -> String? {
        entries.last { $0.project == projectID.uuidString }?.clip
    }
    /// Remember `clipID` for the project; nil forgets the project's selection.
    func remember(_ clipID: String?, for projectID: UUID) {
        var next = entries.filter { $0.project != projectID.uuidString }
        if let clipID, !clipID.isEmpty, clipID.count <= 128 { next.append(Entry(project: projectID.uuidString, clip: clipID)) }
        if next.count > Self.maximumProjects { next.removeFirst(next.count - Self.maximumProjects) }
        if next.isEmpty { defaults.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) }
    }
}

/// Canonical conversion between transport seconds and project ticks (#180).
/// `Double(tick) / fps * fps` is not always `tick` in binary floating point
/// (for example tick 123 at 15 FPS gives 122.99999999999999), so a plain
/// `floor` showed the previous frame at an exact frame boundary after a seek or
/// a stop. A boundary tolerance far below one audio sample removes that error
/// without moving any real time into the next frame.
enum StudioAudioTransport {
    /// One millionth of a tick: about 42 ns at 24 FPS, under 1/500 of a 48 kHz sample.
    static let boundaryToleranceTicks = 0.000_001

    static func seconds(atTick tick: Int, fps: Int) -> Double {
        guard fps > 0 else { return 0 }
        return Double(max(0, tick)) / Double(fps)
    }
    /// Tick that is sounding at `seconds`, clamped to `0...totalTicks`.
    static func tick(atSeconds seconds: Double, fps: Int, totalTicks: Int) -> Int {
        guard fps > 0, totalTicks > 0, seconds.isFinite, seconds > 0 else { return 0 }
        let raw = (seconds * Double(fps) + boundaryToleranceTicks).rounded(.down)
        guard raw.isFinite else { return 0 }
        return Int(min(Double(totalTicks), max(0, raw)))
    }

    /// The nearest time at or after `seconds` that a floor-only conversion
    /// (`Int(seconds * fps)` rounded down, as `StudioViewModel.displayAudioPlaybackTime`
    /// uses) maps to the same tick as `tick(atSeconds:)`. It moves a boundary
    /// time by at most a few ULPs (nanoseconds) and leaves every other time unchanged.
    static func floorSafeSeconds(_ seconds: Double, fps: Int) -> Double {
        guard fps > 0, seconds.isFinite, seconds > 0 else { return seconds }
        var value = seconds
        let target = (seconds * Double(fps) + boundaryToleranceTicks).rounded(.down)
        var steps = 0
        while (value * Double(fps)).rounded(.down) < target, steps < 16 {
            value = value.nextUp; steps += 1
        }
        return value
    }

    /// Frame lookup over cumulative exposure holds. `frameIndex` is a binary
    /// search, so a 60 Hz transport clock costs O(log frames) per update.
    struct FrameClock: Equatable {
        let fps: Int
        /// startTicks[i] is the first tick of frame i; the last entry is the total.
        let startTicks: [Int]
        var totalTicks: Int { startTicks.last ?? 0 }
        var frameCount: Int { startTicks.count - 1 }

        init?(fps: Int, frameTicks: [Int]) {
            guard (1...240).contains(fps), !frameTicks.isEmpty, frameTicks.count <= 100_000,
                  frameTicks.allSatisfy({ $0 > 0 && $0 <= 100_000 }) else { return nil }
            var starts = [0]
            starts.reserveCapacity(frameTicks.count + 1)
            for ticks in frameTicks { starts.append(starts[starts.count - 1] + ticks) }
            self.fps = fps; startTicks = starts
        }
        /// Index of the frame whose exposure contains `tick`; ticks at or past
        /// the end resolve to the last frame, matching `StudioDocument.frameIndex(atTick:)`.
        func frameIndex(atTick tick: Int) -> Int {
            guard tick > 0 else { return 0 }
            guard tick < totalTicks else { return frameCount - 1 }
            var low = 0, high = frameCount - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if startTicks[middle] <= tick { low = middle } else { high = middle - 1 }
            }
            return low
        }
        func frameIndex(atSeconds seconds: Double) -> Int {
            frameIndex(atTick: StudioAudioTransport.tick(atSeconds: seconds, fps: fps, totalTicks: totalTicks))
        }
        func startSeconds(ofFrame index: Int) -> Double {
            StudioAudioTransport.seconds(atTick: startTicks[max(0, min(index, frameCount))], fps: fps)
        }
    }
}

/// Measures how far the audio clock (the actual player position) moves away
/// from the monotonic host clock while the animation follows it (#180). The
/// animation is driven by the audio clock, so a measured drift means either the
/// output stalled, a seek/loop occurred, or the device clock skewed. A seek or
/// loop re-anchors; a drift beyond `bound` re-anchors and is counted; a player
/// that stops advancing for `stallLimit` while it claims to play is a stall.
struct StudioAudioDriftMonitor: Equatable {
    struct Report: Equatable {
        var samples = 0
        /// Largest absolute audio-minus-host drift seen before any re-anchor.
        var maximumDrift = 0.0
        var meanAbsoluteDrift = 0.0
        /// Re-anchors after drift beyond the bound (not seeks or loops).
        var driftCorrections = 0
        /// Re-anchors after a backwards jump: loop wrap or seek.
        var discontinuities = 0
        /// Largest difference in displayed frame between the audio clock and
        /// the host-clock expectation, using the project frame clock.
        var maximumFrameError = 0
        var stalled = false
    }
    enum Observation: Equatable { case anchored, tracking(drift: Double), corrected(drift: Double), discontinuity, stalled }

    /// Default bound: one project frame, clamped to 1/120…1/12 s.
    static func bound(fps: Int) -> Double { min(1.0 / 12, max(1.0 / 120, 1.0 / Double(max(1, fps)))) }

    let bound: Double
    let stallLimit: Double
    let frameClock: StudioAudioTransport.FrameClock?
    private(set) var report = Report()
    private var anchorHost: Double?
    private var anchorPlayer = 0.0
    private var lastPlayer = 0.0
    private var lastAdvanceHost = 0.0
    private var driftTotal = 0.0

    init(bound: Double = 1.0 / 24, stallLimit: Double = 1, frameClock: StudioAudioTransport.FrameClock? = nil) {
        self.bound = bound.isFinite && bound > 0 ? bound : 1.0 / 24
        self.stallLimit = stallLimit.isFinite && stallLimit > 0 ? stallLimit : 1
        self.frameClock = frameClock
    }
    mutating func reset() {
        report = Report(); anchorHost = nil; driftTotal = 0
    }
    @discardableResult
    mutating func observe(host: Double, player: Double, rate: Double = 1) -> Observation {
        guard host.isFinite, player.isFinite, rate.isFinite, rate > 0 else { return .stalled }
        guard let anchor = anchorHost else { return reanchor(host: host, player: player, result: .anchored) }
        // Backwards jumps (loop wrap or explicit seek) larger than one sample
        // re-anchor without counting as drift.
        if player < lastPlayer - 1.0 / 48_000 {
            report.discontinuities += 1
            return reanchor(host: host, player: player, result: .discontinuity)
        }
        if player > lastPlayer + 0.000_001 { lastAdvanceHost = host }
        lastPlayer = player
        if host - lastAdvanceHost >= stallLimit {
            report.stalled = true
            return .stalled
        }
        let expected = anchorPlayer + (host - anchor) * rate
        let drift = player - expected
        report.samples += 1
        driftTotal += abs(drift)
        report.meanAbsoluteDrift = driftTotal / Double(report.samples)
        report.maximumDrift = max(report.maximumDrift, abs(drift))
        if let clock = frameClock {
            let error = abs(clock.frameIndex(atSeconds: player) - clock.frameIndex(atSeconds: max(0, expected)))
            report.maximumFrameError = max(report.maximumFrameError, error)
        }
        if abs(drift) > bound {
            report.driftCorrections += 1
            // A correction keeps the last-advance time: a stuck player that keeps
            // exceeding the bound must still reach the stall limit.
            return reanchor(host: host, player: player, result: .corrected(drift: drift), keepsAdvance: true)
        }
        return .tracking(drift: drift)
    }
    private mutating func reanchor(host: Double, player: Double, result: Observation, keepsAdvance: Bool = false) -> Observation {
        anchorHost = host; anchorPlayer = player; lastPlayer = player
        if !keepsAdvance { lastAdvanceHost = host }
        return result
    }
}

/// Coalesces audible-scrub requests (#180). At most one short grain is being
/// prepared at a time; requests that arrive meanwhile keep only the newest
/// position, which starts when the current grain is ready. Positions outside
/// the timeline are ignored instead of clamped into invented audio.
struct StudioAudioScrubPlanner: Equatable {
    static let defaultGrainSeconds = 0.15
    let grainSeconds: Double
    private(set) var inFlight = false
    private(set) var pending: Double?

    init(grainSeconds: Double = defaultGrainSeconds) {
        self.grainSeconds = grainSeconds.isFinite ? min(0.5, max(0.05, grainSeconds)) : Self.defaultGrainSeconds
    }
    enum Decision: Equatable { case start(StudioAudioPreviewWindow.Range), queued, ignored }

    mutating func request(time: Double, timelineDuration: Double) -> Decision {
        guard StudioAudioPreviewWindow.range(playhead: time, timelineDuration: timelineDuration, limit: grainSeconds) != nil else {
            return .ignored
        }
        if inFlight { pending = time; return .queued }
        return begin(time, timelineDuration: timelineDuration)
    }
    /// The current grain finished preparing (or failed); start the newest queued one.
    mutating func finished(timelineDuration: Double) -> Decision {
        inFlight = false
        guard let next = pending else { return .ignored }
        pending = nil
        return begin(next, timelineDuration: timelineDuration)
    }
    mutating func cancel() { inFlight = false; pending = nil }
    /// Forget queued positions but keep the in-flight grain accounted for, so a
    /// cancelled preparation still finishes before another grain may start.
    mutating func clearPending() { pending = nil }
    private mutating func begin(_ time: Double, timelineDuration: Double) -> Decision {
        guard let range = StudioAudioPreviewWindow.range(playhead: time, timelineDuration: timelineDuration, limit: grainSeconds) else {
            return .ignored
        }
        inFlight = true
        return .start(range)
    }
}
