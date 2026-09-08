import Foundation

private struct Failure: Error { let message: String }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(message: message) }
}
private func fresh() throws -> StudioDocumentEditor {
    var document = try StudioDocument.new(name: "Editable command fixture", width: 512, height: 512, fps: 12)
    document.audioClips = [.init(id: "retained-audio-metadata", soundName: "Existing project audio", track: 1,
                                startTime: 0.25, duration: 2, volume: 0.6)]
    return try StudioDocumentEditor(document: document)
}
private func content(_ document: StudioDocument) -> StudioDocument {
    var value = document; value.revision = 0; value.modifiedAt = value.createdAt
    return value
}
private func request(_ editor: StudioDocumentEditor, _ action: StudioCommandAction) -> StudioCommandRequest {
    .init(requestID: UUID(), projectID: editor.document.id, expectedRevision: editor.document.revision, action: action)
}
private func stroke(id: String = UUID().uuidString, tool: DrawingTool = .brush,
                    points: [StrokePoint] = [StrokePoint(x: 10, y: 20), StrokePoint(x: 90, y: 120)],
                    width: Double = 4, opacity: Double = 0.8, color: String = "#FF0000") -> StudioCommandStroke {
    .init(id: id, tool: tool, points: points, color: color, width: width, opacity: opacity)
}
private func draw(_ editor: StudioDocumentEditor, _ strokes: [StudioCommandStroke]) -> StudioCommand {
    .draw(.init(frame: .id(editor.document.activeFrameID), layer: .id(editor.document.activeLayerID), strokes: strokes))
}
private func rejected(_ request: StudioCommandRequest, editor: inout StudioDocumentEditor,
                      expected: StudioCommandError? = nil,
                      cancellation: () throws -> Void = {}) throws {
    let before = editor.document, undo = editor.canUndo, redo = editor.canRedo, selection = editor.selectedElementIDs
    var thrown: Error?
    do { try StudioCommandExecutor.execute(request, editor: &editor, checkCancellation: cancellation) }
    catch { thrown = error }
    try require(thrown != nil, "invalid request succeeded")
    if let expected { try require(thrown as? StudioCommandError == expected, "unexpected rejection: \(String(describing: thrown))") }
    try require(editor.document == before && editor.canUndo == undo && editor.canRedo == redo && editor.selectedElementIDs == selection,
                "rejected request changed the actual document/history/selection")
}

