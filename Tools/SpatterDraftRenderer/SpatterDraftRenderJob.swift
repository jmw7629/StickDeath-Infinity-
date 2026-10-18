import Foundation

// Foundation-only half of the headless daily-draft renderer (#212). It decodes
// and bounds a render job, plans the brief with the production deterministic
// planner (`SpatterMultiClauseBrief`) on a fresh Studio document, executes the
// typed request through the production `StudioCommandExecutor` and measures the
// document with `SpatterQualityReport` (review record from SpatterReviewEvidence.swift). Nothing here renders, uploads or
// publishes; `main.swift` performs the macOS export and decode measurement.

struct SpatterDraftRenderJob: Equatable {
    static let maximumJobBytes = 64 * 1024
    static let allowedKeys: Set<String> = ["brief", "fps", "width", "height", "seed", "job_id", "project_name"]
    static let fpsRange = 1...60
    static let dimensionRange = 16...1920

    let brief: String
    let fps: Int
    let width: Int
    let height: Int
    let seed: UInt64?
    let jobID: String?
    let projectName: String

    enum Failure: LocalizedError, Equatable {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let detail): return "Invalid render job: \(detail)" }
        }
    }

    private struct Wire: Decodable {
        enum SeedValue: Decodable {
            case number(UInt64), text(String)
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) { self = .text(text) } else { self = .number(try container.decode(UInt64.self)) }
            }
        }
        let brief: String
        let fps: Int?
        let width: Int?
        let height: Int?
        let seed: SeedValue?
        let job_id: String?
        let project_name: String?
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumJobBytes else { throw Failure.invalid("the job must be 1 byte to 64 KiB of JSON.") }
        guard let object = try? JSONSerialization.jsonObject(with: data), let fields = object as? [String: Any] else {
            throw Failure.invalid("the job must be a JSON object.")
        }
        let unknown = Set(fields.keys).subtracting(allowedKeys)
        guard unknown.isEmpty else { throw Failure.invalid("unknown field(s) \(unknown.sorted().joined(separator: ", ")).") }
        let wire: Wire
        do { wire = try JSONDecoder().decode(Wire.self, from: data) }
        catch { throw Failure.invalid("brief must be text; fps, width and height integers; seed an unsigned integer or decimal string.") }
        let brief = wire.brief
        guard !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              brief.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw Failure.invalid("brief must be non-empty text within the instruction limit.") }
        let fps = wire.fps ?? 24, width = wire.width ?? 640, height = wire.height ?? 360
        guard fpsRange.contains(fps) else { throw Failure.invalid("fps must be \(fpsRange.lowerBound)–\(fpsRange.upperBound).") }
        guard dimensionRange.contains(width), dimensionRange.contains(height) else {
            throw Failure.invalid("width and height must be \(dimensionRange.lowerBound)–\(dimensionRange.upperBound) pixels.")
        }
        var seed: UInt64?
        switch wire.seed {
        case nil: break
        case .number(let value)?: seed = value
        case .text(let text)?:
            // Decimal strings carry 63-bit seeds without any floating-point rounding.
            guard (1...20).contains(text.utf8.count), text.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt64(text) else {
                throw Failure.invalid("seed must be an unsigned 64-bit integer.")
            }
            seed = value
        }
        if let text = wire.job_id {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:")
            guard (1...64).contains(text.utf8.count), text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw Failure.invalid("job_id must be 1–64 ASCII letters, digits or -_.:")
            }
        }
        var projectName = "Spatter daily draft"
        if let text = wire.project_name {
            guard let valid = try? StudioDocument.validatedProjectName(text) else { throw Failure.invalid("project_name is not a valid project name.") }
            projectName = valid
        }
        return .init(brief: brief, fps: fps, width: width, height: height, seed: seed, jobID: wire.job_id, projectName: projectName)
    }

    /// Parses the brief with the production grammar. A job seed is appended as
    /// the grammar's own `seed N` suffix when the brief has none; a brief whose
    /// explicit seed differs from the job seed is refused rather than overridden.
    func parsedBrief() throws -> SpatterMultiClauseBrief {
        let parsed = try SpatterMultiClauseBrief.parse(brief)
        guard let seed, parsed.seed != seed else { return parsed }
        var body = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix(".") { body.removeLast() }
        let seeded: SpatterMultiClauseBrief
        do { seeded = try SpatterMultiClauseBrief.parse(body + "; seed \(seed).") }
        catch { throw Failure.invalid("the brief's explicit seed differs from the job seed \(seed).") }
        guard seeded.seed == seed else { throw Failure.invalid("the brief's explicit seed differs from the job seed \(seed).") }
        return seeded
    }
}

