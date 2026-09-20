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
            func audioEditor() throws -> StudioDocumentEditor {
                var value = try StudioDocument.new(name: "Audio command fixture", width: 512, height: 512, fps: 12)
                value.schemaVersion = 13
                let asset = UUID()
                value.audioClips = [
                    .init(id: "first-audio", soundName: "Managed fixture", track: 2, startTime: 0.25,
                          duration: 1, volume: 0.8, assetID: asset, sourceOffset: 0.5),
                    .init(id: "second-audio", soundName: "Shared original", track: 3, startTime: 1.5,
                          duration: 1, volume: 0.6, assetID: asset)
                ]
                value.mutedAudioTracks = [2]; value.audioTrackVolumes = [1, 0.4, 0.7, 1]
                return try .init(document: value)
            }
            func audioCommand(_ settings: StudioAudioClipSettings, id: String = "first-audio") -> StudioCommand {
                .updateAudioClip(.init(clipID: id, settings: settings))
            }
            try test("strict audio wire and drawn artwork form one reversible whole-document transaction") {
                var editor = try audioEditor(); let before = editor.document
                let change = request(editor, .apply([draw(editor, [stroke(id: "audio-batch-drawing")]),
                    audioCommand(.init(volume: 0.3, isMuted: true, fades: .init(fadeIn: 0.25, fadeOut: 0.5)))]))
                let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(change))
                let receipt = try StudioCommandExecutor.execute(decoded, editor: &editor), after = editor.document
                let clip = after.audioClips[0]
                try require(clip.volume == 0.3 && clip.isMuted && clip.fadeEnvelope == .init(sourceStartFrame: 24_000,
                    frameCount: 48_000, fadeInFrames: 12_000, fadeOutFrames: 24_000), "wrong source-bound settings")
                try require(after.audioClips[1] == before.audioClips[1] && after.mutedAudioTracks == before.mutedAudioTracks
                    && after.audioTrackVolumes == before.audioTrackVolumes, "audio command changed another clip or lane")
                try require(after.revision == before.revision + 1 && after.schemaVersion == 14
                    && receipt.changedAudioClipIDs == ["first-audio"] && receipt.createdElementIDs == ["audio-batch-drawing"], "incorrect receipt")
                editor.undo(); try require(content(editor.document) == content(before), "one Undo failed")
                editor.redo(); try require(content(editor.document) == content(after), "one Redo failed")
            }
            try test("partial audio settings preserve fades and clearing fades is explicit and idempotent") {
                var editor = try audioEditor()
                try StudioCommandExecutor.execute(request(editor, .apply([audioCommand(.init(fades: .init(fadeIn: 0.25, fadeOut: 0.5)))])), editor: &editor)
                let envelope = editor.document.audioClips[0].fadeEnvelope
                try StudioCommandExecutor.execute(request(editor, .apply([audioCommand(.init(isMuted: true))])), editor: &editor)
                try require(editor.document.audioClips[0].fadeEnvelope == envelope && editor.document.audioClips[0].volume == 0.8, "mute rewrote omitted values")
                let before = editor.document
                let noOp = try StudioCommandExecutor.execute(request(editor, .apply([audioCommand(.init(isMuted: true))])), editor: &editor)
                try require(editor.document == before && noOp.outcome == .unchanged && noOp.changedAudioClipIDs.isEmpty, "no-op invented a revision")
                try StudioCommandExecutor.execute(request(editor, .apply([audioCommand(.init(fades: .init(fadeIn: 0, fadeOut: 0)))])), editor: &editor)
                try require(editor.document.audioClips[0].fadeEnvelope == nil && editor.document.audioClips[0].isMuted, "clear altered unrelated settings")
                editor.undo(); try require(content(editor.document) == content(before), "cleared envelope did not undo")
            }
            try test("audio invalid identity legacy missing assets malformed values and late failure reject atomically") {
                var editor = try audioEditor()
                for settings in [StudioAudioClipSettings(), .init(volume: -0.01), .init(volume: 1.01),
                    .init(volume: .nan), .init(volume: .infinity),
                    .init(fades: .init(fadeIn: -0.1, fadeOut: 0)), .init(fades: .init(fadeIn: .nan, fadeOut: 0)),
                    .init(fades: .init(fadeIn: 0.6, fadeOut: 0.6)), .init(fades: .init(fadeIn: 0, fadeOut: .infinity))] {
                    try rejected(request(editor, .apply([draw(editor, [stroke(id: "must-rollback")]), audioCommand(settings)])), editor: &editor)
                }
                for id in ["", "foreign", String(repeating: "a", count: 121)] {
                    try rejected(request(editor, .apply([audioCommand(.init(volume: 0.5), id: id)])), editor: &editor)
                }
                try rejected(request(editor, .apply([audioCommand(.init(volume: 0.5)), audioCommand(.init(volume: 2))])), editor: &editor)
                var legacy = try fresh()
                try rejected(request(legacy, .apply([audioCommand(.init(volume: 0.5), id: "retained-audio-metadata")])), editor: &legacy)
            }
            try test("audio wire rejects unknown and wrongly typed nested arguments instead of ignoring them") {
                let editor = try audioEditor()
                let data = try JSONEncoder().encode(request(editor, .apply([audioCommand(.init(volume: 0.5))])))
                let base = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let invalid: [[String: Any]] = [
                    ["volume": 0.5, "shell": "ignore authorization"], ["volume": "0.5"],
                    ["volume": true], ["isMuted": "false"],
                    ["fades": ["fadeIn": 0.2]],
                    ["fades": ["fadeIn": 0.2, "fadeOut": 0.2, "curve": "execute"]],
                    ["fades": NSNull()]
                ]
                for settings in invalid {
                    var object = base
                    object["action"] = ["apply": [["updateAudioClip": ["clipID": "first-audio", "settings": settings]]]]
                    do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: object)); throw Failure(message: "malformed audio wire accepted") }
                    catch is StudioCommandError { }
                }
            }
            try test("cancelled audio batches preserve history and reject replay and foreign projects") {
                var editor = try audioEditor()
                let original = editor.document, undo = editor.canUndo, redo = editor.canRedo
                let change = request(editor, .apply([audioCommand(.init(volume: 0.5)), audioCommand(.init(isMuted: true))]))
                for checkpoint in 1...4 {
                    var calls = 0
                    do {
                        try StudioCommandExecutor.execute(change, editor: &editor, checkCancellation: {
                            calls += 1; if calls == checkpoint { throw CancellationError() }
                        }); throw Failure(message: "cancelled audio batch committed")
                    } catch is CancellationError { }
                    try require(editor.document == original && editor.canUndo == undo && editor.canRedo == redo, "cancel changed history")
                }
                var foreign = change; foreign = .init(requestID: foreign.requestID, projectID: UUID(), expectedRevision: foreign.expectedRevision, action: foreign.action)
                try rejected(foreign, editor: &editor, expected: .wrongProject)
                try StudioCommandExecutor.execute(change, editor: &editor)
                try rejected(change, editor: &editor, expected: .staleRevision)
                try require(StudioCommandContext(document: editor.document).supportedAudioEdits == ["clipVolume", "clipMute", "clipFades"], "capability context omitted implemented settings")
            }
            func imageEditor() throws -> StudioDocumentEditor {
                var editor = try fresh()
                try editor.change { value in
                    value.schemaVersion = 3
                    value.frames[0].rasterAssetID = "image-fixture"
                    value.frames[0].rasterLayerID = value.activeLayerID
                    value.frames[0].rasterPlacement = .init(x: 128, y: 0, width: 256, height: 512)
                }
                return editor
            }
            func imageCommand(_ editor: StudioDocumentEditor, _ placement: StudioRasterPlacement, assetID: String = "image-fixture") -> StudioCommand {
                .updateImagePlacement(.init(frame: .id(editor.document.activeFrameID), assetID: assetID, placement: placement))
            }
            func imageDeletion(_ editor: StudioDocumentEditor, assetID: String = "image-fixture") -> StudioCommand {
                .deleteImage(.init(frame: .id(editor.document.activeFrameID), assetID: assetID))
            }
            try test("explicit image deletion preserves drawings layers other frames and reversible history") {
                var editor = try imageEditor()
                _ = try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, [stroke(id: "retained-drawing")])])), editor: &editor)
                try editor.duplicateFrame()
                let before = editor.document, selected = before.activeFrameID
                let wire = try JSONEncoder().encode(request(editor, .apply([imageDeletion(editor)])))
                let receipt = try StudioCommandExecutor.execute(StudioCommandExecutor.decode(wire), editor: &editor)
                let after = editor.document, frame = after.frames.first { $0.id == selected }!
                try require(frame.rasterAssetID == nil && frame.rasterLayerID == nil && frame.rasterPlacement == nil, "Image reference remains")
                try require(frame.elements == before.frames.first { $0.id == selected }!.elements && after.layers == before.layers && after.audioClips == before.audioClips, "Delete changed drawings layers or audio")
                try require(after.frames.filter { $0.id != selected } == before.frames.filter { $0.id != selected }, "Delete changed another frame sharing the original")
                try require(after.activeFrameID == before.activeFrameID && after.activeLayerID == before.activeLayerID, "Delete changed editor selection")
                try require(after.revision == before.revision + 1 && receipt.outcome == .applied && receipt.deletedElementIDs.isEmpty && receipt.deletedLayerIDs.isEmpty, "Wrong deletion receipt")
                editor.undo();try require(content(editor.document) == content(before), "One Undo did not restore complete original")
                editor.redo();try require(content(editor.document) == content(after), "One Redo did not restore image deletion")
                try rejected(request(editor, .apply([imageDeletion(editor)])), editor: &editor, expected: .invalidReference)
            }
            try test("image deletion strict wire explicit identity historical protection and batch rollback") {
                var editor = try imageEditor()
                try rejected(request(editor, .apply([imageDeletion(editor, assetID: "foreign")])), editor: &editor, expected: .invalidReference)
                try rejected(request(editor, .apply([.deleteImage(.init(frame: .id("foreign"), assetID: "image-fixture"))])), editor: &editor)
                try rejected(request(editor, .apply([imageDeletion(editor), imageCommand(editor, .init(x: 0, y: 0, width: 50, height: 50))])), editor: &editor)
                let wire = try JSONEncoder().encode(request(editor, .apply([imageDeletion(editor)])))
                var object = try JSONSerialization.jsonObject(with: wire) as! [String: Any]
                var action = object["action"] as! [String: Any], commands = action["apply"] as! [[String: Any]]
                var arguments = commands[0]["deleteImage"] as! [String: Any];arguments["deleteAll"] = true
                commands[0]["deleteImage"] = arguments;action["apply"] = commands;object["action"] = action
                do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: object));throw Failure(message: "Unknown deletion field accepted") }
                catch StudioCommandError.malformed { }
                try editor.change { $0.frames[0].rasterPlacement = nil }
                try rejected(request(editor, .apply([imageDeletion(editor)])), editor: &editor, expected: .invalidReference)
            }
            try test("image deletion respects every lock hidden layers and stale revisions") {
                for mode in ["full", "position", "alpha"] {
                    var editor = try imageEditor();try editor.change { $0.layers[0].lockMode = mode }
                    try rejected(request(editor, .apply([imageDeletion(editor)])), editor: &editor)
                }
                for hidden in [true, false] {
                    var editor = try imageEditor();try editor.change { if hidden { $0.layers[0].visible = false } else { $0.layers[0].opacity = 0 } }
                    try rejected(request(editor, .apply([imageDeletion(editor)])), editor: &editor)
                }
                var editor = try imageEditor();let stale = request(editor, .apply([imageDeletion(editor)]))
                try editor.change { $0.gridEnabled = true }
                try rejected(stale, editor: &editor, expected: .staleRevision)
            }
            try test("image deletion cancellation at every observed production checkpoint is atomic") {
                var probe = try imageEditor(), total = 0
                _ = try StudioCommandExecutor.execute(request(probe, .apply([imageDeletion(probe)])), editor: &probe, checkCancellation: { total += 1 })
                try require(total >= 5, "Expected staged cancellation checks absent")
                for cancelAt in 1...total {
                    var editor = try imageEditor(), count = 0
                    try rejected(request(editor, .apply([imageDeletion(editor)])), editor: &editor, cancellation: {
                        count += 1;if count == cancelAt { throw CancellationError() }
                    })
                }
            }
            try test("image placement uses strict wire one transaction and original image identity") {
                var editor = try imageEditor(); let before = editor.document
                let placement = StudioRasterPlacement(x: 7, y: 15, width: 64, height: 128)
                let wire = try JSONEncoder().encode(request(editor, .apply([imageCommand(editor, placement)])))
                let receipt = try StudioCommandExecutor.execute(StudioCommandExecutor.decode(wire), editor: &editor)
                let after = editor.document
                let context = StudioCommandContext(document: after).frames[0]
                try require(context.imageAssetID == "image-fixture" && context.imageLayerID == after.activeLayerID && context.imagePlacement == placement,
                    "Studio automation context lacks actual editable image identity/geometry")
                try require(after.frames[0].rasterPlacement == placement, "Image placement did not change")
                try require(after.frames[0].rasterAssetID == before.frames[0].rasterAssetID && after.frames[0].rasterLayerID == before.frames[0].rasterLayerID, "Image ownership changed")
                try require(after.frames[0].elements == before.frames[0].elements && after.layers == before.layers && after.audioClips == before.audioClips, "Image positioning changed unrelated content")
                try require(after.revision == before.revision + 1 && receipt.createdElementIDs.isEmpty && receipt.deletedElementIDs.isEmpty, "Incorrect edit receipt")
                editor.undo(); try require(content(editor.document) == content(before), "Image Undo failed")
                editor.redo(); try require(content(editor.document) == content(after), "Image Redo failed")
                let redoSnapshot = editor.document
                let unchanged = try StudioCommandExecutor.execute(request(editor, .apply([imageCommand(editor, placement)])), editor: &editor)
                try require(unchanged.outcome == .unchanged && editor.document == redoSnapshot, "Unchanged image placement created history")
                var object = try JSONSerialization.jsonObject(with: wire) as! [String: Any]
                var action = object["action"] as! [String: Any]; var commands = action["apply"] as! [[String: Any]]
                var args = commands[0]["updateImagePlacement"] as! [String: Any]
                var rect = args["placement"] as! [String: Any]; rect["shell"] = "not an instruction"; args["placement"] = rect
                commands[0]["updateImagePlacement"] = args; action["apply"] = commands; object["action"] = action
                do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: object)); throw Failure(message: "Unknown nested image field accepted") }
                catch StudioCommandError.malformed {}
            }
            try test("image positioning isolates duplicated frames and rolls back later batch failures") {
                var editor = try imageEditor()
                let firstID = editor.document.activeFrameID
                try editor.duplicateFrame()
                let before = editor.document, target = StudioRasterPlacement(x: 0, y: 0, width: 50, height: 100)
                try require(before.frames.count == 2 && before.frames[0].rasterAssetID == before.frames[1].rasterAssetID, "Duplicate fixture did not retain shared original")
                let valid = imageCommand(editor, target)
                try rejected(request(editor, .apply([valid, imageCommand(editor, target, assetID: "foreign")])), editor: &editor, expected: .invalidReference)
                _ = try StudioCommandExecutor.execute(request(editor, .apply([valid])), editor: &editor)
                try require(editor.document.frames.first { $0.id == firstID } == before.frames.first { $0.id == firstID }, "Placement changed another frame sharing original bytes")
                try require(editor.document.frames.first { $0.id == editor.document.activeFrameID }?.rasterPlacement == target, "Explicit frame was not positioned")
            }
            try test("invalid nonfinite outside and missing image placements reject atomically") {
                var editor = try imageEditor()
                for rect in [StudioRasterPlacement(x: -1, y: 0, width: 10, height: 10),
                             .init(x: 0, y: 0, width: 0, height: 10), .init(x: 500, y: 0, width: 20, height: 10),
                             .init(x: 0, y: 500, width: 10, height: 20), .init(x: .nan, y: 0, width: 10, height: 10),
                             .init(x: 0, y: 0, width: .infinity, height: 10)] {
                    try rejected(request(editor, .apply([imageCommand(editor, rect)])), editor: &editor)
                }
                let valid = StudioRasterPlacement(x: 0, y: 0, width: 10, height: 10)
                try rejected(request(editor, .apply([imageCommand(editor, valid, assetID: "wrong")])), editor: &editor, expected: .invalidReference)
                try editor.change { $0.frames[0].rasterPlacement = nil }
                try rejected(request(editor, .apply([imageCommand(editor, valid)])), editor: &editor, expected: .invalidReference)
            }
            try test("image placement respects locks visibility cancellation and stale revisions") {
                let rect = StudioRasterPlacement(x: 0, y: 0, width: 64, height: 128)
                for mode in ["full", "position", "alpha"] {
                    var editor = try imageEditor(); try editor.change { $0.layers[0].lockMode = mode }
                    try rejected(request(editor, .apply([imageCommand(editor, rect)])), editor: &editor)
                }
                for hidden in [true, false] {
                    var editor = try imageEditor(); try editor.change { if hidden { $0.layers[0].visible = false } else { $0.layers[0].opacity = 0 } }
                    try rejected(request(editor, .apply([imageCommand(editor, rect)])), editor: &editor)
                }
                var editor = try imageEditor(); let stale = request(editor, .apply([imageCommand(editor, rect)]))
                try editor.change { $0.gridEnabled = true }
                try rejected(stale, editor: &editor, expected: .staleRevision)
                for cancelAt in 1...5 {
                    var probes = 0
                    try rejected(request(editor, .apply([imageCommand(editor, rect)])), editor: &editor, cancellation: {
                        probes += 1; if probes == cancelAt { throw CancellationError() }
                    })
                }
            }
            try test("layer naming is one actual metadata transaction with Unicode and reversible history") {
                var editor = try fresh()
                _ = try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, [stroke(id: "named-ink")])])), editor: &editor)
                let id = editor.document.activeLayerID, before = editor.document
                let rename = request(editor, .apply([.updateLayer(.init(layer: .id(id), settings: .init(name: "Hero 💀 é")))]))
                let receipt = try StudioCommandExecutor.execute(StudioCommandExecutor.decode(JSONEncoder().encode(rename)), editor: &editor)
                let after = editor.document
                try require(after.layers[0].id == id && after.layers[0].name == "Hero 💀 é", "Rename lost identity or Unicode")
                try require(after.frames == before.frames && after.audioClips == before.audioClips, "Rename changed artwork or audio")
                try require(after.revision == before.revision + 1 && receipt.createdLayerIDs.isEmpty && receipt.deletedLayerIDs.isEmpty, "Rename invented layer creation/deletion")
                editor.undo();try require(content(editor.document) == content(before), "Rename Undo changed original content")
                editor.redo();try require(content(editor.document) == content(after), "Rename Redo changed content")
            }
            try test("invalid layer names reject the whole command without metadata or history changes") {
                var editor = try fresh();let id = editor.document.activeLayerID
                for name in ["", "   ", String(repeating: "a", count: 121), "Hero\nInk", "Hero\tInk", "Hero\u{0000}", "e" + String(repeating: "\u{0301}", count: 3000)] {
                    try rejected(request(editor, .apply([.updateLayer(.init(layer: .id(id), settings: .init(name: name)))])), editor: &editor, expected: .invalidSettings)
                }
                _ = try StudioCommandExecutor.execute(request(editor, .apply([.updateLayer(.init(layer: .id(id), settings: .init(name: String(repeating: "a", count: 120))))])), editor: &editor)
                let before = editor.document
                let receipt = try StudioCommandExecutor.execute(request(editor, .apply([.updateLayer(.init(layer: .id(id), settings: .init(name: before.layers[0].name)))])), editor: &editor)
                try require(receipt.outcome == .unchanged && editor.document == before, "Unchanged name created an edit")
            }
            try test("explicit layer deletion is one multi-frame transaction with real receipt undo and redo") {
                var editor = try fresh()
                let keep = editor.document.activeLayerID, first = editor.document.activeFrameID
                _ = try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, [stroke(id: "keep-ink")])])), editor: &editor)
                try editor.addLayer(); let target = editor.document.activeLayerID
                _ = try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, [stroke(id: "delete-ink")])])), editor: &editor)
                try editor.addFrame(); let second = editor.document.activeFrameID
                _ = try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, [stroke(id: "delete-ink-2")])])), editor: &editor)
                try editor.change { value in
                    value.schemaVersion = max(value.schemaVersion, 3)
                    value.frames[0].rasterAssetID = "retained-image"
                    value.frames[0].rasterLayerID = target
                    value.frames[0].rasterPlacement = .init(x: 0, y: 0, width: 20, height: 20)
                }
                editor.selectedElementIDs = ["delete-ink-2"]
                let before = editor.document
                let wire = try JSONEncoder().encode(request(editor, .apply([.deleteLayer(.id(target))])))
                let receipt = try StudioCommandExecutor.execute(StudioCommandExecutor.decode(wire), editor: &editor)
                let after = editor.document
                try require(after.layers.map(\.id) == [keep] && after.activeLayerID == keep, "Wrong remaining layer or active target")
                try require(after.frames.map(\.id) == [first, second] && after.frames[0].elements.map(\.id) == ["keep-ink"] && after.frames[1].elements.isEmpty && after.frames.allSatisfy { $0.rasterAssetID == nil && $0.rasterLayerID == nil && $0.rasterPlacement == nil }, "Layer content survived or frames changed")
                try require(after.audioClips == before.audioClips && after.revision == before.revision + 1, "Unrelated audio changed or deletion was not one transaction")
                try require(receipt.deletedLayerIDs == [target] && Set(receipt.deletedElementIDs) == ["delete-ink", "delete-ink-2"], "Receipt fabricated layer/content result")
                try require(editor.selectedElementIDs.isEmpty && editor.referencedRasterAssetIDsIncludingHistoryAndClipboard.contains("retained-image"), "Stale selection or lost undo image")
                editor.undo(); try require(content(editor.document) == content(before), "Undo did not restore complete original document")
                editor.redo(); try require(content(editor.document) == content(after), "Redo changed deletion")
            }
            try test("layer delete rejects last missing locked and stale targets without changing history") {
                var editor = try fresh()
                try rejected(request(editor, .apply([.deleteLayer(.id(editor.document.activeLayerID))])), editor: &editor)
                try editor.addLayer(); let target = editor.document.activeLayerID
                try rejected(request(editor, .apply([.deleteLayer(.id("missing"))])), editor: &editor, expected: .invalidReference)
                for mode in ["full", "position", "alpha"] {
                    try editor.updateLayer(target) { $0.lockMode = mode; $0.locked = mode == "full" }
                    try rejected(request(editor, .apply([.deleteLayer(.id(target))])), editor: &editor)
                }
                try editor.updateLayer(target) { $0.lockMode = "free"; $0.locked = false }
                let stale = request(editor, .apply([.deleteLayer(.id(target))])); try editor.addLayer()
                try rejected(stale, editor: &editor, expected: .staleRevision)
            }
            try test("layer delete cancellation and a later failed batch command preserve original state") {
                var editor = try fresh();try editor.addLayer();let target=editor.document.activeLayerID
                var checks=0
                try rejected(request(editor,.apply([.deleteLayer(.id(target))])),editor:&editor,cancellation:{
                    checks += 1;if checks == 5 { throw CancellationError() }
                })
                try rejected(request(editor,.apply([.deleteLayer(.id(target)),.selectLayer(.id(target))])),editor:&editor,expected:.invalidReference)
            }
            try test("layer deletion requires an explicit strict wire reference") {
                let editor=try fresh()
                var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(request(editor,.undo))) as! [String:Any]
                for body in [[:], ["all":true], ["id":editor.document.activeLayerID,"all":true]] as [[String:Any]] {
                    object["action"]=["apply":[["deleteLayer":body]]]
                    do { _=try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject:object));throw Failure(message:"Implicit or extra-field delete accepted") }
                    catch is StudioCommandError { }
                }
            }
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
                var textEditor = try fresh(); try rejected(request(textEditor, .apply([draw(textEditor, [stroke(tool: .text)])])), editor: &textEditor, expected: .invalidSettings)
                for tool in [DrawingTool.fill, .smudge, .blur, .calligraphy] {
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
