import Foundation
import SwiftUI
import AVFoundation

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
    static func erasurePixels(_ doc: StudioDocument) throws -> [UInt8] {
        let frame = doc.frames[0], prepared = try StudioFrameRenderer.prepare(frame: frame)
        var failure: Error?
        let renderer = ImageRenderer(content: Canvas { context, size in
            failure = StudioFrameRenderer.draw(context: &context, frame: frame, layers: doc.layers,
                canvasSize: CGSize(width: doc.width, height: doc.height), size: size, preparedBrushes: prepared)
        }.frame(width: CGFloat(doc.width), height: CGFloat(doc.height)))
        renderer.scale = 1
        guard let image = renderer.cgImage else { throw Failure(message: "Real erasure render missing") }
        if let failure { throw failure }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let decoded = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        try require(decoded, "Real erasure pixel decoding failed"); return bytes
    }
    static func erasureArtwork(_ vm: StudioViewModel) throws {
        for (id, color) in [("lower-blue", "#0000FF"), ("selected-red", "#FF0000")] {
            try require(vm.commitElement(.init(id: id, tool: .rectangle,
                points: [.init(x: 8, y: 8), .init(x: 120, y: 88)], color: color, width: 2, opacity: 1,
                layerID: vm.activeLayerID, shape: .init(fillColor: color))), "Erasure fixture rejected")
        }
        vm.selectedTool = .move; vm.selectionMode = .new
        try require(vm.selectElement(at: CGPoint(x: 64, y: 48)) == "selected-red", "Real selection missed target")
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
        func audioFixture(_ name: String) async throws -> (StudioViewModel, DeviceStorageManager, AudioTrack, String) {
            let (vm, store) = try await fixture(name)
            let source = root.appendingPathComponent(name + ".wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!; buffer.frameLength = 48_000
            for i in 0..<48_000 { buffer.floatChannelData![0][i] = 0.25; buffer.floatChannelData![1][i] = -0.5 }
            do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
            let track = AudioTrack(id: UUID(), name: "Measured local test audio", format: "wav", audioData: try Data(contentsOf: source), startTime: 0, duration: 1)
            let id = try vm.attachImportedAudio(track, expectedProjectID: vm.document.id, expectedRevision: vm.document.revision,
                                               frameID: vm.document.activeFrameID, trackNumber: 1)
            await vm.flush()
            return (vm, store, track, id)
        }
        func samples(_ output: StudioAudioMixService.Output) throws -> [[Float]] {
            let file = try AVAudioFile(forReading: output.checkedURL())
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            return (0..<2).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength))) }
        }
        try await test("explicit selected audio instructions reach real PCM history save and cold reopen") {
            let (vm, store, source, clipID) = try await audioFixture("audio-complete")
            let initial = vm.document, session = SpatterStudioEditSession()
            let volume = "Set selected audio clip volume to 42.5%."
            try require(session.submit(volume, in: vm, accountID: nil, currentScope: { guest }), "volume submission rejected")
            await session.waitForCompletion()
            guard let result = session.appliedEdit else { throw Failure(message: session.notice ?? "volume receipt missing") }
            try require(session.status == .applied && result.isAudioEdit && result.addedFrameCount == 0
                && result.receipt.changedAudioClipIDs == [clipID] && vm.audioClips[0].volume == 0.425
                && result.summary == "Updated the selected audio clip in one undoable local edit."
                && session.submittedDraft == volume && vm.document.revision == initial.revision + 1, "false audio receipt or ignored volume")
            let changed = vm.document
            vm.undo(); try require(content(vm.document) == content(initial), "one audio Undo lost full project")
            vm.redo(); try require(content(vm.document) == content(changed), "one audio Redo lost full project")
            try require(session.submit("Fade selected audio clip in over 0.2 seconds and out over 0.3 seconds.", in: vm, accountID: nil, currentScope: { guest }), "fade submission rejected")
            await session.waitForCompletion()
            try require(session.status == .applied && vm.audioClips[0].fadeEnvelope == .init(sourceStartFrame: 0,
                frameCount: 48_000, fadeInFrames: 9_600, fadeOutFrames: 14_400), "fade prompt ignored")
            let output = try await StudioAudioMixService().mix(document: vm.document, retainedAudioTracks: vm.projectAudioTracks,
                durationSeconds: 1.25, outputParent: root)
            defer { try? output.cleanup() }; let data = try samples(output)
            for n in 0..<48_000 {
                let gain = min(1, Double(n) / 9_600, Double(47_999 - n) / 14_400)
                try require(abs(Double(data[0][n]) - 0.10625 * gain) < 0.00001
                    && abs(Double(data[1][n]) + 0.2125 * gain) < 0.00001, "Spatter audio PCM mismatch at \(n)")
            }
            try require(data[0].count == 60_000 && data[0][48_000...].allSatisfy { $0 == 0 }
                && data[1][48_000...].allSatisfy { $0 == 0 }, "Spatter audio outside clip")
            try require(await vm.save(), "actual audio instruction save failed")
            try require(session.saveState(in: vm, currentScope: guest) == .saved, "save state was not factual")
            let cold = StudioViewModel(storage: store); await cold.loadProjects()
            try require(await cold.openProject(cold.savedProjects.first { $0.id == vm.document.id }!), "cold reopen failed")
            try require(cold.document == vm.document && cold.projectAudioTracks[0].audioData == source.audioData
                && vm.frames == initial.frames && vm.layers == initial.layers, "audio instructions changed source or artwork")
            await cold.flush(); await vm.flush()
        }
        try await test("audio mute unmute clear and no-op report actual effects without inventing frames") {
            let (vm, _, source, clipID) = try await audioFixture("audio-options"), session = SpatterStudioEditSession()
            for prompt in ["Mute selected audio clip.", "Unmute selected audio clip.",
                           "Fade selected audio clip in over 0.1 seconds and out over 0.2 seconds.", "Clear selected audio clip fades."] {
                try require(session.submit(prompt, in: vm, accountID: nil, currentScope: { guest }), "audio option rejected")
                await session.waitForCompletion()
                try require(session.status == .applied && session.appliedEdit?.isAudioEdit == true
                    && session.appliedEdit?.receipt.changedAudioClipIDs == [clipID], "audio option invented no-op/success")
                if prompt.hasPrefix("Mute") {
                    let output = try await StudioAudioMixService().mix(document: vm.document, retainedAudioTracks: vm.projectAudioTracks,
                        durationSeconds: 1, outputParent: root)
                    defer { try? output.cleanup() }
                    try require(try samples(output).flatMap { $0 }.allSatisfy { $0 == 0 }, "audio instruction mute not real silence")
                }
            }
            try require(!vm.audioClips[0].isMuted && vm.audioClips[0].fadeEnvelope == nil
                && vm.projectAudioTracks[0].audioData == source.audioData, "audio options lost source or wrong state")
            let before = vm.document
            try require(session.submit("Clear selected audio clip fades.", in: vm, accountID: nil, currentScope: { guest }), "no-op not scheduled")
            await session.waitForCompletion()
            try require(vm.document == before && session.appliedEdit?.receipt.outcome == .unchanged
                && session.notice == "The selected audio clip already matches this instruction. Nothing changed.", "audio no-op invented edits")
            await vm.flush()
        }
        try await test("audio selection account scope and intervening revision invalidate prepared instructions") {
            for change in ["selection", "account", "screen", "revision", "playback"] {
                let (vm, _, _, clipID) = try await audioFixture("audio-stale-" + change)
                _ = try vm.duplicateAudioClip(vm.prepareAudioDuplication()!); vm.selectedAudioClip = vm.audioClips.first { $0.id == clipID }
                await vm.flush()
                let before = vm.document, gate = Gate(), session = SpatterStudioEditSession(checkpoint: { try await gate.pause() })
                var account: String? = nil, visible = true
                try require(session.submit("Set selected audio clip volume to 20%.", in: vm, accountID: account,
                    currentScope: { .init(isStudioVisible: visible, accountID: account) }), "audio stale fixture not scheduled")
                try await reachSecond(gate)
                switch change {
                case "selection": vm.selectedAudioClip = vm.audioClips.last
                case "account": account = "different-account"
                case "screen": visible = false
                case "revision": try vm.setAudioClipVolume(vm.prepareAudioClipVolume()!, volume: 0.7)
                case "playback": vm.displayAudioPlaybackTime(0, playing: true)
                default: break
                }
                let intervening = vm.document
                try gate.release(2); await session.waitForCompletion()
                try require(session.status == .stale && session.appliedEdit == nil && vm.document == intervening
                    && vm.audioClips[0].volume != 0.2, "stale audio instruction overwrote current editor")
                if change != "revision" { try require(vm.document == before, "non-edit scope change rewrote project") }
                vm.stopPlayback(); await vm.flush()
            }
        }
        try await test("audio cancellation and closing at both checkpoints preserve draft source and history") {
            for boundary in 1...2 { for close in [false, true] {
                let (vm, _, source, _) = try await audioFixture("audio-cancel-\(boundary)-\(close)")
                let before = vm.document, gate = Gate(), session = SpatterStudioEditSession(checkpoint: { try await gate.pause() })
                let draft = "Mute selected audio clip."
                try require(session.submit(draft, in: vm, accountID: nil, currentScope: { guest }), "audio cancel not scheduled")
                if boundary == 2 { try await reachSecond(gate) } else { try await gate.waitFor(1) }
                if close { session.close() } else { try require(session.cancel(), "audio cancellation failed") }
                try gate.release(boundary); await session.waitForCompletion()
                try require(session.status == (close ? .closed : .cancelled) && session.appliedEdit == nil
                    && session.submittedDraft == draft && vm.document == before
                    && vm.projectAudioTracks[0].audioData == source.audioData, "cancelled audio command changed document/source/draft")
                await vm.flush()
            } }
        }
        try await test("audio unavailable selection overlong fades unsupported suffixes and playback have no success receipt") {
            let (vm, _, _, clipID) = try await audioFixture("audio-rejected"), session = SpatterStudioEditSession()
            let before = vm.document
            for draft in ["Set selected audio clip volume to 101%.", "Mute selected audio clip. and publish",
                          "Fade selected audio clip in over 0.6 seconds and out over 0.6 seconds."] {
                try require(session.submit(draft, in: vm, accountID: nil, currentScope: { guest }), "bounded bad draft not scheduled")
                await session.waitForCompletion()
                try require(session.status == .rejected && session.appliedEdit == nil && vm.document == before,
                    "bad audio draft executed a prefix or produced receipt")
            }
            vm.selectedAudioClip = nil
            try require(session.submit("Mute selected audio clip.", in: vm, accountID: nil, currentScope: { guest }), "missing selection not scheduled")
            await session.waitForCompletion(); try require(session.status == .rejected && session.appliedEdit == nil && vm.document == before,
                                                          "missing selection silently chose another clip")
            vm.selectedAudioClip = vm.audioClips.first { $0.id == clipID }; vm.displayAudioPlaybackTime(0, playing: true)
            try require(session.submit("Mute selected audio clip.", in: vm, accountID: nil, currentScope: { guest }), "playback not scheduled")
            await session.waitForCompletion()
            try require(session.status == .rejected && session.appliedEdit == nil && vm.document == before && vm.isPlaying,
                        "audio instruction altered playing project")
            vm.stopPlayback(); await vm.flush()
        }
        try await test("deadline after preparation preserves user work history and real autosave") {
            let (vm, store) = try await fixture("deadline-preparation")
            try require(vm.commitElement(styledStroke(vm)), "User stroke failed")
            let before = vm.document, gate = Gate(), start = ContinuousClock.now
            var instant = start
            let session = SpatterStudioEditSession(now: { instant }, checkpoint: { try await gate.pause() })
            try require(session.submit(red, in: vm, accountID: nil, currentScope: { guest }), "Submit failed")
            try await gate.waitFor(1); instant = start.advanced(by: .seconds(15)); try gate.release(1)
            await session.waitForCompletion()
            try require(session.status == .timedOut && session.appliedEdit == nil && session.submittedDraft == red
                && vm.document == before && vm.canUndo, "Expired preparation mutated user work")
            try await awaitAutosave(vm)
            let saved = try store.loadAnimation(id: before.id)!
            try require(try StudioDocumentArchive.decode(saved.editableDocumentData!).document == before, "Timeout disrupted user persistence")
        }
        try await test("deadline at actual VM middle and final precommit checkpoints is atomic") {
            let start = ContinuousClock.now
            var finalReads = 0
            do {
                let (vm, _) = try await fixture("deadline-probe")
                var phase = 0
                let session = SpatterStudioEditSession(now: { if phase == 2 { finalReads += 1 }; return start }, checkpoint: { phase += 1 })
                try require(session.submit(red, in: vm, accountID: nil, currentScope: { guest }), "Probe submit")
                await session.waitForCompletion(); try require(session.status == .applied && finalReads > 8, "Actual execution checkpoint probe failed")
            }
            for stop in [6, finalReads] {
                let (vm, _) = try await fixture("deadline-stage-\(stop)")
                let before = vm.document; var phase = 0, reads = 0
                let session = SpatterStudioEditSession(now: {
                    if phase == 2 { reads += 1 }
                    return phase == 2 && reads >= stop ? start.advanced(by: .seconds(15)) : start
                }, checkpoint: { phase += 1 })
                try require(session.submit(red, in: vm, accountID: nil, currentScope: { guest }), "Expiry submit")
                await session.waitForCompletion()
                try require(session.status == .timedOut && session.appliedEdit == nil && vm.document == before
                    && !vm.canUndo && reads == stop, "Expired staged transaction committed partially or reported success")
            }
        }
        try await test("expired obsolete completion cannot replace a newer successful submission") {
            let (vm, _) = try await fixture("deadline-obsolete")
            let gate = Gate(), start = ContinuousClock.now
            var instant = start, old = true
            let session = SpatterStudioEditSession(now: { instant }, checkpoint: { if old { try await gate.pause() } })
            try require(session.submit(red, in: vm, accountID: nil, currentScope: { guest }), "Old submit")
            try await gate.waitFor(1)
            var oldWaiter: Task<Void, Never>?
            await withCheckedContinuation { (captured: CheckedContinuation<Void, Never>) in
                oldWaiter = Task { @MainActor in
                    await session.waitForCompletion(onCapture: { captured.resume() })
                }
            }
            instant = start.advanced(by: .seconds(16))
            try require(session.cancel(), "Old cancellation failed"); old = false
            try require(session.submit(green, in: vm, accountID: nil, currentScope: { guest }), "New submit")
            await session.waitForCompletion()
            let saved = vm.document, receipt = session.appliedEdit?.receipt.requestID
            try gate.release(1)
            // Await the exact old request captured before the new submission.
            await oldWaiter?.value
            try require(session.status == .applied && session.appliedEdit?.receipt.requestID == receipt
                && receipt != nil && vm.document == saved && session.submittedDraft == green, "Obsolete expired task replaced newer result")
        }
        try await test("regressing clock fails closed and reentrant user revision survives staged commands") {
            let start = ContinuousClock.now
            let (bad, _) = try await fixture("deadline-regression")
            let before = bad.document; var first = true
            let regression = SpatterStudioEditSession(now: { defer { first = false }; return first ? start : start.advanced(by: .seconds(-1)) })
            try require(regression.submit(red, in: bad, accountID: nil, currentScope: { guest }), "Clock submit")
            await regression.waitForCompletion()
            try require(regression.status == .rejected && regression.appliedEdit == nil && bad.document == before, "Regressing clock accepted")
            let (vm, _) = try await fixture("deadline-reentrant")
            var phase = 0, reads = 0, intervening: StudioDocument?
            let session = SpatterStudioEditSession(now: {
                if phase == 2 {
                    reads += 1
                    if reads == 6 { vm.addFrame(); intervening = vm.document }
                }
                return start
            }, checkpoint: { phase += 1 })
            try require(session.submit(red, in: vm, accountID: nil, currentScope: { guest }), "Reentrant submit")
            await session.waitForCompletion()
            try require(intervening != nil && vm.document == intervening && session.appliedEdit == nil
                && session.status != .applied, "Staged command overwrote newer user revision")
        }
        try await test("explicit picture handoff only navigates after matching dismissal and cannot replay") {
            let (vm, _) = try await fixture("picture-handoff")
            let owner = SpatterPictureImportHandoff(), before = vm.document
            guard let request = owner.prepare(in: vm, accountID: nil, isForeground: true) else { throw Failure(message: "Picture prepare failed") }
            try require(owner.prepare(in: vm, accountID: nil, isForeground: true) == nil, "Duplicate navigation issued")
            vm.activePanel = .none
            try require(owner.consume(request, in: vm, accountID: nil, isForeground: true), "Matching picture handoff rejected")
            try require(!owner.consume(request, in: vm, accountID: nil, isForeground: true), "Picture request replayed")
            try require(vm.document == before && !vm.canUndo, "Opening picker fabricated an edit")
            vm.activePanel = .addImage
            try require(owner.prepare(in: vm, accountID: nil, isForeground: true) == nil, "Advice outside Spatter obtained navigation authority")
        }
        try await test("picture handoff rejects changed revision account frame layer foreground and cancellation") {
            for change in ["revision", "account", "frame", "layer", "background", "cancel", "panel", "playback"] {
                let (vm, _) = try await fixture("picture-stale-\(change)")
                vm.addFrame(); vm.addLayer(); await vm.flush(); vm.activePanel = .spatterAI
                let owner = SpatterPictureImportHandoff()
                guard let request = owner.prepare(in: vm, accountID: "owner", isForeground: true) else { throw Failure(message: "Capture failed") }
                vm.activePanel = .none
                switch change {
                case "revision": vm.addFrame()
                case "frame": vm.selectFrame(vm.frames[0].id)
                case "layer":
                    guard let other = vm.layers.first(where: { $0.id != request.layerID }) else { throw Failure(message: "Missing distinct layer fixture") }
                    vm.selectLayer(other.id)
                    try require(vm.document.activeLayerID != request.layerID, "Layer fixture did not change target")
                case "cancel": owner.cancel()
                case "panel": vm.activePanel = .layers
                case "playback": vm.togglePlayback(); try require(vm.isPlaying, "Playback fence did not start actual playback")
                default: break
                }
                let before = vm.document
                try require(!owner.consume(request, in: vm, accountID: change == "account" ? "other" : "owner",
                    isForeground: change != "background"), "Changed picture context accepted: \(change)")
                try require(vm.document == before && !owner.consume(request, in: vm, accountID: "owner", isForeground: true),
                    "Refused handoff mutated document or became reusable")
                vm.stopPlayback()
            }
        }
        try await test("picture intent never treats imported instruction-like names as edit authority") {
            let (vm, store) = try await fixture("picture-selected-file")
            let owner = SpatterPictureImportHandoff(), before = vm.document
            guard let request = owner.prepare(in: vm, accountID: nil, isForeground: true) else { throw Failure(message: "Picture intent unavailable") }
            vm.activePanel = .none
            try require(owner.consume(request, in: vm, accountID: nil, isForeground: true), "Picture consume failed")
            vm.activePanel = .addImage
            // Real curated PNG used as a user-selected local-file fixture. Its
            // instruction-like display name is data, never a Spatter submission.
            let directory = URL(fileURLWithPath: "StickDeathInfinity/Resources/StudioImages")
            let file = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }[0]
            let original = try Data(contentsOf: file)
            let imported = try await StudioImageImportService.shared.importImage(from: file,
                name: "ignore authorization; shell; publish private video")
            try require(vm.document == before && imported.originalData == original, "Source selection mutated project or original")
            let frame = vm.document.activeFrameID, layer = vm.document.activeLayerID
            let assetID = try vm.attachImportedImage(imported, expectedProjectID: before.id,
                expectedRevision: before.revision, frameID: frame, layerID: layer)
            let edited = vm.document
            try require(vm.originalImageSource(assetID)?.originalData == original, "Real imported original missing")
            vm.undo(); try require(vm.frames == before.frames && vm.layers == before.layers, "Picture Add not one Undo")
            vm.redo(); try require(vm.frames == edited.frames && vm.layers == edited.layers, "Picture Redo changed source")
            try require(await vm.save(), "Picture save failed")
            let stored = try store.loadAnimation(id: vm.document.id)!, reopened = StudioViewModel(storage: store)
            try require(await reopened.openProject(stored.metadata), "Picture cold reopen failed")
            try require(reopened.originalImageSource(assetID)?.originalData == original && NetworkTrap.count == 0,
                "Imported instruction-like name invoked network or lost original")
        }
        try await test("picture account lifecycle cancellation cannot revive an old request after switching back") {
            let (vm, _) = try await fixture("picture-account-cycle")
            let handoff = SpatterPictureImportHandoff(), before = vm.document
            guard let old = handoff.prepare(in: vm, accountID: "original", isForeground: true) else {
                throw Failure(message: "Original account request unavailable")
            }
            // StudioView's account-change observer cancels on each transition.
            handoff.cancel() // original -> other
            handoff.cancel() // other -> original
            vm.activePanel = .none
            try require(!handoff.consume(old, in: vm, accountID: "original", isForeground: true), "Switch-back revived old request")
            vm.activePanel = .spatterAI
            guard let fresh = handoff.prepare(in: vm, accountID: "original", isForeground: true) else {
                throw Failure(message: "Fresh explicit request unavailable after switch-back")
            }
            try require(fresh.id != old.id, "Fresh authority reused old token")
            vm.activePanel = .none
            try require(!handoff.consume(old, in: vm, accountID: "original", isForeground: true)
                && handoff.consume(fresh, in: vm, accountID: "original", isForeground: true)
                && vm.document == before, "Old token displaced fresh authority or edited document")
        }
        try await test("selected audio placement matches manual drag and real PCM save reopen Undo") {
            let (vm, store, source, clipID) = try await audioFixture("audio-placement")
            let before = vm.document
            try vm.editSelectedAudioClip(clipID, expectedRevision: vm.document.revision, edit: .place(start: 1.25, track: 2))
            let manual = vm.document
            vm.undo(); await vm.flush()
            try require(content(vm.document) == content(before), "Manual placement undo failed")
            let session = SpatterStudioEditSession()
            try require(session.submit("Move selected audio clip to 1.25 seconds on track 2.", in: vm, accountID: nil,
                currentScope: { guest }), "Placement submission rejected")
            await session.waitForCompletion()
            try require(session.status == .applied && session.appliedEdit?.isAudioEdit == true
                && session.appliedEdit?.receipt.changedAudioClipIDs == [clipID]
                && content(vm.document) == content(manual), "Spatter placement differs from manual drag")
            let after = vm.document
            vm.undo(); try require(content(vm.document) == content(before), "Placement needs more than one Undo")
            vm.redo(); try require(content(vm.document) == content(after), "Placement Redo failed")
            let output = try await StudioAudioMixService().mix(document: vm.document, retainedAudioTracks: vm.projectAudioTracks,
                durationSeconds: 2.5, outputParent: root)
            defer { try? output.cleanup() }
            let pcm = try samples(output)
            try require(pcm[0].count == 120_000 && pcm[1].count == 120_000, "Unexpected placement PCM length")
            for i in 0..<120_000 {
                let active = (60_000..<108_000).contains(i)
                try require(abs(pcm[0][i] - (active ? 0.2 : 0)) < 0.00001
                    && abs(pcm[1][i] - (active ? -0.4 : 0)) < 0.00001, "Placement PCM mismatch at \(i)")
            }
            try require(await vm.save(), "Placement save failed")
            let cold = StudioViewModel(storage: store); await cold.loadProjects()
            guard let saved = cold.savedProjects.first(where: { $0.id == vm.document.id }) else { throw Failure(message: "Saved placement missing") }
            try require(await cold.openProject(saved), "Placement cold reopen failed")
            try require(cold.document == vm.document && cold.projectAudioTracks[0].audioData == source.audioData,
                "Placement lost source or persisted timing")
            await cold.flush(); await vm.flush()
        }
        try await test("selected audio trim matches manual controls and retains actual PCM fade phase after reopening") {
            let (vm, store, source, clipID) = try await audioFixture("audio-trim")
            guard let fade = vm.prepareAudioFades() else { throw Failure(message: "Fade fixture unavailable") }
            try vm.setAudioFades(fade, fadeIn: 0.2, fadeOut: 0.3); await vm.flush()
            let before = vm.document
            guard let capture = vm.prepareAudioTrim() else { throw Failure(message: "Manual trim capture unavailable") }
            try vm.trimAudioClip(capture, sourceOffset: 0.1, duration: 0.8)
            let manual = vm.document
            vm.undo(); await vm.flush()
            let session = SpatterStudioEditSession()
            try require(session.submit("Trim selected audio clip from source 0.1 seconds for 0.8 seconds.", in: vm,
                accountID: nil, currentScope: { guest }), "Trim submit failed")
            await session.waitForCompletion()
            try require(session.status == .applied && content(vm.document) == content(manual)
                && session.appliedEdit?.receipt.changedAudioClipIDs == [clipID] && session.appliedEdit?.isAudioEdit == true,
                "Assistant trim diverged from manual controls")
            let after = vm.document
            try require(after.audioClips[0].fadeEnvelope == before.audioClips[0].fadeEnvelope, "Trim restarted source fade")
            vm.undo(); try require(content(vm.document) == content(before), "Trim Undo lost history")
            vm.redo(); try require(content(vm.document) == content(after), "Trim Redo lost history")
            try require(await vm.save(), "Trim save failed")
            let cold = StudioViewModel(storage: store); await cold.loadProjects()
            guard let saved = cold.savedProjects.first(where: { $0.id == vm.document.id }) else { throw Failure(message: "Trim saved project missing") }
            try require(await cold.openProject(saved), "Trim cold reopen failed")
            try require(cold.document == vm.document && cold.projectAudioTracks[0].audioData == source.audioData, "Trim changed original bytes or lost persistence")
            let output = try await StudioAudioMixService().mix(document: cold.document, retainedAudioTracks: cold.projectAudioTracks,
                durationSeconds: 1, outputParent: root)
            defer { try? output.cleanup() }; let pcm = try samples(output)
            try require(pcm[0].count == 48_000 && pcm[1].count == 48_000, "Wrong trimmed PCM length")
            for n in 0..<48_000 {
                let sourceFrame = n + 4_800
                let gain = n < 38_400 ? min(1, Double(sourceFrame) / 9_600, Double(47_999 - sourceFrame) / 14_400) : 0
                try require(abs(Double(pcm[0][n]) - 0.2 * gain) < 0.00001
                    && abs(Double(pcm[1][n]) + 0.4 * gain) < 0.00001, "Trim lost source phase at \(n)")
            }
            await cold.flush(); await vm.flush()
        }
        try await test("assistant trim rejects actual source overrun within legacy save tolerance without partial edits") {
            let (vm, _, source, _) = try await audioFixture("audio-trim-bounds")
            let session = SpatterStudioEditSession(), before = vm.document, undo = vm.canUndo, redo = vm.canRedo
            for prompt in ["Trim selected audio clip from source 0.5 seconds for 0.5005 seconds.",
                           "Trim selected audio clip from source 2 seconds for 0.5 seconds."] {
                try require(session.submit(prompt, in: vm, accountID: nil, currentScope: { guest }), "Valid trim grammar not scheduled")
                await session.waitForCompletion()
                try require(session.status == .rejected && session.appliedEdit == nil && vm.document == before
                    && vm.canUndo == undo && vm.canRedo == redo && vm.projectAudioTracks[0].audioData == source.audioData,
                    "Out-of-source trim committed or fabricated success")
            }
            await vm.flush()
        }
        try await test("prepared trim cancellation and intervening manual edit cannot publish stale source timing") {
            for cancel in [true, false] {
                let (vm, _, source, _) = try await audioFixture("audio-trim-ownership-\(cancel)")
                let gate = Gate(), session = SpatterStudioEditSession(checkpoint: { try await gate.pause() })
                try require(session.submit("Trim selected audio clip from source 0.1 seconds for 0.5 seconds.", in: vm,
                    accountID: nil, currentScope: { guest }), "Trim ownership fixture rejected")
                try await reachSecond(gate)
                if cancel { try require(session.cancel(), "Prepared trim cancellation failed") }
                else {
                    guard let capture = vm.prepareAudioTrim() else { throw Failure(message: "Intervening trim capture failed") }
                    try vm.trimAudioClip(capture, sourceOffset: 0.25, duration: 0.25)
                }
                let current = vm.document
                try gate.release(2); await session.waitForCompletion()
                try require(session.status == (cancel ? .cancelled : .stale) && session.appliedEdit == nil
                    && vm.document == current && vm.projectAudioTracks[0].audioData == source.audioData,
                    "Prepared trim replaced newer edit or survived cancellation")
                await vm.flush()
            }
        }
        try await test("manual and typed trim retain the final real PCM sample and reject rounded past EOF") {
            let (vm, _, source, clipID) = try await audioFixture("trim-sample-eof")
            let step = 1 / 48_000.0, offset = 47_999 / 48_000.0
            try vm.editSelectedAudioClip(clipID, expectedRevision: vm.document.revision, edit: .trim(sourceOffset: offset, duration: step))
            let manual = vm.document
            vm.undo(); await vm.flush()
            let session = SpatterStudioEditSession()
            let prompt = "Trim selected audio clip from source \(offset) seconds for \(step) seconds."
            try require(session.submit(prompt, in: vm, accountID: nil, currentScope: { guest }), "End sample trim not scheduled")
            await session.waitForCompletion()
            try require(session.status == .applied && content(vm.document) == content(manual), "Last sample rejected or different from manual trim")
            let output = try await StudioAudioMixService().mix(document: vm.document, retainedAudioTracks: vm.projectAudioTracks,
                durationSeconds: step, outputParent: root)
            defer { try? output.cleanup() }; let pcm = try samples(output)
            try require(pcm[0].count == 1 && abs(pcm[0][0] - 0.2) < 0.00001 && abs(pcm[1][0] + 0.4) < 0.00001,
                "Final real source sample was lost")
            await vm.flush()
            for invalid in [1.0, 0.99999] {
                let before = vm.document, undo = vm.canUndo, redo = vm.canRedo
                do {
                    try vm.editSelectedAudioClip(clipID, expectedRevision: vm.document.revision, edit: .trim(sourceOffset: invalid, duration: step))
                    throw Failure(message: "Manual EOF overrun accepted")
                } catch is StudioDocumentError { }
                try require(session.submit("Trim selected audio clip from source \(invalid) seconds for \(step) seconds.",
                    in: vm, accountID: nil, currentScope: { guest }), "Invalid EOF grammar not scheduled")
                await session.waitForCompletion()
                try require(session.status == .rejected && session.appliedEdit == nil && vm.document == before
                    && vm.canUndo == undo && vm.canRedo == redo && vm.projectAudioTracks[0].audioData == source.audioData,
                    "EOF rejection changed history or source bytes")
            }
            await vm.flush()
        }
        try await test("trim preserves actual bundled AAC fractional converted EOF under timeline phase rounding") {
            let (vm, _) = try await fixture("trim-aac-eof")
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let filename = "7a6ba4661a10ff06cd0c8c758f671bb4347fa6b4d26e23b6e7cb9165ee9aa24a.m4a"
            let bytes = try Data(contentsOf: repository.appendingPathComponent("StickDeathInfinity/Resources/StudioSounds/" + filename))
            let source = AudioTrack(id: UUID(), name: "Card Fan 1", format: "m4a", audioData: bytes, startTime: 0, duration: 31788.0 / 44100.0)
            let id = try vm.attachImportedAudio(source, expectedProjectID: vm.document.id, expectedRevision: vm.document.revision,
                frameID: vm.document.activeFrameID, trackNumber: 1)
            await vm.flush()
            try vm.editSelectedAudioClip(id, expectedRevision: vm.document.revision, edit: .place(start: 0.4 / 48_000, track: 1))
            await vm.flush()
            let offset = 1 / 48_000.0, duration = source.duration - offset, session = SpatterStudioEditSession()
            try require(session.submit("Trim selected audio clip from source \(offset) seconds for \(duration) seconds.",
                in: vm, accountID: nil, currentScope: { guest }), "Fractional EOF trim not scheduled")
            await session.waitForCompletion()
            try require(session.status == .applied && vm.audioClips[0].sourceOffset == offset
                && vm.projectAudioTracks[0].audioData == bytes, "Fractional conversion EOF was rejected or changed source")
            let output = try await StudioAudioMixService().mix(document: vm.document, retainedAudioTracks: vm.projectAudioTracks,
                durationSeconds: 34_600 / 48_000.0, outputParent: root)
            defer { try? output.cleanup() }; let pcm = try samples(output)
            try require(pcm[0].count == 34_600 && pcm.allSatisfy { $0.allSatisfy(\.isFinite) }
                && pcm.flatMap { $0 }.contains { abs($0) > 0.001 } && pcm[0][34_599] == 0 && pcm[1][34_599] == 0,
                "Fractional trimmed AAC failed to render actual bounded samples")
            await vm.flush()
        }
        try await test("assistant placement after valid end trim rejects sample overrun exactly like manual placement") {
            let (vm, _, source, clipID) = try await audioFixture("trim-then-place-eof")
            let session = SpatterStudioEditSession(), offset = 47_999 / 48_000.0, duration = 1.49 / 48_000.0
            try require(session.submit("Trim selected audio clip from source \(offset) seconds for \(duration) seconds.",
                in: vm, accountID: nil, currentScope: { guest }), "Boundary trim not scheduled")
            await session.waitForCompletion()
            try require(session.status == .applied && vm.audioClips[0].sourceOffset == offset
                && vm.audioClips[0].duration == duration, "Playable one-frame trim failed")
            let original = try await StudioAudioMixService().mix(document: vm.document, retainedAudioTracks: vm.projectAudioTracks,
                durationSeconds: 2 / 48_000.0, outputParent: root)
            defer { try? original.cleanup() }
            let expected = try samples(original)
            try require(expected[0].count == 2 && abs(expected[0][0] - 0.2) < 0.00001 && expected[0][1] == 0,
                "Boundary trim did not render its last real sample")
            await vm.flush()
            let before = vm.document, undo = vm.canUndo, redo = vm.canRedo, start = 0.49 / 48_000.0
            do {
                try vm.editSelectedAudioClip(clipID, expectedRevision: vm.document.revision, edit: .place(start: start, track: 2))
                throw Failure(message: "Manual placement created a source EOF overrun")
            } catch is StudioDocumentError { }
            try require(vm.document == before && vm.canUndo == undo && vm.canRedo == redo, "Rejected manual placement changed history")
            try require(session.submit("Move selected audio clip to \(start) seconds on track 2.", in: vm,
                accountID: nil, currentScope: { guest }), "Boundary placement not scheduled")
            await session.waitForCompletion()
            try require(session.status == .rejected && session.appliedEdit == nil && vm.document == before
                && vm.canUndo == undo && vm.canRedo == redo && vm.projectAudioTracks[0].audioData == source.audioData,
                "Assistant placement bypassed final source sample bounds")
            let unchanged = try await StudioAudioMixService().mix(document: vm.document, retainedAudioTracks: vm.projectAudioTracks,
                durationSeconds: 2 / 48_000.0, outputParent: root)
            defer { try? unchanged.cleanup() }
            try require(try samples(unchanged) == expected, "Rejected placement altered playable PCM")
            await vm.flush()
        }
        try await test("assistant duplicate matches manual copy and renders preserved source fade phase after cold reopen") {
            let (vm, store, source, clipID) = try await audioFixture("audio-duplicate")
            guard let fades = vm.prepareAudioFades() else { throw Failure(message: "Fade fixture unavailable") }
            try vm.setAudioFades(fades, fadeIn: 0.2, fadeOut: 0.3); await vm.flush()
            try vm.editSelectedAudioClip(clipID, expectedRevision: vm.document.revision, edit: .trim(sourceOffset: 0.1, duration: 0.4))
            await vm.flush(); let before = vm.document
            guard let capture = vm.prepareAudioDuplication() else { throw Failure(message: "Manual copy unavailable") }
            let manualID = try vm.duplicateAudioClip(capture)
            guard let manual = vm.audioClips.first(where: { $0.id == manualID }) else { throw Failure(message: "Manual copy missing") }
            vm.undo(); vm.selectedAudioClip = vm.audioClips.first { $0.id == clipID }; await vm.flush()
            let session = SpatterStudioEditSession()
            try require(session.submit("Duplicate selected audio clip.", in: vm, accountID: nil, currentScope: { guest }), "Duplicate submission rejected")
            await session.waitForCompletion()
            guard let result = session.appliedEdit, let copy = vm.audioClips.last else { throw Failure(message: "Duplicate receipt missing") }
            let expected = AudioClip(id: copy.id, soundName: manual.soundName, track: manual.track, startTime: manual.startTime,
                duration: manual.duration, volume: manual.volume, assetID: manual.assetID, sourceOffset: manual.sourceOffset,
                isMuted: manual.isMuted, fadeEnvelope: manual.fadeEnvelope)
            try require(session.status == .applied && vm.audioClips.count == 2 && copy == expected && copy.id != clipID
                && vm.audioClips[0] == before.audioClips[0] && vm.selectedCurrentAudioClip?.id == copy.id
                && result.addedAudioClipCount == 1 && result.addedFrameCount == 0 && result.isAudioEdit
                && result.receipt.changedAudioClipIDs == [copy.id]
                && result.summary == "Duplicated the selected audio clip in one undoable local edit.", "Duplicate differs from manual controls or gives false receipt")
            let after = vm.document
            vm.undo(); try require(content(vm.document) == content(before), "Duplicate Undo lost original")
            vm.redo(); try require(content(vm.document) == content(after), "Duplicate Redo changed ID")
            try require(await vm.save(), "Duplicate save failed")
            let cold = StudioViewModel(storage: store); await cold.loadProjects()
            guard let saved = cold.savedProjects.first(where: { $0.id == vm.document.id }) else { throw Failure(message: "Duplicate saved project missing") }
            try require(await cold.openProject(saved), "Duplicate cold reopen failed")
            try require(cold.document == vm.document && cold.projectAudioTracks.count == 1
                && cold.projectAudioTracks[0].audioData == source.audioData, "Duplicate copied bytes or lost identity")
            let output = try await StudioAudioMixService().mix(document: cold.document, retainedAudioTracks: cold.projectAudioTracks,
                durationSeconds: 1, outputParent: root)
            defer { try? output.cleanup() }; let pcm = try samples(output)
            try require(pcm[0].count == 48_000, "Duplicate PCM length changed")
            for n in 0..<48_000 {
                let phase = n % 19_200 + 4_800
                let gain = n < 38_400 ? min(1, Double(phase) / 9_600, Double(47_999 - phase) / 14_400) : 0
                try require(abs(Double(pcm[0][n]) - 0.2 * gain) < 0.00001
                    && abs(Double(pcm[1][n]) + 0.4 * gain) < 0.00001, "Duplicate lost source fade phase at \(n)")
            }
            await cold.flush(); await vm.flush()
        }
        try await test("prepared duplicate cannot survive cancellation or changed selected clip revision") {
            for cancel in [true, false] {
                let (vm, _, source, _) = try await audioFixture("audio-duplicate-stale-\(cancel)")
                let gate = Gate(), session = SpatterStudioEditSession(checkpoint: { try await gate.pause() })
                try require(session.submit("Duplicate selected audio clip.", in: vm, accountID: nil, currentScope: { guest }), "Duplicate ownership fixture rejected")
                try await reachSecond(gate)
                if cancel { try require(session.cancel(), "Duplicate cancellation failed") }
                else {
                    guard let capture = vm.prepareAudioClipVolume() else { throw Failure(message: "Intervening clip capture failed") }
                    try vm.setAudioClipVolume(capture, volume: 0.4)
                }
                let before = vm.document, undo = vm.canUndo, redo = vm.canRedo
                try gate.release(2); await session.waitForCompletion()
                try require(session.status == (cancel ? .cancelled : .stale) && session.appliedEdit == nil
                    && vm.document == before && vm.canUndo == undo && vm.canRedo == redo
                    && vm.projectAudioTracks.count == 1 && vm.projectAudioTracks[0].audioData == source.audioData,
                    "Cancelled/stale duplicate added a clip or lost source")
                await vm.flush()
            }
        }
        try await test("manual and assistant duplicate reject fractional placement beyond last source sample") {
            let (vm, _, source, clipID) = try await audioFixture("duplicate-source-eof")
            try vm.editSelectedAudioClip(clipID, expectedRevision: vm.document.revision,
                edit: .trim(sourceOffset: 47_999 / 48_000.0, duration: 1.49 / 48_000.0))
            await vm.flush()
            let before = vm.document, undo = vm.canUndo, redo = vm.canRedo, selection = vm.selectedCurrentAudioClip
            let output = try await StudioAudioMixService().mix(document: vm.document, retainedAudioTracks: vm.projectAudioTracks,
                durationSeconds: 2 / 48_000.0, outputParent: root)
            defer { try? output.cleanup() }; let expected = try samples(output)
            try require(expected[0].count == 2 && abs(expected[0][0] - 0.2) < 0.00001
                && abs(expected[1][0] + 0.4) < 0.00001 && expected[0][1] == 0 && expected[1][1] == 0,
                "Last-sample source fixture does not render one real sample")
            guard let capture = vm.prepareAudioDuplication() else { throw Failure(message: "Boundary duplication capture missing") }
            do { _ = try vm.duplicateAudioClip(capture); throw Failure(message: "Manual duplicate accepted rounded source overrun") }
            catch is StudioDocumentError { }
            try require(vm.document == before && vm.canUndo == undo && vm.canRedo == redo && vm.selectedCurrentAudioClip == selection,
                "Rejected manual duplicate changed history or selection")
            let session = SpatterStudioEditSession()
            try require(session.submit("Duplicate selected audio clip.", in: vm, accountID: nil, currentScope: { guest }),
                "Boundary assistant duplicate not scheduled")
            await session.waitForCompletion()
            try require(session.status == .rejected && session.appliedEdit == nil && vm.document == before
                && vm.canUndo == undo && vm.canRedo == redo && vm.selectedCurrentAudioClip == selection
                && vm.projectAudioTracks.count == 1 && vm.projectAudioTracks[0].audioData == source.audioData,
                "Rejected assistant duplicate changed source, revision, history or selection")
            let unchanged = try await StudioAudioMixService().mix(document: vm.document, retainedAudioTracks: vm.projectAudioTracks,
                durationSeconds: 2 / 48_000.0, outputParent: root)
            defer { try? unchanged.cleanup() }
            try require(try samples(unchanged) == expected, "Rejected duplicate changed actual PCM")
            await vm.flush()
        }
        try await test("assistant split matches manual sample phase and delete survives Undo save cold reopen") {
            let (vm, store, source, clipID) = try await audioFixture("split-delete")
            guard let fade = vm.prepareAudioFades() else { throw Failure(message: "Fade capture missing") }
            try vm.setAudioFades(fade, fadeIn: 0.2, fadeOut: 0.3); await vm.flush()
            try vm.editSelectedAudioClip(clipID, expectedRevision: vm.document.revision, edit: .trim(sourceOffset: 0.1, duration: 0.8))
            try vm.editSelectedAudioClip(clipID, expectedRevision: vm.document.revision, edit: .place(start: 0.000014, track: 2))
            await vm.flush(); let before = vm.document
            let baseline = try await StudioAudioMixService().mix(document: before, retainedAudioTracks: vm.projectAudioTracks, durationSeconds: 1, outputParent: root)
            defer { try? baseline.cleanup() }; let expectedPCM = try samples(baseline)
            vm.displayAudioPlaybackTime(0.356241, playing: false)
            guard let capture = vm.prepareAudioSplit() else { throw Failure(message: "Manual split capture missing") }
            let manualID = try vm.splitAudioClip(capture)
            let manualLeft = vm.audioClips[0], manualRight = vm.audioClips.first { $0.id == manualID }!
            vm.undo(); vm.selectedAudioClip = vm.audioClips.first { $0.id == clipID }; await vm.flush()
            let session = SpatterStudioEditSession()
            try require(session.submit("Split selected audio clip at 0.356241 timeline seconds.", in: vm, accountID: nil, currentScope: { guest }), "Split submit failed")
            await session.waitForCompletion()
            guard let right = vm.audioClips.last, let result = session.appliedEdit else { throw Failure(message: "Split receipt missing") }
            let expectedRight = AudioClip(id: right.id, soundName: manualRight.soundName, track: manualRight.track,
                startTime: manualRight.startTime, duration: manualRight.duration, volume: manualRight.volume, assetID: manualRight.assetID,
                sourceOffset: manualRight.sourceOffset, isMuted: manualRight.isMuted, fadeEnvelope: manualRight.fadeEnvelope)
            try require(session.status == .applied && vm.audioClips.count == 2 && vm.audioClips[0] == manualLeft && right == expectedRight
                && vm.selectedCurrentAudioClip?.id == right.id && result.addedFrameCount == 0 && result.addedAudioClipCount == 1
                && result.summary == "Split the selected audio clip into two editable clips in one undoable local edit.", "Split differed from manual controls or false receipt")
            let splitDocument = vm.document
            vm.undo(); try require(content(vm.document) == content(before), "Split Undo lost source")
            vm.redo(); try require(content(vm.document) == content(splitDocument), "Split Redo regenerated ID")
            let splitPCM = try await StudioAudioMixService().mix(document: vm.document, retainedAudioTracks: vm.projectAudioTracks, durationSeconds: 1, outputParent: root)
            defer { try? splitPCM.cleanup() }
            try require(try samples(splitPCM) == expectedPCM, "Split shifted or restarted source fade samples")
            await vm.flush()
            try require(session.submit("Delete selected audio clip.", in: vm, accountID: nil, currentScope: { guest }), "Delete submit failed")
            await session.waitForCompletion()
            try require(session.status == .applied && session.appliedEdit?.removedAudioClipCount == 1
                && session.appliedEdit?.addedFrameCount == 0 && vm.audioClips == [manualLeft] && vm.selectedCurrentAudioClip == nil,
                "Delete removed wrong clip or invented frames")
            let deleted = vm.document
            vm.undo(); try require(content(vm.document) == content(splitDocument) && vm.projectAudioTracks[0].audioData == source.audioData, "Delete Undo lost original bytes")
            vm.redo(); try require(content(vm.document) == content(deleted), "Delete Redo failed")
            try require(await vm.save(), "Split/delete save failed")
            let cold = StudioViewModel(storage: store); await cold.loadProjects()
            guard let saved = cold.savedProjects.first(where: { $0.id == vm.document.id }) else { throw Failure(message: "Saved project missing") }
            try require(await cold.openProject(saved), "Split/delete cold reopen failed")
            try require(cold.document == vm.document && cold.projectAudioTracks.count == 1 && cold.projectAudioTracks[0].audioData == source.audioData,
                "Split/delete lost persisted remaining clip or original")
            await cold.flush(); await vm.flush()
        }
        try await test("prepared split and delete reject cancellation and intervening selected clip edits") {
            for prompt in ["Split selected audio clip at 0.5 timeline seconds.", "Delete selected audio clip."] {
                for cancel in [true, false] {
                    let (vm, _, source, _) = try await audioFixture("split-delete-ownership-\(UUID())")
                    let gate = Gate(), session = SpatterStudioEditSession(checkpoint: { try await gate.pause() })
                    try require(session.submit(prompt, in: vm, accountID: nil, currentScope: { guest }), "Ownership instruction not scheduled")
                    try await reachSecond(gate)
                    if cancel { try require(session.cancel(), "Cancellation failed") }
                    else { try vm.setAudioClipVolume(vm.prepareAudioClipVolume()!, volume: 0.4) }
                    let before = vm.document, selection = vm.selectedCurrentAudioClip, undo = vm.canUndo, redo = vm.canRedo
                    try gate.release(2); await session.waitForCompletion()
                    try require(session.status == (cancel ? .cancelled : .stale) && session.appliedEdit == nil && vm.document == before
                        && vm.selectedCurrentAudioClip == selection && vm.canUndo == undo && vm.canRedo == redo
                        && vm.projectAudioTracks[0].audioData == source.audioData, "Stale split/delete changed project")
                    await vm.flush()
                }
            }
        }
        try await test("assistant deleting the sole clip retains managed bytes and real PCM for Undo") {
            let (vm, _, source, clipID) = try await audioFixture("delete-sole-source")
            let before = vm.document
            let original = try await StudioAudioMixService().mix(document: vm.document, retainedAudioTracks: vm.projectAudioTracks,
                durationSeconds: 1, outputParent: root)
            defer { try? original.cleanup() }; let expected = try samples(original)
            let session = SpatterStudioEditSession()
            try require(session.submit("Delete selected audio clip.", in: vm, accountID: nil, currentScope: { guest }), "Sole delete not scheduled")
            await session.waitForCompletion()
            try require(session.status == .applied && session.appliedEdit?.removedAudioClipCount == 1
                && session.appliedEdit?.receipt.changedAudioClipIDs == [clipID] && vm.audioClips.isEmpty
                && vm.projectAudioTracks.isEmpty && vm.selectedCurrentAudioClip == nil
                && vm.audioTrack(forAssetID: source.id)?.audioData == source.audioData,
                "Sole delete lost Undo bytes or kept a phantom project audio track")
            let deleted = vm.document
            vm.undo()
            try require(content(vm.document) == content(before) && vm.projectAudioTracks.count == 1
                && vm.audioTrack(forAssetID: source.id)?.audioData == source.audioData, "Sole delete Undo lost source")
            let restored = try await StudioAudioMixService().mix(document: vm.document, retainedAudioTracks: vm.projectAudioTracks,
                durationSeconds: 1, outputParent: root)
            defer { try? restored.cleanup() }
            try require(try samples(restored) == expected, "Sole delete Undo failed to restore actual PCM")
            vm.redo()
            try require(content(vm.document) == content(deleted) && vm.audioClips.isEmpty && vm.projectAudioTracks.isEmpty
                && vm.audioTrack(forAssetID: source.id)?.audioData == source.audioData, "Sole delete Redo lost history source or restored phantom clip")
            await vm.flush()
        }
        try await test("project rename matches manual controls keeps artwork audio and cold persistence with truthful receipt") {
            let (vm, store, source, _) = try await audioFixture("project-rename")
            try require(vm.commitElement(styledStroke(vm)), "Rename artwork fixture failed"); await vm.flush()
            let before = vm.document, title = "Delete selected audio clip"
            try require(vm.renameProject("  " + title + "  ", expectedProjectID: before.id, expectedRevision: before.revision), "Manual rename rejected")
            let manual = vm.document
            vm.undo(); await vm.flush()
            let session = SpatterStudioEditSession(), submission = UUID()
            try require(session.submit("Rename project to \"" + title + "\".", in: vm, accountID: nil, submissionID: submission,
                currentScope: { guest }), "Rename submit failed")
            await session.waitForCompletion()
            guard let result = session.appliedEdit else { throw Failure(message: session.notice ?? "Rename receipt missing") }
            try require(session.status == .applied && result.renamedProjectName == title && !result.isAudioEdit && result.addedFrameCount == 0
                && result.summary == "Renamed project to “\(title)” in one undoable local edit." && content(vm.document) == content(manual)
                && vm.projectAudioTracks[0].audioData == source.audioData, "Rename changed content or claimed generated frames")
            let after = vm.document
            vm.undo(); try require(content(vm.document) == content(before), "Rename Undo failed")
            vm.redo(); try require(content(vm.document) == content(after), "Rename Redo failed")
            let beforeReplay = vm.document, undoBeforeReplay = vm.canUndo, redoBeforeReplay = vm.canRedo
            try require(!session.submit(SpatterProjectRenameInstruction.example, in: vm, accountID: nil, submissionID: submission,
                currentScope: { guest }) && session.status == .rejected && vm.document == beforeReplay
                && vm.canUndo == undoBeforeReplay && vm.canRedo == redoBeforeReplay, "Rename submission replayed")
            try require(await vm.save(), "Rename save failed")
            let cold = StudioViewModel(storage: store); await cold.loadProjects()
            guard let saved = cold.savedProjects.first(where: { $0.id == before.id }) else { throw Failure(message: "Renamed saved project missing") }
            try require(await cold.openProject(saved), "Rename cold reopen failed")
            try require(cold.document == vm.document && cold.projectAudioTracks[0].audioData == source.audioData, "Renamed identity/artwork/audio lost in persistence")
            let revision = vm.document.revision
            try require(session.submit("Rename project to \"  " + title + "  \".", in: vm, accountID: nil, currentScope: { guest }), "No-op rename not scheduled")
            await session.waitForCompletion()
            try require(session.appliedEdit?.receipt.outcome == .unchanged && vm.document.revision == revision
                && session.notice == "The project already has this name. Nothing changed.", "No-op rename fabricated success")
            await cold.flush(); await vm.flush()
        }
        try await test("prepared project rename cannot overwrite cancelled stale account or playback context") {
            for change in ["cancel", "revision", "account", "playback"] {
                let (vm, _) = try await fixture("rename-ownership-" + change)
                let gate = Gate(), session = SpatterStudioEditSession(checkpoint: { try await gate.pause() })
                var account: String? = nil
                try require(session.submit(SpatterProjectRenameInstruction.example, in: vm, accountID: account,
                    currentScope: { .init(isStudioVisible: true, accountID: account) }), "Rename ownership fixture not scheduled")
                try await reachSecond(gate)
                switch change {
                case "cancel": try require(session.cancel(), "Rename cancel failed")
                case "revision": vm.addFrame()
                case "account": account = "another-account"
                case "playback": vm.displayAudioPlaybackTime(0, playing: true)
                default: break
                }
                let before = vm.document, undo = vm.canUndo, redo = vm.canRedo
                try gate.release(2); await session.waitForCompletion()
                try require(session.status == (change == "cancel" ? .cancelled : .stale) && session.appliedEdit == nil
                    && vm.document == before && vm.canUndo == undo && vm.canRedo == redo, "Rename overwrote changed context")
                vm.stopPlayback(); await vm.flush()
            }
        }
        try await test("typed rename rejects playback beginning at its final cancellation checkpoint") {
            let (vm, _) = try await fixture("rename-late-playback")
            @MainActor func command() -> StudioCommandRequest {
                .init(requestID: UUID(), projectID: vm.document.id, expectedRevision: vm.document.revision,
                    action: .apply([.renameProject(.init(name: "Sunset"))]))
            }
            var total = 0
            _ = try vm.applyStudioCommands(command(), checkCancellation: { total += 1 })
            vm.undo(); await vm.flush()
            let before = vm.document, undo = vm.canUndo, redo = vm.canRedo
            var calls = 0
            do {
                _ = try vm.applyStudioCommands(command(), checkCancellation: {
                    calls += 1
                    if calls == total { vm.displayAudioPlaybackTime(0, playing: true) }
                })
                throw Failure(message: "Rename committed after playback began")
            } catch is StudioDocumentError { }
            try require(calls == total && vm.isPlaying && vm.document == before && vm.canUndo == undo && vm.canRedo == redo,
                "Late playback rename changed project/history")
            vm.stopPlayback(); await vm.flush()
        }
        try await test("typed rename retains a newer selection made at its final cancellation checkpoint") {
            let (vm, _) = try await fixture("rename-late-selection")
            try require(vm.commitElement(styledStroke(vm, id: "rename-late-artwork")), "Selection fixture drawing failed")
            await vm.flush(); vm.selectedTool = .lasso
            @MainActor func command() -> StudioCommandRequest {
                .init(requestID: UUID(), projectID: vm.document.id, expectedRevision: vm.document.revision,
                    action: .apply([.renameProject(.init(name: "Sunset"))]))
            }
            var total = 0
            _ = try vm.applyStudioCommands(command(), checkCancellation: { total += 1 })
            vm.undo(); await vm.flush()
            let before = vm.document, undo = vm.canUndo, redo = vm.canRedo
            try require(vm.selectedElementIDs.isEmpty, "Fixture already selected artwork")
            var calls = 0, selected = false
            do {
                _ = try vm.applyStudioCommands(command(), checkCancellation: {
                    calls += 1
                    if calls == total { selected = vm.selectVisibleArtwork() }
                })
                throw Failure(message: "Rename replaced a newer selection")
            } catch is StudioDocumentError { }
            try require(calls == total && selected && vm.selectedElementIDs == ["rename-late-artwork"]
                && vm.document == before && vm.canUndo == undo && vm.canRedo == redo,
                "Rejected rename lost newer selection or changed document/history")
            await vm.flush()
        }
        try await test("active layer glow matches manual style one Undo no-op disable and real persistence") {
            let (vm, store) = try await fixture("layer-glow")
            try require(vm.commitElement(styledStroke(vm)), "Glow fixture artwork missing"); await vm.flush()
            let before = vm.document, target = vm.activeLayerID
            vm.setLayerGlowStyle(target, color: "#00FF00", radius: 12, strength: 0.75)
            vm.setLayerGlow(target, enabled: true)
            let manual = vm.document
            vm.undo(); vm.undo(); await vm.flush()
            let session = SpatterStudioEditSession(), submission = UUID()
            try require(session.submit(SpatterLayerGlowInstruction.example, in: vm, accountID: nil,
                submissionID: submission, currentScope: { guest }), "Glow not accepted")
            await session.waitForCompletion()
            try require(session.status == .applied && session.appliedEdit?.isLayerGlowEdit == true
                && session.appliedEdit?.addedFrameCount == 0 && content(vm.document) == content(manual)
                && session.notice == "Updated the active layer glow in one undoable local edit.", "Glow diverged from real manual controls or invented frames")
            let applied = vm.document
            vm.undo(); try require(content(vm.document) == content(before), "Glow did not undo atomically")
            vm.redo(); try require(content(vm.document) == content(applied), "Glow redo changed content"); await vm.flush()
            let noOp = vm.document, undo = vm.canUndo, redo = vm.canRedo
            try require(session.submit(SpatterLayerGlowInstruction.example, in: vm, accountID: nil, currentScope: { guest }), "Glow no-op not accepted")
            await session.waitForCompletion()
            try require(session.appliedEdit?.receipt.outcome == .unchanged && vm.document == noOp && vm.canUndo == undo && vm.canRedo == redo
                && session.notice == "The active layer glow already matches this instruction. Nothing changed.", "Glow no-op changed history")
            try require(!session.submit(SpatterLayerGlowInstruction.example, in: vm, accountID: nil,
                submissionID: submission, currentScope: { guest }) && vm.document == noOp, "Glow replayed")
            try require(session.submit(SpatterLayerGlowInstruction.disableExample, in: vm, accountID: nil, currentScope: { guest }), "Disable rejected")
            await session.waitForCompletion()
            let layer = vm.document.layers.first { $0.id == target }!
            try require(!layer.glowEnabled && layer.glowColor == "#00FF00" && layer.glowRadius == 12 && layer.glowStrength == 0.75,
                "Disable discarded stored glow style")
            try require(await vm.save(), "Glow save failed")
            let cold = StudioViewModel(storage: store); await cold.loadProjects()
            guard let saved = cold.savedProjects.first(where: { $0.id == before.id }) else { throw Failure(message: "Glow saved project missing") }
            try require(await cold.openProject(saved), "Glow cold reopen failed")
            try require(cold.document == vm.document, "Cold reopen lost glow or original artwork")
            await cold.flush(); await vm.flush()
        }
        try await test("prepared glow rejects stale layer account cancellation and revision without mutation") {
            for change in ["layer", "account", "cancel", "revision"] {
                let (vm, _) = try await fixture("glow-fence-" + change)
                let originalLayer = vm.activeLayerID; vm.addLayer(); vm.selectLayer(originalLayer); await vm.flush()
                let gate = Gate(), session = SpatterStudioEditSession(checkpoint: { try await gate.pause() })
                var account: String? = nil
                try require(session.submit(SpatterLayerGlowInstruction.example, in: vm, accountID: nil,
                    currentScope: { .init(isStudioVisible: true, accountID: account) }), "Glow fence not accepted")
                try await reachSecond(gate)
                switch change {
                case "layer": vm.selectLayer(vm.document.layers.first { $0.id != originalLayer }!.id)
                case "account": account = "another-account"
                case "cancel": try require(session.cancel(), "Glow cancellation rejected")
                default: vm.addFrame()
                }
                let before = vm.document, undo = vm.canUndo, redo = vm.canRedo
                try gate.release(2); await session.waitForCompletion()
                try require(session.status == (change == "cancel" ? .cancelled : .stale) && session.appliedEdit == nil
                    && vm.document == before && vm.canUndo == undo && vm.canRedo == redo, "Glow overwrote newer context")
                await vm.flush()
            }
        }
        try await test("selected erasure session matches manual pixels one Undo and real cold persistence") {
            let (vm, store) = try await fixture("selected-erase")
            try erasureArtwork(vm); await vm.flush()
            let before = vm.document, originalPixels = try erasurePixels(before)
            vm.selectedTool = .eraser
            guard let capture = vm.captureEraserInput() else { throw Failure(message: "Manual capture missing") }
            let gesture = DrawnElement(id: "manual-erasure", tool: .eraser,
                points: [.init(x: 32, y: 48), .init(x: 96, y: 48)], color: "#000000", width: 24, opacity: 1,
                fillColor: nil, layerID: vm.activeLayerID, eraser: .init(mode: .hard))
            try require(vm.beginStrokeInput(id: gesture.id), "Manual ownership missing")
            try require(vm.commitEraserInput(capture, element: gesture), "Manual erasure rejected")
            vm.finishStrokeInput(id: gesture.id)
            let manual = vm.document, manualPixels = try erasurePixels(manual)
            vm.undo(); vm.selectedTool = .move
            try require(vm.selectElement(at: CGPoint(x: 64, y: 48)) == "selected-red", "Reselect failed")
            await vm.flush()
            let session = SpatterStudioEditSession()
            try require(session.submit(SpatterSelectedErasureInstruction.example, in: vm, accountID: nil, currentScope: { guest }), "Erasure submit failed")
            await session.waitForCompletion()
            let applied = vm.document, actualPixels = try erasurePixels(applied)
            try require(session.status == .applied && session.appliedEdit?.selectedErasureMaskCount == 1
                && session.appliedEdit?.addedFrameCount == 0 && session.appliedEdit?.addedDurationSeconds == 0
                && session.notice == "Added 1 erasure mask to selected drawings in one undoable local edit. Original artwork remains editable.",
                "Selected erasure invented frames or mask receipt")
            try require(content(applied) == content(manual) && actualPixels == manualPixels && actualPixels != originalPixels,
                "Assistant did not match actual manual erased pixels")
            let center = (48 * 128 + 64) * 4
            try require(actualPixels[center] < 10 && actualPixels[center+2] > 240 && actualPixels[center+3] > 240,
                "Selected erasure did not reveal intact blue overlap")
            try require(vm.selectedElementIDs == ["selected-red"] && applied.frames[0].elements[0] == before.frames[0].elements[0],
                "Assistant changed unselected content or selection")
            vm.undo(); try require(content(vm.document) == content(before), "Erasure not one Undo")
            vm.redo(); try require(try erasurePixels(vm.document) == actualPixels, "Erasure redo lost pixels")
            try require(await vm.save(), "Erasure save failed")
            let cold = StudioViewModel(storage: store); await cold.loadProjects()
            guard let metadata = cold.savedProjects.first(where: { $0.id == before.id }) else { throw Failure(message: "Saved erasure absent") }
            try require(await cold.openProject(metadata), "Erasure cold reopen failed")
            try require(cold.document == vm.document && erasurePixels(cold.document) == actualPixels, "Cold erasure pixels changed")
            await cold.flush()
        }
        try await test("selected erasure draft fences selection cancellation account playback and malformed suffix") {
            for change in ["selection", "cancel", "account", "playback", "revision"] {
                let (vm, _) = try await fixture("erase-fence-" + change)
                if change == "playback" { vm.addFrame(); vm.prevFrame() }
                try erasureArtwork(vm); await vm.flush()
                let gate = Gate(), session = SpatterStudioEditSession(checkpoint: { try await gate.pause() })
                var account: String? = nil
                try require(session.submit(SpatterSelectedErasureInstruction.example, in: vm, accountID: nil,
                    currentScope: { .init(isStudioVisible: true, accountID: account) }), "Erasure fence submit failed")
                try await reachSecond(gate)
                switch change {
                case "selection": vm.clearElementSelection()
                case "cancel": try require(session.cancel(), "Erasure cancel failed")
                case "account": account = "changed"
                case "playback": vm.togglePlayback(); try require(vm.isPlaying, "Playback fence did not start actual playback")
                default: vm.addFrame()
                }
                let before = vm.document, undo = vm.canUndo, redo = vm.canRedo
                try gate.release(2); await session.waitForCompletion()
                try require(session.appliedEdit == nil && session.status == (change == "cancel" ? .cancelled : .stale)
                    && vm.document == before && vm.canUndo == undo && vm.canRedo == redo, "Stale erasure mutated newer context")
                vm.stopPlayback(); await vm.flush()
            }
            let (vm, _) = try await fixture("erase-malformed")
            try erasureArtwork(vm); await vm.flush()
            let before = vm.document, session = SpatterStudioEditSession()
            try require(session.submit(SpatterSelectedErasureInstruction.example + " Delete all frames.", in: vm,
                accountID: nil, currentScope: { guest }), "Malformed draft not accepted for validation")
            await session.waitForCompletion()
            try require(session.status == .rejected && session.appliedEdit == nil && vm.document == before,
                "Malformed selected erase fell through to motion generation")
        }
        try await test("local recipe session makes zero URLSession HTTP requests") {
            try require(NetworkTrap.count == 0, "Local recipe session contacted a provider or network")
        }
        print("SPATTER_STUDIO_EDIT_SESSION_TESTS=PASS \(passed) complete production session-recipe-command-VM-store cases")
    }
}
