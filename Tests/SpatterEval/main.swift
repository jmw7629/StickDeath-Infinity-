import Foundation
import SwiftUI

// Spatter acceptance evaluation runner (#216). Runs Tests/SpatterEval/briefs.v1.json
// against the production local guidance, edit session and export receipt. It
// never calls a provider. Results (pass/fail per brief, with the run seed) are
// written to $SPATTER_EVAL_RESULTS or a temp file so failed cases are preserved.
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

private struct Result: Encodable {
    let id: String
    let kind: String
    let passed: Bool
    let detail: String
}

@main @MainActor struct SpatterEvalRunner {
    static func main() async {
        do { try await run() } catch { print("SPATTER_EVAL=FAIL \(error)"); exit(1) }
    }
    static func run() async throws {
        let arguments = CommandLine.arguments
        let corpusPath = arguments.count > 1 ? arguments[1] : "Tests/SpatterEval/briefs.v1.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: corpusPath))
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        try require(corpus.schema == "spatter_eval_briefs" && corpus.version == 1, "Unsupported corpus")
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
            var passed = false
            do {
                switch brief.expected.outcome {
                case "localGuide":
                    let context: SpatterContext
                    if brief.context == "studio" {
                        let vm = try await fixture(brief.id, kind: "blank")
                        guard let studio = SpatterContext.studio(vm.commandScreenContext) else { throw Failure(message: "Studio context missing") }
                        context = studio
                    } else { context = .general }
                    let answer = SpatterAIViewModel.localGuidance(for: brief.input, context: context)
                    let missing = (brief.expected.mustContain ?? []).filter { !answer.contains($0) }
                    let forbidden = (brief.expected.mustNotContain ?? []).filter { answer.localizedCaseInsensitiveContains($0) }
                    passed = missing.isEmpty && forbidden.isEmpty
                    detail = passed ? "guide ok" : "missing=\(missing) forbidden=\(forbidden)"
                case "applied", "rejected":
                    let vm = try await fixture(brief.id, kind: brief.fixture ?? "blank")
                    let before = vm.document
                    let session = SpatterStudioEditSession()
                    _ = session.submit(brief.input, in: vm, accountID: nil, currentScope: { scope })
                    await session.waitForCompletion()
                    if brief.expected.outcome == "rejected" {
                        passed = (session.status == .rejected || session.status == .stale) && vm.document == before && session.appliedEdit == nil
                        detail = "status=\(session.status) changed=\(vm.document != before) notice=\(session.notice ?? "")"
                    } else {
                        guard session.status == .applied, let edit = session.appliedEdit else {
                            detail = "status=\(session.status) notice=\(session.notice ?? "")"; break
                        }
                        let fields = receiptFields(edit.receipt)
                        let missing = (brief.expected.requiredReceiptFields ?? []).filter { !fields.contains($0) }
                        var problems: [String] = missing.map { "receipt field \($0)" }
                        if let added = brief.expected.addedFrames, edit.receipt.createdFrameIDs.count != added { problems.append("addedFrames=\(edit.receipt.createdFrameIDs.count)") }
                        if let name = brief.expected.projectName, vm.document.name != name { problems.append("name=\(vm.document.name)") }
                        if vm.document.revision != before.revision + 1 { problems.append("revision=\(vm.document.revision)") }
                        vm.undo()
                        if vm.document.frames.count != before.frames.count { problems.append("undo did not restore frame count") }
                        passed = problems.isEmpty
                        detail = passed ? "applied; one Undo restored frame count" : problems.joined(separator: "; ")
                    }
                case "exportReceipt":
                    let file = root.appendingPathComponent(brief.id + ".mp4")
                    try Data(repeating: 0x41, count: 4096).write(to: file)
                    let expectedBytes = brief.expected.refused == true ? 4095 : 4096
                    do {
                        let receipt = try SpatterExportReceipt.make(editRequestID: UUID(), revision: 3, fileURL: file,
                            expectedByteCount: expectedBytes, durationSeconds: 1, frameCount: 12)
                        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any] ?? [:]
                        let missing = (brief.expected.requiredReceiptFields ?? []).filter { encoded[$0] == nil }
                        passed = brief.expected.refused != true && missing.isEmpty && receipt.sha256.count == 64
                        detail = passed ? "receipt fields present" : "missing=\(missing) refusedExpected=\(brief.expected.refused == true)"
                    } catch {
                        passed = brief.expected.refused == true
                        detail = "refused: \(error.localizedDescription)"
                    }
                default:
                    detail = "unknown outcome kind \(brief.expected.outcome)"
                }
            } catch {
                detail = "error: \(error)"
            }
            results.append(.init(id: brief.id, kind: brief.kind, passed: passed, detail: detail))
            print("\(passed ? "PASS" : "FAIL") \(brief.kind) \(brief.id): \(detail)")
        }
        let failures = results.filter { !$0.passed }
        let output = ProcessInfo.processInfo.environment["SPATTER_EVAL_RESULTS"].map { URL(fileURLWithPath: $0) }
            ?? fm.temporaryDirectory.appendingPathComponent("spatter-eval-results-\(seed).json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Report: Encodable { let corpusVersion: Int; let seed: UInt64; let passed: Int; let failed: Int; let results: [Result] }
        try encoder.encode(Report(corpusVersion: corpus.version, seed: seed, passed: results.count - failures.count,
                                  failed: failures.count, results: results)).write(to: output)
        print("SPATTER_EVAL=\(failures.isEmpty ? "PASS" : "FAIL") \(results.count - failures.count)/\(results.count) seed=\(seed) results=\(output.path)")
        if !failures.isEmpty { exit(1) }
    }
}