/// The planned, executed and measured editable document for one job.
struct SpatterDraftPlannedDocument {
    let brief: SpatterMultiClauseBrief
    let document: StudioDocument
    let storyboard: SpatterStoryboard
    let generatedLayerIDs: Set<String>

    /// Deterministic request identity derived from the seed, so the same job
    /// replays the same typed command bytes.
    static func requestID(seed: UInt64, salt: UInt64) -> UUID {
        var random = SpatterDeterministicRandom(seed: seed ^ salt)
        let high = random.next(), low = random.next()
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 { bytes[index] = UInt8(truncatingIfNeeded: high >> (UInt64(index) * 8)); bytes[8 + index] = UInt8(truncatingIfNeeded: low >> (UInt64(index) * 8)) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40; bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Plans the brief against a fresh project exactly as Studio does, then
    /// removes the new project's initial empty frame with a second typed request
    /// so the draft contains only generated poses (an empty lead-in frame would
    /// be a blank-frame quality finding).
    static func make(job: SpatterDraftRenderJob, checkCancellation: () throws -> Void = {}) throws -> Self {
        let brief = try job.parsedBrief()
        let fresh = try StudioDocument.new(name: job.projectName, width: job.width, height: job.height, fps: job.fps)
        let seedFrameID = fresh.frames[0].id
        let plan = try brief.prepare(in: StudioCommandContext(document: fresh), requestID: requestID(seed: brief.seed, salt: 0x5344_4931), checkCancellation: checkCancellation)
        var editor = try StudioDocumentEditor(document: fresh)
        let receipt = try execute(plan.prepared.request, on: &editor, checkCancellation: checkCancellation)
        guard receipt.outcome == .applied, receipt.createdLayerIDs.count == brief.actors.count,
              receipt.createdFrameIDs.count == plan.storyboard.frameCount else { throw SpatterDraftRenderJob.Failure.invalid("the planned request did not apply as one edit.") }
        let trim = StudioCommandRequest(requestID: requestID(seed: brief.seed, salt: 0x5344_4932), projectID: fresh.id,
                                        expectedRevision: editor.document.revision, action: .apply([.deleteFrameRange(.init(frameIDs: [seedFrameID]))]))
        let trimmed = try execute(trim, on: &editor, checkCancellation: checkCancellation)
        guard trimmed.outcome == .applied, trimmed.deletedFrameIDs == [seedFrameID] else { throw SpatterDraftRenderJob.Failure.invalid("the empty lead-in frame could not be removed.") }
        let document = editor.document
        try document.validate()
        guard document.totalTimelineTicks == plan.storyboard.totalTicks else { throw SpatterDraftRenderJob.Failure.invalid("the document timing differs from the storyboard.") }
        return .init(brief: brief, document: document, storyboard: plan.storyboard, generatedLayerIDs: Set(receipt.createdLayerIDs))
    }

    private static func execute(_ request: StudioCommandRequest, on editor: inout StudioDocumentEditor,
                                checkCancellation: () throws -> Void) throws -> StudioCommandReceipt {
        // Round-trip through the strict wire decoder exactly like the view model does.
        let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(request))
        return try StudioCommandExecutor.execute(decoded, editor: &editor, checkCancellation: checkCancellation)
    }

    func quality(movie: SpatterQualityReport.MovieMeasurement?) -> SpatterQualityReport {
        SpatterQualityReport.analyze(document, requestedTicks: storyboard.totalTicks, generatedLayerIDs: generatedLayerIDs, movie: movie)
    }
}

enum SpatterDraftReceipt {
    static let schema = "sdi_spatter_draft_render_receipt"
    static let version = 1

    /// The production review record (`SpatterQualityReport.ReviewRecord`, schema
    /// `spatter_quality_report` v1) that `draft_queue.quality_record_problem` accepts.
    static func quality(_ report: SpatterQualityReport, movie: SpatterQualityReport.MovieMeasurement?) throws -> Any {
        try JSONSerialization.jsonObject(with: report.reviewRecord(movie: movie).json())
    }

    static func failure(_ message: String, jobID: String?) -> [String: Any] {
        ["schema": schema, "version": version, "status": "failed", "job_id": jobID.map { $0 as Any } ?? NSNull(),
         "private_draft": true, "published": false, "owner_approval_required": true, "error": String(message.prefix(2000))]
    }

    static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(#"{"status":"failed","error":"Receipt encoding failed."}"#.utf8)
    }
}
