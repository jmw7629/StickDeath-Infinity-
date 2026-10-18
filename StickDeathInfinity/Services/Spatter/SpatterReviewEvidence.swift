import Foundation

// MARK: - Measured review evidence for Spatter renders (#213, #214)
//
// Production uses of SpatterQualityReport: the brief-scope report shown on a
// Spatter brief receipt, and the JSON record attached to a draft submission
// (`p_quality` in backend/sql/spatter-draft-jobs.sql, `RenderResult.quality` in
// backend/spatter/draft_queue.py). Findings are measured, never estimated, and
// a passing record never replaces the owner's approval of the exact render.

extension SpatterQualityReport {
    /// Measures only the frames and layers a brief created. The project around
    /// them may legitimately hold a blank starting frame or deliberate stills;
    /// those belong to the creator, not to the generated sequence.
    /// Returns nil when none of the created frames remain in the document.
    static func briefScope(_ document: StudioDocument, createdFrameIDs: [String], createdLayerIDs: [String],
                           requestedTicks: Int?, movie: MovieMeasurement? = nil,
                           thresholds: Thresholds = .init()) -> SpatterQualityReport? {
        let ids = Set(createdFrameIDs)
        var scoped = document
        scoped.frames = document.frames.filter { ids.contains($0.id) }
        guard !scoped.frames.isEmpty else { return nil }
        let layers = Set(createdLayerIDs).intersection(document.layers.map(\.id))
        return analyze(scoped, requestedTicks: requestedTicks, generatedLayerIDs: layers,
                       limbVarianceTolerance: thresholds.limbVarianceTolerance, movie: movie, thresholds: thresholds)
    }

    /// Wire form of a report: what a reviewer, the draft queue and the admin
    /// review list read. `passes` is the threshold verdict only.
    struct ReviewRecord: Codable, Equatable {
        struct RecordFinding: Codable, Equatable {
            let kind: String
            let frameIndex: Int?
            let detail: String
        }
        struct Movie: Codable, Equatable {
            let decodedFrameCount: Int
            let decodedDurationSeconds: Double
            let expectedFrameCount: Int
            let expectedDurationSeconds: Double
            let audioOffsetSeconds: Double?
        }
        static let schemaName = "spatter_quality_report"
        var schema = ReviewRecord.schemaName
        var version = 1
        let passes: Bool
        let failures: [String]
        let findings: [RecordFinding]
        let unmeasured: [String]
        let frameCount: Int
        let fps: Int
        let actualTicks: Int
        let requestedTicks: Int?
        let movie: Movie?
        let note: String

        /// Sorted-key JSON, bounded like the other review payloads.
        func json() throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(self)
            guard data.count <= 64 * 1024 else { throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "Quality record exceeds 64 KiB.")) }
            return data
        }
    }

    func reviewRecord(movie: MovieMeasurement? = nil, thresholds: Thresholds = .init()) -> ReviewRecord {
        let verdict = verdict(thresholds)
        return ReviewRecord(passes: verdict.passes, failures: verdict.failures,
            findings: findings.map { .init(kind: $0.kind.rawValue, frameIndex: $0.frameIndex, detail: $0.detail) },
            unmeasured: unmeasured, frameCount: frameCount, fps: fps, actualTicks: actualTicks, requestedTicks: requestedTicks,
            movie: movie.map { .init(decodedFrameCount: $0.decodedFrameCount, decodedDurationSeconds: $0.decodedDurationSeconds,
                                     expectedFrameCount: $0.expectedFrameCount, expectedDurationSeconds: $0.expectedDurationSeconds,
                                     audioOffsetSeconds: $0.audioOffsetSeconds) },
            note: Verdict.note)
    }

    /// Short reviewer-facing lines: verdict, counts, failures and what was not measured.
    func summaryLines(_ thresholds: Thresholds = .init()) -> [String] {
        let verdict = verdict(thresholds)
        var lines = [(verdict.passes ? "Quality gates passed" : "Quality gates failed")
            + " for \(frameCount) frame(s), \(actualTicks) tick(s) at \(fps) FPS"
            + (requestedTicks.map { " (requested \($0))" } ?? "") + "."]
        lines.append("Blank \(blankFrameCount) · unintended freezes \(frozenFrameCount) · off-canvas \(outOfCanvasCount).")
        lines.append(contentsOf: verdict.failures)
        if !unmeasured.isEmpty { lines.append("Not measured: " + unmeasured.joined(separator: ", ") + ".") }
        lines.append(Verdict.note)
        return lines
    }
}
