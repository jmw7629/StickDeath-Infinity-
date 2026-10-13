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
