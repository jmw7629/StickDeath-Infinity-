import Foundation
import SwiftUI

// Spatter acceptance evaluation runner (#216). Runs Tests/SpatterEval/briefs.v1.json
// against the production local guidance, edit session and export receipt. It
// never calls a provider. Results (pass/fail per brief, per-dimension scores and
// the run seed) are written to $SPATTER_EVAL_RESULTS or a temp file; CI uploads
// that file even when the suite fails, so failed cases are preserved.
//
// Dimensions (1 = met, 0 = not met, absent = not applicable to that outcome):
//   factuality    guide answers contain every required fact; receipts carry
//                 the required fields and describe the real revision/file.
//   adherence     the outcome matches the brief (applied or refused, forbidden
//                 claims absent, expected frame count and name).
//   editability   an applied edit is one revision whose created frames, layers
//                 and drawings exist as editable objects in the document.
//   reversibility one Undo restores the frame and layer structure; a refusal
//                 leaves the document equal to its captured state.
//   privacy       no local file path, provider key or bearer token appears in an
//                 answer, notice or receipt; no cloud backend is configured.
//   quality       answers and notices are non-empty and bounded; an applied
//                 edit changes the project or reports that nothing changed.
// A brief passes only when every applicable dimension scores 1.
//
// Compile with the SpatterStudioEditSession source list plus
// StickDeathInfinity/Services/Spatter/SpatterKnowledgeBase.swift and
// StickDeathInfinity/ViewModels/SpatterAIViewModel.swift (see the report).

private struct Failure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }

private struct Corpus: Decodable {
    struct Brief: Decodable {
        struct Expected: Decodable {
            let outcome: String
            var mustContain: [String]? = nil
            var mustNotContain: [String]? = nil
            var requiredReceiptFields: [String]? = nil
            var addedFrames: Int? = nil
            var projectName: String? = nil
            var refused: Bool? = nil
        }
        let id: String
        let kind: String
        let input: String
        var context: String? = nil
        var fixture: String? = nil
        let expected: Expected
    }
    let schema: String
    let version: Int
    let briefs: [Brief]
}

private struct Scores: Encodable {
    var factuality: Double? = nil
    var adherence: Double? = nil
    var editability: Double? = nil
    var reversibility: Double? = nil
    var privacy: Double? = nil
    var quality: Double? = nil
    static let names = ["factuality", "adherence", "editability", "reversibility", "privacy", "quality"]
    var values: [String: Double] {
        var out: [String: Double] = [:]
        for (name, value) in zip(Self.names, [factuality, adherence, editability, reversibility, privacy, quality]) {
            if let value { out[name] = value }
        }
        return out
    }
    var failing: [String] { values.filter { $0.value < 1 }.map(\.key).sorted() }
    var allMet: Bool { !values.isEmpty && failing.isEmpty }
    static func score(_ met: Bool) -> Double { met ? 1 : 0 }
}

private struct Result: Encodable {
    let id: String
    let kind: String
    let passed: Bool
    let scores: Scores
    let detail: String
}

/// Text that must never reach an answer, notice or receipt: the evaluation's
/// local directory, absolute device paths and provider-key or token shapes.
private func leaksPrivateData(_ text: String, root: URL) -> Bool {
    if text.contains(root.path) || text.contains("file://") { return true }
    for pattern in [#"\bsk-[A-Za-z0-9_-]{12,}"#, #"/Users/[^\s]+"#, #"/var/mobile/[^\s]+"#, #"(?i)\bBearer\s+[A-Za-z0-9._-]{12,}"#] {
        if text.range(of: pattern, options: .regularExpression) != nil { return true }
    }
    return false
}

