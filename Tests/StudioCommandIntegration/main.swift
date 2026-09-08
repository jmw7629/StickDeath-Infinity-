import Foundation
import SwiftUI

private struct Failure: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(message: message) }
}
private final class NetworkTrap: URLProtocol {
    private static let lock = NSLock()
    private static var attempts = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    override class func canInit(with request: URLRequest) -> Bool {
        guard ["https", "http"].contains(request.url?.scheme ?? "") else { return false }
        lock.lock(); attempts += 1; lock.unlock(); return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

@main @MainActor struct StudioCommandIntegrationTests {
    static func command(_ vm: StudioViewModel, _ action: StudioCommandAction) -> StudioCommandRequest {
        .init(requestID: UUID(), projectID: vm.document.id, expectedRevision: vm.document.revision, action: action)
    }
    static func draw(_ vm: StudioViewModel, id: String = UUID().uuidString) -> StudioCommand {
        .draw(.init(frame: .id(vm.document.activeFrameID), layer: .id(vm.activeLayerID), strokes: [
            .init(id: id, tool: .brush, points: [.init(x: 16, y: 20), .init(x: 40, y: 30)],
                  color: "#FF0000", width: 4, opacity: 0.8)
        ]))
    }
    static func content(_ document: StudioDocument) -> StudioDocument {
        var result = document; result.revision = 0; result.modifiedAt = result.createdAt; return result
    }
    static func waitForAutosave(_ vm: StudioViewModel) async throws {
        for _ in 0..<200 {
            if !vm.isDirty && !vm.isSaving { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure(message: "Actual production autosave did not complete within four seconds")
    }
    static func largeProject(_ storage: DeviceStorageManager) async throws -> StudioViewModel {
        var document = try StudioDocument.new(name: "Large editable project", width: 64, height: 64, fps: 12)
        let points = Array(repeating: StrokePoint(x: 16, y: 16), count: 100_000)
        document.frames[0].elements = (0..<2).map {
            .init(id: "existing-\($0)", tool: .brush, points: points, color: "#FF0000", width: 2,
                  opacity: 1, layerID: document.activeLayerID)
        }
        let metadata = AnimationMetadata(id: document.id, title: document.name, fps: document.fps,
            canvasWidth: document.width, canvasHeight: document.height, frameCount: 1, layerCount: 1,
            createdAt: document.createdAt, modifiedAt: document.modifiedAt, thumbnailData: nil)
        try storage.saveAnimation(.init(id: document.id, metadata: metadata, frames: [.init(imageData: nil)],
            audioTracks: [], editableDocumentData: StudioDocumentArchive(document: document, rasterFrameIndices: [:]).encoded()))
        let vm = StudioViewModel(storage: storage)
        try require(await vm.openProject(metadata), "large production project did not reopen")
        return vm
    }
    static func strokes(_ vm: StudioViewModel, count: Int, prefix: String) -> StudioCommand {
        .draw(.init(frame: .id(vm.document.activeFrameID), layer: .id(vm.activeLayerID), strokes: (0..<count).map {
            .init(id: "\(prefix)-\($0)", tool: .brush, points: [.init(x: 16, y: 16), .init(x: 17, y: 17)],
                  color: "#00FF00", width: 2, opacity: 1)
        }))
    }
    static func main() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-command-integration-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root); URLProtocol.unregisterClass(NetworkTrap.self) }
        var passed = 0
        func test(_ name: String, _ body: () async throws -> Void) async throws {
            try await body(); passed += 1; print("PASS \(name)")
        }
        func store(_ name: String) -> DeviceStorageManager { .init(documentsDirectory: root.appendingPathComponent(name)) }
        do {
            try require(URLProtocol.registerClass(NetworkTrap.self), "Could not register offline HTTP request trap")
            try require(AppConfig.backendURL == nil, "This offline integration process unexpectedly has backend configuration")
            try await test("library context exposes no stale project and refuses typed/wire commands") {
                let vm = StudioViewModel(storage: store("library"))
                let context = vm.commandScreenContext
                try require(context.route == .library && context.document == nil && context.selectedTool == nil
                            && context.retainedAudio.isEmpty && !context.canApplyCommands, "library exposed an internal placeholder document")
                let request = command(vm, .apply([draw(vm)])), before = vm.document
                for wire in [false, true] {
                    do {
                        if wire { _ = try vm.applyStudioCommands(JSONEncoder().encode(request)) }
                        else { _ = try vm.applyStudioCommands(request) }
                        throw Failure(message: "library accepted an edit")
                    } catch StudioDocumentError.unavailable { }
                }
                try require(vm.document == before && !vm.isEditing && vm.savedProjects.isEmpty, "rejected library command created or changed a project")
            }
            try await test("wire commands through actual VM persist full document and share UI undo/redo") {
                let storage = store("roundtrip"), vm = StudioViewModel(storage: store("roundtrip"))
                try require(await vm.createProject(name: "Commands A", width: 64, height: 64, fps: 12), "create failed")
                let before = vm.document
                let request = command(vm, .apply([
                    .addLayer(.init(name: "Command ink", result: "ink")),
                    .addFrame(.init(after: .id(before.activeFrameID), result: "second")),
                    .draw(.init(frame: .created("second"), layer: .created("ink"), strokes: [
                        .init(id: "editable-stroke", tool: .line, points: [.init(x: 10, y: 10), .init(x: 48, y: 48)],
                              color: "#00FF00", width: 3, opacity: 0.7)
                    ])), .canvasOptions(.init(grid: true, onion: true))
                ]))
                let receipt = try vm.applyStudioCommands(JSONEncoder().encode(request))
                let changed = vm.document
                try require(receipt.outcome == .applied && vm.isDirty && vm.canUndo && changed.frames.count == 2 && changed.layers.count == 2,
                            "VM did not expose actual edit/dirty/undo state")
                try require(receipt.revision == before.revision + 1 && receipt.createdElementIDs == ["editable-stroke"], "wrong transaction receipt")
                vm.undo()
                try require(content(vm.document) == content(before) && vm.canRedo, "ordinary UI undo did not reverse command transaction")
                vm.redo()
                try require(content(vm.document) == content(changed), "ordinary UI redo did not restore command transaction")
                await vm.flush()
                try require(!vm.isDirty, "flush did not persist command document")
                let saved = vm.document
                await vm.backToProjects()
                try require(vm.commandScreenContext.document == nil && vm.savedProjects.count == 1, "library leaked last editing context")
                let reopened = StudioViewModel(storage: storage)
                try require(await reopened.openProject(vm.savedProjects[0]), "reopen failed")
                try require(reopened.document == saved && reopened.frames[1].elements[0].id == "editable-stroke", "actual saved document lost command edits")
                let oldRequest = request
                await reopened.backToProjects()
                try require(await reopened.createProject(name: "Commands B", width: 64, height: 64, fps: 24), "second create failed")
                let second = reopened.document
                do { _ = try reopened.applyStudioCommands(oldRequest); throw Failure(message: "old project response changed new project") }
                catch StudioCommandError.wrongProject { }
                try require(reopened.document == second, "foreign response changed new project")
            }
            try await test("real debounced autosave persists without an explicit save call") {
                let storage = store("autosave"), vm = StudioViewModel(storage: store("autosave"))
                try require(await vm.createProject(name: "Autosave", width: 64, height: 64, fps: 12), "create failed")
                try vm.applyStudioCommands(command(vm, .apply([draw(vm, id: "autosaved")])) )
                try require(vm.isDirty, "edit was incorrectly reported saved before debounce")
                try await waitForAutosave(vm)
                let saved = try storage.loadAnimation(id: vm.document.id)!
                let decoded = try StudioDocumentArchive.decode(saved.editableDocumentData!).document
                try require(decoded == vm.document && decoded.frames[0].elements[0].id == "autosaved", "autosave did not write actual command document")
            }
            try await test("current panel/tool/selection/playhead context and no-op playback preservation") {
                let vm = StudioViewModel(storage: store("context"))
                try require(await vm.createProject(name: "Context", width: 64, height: 64, fps: 12), "create failed")
                try vm.applyStudioCommands(command(vm, .apply([draw(vm, id: "selection")])))
                vm.selectedTool = .move; vm.activePanel = .spatterAI; vm.selectElement(at: CGPoint(x: 20, y: 22))
                let context = vm.commandScreenContext
                try require(context.route == .editor && context.activePanel == .spatterAI && context.selectedTool == .move
                            && context.selectedElementIDs == ["selection"] && context.document?.projectID == vm.document.id,
                            "context does not reflect actual Studio selection and panel")
                vm.addFrame(); await vm.flush()
                vm.togglePlayback(); vm.advancePlaybackFrame()
                let playing = vm.commandScreenContext, priorMessage = vm.message
                let noOp = try vm.applyStudioCommands(command(vm, .apply([.selectFrame(.id(vm.document.activeFrameID))])))
                try require(noOp.outcome == .unchanged && vm.isPlaying && vm.commandScreenContext.displayedFrameID == playing.displayedFrameID
                            && !vm.isDirty && vm.message == priorMessage, "no-op stopped playback or changed save state")
                try vm.applyStudioCommands(command(vm, .apply([.canvasOptions(.init(grid: true, onion: nil))])))
                try require(!vm.isPlaying && vm.isDirty && vm.commandScreenContext.displayedFrameID == vm.document.activeFrameID,
                            "committed transaction did not stop transient playback safely")
                await vm.flush()
            }
            try await test("stale and invalid staged commands preserve VM document/history/playback/errors") {
                let vm = StudioViewModel(storage: store("rollback"))
                try require(await vm.createProject(name: "Rollback", width: 64, height: 64, fps: 12), "create failed")
                let stale = command(vm, .apply([draw(vm)]))
                vm.addFrame(); await vm.flush(); vm.togglePlayback(); vm.advancePlaybackFrame()
                vm.message = "Existing storage notice"
                let before = vm.document, playhead = vm.currentFrameIndex, undo = vm.canUndo, redo = vm.canRedo
                do { _ = try vm.applyStudioCommands(stale); throw Failure(message: "stale context was accepted") }
                catch StudioCommandError.staleRevision { }
                let invalid = command(vm, .apply([.addLayer(.init(name: "Staged only", result: "new")), .selectFrame(.id("not-in-this-project"))]))
                do { _ = try vm.applyStudioCommands(invalid); throw Failure(message: "invalid staged command succeeded") }
                catch StudioCommandError.invalidReference { }
                try require(vm.document == before && vm.canUndo == undo && vm.canRedo == redo && vm.isPlaying
                            && vm.currentFrameIndex == playhead && !vm.isDirty && vm.message == "Existing storage notice", "failure changed VM state")
                vm.stopPlayback()
            }
            try await test("cancellation leaves partial staged commands unpublished and preserves pending user autosave") {
                let storage = store("cancel"), vm = StudioViewModel(storage: store("cancel"))
                try require(await vm.createProject(name: "Cancel", width: 64, height: 64, fps: 12), "create failed")
                vm.commitElement(.init(id: "user-stroke", tool: .brush, points: [.init(x: 8, y: 8), .init(x: 32, y: 32)],
                                       color: "#FF0000", width: 3, opacity: 1, layerID: vm.activeLayerID))
                let before = vm.document
                let request = command(vm, .apply([.addLayer(.init(name: "Cancelled", result: "temporary")), .canvasOptions(.init(grid: true, onion: true))]))
                var checks = 0
                do {
                    try vm.applyStudioCommands(request, checkCancellation: { checks += 1; if checks == 4 { throw CancellationError() } })
                    throw Failure(message: "cancellation was ignored")
                } catch is CancellationError { }
                try require(vm.document == before && vm.isDirty && vm.canUndo, "cancel changed pending user work")
                let task = Task { @MainActor () -> Bool in
                    do { try vm.applyStudioCommands(request); return false }
                    catch is CancellationError { return true }
                    catch { return false }
                }
                task.cancel(); let cancelled = await task.value
                try require(cancelled && vm.document == before, "actual cancelled Task changed VM")
                try await waitForAutosave(vm)
                let saved = try storage.loadAnimation(id: vm.document.id)!
                try require(try StudioDocumentArchive.decode(saved.editableDocumentData!).document == before, "cancel disrupted prior user autosave")
            }
            try await test("storage failure remains dirty and editable; retry saves actual command results") {
                let storage = store("save-failure"), vm = StudioViewModel(storage: store("save-failure"))
                try require(await vm.createProject(name: "Save retry", width: 64, height: 64, fps: 12), "create failed")
                let preserved = root.appendingPathComponent("preserved-animations")
                try fm.moveItem(at: storage.animationsDir, to: preserved)
                try Data("file blocking directory fixture".utf8).write(to: storage.animationsDir)
                let receipt = try vm.applyStudioCommands(command(vm, .apply([draw(vm, id: "unsaved-command")])))
                let changed = vm.document
                let saved = await vm.save(); await vm.backToProjects()
                try require(receipt.outcome == .applied && !saved && vm.isEditing && vm.isDirty && vm.document == changed
                            && vm.message?.contains("Save failed") == true, "failed persistence discarded edits or claimed save success")
                try fm.removeItem(at: storage.animationsDir); try fm.moveItem(at: preserved, to: storage.animationsDir)
                try require(await vm.save(), "storage retry failed")
                let record = try storage.loadAnimation(id: vm.document.id)!
                try require(!vm.isDirty && (try StudioDocumentArchive.decode(record.editableDocumentData!)).document == changed,
                            "retry did not save actual command result")
            }
            try await test("original raster, layer metadata and audio records survive VM command save/reopen") {
                let storage = store("originals"), id = UUID(), now = Date()
                let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jfN0AAAAASUVORK5CYII=")!
                let audio = Data("opaque original audio bytes; no playback claim".utf8), audioID = UUID()
                let metadata = AnimationMetadata(id: id, title: "Originals", fps: 12, canvasWidth: 64, canvasHeight: 64,
                    frameCount: 1, layerCount: 1, createdAt: now, modifiedAt: now, thumbnailData: nil)
                let layer = LayerData(id: UUID(), name: "Original metadata", opacity: 0.4, blendMode: "multiply", locked: true, visible: true)
                try storage.saveAnimation(.init(id: id, metadata: metadata, frames: [.init(imageData: png, layerData: [layer])],
                    audioTracks: [.init(id: audioID, name: "Original audio", format: "wav", audioData: audio, startTime: 0.5, duration: 2)]))
                let vm = StudioViewModel(storage: storage)
                try require(await vm.openProject(metadata), "legacy open failed")
                let context = vm.commandScreenContext
                try require(context.retainedAudio.count == 1 && context.retainedAudio[0].id == audioID && context.retainedAudio[0].hasAudioData
                            && context.retainedAudio[0].startTime == 0.5 && context.retainedAudio[0].timingKnown,
                            "context silently omitted retained audio metadata")
                try vm.applyStudioCommands(command(vm, .apply([draw(vm, id: "over-original"),
                    .duplicateFrame(.init(source: .id(vm.document.activeFrameID), result: "copy"))])))
                await vm.flush(); await vm.backToProjects()
                let loaded = try storage.loadAnimation(id: id)!
                try require(loaded.frames.count == 2 && loaded.frames.allSatisfy({ $0.imageData == png && $0.layerData?.first?.id == layer.id })
                            && loaded.audioTracks[0].audioData == audio, "command persistence lost original records")
                let reopened = StudioViewModel(storage: storage)
                try require(await reopened.openProject(loaded.metadata), "editable reopen failed")
                try require(reopened.frames.count == 2 && reopened.frames.allSatisfy({ $0.elements.count == 1 })
                            && reopened.rasterData(reopened.frames[0].rasterAssetID) == png, "reopen lost editable or original content")
            }
            try await test("audio selection context remains canonical through command undo and redo") {
                let vm = StudioViewModel(storage: store("audio-selection"))
                try require(await vm.createProject(name: "Audio context", width: 64, height: 64, fps: 12), "create failed")
                let clip = AudioClip(id: "selected-audio", soundName: "Opaque metadata; no playback claim", track: 1, startTime: 0, duration: 1)
                vm.audioClips = [clip]; vm.selectedAudioClip = clip
                try require(vm.commandScreenContext.selectedAudioClipID == clip.id, "existing audio selection is missing")
                try vm.applyStudioCommands(command(vm, .undo))
                try require(vm.commandScreenContext.document?.editableAudioClips.isEmpty == true
                    && vm.commandScreenContext.selectedAudioClipID == nil, "undo exposed a deleted audio selection")
                try vm.applyStudioCommands(command(vm, .redo))
                try require(vm.commandScreenContext.document?.editableAudioClips == [clip]
                    && vm.commandScreenContext.selectedAudioClipID == clip.id, "redo context does not reflect restored canonical audio")
                vm.audioClips = []
                try require(vm.commandScreenContext.selectedAudioClipID == nil, "ordinary VM audio change exposed stale selection")
                await vm.flush()
            }
            try await test("large valid batch is rejected before staging and preserves pending user autosave") {
                let storage = store("work-rejection"), vm = try await largeProject(store("work-rejection"))
                vm.commitElement(.init(id: "pending-user-stroke", tool: .brush, points: [.init(x: 8, y: 8)],
                    color: "#FF0000", width: 3, opacity: 1, layerID: vm.activeLayerID))
                vm.addFrame()
                vm.togglePlayback(); vm.message = "Prior notice"
                let before = vm.document, undo = vm.canUndo, redo = vm.canRedo
                let wire = try JSONEncoder().encode(command(vm, .apply([strokes(vm, count: 256, prefix: "oversized")])) )
                let started = Date()
                do { try vm.applyStudioCommands(wire); throw Failure(message: "expensive 200k-point × 256-stroke batch was accepted") }
                catch StudioDocumentError.unavailable(let reason) { try require(reason.contains("smaller batch"), "unrelated work rejection") }
                print("WORK_BUDGET_REJECTION_SECONDS=\(Date().timeIntervalSince(started))")
                try require(vm.document == before && vm.isDirty && vm.canUndo == undo && vm.canRedo == redo
                    && vm.isPlaying && vm.message == "Prior notice", "work rejection changed editor/playback/save state")
                try await waitForAutosave(vm)
                let record = try storage.loadAnimation(id: vm.document.id)!
                try require(try StudioDocumentArchive.decode(record.editableDocumentData!).document == before,
                            "work rejection interrupted pending user autosave")
                vm.stopPlayback()
            }
            try await test("near work-budget boundary accepts three strokes and rejects four without truncation") {
                let vm = try await largeProject(store("work-boundary"))
                let before = vm.document
                let four = command(vm, .apply([strokes(vm, count: 4, prefix: "too-many")]))
                do { try vm.applyStudioCommands(four); throw Failure(message: "over-boundary batch was accepted") }
                catch StudioDocumentError.unavailable { }
                try require(vm.document == before && !vm.isDirty && !vm.canUndo, "boundary rejection partially applied")
                let started = Date()
                let receipt = try vm.applyStudioCommands(command(vm, .apply([strokes(vm, count: 3, prefix: "accepted")])))
                print("WORK_BUDGET_NEAR_BOUND_SECONDS=\(Date().timeIntervalSince(started))")
                try require(receipt.outcome == .applied && receipt.createdElementIDs.count == 3
                    && vm.document.frames[0].elements.count == 5 && vm.document.revision == before.revision + 1,
                    "near-boundary command was truncated or lost atomic history")
                vm.undo(); try require(content(vm.document) == content(before), "near-boundary undo failed")
                await vm.flush()
            }
            try require(NetworkTrap.count == 0, "offline VM command integration attempted a URLSession HTTP request")
            passed += 1; print("PASS no URLSession HTTP requests observed across offline VM command journeys")
            print("STUDIO_COMMAND_INTEGRATION_TESTS=PASS \(passed) production VM cases")
        } catch { print("STUDIO_COMMAND_INTEGRATION_TESTS=FAIL \(error)"); exit(1) }
    }
}
