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
    static func largeProject(_ storage: DeviceStorageManager, withMasks: Bool = false) async throws -> StudioViewModel {
        var document = try StudioDocument.new(name: "Large editable project", width: 64, height: 64, fps: 12)
        let points = Array(repeating: StrokePoint(x: 16, y: 16), count: 100_000)
        document.frames[0].elements = (0..<2).map {
            .init(id: "existing-\($0)", tool: .brush, points: points, color: "#FF0000", width: 2,
                  opacity: 1, layerID: document.activeLayerID)
        }
        if withMasks {
            document.schemaVersion = 29
            let target = document.frames[0].elements[0]
            document.frames[0].elements[0].selectionErasures = Array(repeating: .init(
                points: Array(repeating: .init(x: 16, y: 16), count: 4096), width: 10, opacity: 0.5,
                mode: .soft, pathToElement: try target.erasurePlacement().invertedForErasure()), count: 16)
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
            try await test("native Cut entry point pastes across frame layer and cold reopens without extra frames") {
                let storage = store("cut-drawings"), vm = StudioViewModel(storage: store("cut-drawings"))
                try require(await vm.createProject(name: "Cut drawings", width: 64, height: 64, fps: 12), "Cut create failed")
                let source = DrawnElement(id: "cut-source", tool: .line, points: [.init(x: 8, y: 32), .init(x: 56, y: 32)],
                    color: "#FF0000", width: 8, opacity: 1, layerID: vm.activeLayerID)
                try require(vm.commitElement(source), "Cut source rejected")
                vm.selectedTool = .move
                try require(vm.selectElement(at: CGPoint(x: 32, y: 32)) == source.id, "Cut real selection failed")
                await vm.flush()
                let original = vm.document
                try require(vm.canCutSelected && vm.cutSelected(), "Actual Cut command failed")
                try require(vm.frames.count == 1 && vm.currentFrame.elements.isEmpty && vm.canPaste, "Cut made unwanted frame or lost clipboard")
                vm.undo(); try require(vm.currentFrame.elements == [source], "Cut Undo did not restore source")
                vm.redo(); vm.addFrame(); vm.addLayer()
                let count = vm.frames.count, destination = vm.activeLayerID
                vm.pasteClipboard()
                try require(vm.frames.count == count && vm.currentFrame.elements.count == 1
                    && vm.currentFrame.elements[0].id != source.id && vm.currentFrame.elements[0].points == source.points
                    && vm.currentFrame.elements[0].layerID == destination, "Cut cross-frame/layer paste was not exact")
                try require(await vm.save(), "Cut save failed")
                let cold = StudioViewModel(storage: storage); await cold.loadProjects()
                guard let metadata = cold.savedProjects.first(where: { $0.id == original.id }) else { throw Failure(message: "Cut saved project absent") }
                try require(await cold.openProject(metadata), "Cut cold open failed")
                try require(cold.document == vm.document, "Cut cold reopen lost artwork")
                await cold.flush()
            }
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
            try await test("selected erasure wire preserves multi-layer selection history and actual cold storage") {
                let storage = store("selected-eraser"), vm = StudioViewModel(storage: store("selected-eraser"))
                try require(await vm.createProject(name: "Selected erasure", width: 64, height: 64, fps: 12), "Create failed")
                let frame = vm.currentFrame.id
                _ = try vm.applyStudioCommands(command(vm, .apply([draw(vm, id: "first"),
                    .addLayer(.init(name: "Second", result: "second")),
                    .draw(.init(frame: .id(frame), layer: .created("second"), strokes: [
                        .init(id: "second", tool: .line, points: [.init(x: 16, y: 44), .init(x: 40, y: 44)], color: "#0000FF", width: 8, opacity: 1)]))])))
                try require(await vm.save(), "Setup save failed")
                vm.selectedTool = .lasso
                try require(vm.selectVisibleArtwork() && vm.selectedElementIDs == ["first", "second"], "Real multi-layer selection failed")
                vm.selectedTool = .eraser
                let before = vm.document, selection = vm.selectedElementIDs
                let operation = StudioCommand.eraseSelectedElements(.init(frame: .id(frame), layer: .id(vm.activeLayerID),
                    elementIDs: selection.sorted(), points: [.init(x: 28, y: 12), .init(x: 28, y: 52)], width: 10, opacity: 0.5, mode: .soft))
                let receipt = try vm.applyStudioCommands(JSONEncoder().encode(command(vm, .apply([operation]))))
                let changed = vm.document
                try require(receipt.outcome == .applied && vm.selectedElementIDs == selection &&
                    changed.frames[0].elements.allSatisfy { $0.selectionErasures?.count == 1 }, "Typed multi-layer masks or selection missing")
                vm.undo(); try require(content(vm.document) == content(before), "VM Undo lost original sources")
                vm.redo(); try require(content(vm.document) == content(changed), "VM Redo lost masks")
                try require(await vm.save(), "Mask save failed")
                let reopened = StudioViewModel(storage: storage)
                try require(await reopened.openProject(storage.listAnimations().first!), "Mask project did not cold reopen")
                try require(content(reopened.document) == content(changed) && NetworkTrap.count == 0, "Cold storage changed masks or contacted network")
            }
            try await test("selected erasure rejects changed live selection or tool during staging") {
                let vm = StudioViewModel(storage: store("selected-eraser-fence"))
                try require(await vm.createProject(name: "Captured eraser", width: 64, height: 64, fps: 12), "Create failed")
                _ = try vm.applyStudioCommands(command(vm, .apply([draw(vm, id: "target")])))
                try require(await vm.save(), "Setup save failed")
                for change in ["selection", "tool"] {
                    vm.selectedTool = .lasso; try require(vm.selectVisibleArtwork(), "Selection failed")
                    vm.selectedTool = .eraser
                    let operation = StudioCommand.eraseSelectedElements(.init(frame: .id(vm.currentFrame.id), layer: .id(vm.activeLayerID),
                        elementIDs: ["target"], points: [.init(x: 28, y: 24)], width: 10, opacity: 1, mode: .hard))
                    let before = vm.document, undo = vm.canUndo, redo = vm.canRedo
                    var calls = 0
                    do {
                        _ = try vm.applyStudioCommands(command(vm, .apply([operation])), checkCancellation: {
                            calls += 1
                            if calls == 4 {
                                if change == "selection" { vm.clearElementSelection() }
                                else { vm.selectedTool = .brush }
                            }
                        })
                        throw Failure(message: "Changed live eraser context committed")
                    } catch StudioDocumentError.unavailable { }
                    try require(calls >= 4 && vm.document == before && vm.canUndo == undo && vm.canRedo == redo,
                        "Rejected erasure replaced an intervening selection/tool change")
                    try require(change == "selection" ? vm.selectedElementIDs.isEmpty : vm.selectedTool == .brush,
                        "Rejected erasure overwrote the newer UI context")
                }
            }
            try await test("existing selected-erasure samples count toward interactive command work") {
                let vm = try await largeProject(store("masked-work-boundary"), withMasks: true)
                let before = vm.document
                do {
                    _ = try vm.applyStudioCommands(command(vm, .apply([strokes(vm, count: 3, prefix: "mask-heavy")])))
                    throw Failure(message: "Nested mask samples were omitted from repeated validation budget")
                } catch StudioDocumentError.unavailable { }
                try require(vm.document == before && !vm.canUndo && !vm.isDirty, "Mask-work rejection changed source or history")
            }
            try await test("styled brush wire commands persist through actual VM cold reopen without network") {
                let storage = store("styled-brush"), vm = StudioViewModel(storage: storage)
                try require(await vm.createProject(name: "Styled commands", width: 64, height: 64, fps: 12), "Styled project creation failed")
                let descriptor = StudioBrushDescriptor(family: .watercolor, seed: UInt64.max, smoothing: 1, pressureEnabled: true, texture: 0.8, grain: 0.4)
                let operation = StudioCommand.draw(.init(frame: .id(vm.currentFrame.id), layer: .id(vm.activeLayerID), strokes: [
                    .init(id: "typed-watercolor", tool: .brush, points: [.init(x: 10, y: 20, pressure: 0.3), .init(x: 48, y: 44, pressure: 0.9)], color: "#0066CC", width: 12, opacity: 0.6, brush: descriptor)]))
                let receipt = try vm.applyStudioCommands(JSONEncoder().encode(command(vm, .apply([operation]))))
                try require(receipt.createdElementIDs == ["typed-watercolor"] && vm.currentFrame.elements.last?.brush == descriptor && vm.document.schemaVersion == 25, "Styled command did not reach actual canonical editor")
                try require(await vm.save(), "Styled command save failed")
                let metadata = storage.listAnimations().first!
                let reopened = StudioViewModel(storage: storage)
                try require(await reopened.openProject(metadata), "Styled command cold reopen failed")
                try require(reopened.currentFrame.elements.last?.brush == descriptor, "Cold reopen lost typed brush settings")
                try require(NetworkTrap.count == 0, "Local styled command made a cloud request")
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
            try await test("frame repeat keeps unique identities and commits one reversible persisted edit") {
                let storage = store("repeat-frame"), vm = StudioViewModel(storage: store("repeat-frame"))
                try require(await vm.createProject(name: "Repeat pose", width: 64, height: 64, fps: 12), "Create failed")
                try vm.applyStudioCommands(command(vm, .apply([draw(vm, id: "pose")])))
                let source = vm.document.activeFrameID
                vm.addFrame()
                let before = vm.document
                try require(vm.repeatFrame(source, additionalCopies: 4), "Repeat refused valid source")
                let after = vm.document
                try require(after.frames.count == 6 && after.revision == before.revision + 1,
                            "Repeat did not commit exactly one revision")
                let poses = after.frames.filter { !$0.elements.isEmpty }
                try require(poses.count == 5 && Set(after.frames.map(\.id)).count == 6
                    && Set(poses.flatMap { $0.elements.map(\.id) }).count == 5,
                    "Repeated content lost editable identity")
                try require(poses.allSatisfy { $0.elements[0].points == poses[0].elements[0].points }, "Repeat changed the pose")
                vm.undo(); try require(content(vm.document) == content(before), "One Undo did not restore original frame selection/content")
                vm.redo(); try require(content(vm.document) == content(after), "Redo did not restore repeat")
                let beforeRejection = vm.document
                try require(!vm.repeatFrame("missing", additionalCopies: 4) && !vm.repeatFrame(source, additionalCopies: 25)
                    && vm.document == beforeRejection, "Rejected repeat changed the project")
                await vm.flush()
                let reopened = StudioViewModel(storage: storage)
                try require(await reopened.openProject(storage.loadAnimation(id: after.id)!.metadata), "Repeated project reopen failed")
                try require(content(reopened.document) == content(after), "Repeat did not persist")
            }
            try await test("frame exposures persist and drive real playback and audio scrubbing") {
                let storage = store("frame-holds"), vm = StudioViewModel(storage: store("frame-holds"))
                try require(await vm.createProject(name: "Exposure", width: 64, height: 64, fps: 12), "Create failed")
                let first = vm.document.activeFrameID; vm.addFrame()
                let second = vm.document.activeFrameID, before = vm.document
                vm.setFrameHold(first, ticks: 3)
                let after = vm.document
                try require(after.schemaVersion == 21 && after.totalTimelineTicks == 4
                    && after.startTick(ofFrame: 1) == 3 && abs(vm.audioDuration - 1.0 / 3.0) < 0.000001,
                    "Canonical exposure timeline is wrong")
                vm.undo(); try require(content(vm.document) == content(before), "Hold Undo failed")
                vm.redo(); try require(content(vm.document) == content(after), "Hold Redo failed")
                vm.selectFrame(first); vm.togglePlayback()
                vm.advancePlaybackFrame(); try require(vm.currentFrame.id == first, "Hold advanced too early")
                vm.advancePlaybackFrame(); try require(vm.currentFrame.id == first, "Hold skipped its final tick")
                vm.advancePlaybackFrame(); try require(vm.currentFrame.id == second, "Playback missed hold boundary")
                vm.stopPlayback(); vm.displayAudioPlaybackTime(2.0 / 12.0, playing: true)
                try require(vm.currentFrame.id == first, "Audio scrub ignored exposure")
                vm.displayAudioPlaybackTime(3.0 / 12.0, playing: true)
                try require(vm.currentFrame.id == second, "Audio scrub boundary was wrong")
                vm.stopPlayback(); vm.copyFrame(first); vm.pasteFrame()
                try require(vm.currentFrame.durationTicks == 3, "Copy/paste lost exposure")
                await vm.flush()
                let loaded = try storage.loadAnimation(id: vm.document.id)!
                let reopened = StudioViewModel(storage: storage)
                try require(await reopened.openProject(loaded.metadata) && reopened.document.frames.map(\.durationTicks) == vm.document.frames.map(\.durationTicks), "Exposure did not survive reopen")
                let request = command(vm, .apply([.setFrameHold(.init(frame: .id(first), ticks: 6))]))
                _ = try vm.applyStudioCommands(JSONEncoder().encode(request))
                try require(vm.document.frames.first { $0.id == first }?.durationTicks == 6
                    && vm.commandScreenContext.document?.frames.first { $0.id == first }?.durationTicks == 6, "Wire exposure/context mismatch")
                let beforeInvalid = vm.document
                do {
                    _ = try vm.applyStudioCommands(command(vm, .apply([.setFrameHold(.init(frame: .id(first), ticks: 601))])))
                    throw Failure(message: "Invalid typed exposure accepted")
                } catch StudioCommandError.invalidSettings { }
                try require(vm.document == beforeInvalid, "Rejected exposure mutated document")
                var clipboardEditor = try StudioDocumentEditor(document: before)
                try clipboardEditor.change { $0.frames[0].holdTicks = 3; $0.schemaVersion = 21 }
                try clipboardEditor.copyFrame(first); clipboardEditor.undo()
                try clipboardEditor.pasteFrame()
                try require(clipboardEditor.document.schemaVersion == 21
                    && clipboardEditor.document.frames.last?.durationTicks == 3, "Clipboard exposure after Undo lost schema")
                var malformed = vm.document; malformed.frames[0].holdTicks = Int.max
                do { try malformed.validate(); throw Failure(message: "Invalid exposure accepted") }
                catch is StudioDocumentError { }
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
            try await test("real menu dismissal handoff consumes once and rejects stale ownership without changing content") {
                let vm = StudioViewModel(storage: store("menu-handoff"))
                try require(await vm.createProject(name: "Menu", width: 64, height: 64, fps: 12), "Menu project creation failed")
                let original = vm.document
                let destinations: [StudioPanelType] = [.projectSettings, .framesViewer, .magicCut, .backgroundLibrary, .rotoscope, .addImage, .aiVoice, .spatterAI]
                for destination in destinations {
                    vm.activePanel = .menu
                    guard let request = vm.prepareMenuHandoff(to: destination, accountID: "owner", isForeground: true) else { throw Failure(message: "Visible menu destination denied") }
                    try require(vm.activePanel == .menu, "Preparation navigated before sheet dismissal")
                    vm.activePanel = .none
                    try require(vm.consumeMenuHandoff(request, accountID: "owner", isForeground: true) && vm.activePanel == destination,
                                "Actual dismissal did not open its captured destination")
                    try require(!vm.consumeMenuHandoff(request, accountID: "owner", isForeground: true), "Menu request replayed")
                }
                try require(vm.document == original && !vm.canUndo, "Navigation changed document/history")
                @MainActor func prepare() throws -> StudioViewModel.MenuHandoff {
                    vm.activePanel = .menu
                    guard let request = vm.prepareMenuHandoff(to: .addImage, accountID: "owner", isForeground: true) else { throw Failure(message: "Menu fixture not eligible") }
                    vm.activePanel = .none
                    return request
                }
                let superseded = try prepare()
                vm.activePanel = .layers; vm.activePanel = .none
                try require(!vm.consumeMenuHandoff(superseded, accountID: "owner", isForeground: true), "Newer panel did not revoke old destination")
                let lifecycle = try prepare()
                vm.cancelMenuHandoff() // Same invalidation used by host background/account/disappearance callbacks.
                try require(!vm.consumeMenuHandoff(lifecycle, accountID: "owner", isForeground: true), "Returning to same account/foreground revived canceled request")
                let account = try prepare()
                try require(!vm.consumeMenuHandoff(account, accountID: "other", isForeground: true) && vm.activePanel == .none, "Cross-account request opened")
                try require(!vm.consumeMenuHandoff(account, accountID: "owner", isForeground: true), "Rejected account request was reusable")
                let background = try prepare()
                try require(!vm.consumeMenuHandoff(background, accountID: "owner", isForeground: false), "Background navigation opened")
                let revision = try prepare()
                vm.addFrame()
                try require(!vm.consumeMenuHandoff(revision, accountID: "owner", isForeground: true), "Edited project accepted stale destination")
                await vm.flush()
                let replacedProject = try prepare()
                await vm.backToProjects()
                try require(await vm.createProject(name: "Other menu project", width: 64, height: 64, fps: 12), "Replacement project failed")
                try require(!vm.consumeMenuHandoff(replacedProject, accountID: "owner", isForeground: true), "Original menu opened in replacement project")
                vm.activePanel = .menu
                try require(vm.prepareMenuHandoff(to: .layers, accountID: "owner", isForeground: true) == nil,
                            "Unadvertised destination was accepted")
                try require(vm.prepareMenuHandoff(to: .addImage, accountID: "owner", isForeground: false) == nil,
                            "Background menu prepared a request")
                await vm.flush()
            }
            try require(NetworkTrap.count == 0, "offline VM command integration attempted a URLSession HTTP request")
            passed += 1; print("PASS no URLSession HTTP requests observed across offline VM command journeys")
            print("STUDIO_COMMAND_INTEGRATION_TESTS=PASS \(passed) production VM cases")
        } catch { print("STUDIO_COMMAND_INTEGRATION_TESTS=FAIL \(error)"); exit(1) }
    }
}
