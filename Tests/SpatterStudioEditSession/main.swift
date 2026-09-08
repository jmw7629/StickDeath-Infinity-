import Foundation
import SwiftUI

private struct Failure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
private final class NetworkTrap: URLProtocol {
    private static let lock = NSLock()
    private static var attempts = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    override class func canInit(with request: URLRequest) -> Bool {
        guard ["http", "https"].contains(request.url?.scheme ?? "") else { return false }
        lock.lock(); attempts += 1; lock.unlock(); return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() { }
}

/// Controls only the real session's scheduler boundary, never edits or receipts.
@MainActor private final class Gate {
    private(set) var hits = 0
    private var waiting: [Int: CheckedContinuation<Void, Error>] = [:]
    func pause() async throws {
        hits += 1; let index = hits
        try await withCheckedThrowingContinuation { waiting[index] = $0 }
    }
    func waitFor(_ count: Int) async throws {
        for _ in 0..<2000 {
            if hits >= count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw Failure(message: "Production session checkpoint did not arrive")
    }
    func release(_ index: Int) throws {
        guard let continuation = waiting.removeValue(forKey: index) else { throw Failure(message: "Checkpoint missing") }
        continuation.resume()
    }
}

@main @MainActor struct SpatterStudioEditSessionTests {
    nonisolated static let red = "Append 8 frames of a red outlined circle moving from (20%, 50%) to (80%, 50%), radius 8%, line width 3 px."
    nonisolated static let green = "Append 5 frames of a green outlined circle moving from (75%, 30%) to (25%, 70%), radius 6%, line width 2 px."
    static let guest = SpatterStudioEditSession.Scope(isStudioVisible: true, accountID: nil)
    static func content(_ value: StudioDocument) -> StudioDocument {
        var value = value; value.revision = 0; value.modifiedAt = value.createdAt; return value
    }
    static func styledStroke(_ vm: StudioViewModel, id: String = "original-styled") -> DrawnElement {
        .init(id: id, tool: .brush, points: [.init(x: 5, y: 10, pressure: 0.3, timestamp: 0),
            .init(x: 40, y: 30, pressure: 0.9, timestamp: 0.2)], color: "#0000FF", width: 6, opacity: 0.7,
            layerID: vm.activeLayerID, brush: .init(family: .grain, seed: 9821, smoothing: 0, pressureEnabled: true))
    }
    static func awaitAutosave(_ vm: StudioViewModel) async throws {
        for _ in 0..<200 {
            if !vm.isDirty && !vm.isSaving { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure(message: "Actual autosave did not complete within four seconds")
    }
    private static func reachSecond(_ gate: Gate) async throws {
        try await gate.waitFor(1); try gate.release(1); try await gate.waitFor(2)
    }
    static func main() async {
        do { try await run() }
        catch { print("SPATTER_STUDIO_EDIT_SESSION_TESTS=FAIL \(error)"); exit(1) }
    }
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-spatter-edit-session-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root); URLProtocol.unregisterClass(NetworkTrap.self) }
        try require(URLProtocol.registerClass(NetworkTrap.self), "HTTP fixture trap unavailable")
        try require(AppConfig.backendURL == nil, "Local fixture unexpectedly configured a cloud backend")
        func storage(_ name: String) -> DeviceStorageManager { .init(documentsDirectory: root.appendingPathComponent(name)) }
        func fixture(_ name: String, fps: Int = 24) async throws -> (StudioViewModel, DeviceStorageManager) {
            let store = storage(name), vm = StudioViewModel(storage: store)
            try require(await vm.createProject(name: name, width: 128, height: 96, fps: fps), "Create failed")
            vm.activePanel = .spatterAI
            return (vm, store)
        }
        var passed = 0
        func test(_ name: String, _ operation: () async throws -> Void) async throws {
            do { try await operation(); passed += 1; print("PASS \(name)") }
            catch { print("FAIL \(name): \(error)"); throw error }
        }