@main @MainActor struct StudioCommandTests {
    static func main() async {
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body(); passed += 1; print("PASS \(name)")
        }
        do {
            try test("typed JSON roundtrip, strict unknown operation and schema rejection") {
                let editor = try fresh()
                let valid = request(editor, .apply([draw(editor, [stroke()])]))
                let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(valid))
                try require(decoded.requestID == valid.requestID && decoded.projectID == valid.projectID, "wire identity lost")
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as! [String: Any]
                for action in [["apply": [["shell": ["command": "untrusted text only"]]]],
                               ["export": true], ["apply": [["selectLayer": ["id": "x"], "admin": true]]]] as [[String: Any]] {
                    object["action"] = action
                    do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: object)); throw Failure(message: "unknown/mixed operation accepted") }
                    catch is StudioCommandError { }
                }
                object["action"] = ["undo": true]; object["schemaVersion"] = 99
                do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: object)); throw Failure(message: "future schema accepted") }
                catch StudioCommandError.unsupportedCommand { }
                var extra = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as! [String: Any]
                extra["admin"] = "untrusted text only"
                do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: extra)); throw Failure(message: "unknown envelope field accepted") }
                catch StudioCommandError.malformed { }
                extra.removeValue(forKey: "admin")
                extra["action"] = ["apply": [["canvasOptions": ["grid": true, "execute": "untrusted text only"]]]]
                do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: extra)); throw Failure(message: "unknown command argument accepted") }
                catch StudioCommandError.malformed { }
            }
            try test("one mixed actual-document transaction, typed result references, one-step undo/redo") {
                var editor = try fresh(); let before = editor.document
                let commands: [StudioCommand] = [
                    .addLayer(.init(name: "Action", result: "ink")),
                    .draw(.init(frame: .id(before.activeFrameID), layer: .created("ink"), strokes: [stroke(id: "first-stroke")])),
                    .addFrame(.init(after: .id(before.activeFrameID), result: "second")),
                    .draw(.init(frame: .created("second"), layer: .created("ink"), strokes: [stroke(id: "second-stroke", tool: .line)])),
                    .updateLayer(.init(layer: .created("ink"), settings: .init(opacity: 0.5, blend: .multiply, glowEnabled: true))),
                    .canvasOptions(.init(grid: true, onion: true)),
                    .selectFrame(.id(before.activeFrameID))
                ]
                let result = try StudioCommandExecutor.execute(request(editor, .apply(commands)), editor: &editor)
                let after = editor.document
                try require(result.outcome == .applied && result.revision == before.revision + 1, "bulk edit was not one revision")
                try require(after.frames.count == 2 && after.layers.count == 2 && after.frames.allSatisfy({ $0.elements.count == 1 }), "real document construction failed")
                try require(result.created["ink"]?.id == after.layers[0].id && result.created["second"]?.id == after.frames[1].id,
                            "created references did not identify real canonical IDs")
                try require(result.createdElementIDs == ["first-stroke", "second-stroke"] && after.audioClips == before.audioClips,
                            "receipt or retained actual audio metadata is wrong")
                try require(after.layers[0].opacity == 0.5 && after.layers[0].blendMode == "multiply" && after.gridEnabled && after.onionEnabled,
                            "layer/settings operations did not affect actual document")
                let undo = try StudioCommandExecutor.execute(request(editor, .undo), editor: &editor)
                try require(undo.outcome == .undone && content(editor.document) == content(before) && !editor.canUndo && editor.canRedo,
                            "one undo did not reverse entire mixed transaction")
                let redo = try StudioCommandExecutor.execute(request(editor, .redo), editor: &editor)
                try require(redo.outcome == .redone && content(editor.document) == content(after), "redo did not restore full transaction")
            }
            try test("project identity, stale revision and replay reject before editing") {
                var editor = try fresh()
                let valid = request(editor, .apply([draw(editor, [stroke()])]))
                let foreign = StudioCommandRequest(requestID: UUID(), projectID: UUID(), expectedRevision: editor.document.revision, action: valid.action)
                try rejected(foreign, editor: &editor, expected: .wrongProject)
                try StudioCommandExecutor.execute(valid, editor: &editor)
                try rejected(valid, editor: &editor, expected: .staleRevision)
            }
            try test("failure after staged layer creation preserves original document and undo/redo") {
                var editor = try fresh()
                try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, [stroke(id: "retained")])])), editor: &editor)
                let before = editor.document
                let commands: [StudioCommand] = [.addLayer(.init(name: "Never committed", result: "new")),
                    .draw(.init(frame: .id(before.activeFrameID), layer: .created("new"), strokes: [stroke(tool: .smudge)]))]
                try rejected(request(editor, .apply(commands)), editor: &editor, expected: .unsupportedTool)
                try StudioCommandExecutor.execute(request(editor, .undo), editor: &editor)
                try require(editor.document.frames[0].elements.isEmpty, "failed staging polluted previous undo step")
                try StudioCommandExecutor.execute(request(editor, .redo), editor: &editor)
                try require(content(editor.document) == content(before), "failed staging polluted redo")
            }
            try test("cancellation before staging, between commands and before final commit") {
                for cancellationPoint in [1, 3] {
                    var editor = try fresh(); var checkpoints = 0
                    let commands: [StudioCommand] = [.addLayer(.init(name: "Staged", result: "layer"))]
                    try rejected(request(editor, .apply(commands)), editor: &editor, cancellation: {
                        checkpoints += 1; if checkpoints == cancellationPoint { throw CancellationError() }
                    })
                }
                var editor = try fresh(); var checkpoints = 0
                let commands: [StudioCommand] = [.addLayer(.init(name: "Staged", result: "layer")), .canvasOptions(.init(grid: true, onion: true))]
                try rejected(request(editor, .apply(commands)), editor: &editor, cancellation: {
                    checkpoints += 1; if checkpoints == 3 { throw CancellationError() }
                })
            }
            try test("cancellation during point validation leaves no partial stroke") {
                var editor = try fresh(); var checkpoints = 0
                let points = (0..<300).map { StrokePoint(x: CGFloat($0), y: 40) }
                try rejected(request(editor, .apply([draw(editor, [stroke(points: points)])])), editor: &editor, cancellation: {
                    checkpoints += 1; if checkpoints == 5 { throw CancellationError() }
                })
            }
            try test("unknown references, forward aliases, wrong alias kinds and duplicate aliases reject atomically") {
                let cases: [[StudioCommand]] = [
                    [.selectFrame(.id("absent"))], [.selectFrame(.created("future"))],
                    [.addLayer(.init(name: "Layer", result: "kind")), .selectFrame(.created("kind"))],
                    [.addLayer(.init(name: "Layer", result: "duplicate")), .addLayer(.init(name: "Layer2", result: "duplicate"))]
                ]
                for commands in cases { var editor = try fresh(); try rejected(request(editor, .apply(commands)), editor: &editor, expected: .invalidReference) }
            }
            try test("explicit selected deletion only; last-frame and unknown element deletion rejected") {
                var editor = try fresh()
                try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, [stroke(id: "keep"), stroke(id: "remove")])])), editor: &editor)
                let frame = StudioCommandReference.id(editor.document.activeFrameID)
                try rejected(request(editor, .apply([.deleteElements(.init(frame: frame, elementIDs: []))])), editor: &editor, expected: .missingSelection)
                try rejected(request(editor, .apply([.deleteElements(.init(frame: frame, elementIDs: ["not-there"]))])), editor: &editor, expected: .invalidReference)
                try rejected(request(editor, .apply([.deleteFrame(frame)])), editor: &editor, expected: .cannotDeleteLastFrame)
                let result = try StudioCommandExecutor.execute(request(editor, .apply([.deleteElements(.init(frame: frame, elementIDs: ["remove"]))])), editor: &editor)
                try require(editor.document.frames[0].elements.map(\.id) == ["keep"] && result.deletedElementIDs == ["remove"], "explicit deletion result is wrong")
            }
            try test("visibility and full/alpha locks use actual editor rejection with rollback") {
                for mode in ["hidden", "full", "alpha"] {
                    var editor = try fresh()
                    try editor.updateLayer(editor.document.activeLayerID) { layer in
                        if mode == "hidden" { layer.visible = false }
                        else { layer.lockMode = mode; layer.locked = mode == "full" }
                    }
                    try rejected(request(editor, .apply([draw(editor, [stroke()])])), editor: &editor)
                }
            }
            try test("finite geometry, canvas bounds, color and exact shape endpoints are validated") {
                let invalid = [stroke(width: .nan), stroke(opacity: .infinity), stroke(color: "not-a-color"),
                    stroke(points: [.init(x: -1, y: 0)]), stroke(points: [.init(x: 513, y: 0)]),
                    stroke(points: [.init(x: 1, y: 1, pressure: 2)]), stroke(points: []),
                    stroke(tool: .rectangle, points: [.init(x: 1, y: 1)])]
                for value in invalid { var editor = try fresh(); try rejected(request(editor, .apply([draw(editor, [value])])), editor: &editor, expected: .invalidGeometry) }
                for tool in [DrawingTool.fill, .text, .smudge, .blur, .calligraphy] {
                    var editor = try fresh(); try rejected(request(editor, .apply([draw(editor, [stroke(tool: tool)])])), editor: &editor, expected: .unsupportedTool)
                }
            }
            try test("command, encoded bytes, input stroke and point limits fail closed") {
                var editor = try fresh()
                let noOp = StudioCommand.selectFrame(.id(editor.document.activeFrameID))
                try rejected(request(editor, .apply(Array(repeating: noOp, count: StudioCommandExecutor.maximumCommands + 1))), editor: &editor, expected: .limitExceeded)
                try rejected(request(editor, .apply([])), editor: &editor, expected: .limitExceeded)
                try rejected(request(editor, .apply([draw(editor, Array(repeating: stroke(), count: 257))])), editor: &editor, expected: .limitExceeded)
                let tooManyPoints = Array(repeating: StrokePoint(x: 10, y: 20), count: 4097)
                try rejected(request(editor, .apply([draw(editor, [stroke(points: tooManyPoints)])])), editor: &editor, expected: .limitExceeded)
                do { _ = try StudioCommandExecutor.decode(Data(repeating: 32, count: StudioCommandExecutor.maximumRequestBytes + 1)); throw Failure(message: "oversized wire request accepted") }
                catch StudioCommandError.limitExceeded { }
            }
            try test("duplicate operations charge generated geometry, not only input payload size") {
                var editor = try fresh()
                let original = DrawnElement(id: "large", tool: .brush,
                    points: Array(repeating: StrokePoint(x: 1, y: 1), count: 65_537), color: "#FF0000", width: 3, opacity: 1,
                    layerID: editor.document.activeLayerID)
                try editor.commit(original, frameID: editor.document.activeFrameID)
                try rejected(request(editor, .apply([.duplicateFrame(.init(source: .id(editor.document.activeFrameID), result: "too-large"))])),
                    editor: &editor, expected: .limitExceeded)
                try rejected(request(editor, .apply([.duplicateLayer(.init(source: .id(editor.document.activeLayerID), result: "too-large"))])),
                    editor: &editor, expected: .limitExceeded)
            }
            try test("actual frame/layer duplicate and reorder preserve unique identities and metadata") {
                var editor = try fresh()
                try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, [stroke(id: "original")])])), editor: &editor)
                let layer = editor.document.activeLayerID, frame = editor.document.activeFrameID
                let result = try StudioCommandExecutor.execute(request(editor, .apply([
                    .duplicateFrame(.init(source: .id(frame), result: "copy-frame")),
                    .duplicateLayer(.init(source: .id(layer), result: "copy-layer")),
                    .moveFrame(.init(target: .created("copy-frame"), direction: .earlier)),
                    .moveLayer(.init(target: .created("copy-layer"), direction: .later))
                ])), editor: &editor)
                try require(editor.document.frames[0].id == result.created["copy-frame"]?.id && editor.document.layers[1].id == result.created["copy-layer"]?.id,
                            "move did not reorder canonical arrays")
                let ids = editor.document.frames.flatMap { $0.elements.map(\.id) }
                try require(ids.count == 4 && Set(ids).count == 4, "duplicate reused drawing identities")
            }
            try test("no-op, removed temporary results, unsupported movement and absent undo are factual") {
                var editor = try fresh()
                editor.selectedElementIDs = ["retained-ui-selection"]
                let noOp = try StudioCommandExecutor.execute(request(editor, .apply([.selectFrame(.id(editor.document.activeFrameID))])), editor: &editor)
                try require(noOp.outcome == .unchanged && noOp.revision == 0 && !editor.canUndo, "no-op created success history")
                try require(editor.selectedElementIDs == ["retained-ui-selection"], "no-op changed transient UI selection")
                try rejected(request(editor, .undo), editor: &editor, expected: .noHistory)
                try rejected(request(editor, .apply([.moveFrame(.init(target: .id(editor.document.activeFrameID), direction: .earlier))])), editor: &editor, expected: .cannotMove)
                let temporary = try StudioCommandExecutor.execute(request(editor, .apply([
                    .addFrame(.init(after: .id(editor.document.activeFrameID), result: "temporary")), .deleteFrame(.created("temporary"))
                ])), editor: &editor)
                try require(temporary.created.isEmpty && temporary.createdFrameIDs.isEmpty && temporary.outcome == .unchanged,
                            "receipt claimed a deleted temporary frame remained")
            }
            try test("context reflects real document and exposes only available local operations") {
                let editor = try fresh(), document = editor.document
                let context = StudioCommandContext(document: document)
                try require(context.projectID == document.id && context.activeFrameID == document.activeFrameID && context.layers == document.layers,
                            "context detached from actual document")
                try require(context.editableAudioClips == document.audioClips && !context.supportedTools.contains(.smudge)
                            && context.unavailableCommands.contains("export") && context.unavailableCommands.contains("shell"),
                            "context invented supported capabilities")
            }
            let cancelled = Task { @MainActor () -> Bool in
                do {
                    var editor = try fresh()
                    try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, [stroke()])])), editor: &editor)
                    return false
                } catch is CancellationError { return true }
                catch { return false }
            }
            cancelled.cancel()
            let cancellationObserved = await cancelled.value
            try require(cancellationObserved, "default executor check did not observe actual Swift Task cancellation")
            passed += 1; print("PASS default cancellation observes a cancelled actual Swift Task")
            print("STUDIO_COMMAND_TESTS=PASS \(passed) production command cases")
        } catch {
            print("STUDIO_COMMAND_TESTS=FAIL \(error)")
            exit(1)
        }
    }
}