@main @MainActor struct SpatterEvalRunner {
    static func main() async {
        do { try await run() } catch { print("SPATTER_EVAL=FAIL \(error)"); exit(1) }
    }
    static func run() async throws {
        let arguments = CommandLine.arguments
        // v2 (October 13) is the current corpus; v1 stays runnable as the frozen baseline.
        let corpusPath = arguments.count > 1 ? arguments[1] : "Tests/SpatterEval/briefs.v2.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: corpusPath))
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        try require(corpus.schema == "spatter_eval_briefs" && (1...2).contains(corpus.version), "Unsupported corpus")
        try require(corpus.version == 1 || corpus.briefs.count >= 60, "Corpus v2 must hold at least 60 briefs")
        try require(Set(corpus.briefs.map(\.id)).count == corpus.briefs.count, "Brief identifiers must be unique")
        let seed = UInt64(ProcessInfo.processInfo.environment["SPATTER_EVAL_SEED"] ?? "") ?? UInt64(Date().timeIntervalSince1970)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-spatter-eval-\(seed)-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try require(AppConfig.backendURL == nil, "Evaluation must run without a configured cloud backend")
        let scope = SpatterStudioEditSession.Scope(isStudioVisible: true, accountID: nil)
        var results: [Result] = []

        func fixture(_ name: String, kind: String) async throws -> StudioViewModel {
            let store = DeviceStorageManager(documentsDirectory: root.appendingPathComponent(name))
            let vm = StudioViewModel(storage: store)
            try require(await vm.createProject(name: "Eval \(name)", width: 128, height: 96, fps: 12), "Fixture creation failed")
            if kind == "selectedDrawing" {
                try require(vm.commitElement(.init(id: "eval-drawing", tool: .rectangle,
                    points: [.init(x: 8, y: 8), .init(x: 120, y: 88)], color: "#FF0000", width: 2, opacity: 1,
                    layerID: vm.activeLayerID, shape: .init(fillColor: "#FF0000"))), "Drawing fixture rejected")
                vm.selectedTool = .move; vm.selectionMode = .new
                try require(vm.selectElement(at: CGPoint(x: 64, y: 48)) == "eval-drawing", "Fixture selection failed")
            }
            vm.activePanel = .spatterAI; await vm.flush()
            return vm
        }
        func receiptFields(_ receipt: StudioCommandReceipt) -> Set<String> {
            var fields: Set<String> = ["requestID", "projectID", "previousRevision", "revision", "outcome"]
            if !receipt.createdFrameIDs.isEmpty { fields.insert("createdFrameIDs") }
            if !receipt.createdLayerIDs.isEmpty { fields.insert("createdLayerIDs") }
            if !receipt.createdElementIDs.isEmpty { fields.insert("createdElementIDs") }
            return fields
        }

        for brief in corpus.briefs {
            var detail = ""
            var scores = Scores()
            do {
                switch brief.expected.outcome {
                case "localGuide":
                    let context: SpatterContext
                    if brief.context == "studio" {
                        let vm = try await fixture(brief.id, kind: "blank")
                        guard let studio = SpatterContext.studio(vm.commandScreenContext) else { throw Failure(message: "Studio context missing") }
                        context = studio
                    } else if brief.context == "library" { context = .library }
                    else { context = .general }
                    let answer = SpatterAIViewModel.localGuidance(for: brief.input, context: context)
                    let missing = (brief.expected.mustContain ?? []).filter { !answer.contains($0) }
                    let forbidden = (brief.expected.mustNotContain ?? []).filter { answer.localizedCaseInsensitiveContains($0) }
                    scores.factuality = Scores.score(missing.isEmpty)
                    scores.adherence = Scores.score(forbidden.isEmpty)
                    scores.privacy = Scores.score(!leaksPrivateData(answer, root: root))
                    scores.quality = Scores.score(!answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && answer.count <= 8_000)
                    detail = scores.allMet ? "guide ok" : "missing=\(missing) forbidden=\(forbidden) failing=\(scores.failing)"
                case "applied", "rejected":
                    let vm = try await fixture(brief.id, kind: brief.fixture ?? "blank")
                    let before = vm.document
                    let session = SpatterStudioEditSession()
                    _ = session.submit(brief.input, in: vm, accountID: nil, currentScope: { scope })
                    await session.waitForCompletion()
                    let notice = session.notice ?? ""
                    scores.privacy = Scores.score(!leaksPrivateData(notice, root: root))
                    if brief.expected.outcome == "rejected" {
                        scores.adherence = Scores.score((session.status == .rejected || session.status == .stale) && session.appliedEdit == nil)
                        scores.reversibility = Scores.score(vm.document == before)
                        scores.quality = Scores.score(!notice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && notice.count <= 2_000)
                        detail = "status=\(session.status) changed=\(vm.document != before) notice=\(notice)"
                    } else {
                        guard session.status == .applied, let edit = session.appliedEdit else {
                            scores.adherence = 0
                            detail = "status=\(session.status) notice=\(notice)"; break
                        }
                        let fields = receiptFields(edit.receipt)
                        let missing = (brief.expected.requiredReceiptFields ?? []).filter { !fields.contains($0) }
                        var problems: [String] = missing.map { "receipt field \($0)" }
                        let receiptTruthful = missing.isEmpty && edit.receipt.previousRevision == before.revision
                            && edit.receipt.revision == vm.document.revision && edit.receipt.projectID == vm.document.id
                        scores.factuality = Scores.score(receiptTruthful)
                        if !receiptTruthful && missing.isEmpty { problems.append("receipt revision/project mismatch") }
                        var adheres = true
                        if let added = brief.expected.addedFrames, edit.receipt.createdFrameIDs.count != added {
                            problems.append("addedFrames=\(edit.receipt.createdFrameIDs.count)"); adheres = false
                        }
                        if let name = brief.expected.projectName, vm.document.name != name { problems.append("name=\(vm.document.name)"); adheres = false }
                        scores.adherence = Scores.score(adheres)
                        // Editable: one revision, and every created identity is a real
                        // frame, layer or drawing in the document (not a flattened copy).
                        let frameIDs = Set(vm.document.frames.map(\.id)), layerIDs = Set(vm.document.layers.map(\.id))
                        let elementIDs = Set(vm.document.frames.flatMap { $0.elements.map(\.id) })
                        var editable = vm.document.revision == before.revision + 1
                        if !editable { problems.append("revision=\(vm.document.revision)") }
                        let orphans = edit.receipt.createdFrameIDs.filter { !frameIDs.contains($0) }
                            + edit.receipt.createdLayerIDs.filter { !layerIDs.contains($0) }
                            + edit.receipt.createdElementIDs.filter { !elementIDs.contains($0) }
                        if !orphans.isEmpty { editable = false; problems.append("created identities missing: \(Array(orphans.prefix(4)))") }
                        scores.editability = Scores.score(editable)
                        scores.quality = Scores.score(vm.document != before || edit.receipt.outcome == .unchanged)
                        vm.undo()
                        let restored = vm.document.frames.map(\.id) == before.frames.map(\.id)
                            && vm.document.layers.map(\.id) == before.layers.map(\.id)
                        if !restored { problems.append("undo did not restore frame and layer structure") }
                        scores.reversibility = Scores.score(restored)
                        detail = problems.isEmpty ? "applied; one Undo restored frames and layers" : problems.joined(separator: "; ")
                    }
                case "exportReceipt":
                    let file = root.appendingPathComponent(brief.id + ".mp4")
                    try Data(repeating: 0x41, count: 4096).write(to: file)
                    let expectedBytes = brief.expected.refused == true ? 4095 : 4096
                    do {
                        let receipt = try SpatterExportReceipt.make(editRequestID: UUID(), revision: 3, fileURL: file,
                            expectedByteCount: expectedBytes, durationSeconds: 1, frameCount: 12)
                        let json = try JSONEncoder().encode(receipt)
                        let encoded = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
                        let missing = (brief.expected.requiredReceiptFields ?? []).filter { encoded[$0] == nil }
                        scores.adherence = Scores.score(brief.expected.refused != true)
                        scores.factuality = Scores.score(missing.isEmpty && receipt.sha256.count == 64 && receipt.byteCount == expectedBytes)
                        scores.privacy = Scores.score(!leaksPrivateData(String(decoding: json, as: UTF8.self) + receipt.summary, root: root))
                        scores.quality = Scores.score(!receipt.summary.isEmpty)
                        detail = scores.allMet ? "receipt fields present"
                            : "missing=\(missing) refusedExpected=\(brief.expected.refused == true) failing=\(scores.failing)"
                    } catch {
                        scores.adherence = Scores.score(brief.expected.refused == true)
                        scores.privacy = Scores.score(!leaksPrivateData(error.localizedDescription, root: root))
                        detail = "refused: \(error.localizedDescription)"
                    }
                default:
                    detail = "unknown outcome kind \(brief.expected.outcome)"
                }
            } catch {
                scores.adherence = 0
                detail = "error: \(error)"
            }
            // Every brief runs with no cloud backend; a configured one fails privacy.
            if AppConfig.backendURL != nil { scores.privacy = 0 }
            let passed = scores.allMet
            results.append(.init(id: brief.id, kind: brief.kind, passed: passed, scores: scores, detail: detail))
            print("\(passed ? "PASS" : "FAIL") \(brief.kind) \(brief.id): \(detail)")
        }
        let failures = results.filter { !$0.passed }
        let output = ProcessInfo.processInfo.environment["SPATTER_EVAL_RESULTS"].map { URL(fileURLWithPath: $0) }
            ?? fm.temporaryDirectory.appendingPathComponent("spatter-eval-results-\(seed).json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Per-dimension share of met briefs among the briefs where it applies.
        struct Dimension: Encodable { let applicable: Int; let met: Int; let score: Double }
        var dimensions: [String: Dimension] = [:]
        for name in Scores.names {
            let values = results.compactMap { $0.scores.values[name] }
            let met = values.filter { $0 >= 1 }.count
            dimensions[name] = .init(applicable: values.count, met: met, score: values.isEmpty ? 0 : Double(met) / Double(values.count))
        }
        struct Report: Encodable {
            let schema: String; let corpusVersion: Int; let seed: UInt64; let passed: Int; let failed: Int
            let dimensions: [String: Dimension]; let results: [Result]
        }
        try encoder.encode(Report(schema: "spatter_eval_report.v2", corpusVersion: corpus.version, seed: seed,
                                  passed: results.count - failures.count, failed: failures.count,
                                  dimensions: dimensions, results: results)).write(to: output)
        for name in Scores.names {
            if let value = dimensions[name] { print("DIMENSION \(name) \(value.met)/\(value.applicable)") }
        }
        print("SPATTER_EVAL=\(failures.isEmpty ? "PASS" : "FAIL") \(results.count - failures.count)/\(results.count) seed=\(seed) results=\(output.path)")
        if !failures.isEmpty { exit(1) }
    }
}