        try await test("immutable explicit draft creates real schema2-compatible editable motion and factual receipt") {
            let (vm, store) = try await fixture("editable")
            let original = styledStroke(vm)
            try require(vm.commitElement(original), "Actual styled stroke failed")
            vm.addFrame(); vm.prevFrame()
            let before = vm.document, gate = Gate(), session = SpatterStudioEditSession(checkpoint: { try await gate.pause() })
            let scope = SpatterStudioEditSession.Scope(isStudioVisible: true, accountID: "owner-A")
            var callerDraft = red
            try require(session.submit(callerDraft, in: vm, accountID: scope.accountID, currentScope: { scope }), "Recipe not accepted")
            callerDraft = "different text typed after submission"
            try await reachSecond(gate)
            try require(vm.document == before && session.appliedEdit == nil && session.submittedDraft == red,
                        "Preparation mutated content or captured a later draft")
            try gate.release(2); await session.waitForCompletion()
            guard let result = session.appliedEdit else { throw Failure(message: "Actual edit receipt missing") }
            let changed = vm.document
            try require(session.status == .applied && result.addedFrameCount == 8 && result.fps == 24
                && result.addedDurationSeconds == 8.0 / 24.0 && result.receipt.revision == before.revision + 1,
                "Result invented count, timing or transaction revision")
            try require(changed.schemaVersion == 2 && Array(changed.frames.prefix(2)) == before.frames
                && changed.frames[0].elements[0].brush == original.brush && changed.frames[0].elements[0].points == original.points,
                "Original schema2 pressure, seed, stroke or frames changed")
            try require(changed.frames.dropFirst(2).allSatisfy { $0.elements.count == 1 && $0.elements[0].tool == .circle && $0.elements[0].color == "#FF0000" },
                "Local instruction did not create real editable circles")
            try require(session.saveState(in: vm, currentScope: scope) == .unsaved && !result.summary.lowercased().contains("saved"),
                "In-memory receipt falsely claimed save success")
            try require(callerDraft == "different text typed after submission", "Session cleared or rewrote caller draft")
            try require(await vm.save(), "Actual save failed")
            try require(session.saveState(in: vm, currentScope: scope) == .saved, "Actual successful save was not reflected")
            try require(session.saveState(in: vm, currentScope: .init(isStudioVisible: true, accountID: "other")) == .unavailable
                && session.saveState(in: vm, currentScope: .init(isStudioVisible: false, accountID: scope.accountID)) == .unavailable,
                "Receipt save state leaked into another account or screen")
            vm.undo(); try require(content(vm.document) == content(before), "One ordinary undo did not reverse complete recipe")
            try require(session.saveState(in: vm, currentScope: scope) == .projectChanged, "Receipt stayed current after undo")
            vm.redo(); try require(content(vm.document) == content(changed), "Redo did not restore exact content and identities")
            try require(await vm.save(), "Redo save failed")
            let record = try store.loadAnimation(id: vm.document.id)!, reopened = StudioViewModel(storage: store)
            try require(await reopened.openProject(record.metadata), "Actual reopen failed")
            try require(reopened.document == vm.document && reopened.frames[0].elements[0].brush == original.brush,
                        "Actual persisted recipe lost original schema2 content")
        }
        try await test("guest local action uses a different prompt and current FPS without authentication or cloud") {
            let (vm, _) = try await fixture("guest", fps: 12), session = SpatterStudioEditSession()
            try require(session.submit(green, in: vm, accountID: nil, currentScope: { guest }), "Guest recipe unavailable")
            await session.waitForCompletion()
            try require(session.appliedEdit?.addedFrameCount == 5 && session.appliedEdit?.addedDurationSeconds == 5.0 / 12.0,
                        "Prompt frame count or project FPS ignored")
            let frames = Array(vm.frames.dropFirst())
            try require(frames.count == 5 && frames.first!.elements[0].points[0].x > frames.last!.elements[0].points[0].x
                && frames.allSatisfy { $0.elements[0].color == "#00FF00" }, "Prompt direction or color ignored")
        }
        try await test("unsupported advice extra clauses and missing values preserve draft user history and pending autosave") {
            let (vm, store) = try await fixture("unsupported")
            try require(vm.commitElement(styledStroke(vm)), "User edit failed")
            let before = vm.document, session = SpatterStudioEditSession()
            for draft in ["How do layers work?", red + " and publish to YouTube", red.replacingOccurrences(of: ", radius 8%", with: "")] {
                try require(session.submit(draft, in: vm, accountID: nil, currentScope: { guest }), "Bounded draft was not scheduled")
                await session.waitForCompletion()
                try require(session.status == .rejected && session.appliedEdit == nil && session.submittedDraft == draft
                    && vm.document == before && vm.canUndo, "Unsupported draft executed a prefix or lost user history")
            }
            try await awaitAutosave(vm)
            let saved = try store.loadAnimation(id: before.id)!
            try require(try StudioDocumentArchive.decode(saved.editableDocumentData!).document == before,
                        "Rejected recipe disrupted the user's autosave")
        }
        try await test("in-flight duplicates and accepted-token replay cannot apply a second transaction") {
            let (vm, _) = try await fixture("duplicate"), gate = Gate()
            let session = SpatterStudioEditSession(checkpoint: { try await gate.pause() }), id = UUID()
            try require(session.submit(red, in: vm, accountID: nil, submissionID: id, currentScope: { guest }), "First request rejected")
            try await gate.waitFor(1)
            try require(!session.submit(green, in: vm, accountID: nil, currentScope: { guest }) && session.submittedDraft == red
                && session.isWorking, "Duplicate replaced the active request or draft")
            try gate.release(1); try await gate.waitFor(2); try gate.release(2); await session.waitForCompletion()
            let changed = vm.document
            await session.waitForCompletion()
            try require(!session.submit(red, in: vm, accountID: nil, submissionID: id, currentScope: { guest }), "Accepted token replayed")
            try require(vm.document == changed && vm.frames.count == 9, "Duplicate completion changed actual content")
        }
        try await test("cancellation at either async boundary retains edits draft history and user autosave") {
            for boundary in [1, 2] {
                let (vm, store) = try await fixture("cancel-\(boundary)")
                try require(vm.commitElement(styledStroke(vm)), "Original edit failed")
                let before = vm.document, gate = Gate(), session = SpatterStudioEditSession(checkpoint: { try await gate.pause() })
                try require(session.submit(red, in: vm, accountID: nil, currentScope: { guest }), "Submit failed")
                if boundary == 2 { try await reachSecond(gate) } else { try await gate.waitFor(1) }
                try require(session.cancel(), "Pending request did not cancel")
                try gate.release(boundary); await session.waitForCompletion()
                try require(session.status == .cancelled && session.submittedDraft == red && session.appliedEdit == nil
                    && vm.document == before && vm.canUndo, "Cancelled recipe changed content/history/draft")
                try await awaitAutosave(vm)
                let saved = try store.loadAnimation(id: before.id)!
                try require(try StudioDocumentArchive.decode(saved.editableDocumentData!).document == before,
                            "Cancellation cancelled pending user persistence")
            }
        }
        try await test("closing invalidates prepared work and prevents reuse without claiming prior edits were cancelled") {
            let (vm, _) = try await fixture("close"), gate = Gate()
            let session = SpatterStudioEditSession(checkpoint: { try await gate.pause() }), before = vm.document
            try require(session.submit(red, in: vm, accountID: nil, currentScope: { guest }), "Submit failed")
            try await reachSecond(gate); session.close(); try gate.release(2); await session.waitForCompletion()
            try require(session.isClosed && session.status == .closed && session.submittedDraft == red && vm.document == before,
                        "Close lost draft or applied old work")
            try require(!session.submit(green, in: vm, accountID: nil, currentScope: { guest }), "Closed session reopened implicitly")
            let completed = SpatterStudioEditSession()
            try require(completed.submit(green, in: vm, accountID: nil, currentScope: { guest }), "Fresh session unavailable")
            await completed.waitForCompletion(); let changed = vm.document
            try require(!completed.cancel() && completed.status == .applied && vm.document == changed,
                        "Late cancel falsely claimed committed edits were cancelled")
            completed.close(); try require(completed.notice == "Local edit session closed." && vm.document == changed,
                                          "Close misreported prior committed work")
        }
        try await test("account switches sign-in and sign-out discard the prepared action before edits") {
            let identities: [(String?, String?)] = [("A", "B"), (nil, "A"), ("A", nil)]
            for (index, pair) in identities.enumerated() {
                let (vm, _) = try await fixture("account-\(index)"), gate = Gate()
                let session = SpatterStudioEditSession(checkpoint: { try await gate.pause() }), before = vm.document
                var account = pair.0
                try require(session.submit(red, in: vm, accountID: account, currentScope: { .init(isStudioVisible: true, accountID: account) }), "Submit failed")
                try await reachSecond(gate); account = pair.1; try gate.release(2); await session.waitForCompletion()
                try require(session.status == .stale && session.appliedEdit == nil && session.submittedDraft == red
                    && vm.document == before && !vm.canUndo, "Account switch applied captured work")
            }
        }
        try await test("frame layer selection tool panel and playback changes invalidate the captured context") {
            let mutations: [(String, (StudioViewModel) -> Void)] = [
                ("revision", { $0.addFrame() }), ("layer", { $0.addLayer() }),
                ("element-selection", { $0.selectElement(at: CGPoint(x: 20, y: 20)) }),
                ("tool", { $0.selectedTool = .eraser }), ("panel", { $0.activePanel = .layers }),
                ("playback", { $0.togglePlayback() }), ("frame-selection", { $0.currentFrameIndex = 1 }),
                ("audio-selection", { $0.selectedAudioClip = $0.audioClips.first })
            ]
            for (name, mutate) in mutations {
                let (vm, _) = try await fixture("context-\(name)")
                try require(vm.commitElement(styledStroke(vm)), "Original stroke failed")
                vm.addFrame(); vm.prevFrame()
                vm.audioClips = [.init(id: "selection-audio", soundName: "Original clip", track: 0, startTime: 0, duration: 1)]
                let gate = Gate(), session = SpatterStudioEditSession(checkpoint: { try await gate.pause() })
                try require(session.submit(red, in: vm, accountID: nil, currentScope: { guest }), "Submit failed")
                try await reachSecond(gate); mutate(vm)
                if name == "element-selection" { try require(!vm.selectedElementIDs.isEmpty, "Production hit test did not change selection") }
                let afterUserChange = vm.document, playing = vm.isPlaying
                try gate.release(2); await session.waitForCompletion()
                try require(session.status == .stale && session.appliedEdit == nil && vm.document == afterUserChange
                    && vm.isPlaying == playing, "Stale \(name) request changed document or playback")
                vm.stopPlayback()
            }
        }
        try await test("leaving Studio or opening another real project rejects prepared old-context work") {
            for replacement in [false, true] {
                let (vm, _) = try await fixture("route-\(replacement)"), gate = Gate()
                let session = SpatterStudioEditSession(checkpoint: { try await gate.pause() })
                var visible = true
                try require(session.submit(red, in: vm, accountID: nil, currentScope: { .init(isStudioVisible: visible, accountID: nil) }), "Submit failed")
                try await reachSecond(gate)
                if replacement {
                    await vm.backToProjects()
                    try require(await vm.createProject(name: "Other actual project", width: 128, height: 96, fps: 12), "Other project create failed")
                } else { visible = false }
                let before = vm.document
                try gate.release(2); await session.waitForCompletion()
                try require(session.status == .stale && vm.document == before && session.appliedEdit == nil,
                            "Changed route or project accepted old work")
            }
        }
        try await test("active and rejected brush drafts block initial action without losing their real capture") {
            let (vm, _) = try await fixture("brush-initial"), session = SpatterStudioEditSession(), before = vm.document
            try require(vm.beginStrokeInput(id: "live-touch"), "Actual touch capture unavailable")
            try require(!session.submit(red, in: vm, accountID: nil, currentScope: { guest }) && vm.activeStrokeID == "live-touch"
                && vm.document == before && session.status == .rejected, "Local action interfered with active touch")
            vm.finishStrokeInput(id: "live-touch")
            var rejected = styledStroke(vm, id: "kept-draft"); rejected.width = 0.1
            try require(!vm.commitElement(rejected) && vm.pendingBrushStroke != nil, "Actual invalid brush was not retained")
            try require(!session.submit(red, in: vm, accountID: nil, currentScope: { guest }) && vm.pendingBrushStroke?.element == rejected
                && vm.document == before && session.submittedDraft == red, "Local action discarded rejected brush")
            vm.discardRejectedBrush()
        }
        try await test("touch or rejected brush arriving after preparation prevents commit and remains recoverable") {
            for rejected in [false, true] {
                let (vm, _) = try await fixture("brush-late-\(rejected)"), gate = Gate()
                let session = SpatterStudioEditSession(checkpoint: { try await gate.pause() }), before = vm.document
                try require(session.submit(red, in: vm, accountID: nil, currentScope: { guest }), "Submit failed")
                try await reachSecond(gate)
                if rejected {
                    var invalid = styledStroke(vm); invalid.width = 0.1
                    try require(!vm.commitElement(invalid), "Invalid brush unexpectedly committed")
                } else { try require(vm.beginStrokeInput(id: "late-touch"), "Touch did not start") }
                try gate.release(2); await session.waitForCompletion()
                try require(session.status == .rejected && vm.document == before && session.appliedEdit == nil
                    && (rejected ? vm.pendingBrushStroke != nil : vm.activeStrokeID == "late-touch"), "Prepared recipe lost later touch state")
                vm.finishStrokeInput(id: "late-touch"); vm.discardRejectedBrush()
            }
        }
        try await test("real save failure is unsaved after real receipt and retry persists identical generated identities") {
            let (vm, store) = try await fixture("storage-failure"), session = SpatterStudioEditSession()
            let preserved = root.appendingPathComponent("held-owned-animations")
            try fm.moveItem(at: store.animationsDir, to: preserved)
            try Data("owned test blocker".utf8).write(to: store.animationsDir)
            try require(session.submit(red, in: vm, accountID: nil, currentScope: { guest }), "Submit failed")
            await session.waitForCompletion()
            let changed = vm.document
            try require(session.status == .applied && session.appliedEdit?.addedFrameCount == 8, "Actual in-memory receipt absent")
            try require(!(await vm.save()), "Blocked production save falsely succeeded")
            await vm.backToProjects()
            try require(session.saveState(in: vm, currentScope: guest) == .unsaved && vm.isEditing && vm.isDirty
                && vm.message?.contains("Save failed") == true && vm.document == changed && session.submittedDraft == red,
                "Storage failure lost content/draft or was called saved")
            try fm.removeItem(at: store.animationsDir); try fm.moveItem(at: preserved, to: store.animationsDir)
            try require(await vm.save(), "Production retry failed")
            try require(session.saveState(in: vm, currentScope: guest) == .saved, "Real retry state was not current")
            let saved = try store.loadAnimation(id: changed.id)!
            try require(try StudioDocumentArchive.decode(saved.editableDocumentData!).document == changed,
                        "Real retry changed receipt identities or content")
        }
        try await test("replay bookkeeping is bounded and never evicts an accepted submission token") {
            let (vm, _) = try await fixture("request-bound"), session = SpatterStudioEditSession(), first = UUID(), before = vm.document
            for index in 0..<SpatterStudioEditSession.maximumSubmissions {
                try require(session.submit("Unsupported explicit input", in: vm, accountID: nil, submissionID: index == 0 ? first : UUID(), currentScope: { guest }), "Session stopped before documented bound")
                await session.waitForCompletion()
            }
            try require(!session.submit(red, in: vm, accountID: nil, currentScope: { guest }), "Session limit silently evicted IDs")
            try require(!session.submit(red, in: vm, accountID: nil, submissionID: first, currentScope: { guest })
                && vm.document == before && !vm.canUndo, "Old accepted token replayed after bounded history")
        }
        try await test("old cancelled completion cannot replace or duplicate a later successful request") {
            let (vm, _) = try await fixture("late-old"), gate = Gate()
            let session = SpatterStudioEditSession(checkpoint: { try await gate.pause() })
            try require(session.submit(red, in: vm, accountID: nil, currentScope: { guest }), "First request rejected")
            try await gate.waitFor(1)
            var observerStarted = false
            let oldCompletion = Task { @MainActor in observerStarted = true; await session.waitForCompletion() }
            while !observerStarted { await Task.yield() }
            try require(session.cancel(), "Old request did not cancel")
            try require(session.submit(green, in: vm, accountID: nil, currentScope: { guest }), "New request rejected after cancel")
            try await gate.waitFor(2); try gate.release(2); try await gate.waitFor(3); try gate.release(3)
            await session.waitForCompletion()
            let changed = vm.document, receiptID = session.appliedEdit?.receipt.requestID
            try gate.release(1); await oldCompletion.value
            try require(session.status == .applied && session.appliedEdit?.receipt.requestID == receiptID
                && session.appliedEdit?.addedFrameCount == 5 && session.submittedDraft == green && vm.document == changed,
                "Old cancelled task overwrote the latest receipt/draft or edited again")
        }
        try await test("session does not retain the Studio VM while waiting before preparation") {
            let store = storage("released-vm")
            var vm: StudioViewModel? = StudioViewModel(storage: store)
            try require(await vm!.createProject(name: "Released", width: 128, height: 96, fps: 12), "Create failed")
            weak var weakVM = vm
            let gate = Gate(), session = SpatterStudioEditSession(checkpoint: { try await gate.pause() })
            try require(session.submit(red, in: vm!, accountID: nil, currentScope: { guest }), "Submit failed")
            try await gate.waitFor(1); vm = nil
            try require(weakVM == nil, "Pending session retained a VM through a closure cycle")
            weakVM = nil
            try gate.release(1); await session.waitForCompletion()
            try require(session.status == .stale && session.appliedEdit == nil && session.submittedDraft == red,
                        "Released VM produced a fictional receipt")
        }
        try await test("scope mismatches library and oversized drafts reject synchronously without clearing caller input") {
            let (vm, _) = try await fixture("initial-scope"), session = SpatterStudioEditSession(), before = vm.document
            try require(!session.submit(red, in: vm, accountID: "A", currentScope: { .init(isStudioVisible: true, accountID: "B") }), "Wrong account accepted")
            try require(!session.submit(red, in: vm, accountID: nil, currentScope: { .init(isStudioVisible: false, accountID: nil) }), "Non-Studio route accepted")
            let large = String(repeating: "💀", count: 257)
            try require(!session.submit(large, in: vm, accountID: nil, currentScope: { guest }) && large.utf8.count == 1028,
                        "Oversized draft truncated or scheduled")
            await vm.backToProjects()
            try require(!session.submit(red, in: vm, accountID: nil, currentScope: { guest }) && vm.document == before,
                        "Library-only context accepted an edit")
        }
        try await test("actual large-project work rejection preserves the complete document without partial local edits") {
            let store = storage("large-work")
            var document = try StudioDocument.new(name: "Existing large project", width: 128, height: 96, fps: 12)
            let points = Array(repeating: StrokePoint(x: 12, y: 12), count: 100_000)
            document.frames[0].elements = (0..<2).map {
                .init(id: "existing-large-\($0)", tool: .brush, points: points, color: "#0000FF", width: 2, opacity: 1, layerID: document.activeLayerID)
            }
            let metadata = AnimationMetadata(id: document.id, title: document.name, fps: document.fps,
                canvasWidth: document.width, canvasHeight: document.height, frameCount: 1, layerCount: 1,
                createdAt: document.createdAt, modifiedAt: document.modifiedAt, thumbnailData: nil)
            try store.saveAnimation(.init(id: document.id, metadata: metadata, frames: [.init(imageData: nil)], audioTracks: [],
                editableDocumentData: StudioDocumentArchive(document: document, rasterFrameIndices: [:]).encoded()))
            let vm = StudioViewModel(storage: store), session = SpatterStudioEditSession()
            try require(await vm.openProject(metadata), "Existing large project failed to open")
            let before = vm.document
            try require(session.submit(red, in: vm, accountID: nil, currentScope: { guest }), "Preparation was not accepted")
            await session.waitForCompletion()
            try require(session.status == .rejected && session.notice?.contains("too large") == true
                && session.appliedEdit == nil && session.submittedDraft == red && vm.document == before && !vm.isDirty && !vm.canUndo,
                "Work-limit failure changed existing data or produced a false receipt")
        }
        try await test("local recipe session makes zero URLSession HTTP requests") {
            try require(NetworkTrap.count == 0, "Local recipe session contacted a provider or network")
        }
        print("SPATTER_STUDIO_EDIT_SESSION_TESTS=PASS \(passed) complete production session-recipe-command-VM-store cases")
    }
}
