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
            try test("Cut uses existing clipboard preserves order fresh paste IDs and one Undo") {
                var editor = try fresh()
                _ = try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, [stroke(id: "lower"), stroke(id: "upper")])])), editor: &editor)
                editor.selectedElementIDs = ["lower", "upper"]
                let before = editor.document
                let cut = StudioCommand.cutElements(.init(frame: .id(before.activeFrameID), elementIDs: ["upper", "lower"]))
                let wire = try StudioCommandExecutor.decode(JSONEncoder().encode(request(editor, .apply([cut]))))
                let receipt = try StudioCommandExecutor.execute(wire, editor: &editor)
                try require(editor.document.frames.count == before.frames.count && editor.document.frames[0].elements.isEmpty,
                    "Cut added a frame or retained selected drawings")
                try require(editor.clipboardElements?.map(\.id) == ["lower", "upper"] && receipt.clipboardElementCount == 2,
                    "Cut clipboard lost painting order")
                let clipboard = editor.clipboardVersion
                _ = try StudioCommandExecutor.execute(request(editor, .undo), editor: &editor)
                try require(content(editor.document) == content(before), "Cut was not one Undo")
                _ = try StudioCommandExecutor.execute(request(editor, .redo), editor: &editor)
                _ = try StudioCommandExecutor.execute(request(editor, .apply([.pasteElements(.init(frame: .id(editor.document.activeFrameID),
                    layer: .id(editor.document.activeLayerID), clipboardID: clipboard.uuidString))])), editor: &editor)
                let pasted = editor.document.frames[0].elements
                try require(pasted.count == 2 && Set(pasted.map(\.id)).isDisjoint(with: ["lower", "upper"])
                    && pasted.map(\.points) == before.frames[0].elements.map(\.points), "Cut paste lost source or reused IDs")
            }
            try test("Cut failure cancellation and later batch rejection preserve prior clipboard and document") {
                var editor = try fresh()
                _ = try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, [stroke(id: "target"), stroke(id: "prior")])])), editor: &editor)
                try editor.copyElements(frameID: editor.document.activeFrameID, ids: ["prior"])
                editor.selectedElementIDs = ["target"]
                let cut = StudioCommand.cutElements(.init(frame: .id(editor.document.activeFrameID), elementIDs: ["target"]))
                let version = editor.clipboardVersion, originalClipboard = editor.clipboardElements
                var probe = editor, checkpoints = 0
                _ = try StudioCommandExecutor.execute(request(probe, .apply([cut])), editor: &probe, checkCancellation: { checkpoints += 1 })
                for stop in 1...checkpoints {
                    var calls = 0
                    try rejected(request(editor, .apply([cut])), editor: &editor, cancellation: {
                        calls += 1; if calls == stop { throw CancellationError() }
                    })
                    try require(editor.clipboardVersion == version && editor.clipboardElements == originalClipboard, "Cancelled Cut replaced clipboard")
                }
                try rejected(request(editor, .apply([cut, .renameProject(.init(name: ""))])), editor: &editor)
                try require(editor.clipboardVersion == version && editor.clipboardElements == originalClipboard, "Failed batch published Cut clipboard")
                let before = editor.document
                for mode in ["full", "position", "alpha"] {
                    var locked = try StudioDocumentEditor(document: before)
                    try locked.copyElements(frameID: before.activeFrameID, ids: ["prior"])
                    locked.selectedElementIDs = ["target"]
                    try locked.change { $0.layers[0].lockMode = mode }
                    let oldVersion = locked.clipboardVersion
                    try rejected(request(locked, .apply([cut])), editor: &locked)
                    try require(locked.clipboardVersion == oldVersion, "Locked Cut replaced clipboard")
                }
                let stale = StudioCommandRequest(requestID: UUID(), projectID: before.id, expectedRevision: before.revision - 1, action: .apply([cut]))
                try rejected(stale, editor: &editor, expected: .staleRevision)
                try rejected(request(editor, .apply([.cutElements(.init(frame: .id(before.activeFrameID), elementIDs: ["prior"]))])), editor: &editor)
            }
            try test("explicit selected erasure matches manual transaction and preserves sources with one undo") {
                var editor = try fresh()
                _ = try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, [stroke(id: "target"), stroke(id: "overlap")])])), editor: &editor)
                editor.selectedElementIDs = ["target"]
                let before = editor.document
                let points = [StrokePoint(x: 40, y: 50), StrokePoint(x: 50, y: 60)]
                let command = StudioCommand.eraseSelectedElements(.init(frame: .id(before.activeFrameID), layer: .id(before.activeLayerID),
                    elementIDs: ["target"], points: points, width: 12, opacity: 0.5, mode: .soft))
                var manual = editor
                try manual.eraseSelectedElements(DrawnElement(id: "manual", tool: .eraser, points: points,
                    color: "#000000", width: 12, opacity: 0.5, fillColor: nil, layerID: before.activeLayerID,
                    eraser: .init(mode: .soft)), frameID: before.activeFrameID, elementIDs: ["target"])
                let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(request(editor, .apply([command]))))
                let receipt = try StudioCommandExecutor.execute(decoded, editor: &editor)
                try require(content(editor.document) == content(manual.document), "Typed erasure diverged from manual editor operation")
                try require(editor.selectedElementIDs == manual.selectedElementIDs, "Pure typed erasure lost manual selection")
                var combined = manual
                _ = try StudioCommandExecutor.execute(request(combined, .apply([.renameProject(.init(name: "Renamed selected artwork")), command])), editor: &combined)
                try require(combined.selectedElementIDs == manual.selectedElementIDs, "Rename/erasure batch lost selection")
                var mixed = manual
                _ = try StudioCommandExecutor.execute(request(mixed, .apply([command, draw(mixed, [stroke(id: "new-draw")])])), editor: &mixed)
                try require(mixed.selectedElementIDs.isEmpty, "Mixed drawing batch unexpectedly preserved selection")
                try require(editor.document.frames[0].elements[0].points == before.frames[0].elements[0].points &&
                    editor.document.frames[0].elements[1] == before.frames[0].elements[1], "Erasure rewrote source or overlap")
                try require(receipt.createdElementIDs.isEmpty && editor.document.revision == before.revision + 1, "Erasure invented source IDs or multiple revisions")
                let after = content(editor.document)
                _ = try StudioCommandExecutor.execute(request(editor, .undo), editor: &editor)
                try require(content(editor.document) == content(before), "Erasure was not one Undo")
                _ = try StudioCommandExecutor.execute(request(editor, .redo), editor: &editor)
                try require(content(editor.document) == after, "Redo lost masks")
            }
            try test("selected erasure rejects stale malformed locked unseen targets and rolls back a batch") {
                var editor = try fresh()
                _ = try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, [stroke(id: "target"), stroke(id: "unseen")])])), editor: &editor)
                editor.selectedElementIDs = ["target"]
                let frame = editor.document.activeFrameID, layer = editor.document.activeLayerID
                func erasure(_ ids: [String] = ["target"], width: Double = 10) -> StudioCommand {
                    .eraseSelectedElements(.init(frame: .id(frame), layer: .id(layer), elementIDs: ids,
                        points: [.init(x: 40, y: 50)], width: width, opacity: 1, mode: .hard))
                }
                let valid = request(editor, .apply([erasure()]))
                try rejected(.init(requestID: UUID(), projectID: valid.projectID, expectedRevision: valid.expectedRevision - 1, action: valid.action), editor: &editor, expected: .staleRevision)
                for ids in [[], ["target", "target"], ["unseen"], ["target", "unseen"], ["missing"]] {
                    try rejected(request(editor, .apply([erasure(ids)])), editor: &editor)
                }
                for width in [0, 513, Double.nan] { try rejected(request(editor, .apply([erasure(width: width)])), editor: &editor) }
                try rejected(request(editor, .apply([.renameProject(.init(name: "must roll back")), erasure(width: 0)])), editor: &editor)
                let original = editor.document
                try editor.change { $0.layers[0].locked = true }
                try rejected(request(editor, .apply([erasure()])), editor: &editor)
                editor = try StudioDocumentEditor(document: original); editor.selectedElementIDs = ["target"]
                for cancellationIndex in 1...8 {
                    var calls = 0
                    try rejected(request(editor, .apply([.renameProject(.init(name: "cancelled rename")), erasure()])), editor: &editor,
                        cancellation: { calls += 1; if calls == cancellationIndex { throw CancellationError() } })
                }
                let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as! [String: Any]
                let fields = ((base["action"] as! [String: Any])["apply"] as! [[String: Any]])[0]["eraseSelectedElements"] as! [String: Any]
                var unknown = fields; unknown["shell"] = "delete everything"
                var nested = fields; nested["points"] = [["x": 1, "y": 1, "admin": true]]
                var missing = fields; missing.removeValue(forKey: "mode")
                for invalid in [unknown, nested, missing] {
                    var object = base; object["action"] = ["apply": [["eraseSelectedElements": invalid]]]
                    do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: object)); throw Failure(message: "Malformed selected erasure decoded") }
                    catch is StudioCommandError { }
                }
                try rejected(request(editor, .apply([draw(editor, [StudioCommandStroke(id: "not-selected-mask", tool: .eraser,
                    points: [.init(x: 1, y: 1)], color: "#000000", width: 10, opacity: 1, eraser: .init())])])), editor: &editor)
            }
            try test("masked frame clones consume generated mask and sample budgets atomically") {
                // Delete each prior frame after copying: the live project stays
                // within model limits while the request's generated work grows.
                for (maskCount, samples, copies) in [(64, 1, 16), (8, 4096, 2)] {
                    var editor = try fresh()
                    _ = try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, [stroke(id: "source")])])), editor: &editor)
                    let layer = editor.document.activeLayerID
                    for _ in 0..<maskCount {
                        try editor.eraseSelectedElements(DrawnElement(id: "mask", tool: .eraser,
                            points: Array(repeating: StrokePoint(x: 40, y: 50), count: samples), color: "#000000",
                            width: 10, opacity: 1, fillColor: nil, layerID: layer, eraser: .init()),
                            frameID: editor.document.activeFrameID, elementIDs: ["source"])
                    }
                    var commands: [StudioCommand] = [.renameProject(.init(name: "must roll back masked clones"))]
                    var source = StudioCommandReference.id(editor.document.activeFrameID)
                    for index in 0..<copies {
                        let alias = "copy-\(index)"
                        commands.append(.duplicateFrame(.init(source: source, result: alias)))
                        commands.append(.deleteFrame(source))
                        source = .created(alias)
                    }
                    try rejected(request(editor, .apply(commands)), editor: &editor, expected: .limitExceeded)
                }
            }
            try test("typed tween uses canonical adjacent endpoints four easings factual receipts and one undo") {
                for easing in StudioTweenEasing.allCases {
                    var editor = try fresh()
                    let first = editor.document.activeFrameID
                    _ = try StudioCommandExecutor.execute(request(editor, .apply([
                        draw(editor, [stroke(id: "start")]),
                        .duplicateFrame(.init(source: .id(first), result: "end"))
                    ])), editor: &editor)
                    let last = editor.document.frames[1].id
                    _ = try StudioCommandExecutor.execute(request(editor, .apply([
                        .translateElements(.init(frame: .id(last), elementIDs: editor.document.frames[1].elements.map(\.id), dx: 100, dy: 0)),
                        .setFrameHold(.init(frame: .id(first), ticks: 2)), .setFrameHold(.init(frame: .id(last), ticks: 3))
                    ])), editor: &editor)
                    let before = content(editor.document)
                    let command = StudioCommand.tweenFrames(.init(after: .id(first), to: .id(last), inbetweenCount: 1, easing: easing))
                    let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(request(editor, .apply([command]))))
                    let receipt = try StudioCommandExecutor.execute(decoded, editor: &editor)
                    let frames = editor.document.frames
                    try require(frames.count == 3 && frames[0] == before.frames[0] && frames[2] == before.frames[1], "Tween changed endpoint artwork or holds")
                    let factor = easing == .easeIn ? 0.25 : easing == .easeOut ? 0.75 : 0.5
                    let generated = frames[1].elements[0]
                    // Translation is canonical affine metadata; the renderer
                    // applies it without destructively rewriting source points.
                    let transform = generated.transform ?? StudioElementTransform()
                    for (index, point) in generated.points.enumerated() {
                        let rendered = transform.point(CGPoint(x: point.x + (generated.translation?.x ?? 0),
                                                               y: point.y + (generated.translation?.y ?? 0)))
                        let original = before.frames[0].elements[0].points[index]
                        try require(abs(rendered.x - (original.x + 100 * factor)) < 0.00001 &&
                            abs(rendered.y - original.y) < 0.00001, "Typed tween did not use chosen canonical easing in rendered coordinates")
                    }
                    try require(frames[1].durationTicks == 1, "Typed tween changed generated exposure")
                    try require(receipt.createdFrameIDs == [frames[1].id] && Set(receipt.createdElementIDs) == Set(frames[1].elements.map(\.id)), "Tween receipt invented or omitted generated identities")
                    let after = content(editor.document)
                    _ = try StudioCommandExecutor.execute(request(editor, .undo), editor: &editor)
                    try require(content(editor.document) == before, "Tween undo did not restore exact endpoint document")
                    _ = try StudioCommandExecutor.execute(request(editor, .redo), editor: &editor)
                    try require(content(editor.document) == after, "Tween redo regenerated identities or geometry")
                    try require(StudioCommandContext(document: editor.document).supportedTweenEasings.contains(easing), "Typed context omitted easing")
                }
            }
            try test("typed tween rejects bounds stale context unknown wire fields and cancellation atomically") {
                var editor = try fresh()
                let first = editor.document.activeFrameID
                _ = try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, [stroke(id: "start")]),
                    .duplicateFrame(.init(source: .id(first), result: "end"))])), editor: &editor)
                let last = editor.document.frames[1].id
                func tween(_ count: Int) -> StudioCommand { .tweenFrames(.init(after: .id(first), to: .id(last), inbetweenCount: count, easing: .linear)) }
                for count in [0, 25, Int.max] {
                    try rejected(request(editor, .apply([tween(count)])), editor: &editor, expected: .limitExceeded)
                }
                var stale = request(editor, .apply([tween(2)]))
                stale = .init(requestID: stale.requestID, projectID: stale.projectID, expectedRevision: stale.expectedRevision - 1, action: stale.action)
                try rejected(stale, editor: &editor, expected: .staleRevision)
                let valid = request(editor, .apply([tween(2)]))
                var probe = editor, checkpoints = 0
                _ = try StudioCommandExecutor.execute(valid, editor: &probe, checkCancellation: { checkpoints += 1 })
                var cancelledChecks = 0
                try rejected(valid, editor: &editor, cancellation: {
                    cancelledChecks += 1
                    if cancelledChecks == checkpoints { throw CancellationError() }
                })
                try require(cancelledChecks == checkpoints, "Did not cancel at final real transaction checkpoint")
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as! [String: Any]
                var action = object["action"] as! [String: Any], commands = action["apply"] as! [[String: Any]]
                var fields = commands[0]["tweenFrames"] as! [String: Any]
                fields["shell"] = "untrusted capability"; commands[0]["tweenFrames"] = fields
                action["apply"] = commands; object["action"] = action
                do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: object)); throw Failure(message: "Tween accepted unknown wire field") }
                catch StudioCommandError.malformed { }
            }
            try test("all native brush families pass strict typed wire and one reversible canonical transaction") {
                for family in StudioBrushFamily.allCases {
                    var editor = try fresh(); let before = content(editor.document)
                    var styled = stroke(id: "typed-" + family.rawValue)
                    styled.brush = .init(family: family, seed: UInt64.max, gradientEndColor: family == .gradient ? .init(red: 0, green: 0, blue: 1) : nil)
                    let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(request(editor, .apply([draw(editor, [styled])]))))
                    let receipt = try StudioCommandExecutor.execute(decoded, editor: &editor)
                    try require(editor.document.frames[0].elements[0].brush == styled.brush && receipt.createdElementIDs == [styled.id], "Typed brush descriptor/seed or factual receipt changed")
                    let after = content(editor.document)
                    _ = try StudioCommandExecutor.execute(request(editor, .undo), editor: &editor)
                    try require(content(editor.document) == before, "Styled request undo lost original document")
                    _ = try StudioCommandExecutor.execute(request(editor, .redo), editor: &editor)
                    try require(content(editor.document) == after, "Styled request redo changed captured settings")
                    try require(StudioCommandContext(document: editor.document).supportedBrushFamilies.contains(family), "Command context omits supported family")
                }
            }
            try test("typed alpha lock and Pencil tilt use actual canonical paint semantics") {
                var editor = try fresh()
                _ = try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, [stroke(id: "base")])])), editor: &editor)
                var tilted = stroke(id: "tilted", points: [.init(x: 20, y: 30, pressure: 0.4, timestamp: 0, tilt: .init(altitude: 0.5, azimuth: 1))])
                tilted.brush = .init(version: 2, family: .calligraphy, seed: 12, pressureEnabled: true, tiltEnabled: true)
                let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(request(editor, .apply([
                    .updateLayer(.init(layer: .id(editor.document.activeLayerID), settings: .init(lock: .alpha))), draw(editor, [tilted])]))))
                _ = try StudioCommandExecutor.execute(decoded, editor: &editor)
                let actual = editor.document.frames[0].elements.last!
                try require(actual.preservesLayerAlpha == true && actual.points == tilted.points && actual.brush == tilted.brush && editor.document.schemaVersion == 24, "Typed capture lost canonical alpha/tilt metadata")
            }
            try test("invalid brush settings mixed descriptors and geometry budgets roll back entire transactions") {
                for invalidCase in 0..<5 {
                    var editor = try fresh(); var bad = stroke(id: "bad")
                    bad.brush = .init(family: .neon, seed: 1)
                    if invalidCase == 0 { bad.brush?.texture = 2 }
                    if invalidCase == 1 { bad.brush?.version = 99 }
                    if invalidCase == 2 { bad.shape = .init() }
                    if invalidCase == 3 { bad.brush?.tiltEnabled = true }
                    if invalidCase == 4 {
                        bad = stroke(id: "bad", points: (0..<4096).map { .init(x: $0 % 2 == 0 ? 0 : 512, y: 20) }, width: 1)
                        bad.brush = .init(family: .neon, seed: 1, smoothing: 0)
                    }
                    try rejected(request(editor, .apply([draw(editor, [stroke(id: "must-rollback"), bad])])), editor: &editor)
                }
            }
            try test("strict brush nested fields reject injected capabilities instead of silently ignoring them") {
                let editor = try fresh(); var styled = stroke(id: "strict")
                styled.brush = .init(family: .neon, seed: 1)
                let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request(editor, .apply([draw(editor, [styled])])))) as! [String:Any]
                for field in ["shell", "texturePath", "providerKey"] {
                    var object = original
                    var action = object["action"] as! [String:Any]; var operations = action["apply"] as! [[String:Any]]
                    var draw = operations[0]["draw"] as! [String:Any]; var values = draw["strokes"] as! [[String:Any]]
                    var brush = values[0]["brush"] as! [String:Any]; brush[field] = "untrusted input"
                    values[0]["brush"] = brush; draw["strokes"] = values; operations[0]["draw"] = draw; action["apply"] = operations; object["action"] = action
                    do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: object)); throw Failure(message: "Unknown brush field accepted") }
                    catch StudioCommandError.malformed { }
                }
            }
            try test("strict arrowhead command shares schema26 and preserves one reversible transaction") {
                var editor = try fresh(); let before = content(editor.document)
                var arrow = stroke(id: "typed-arrow", tool: .line)
                arrow.shape = .init(version: 2, arrowEnds: .both, arrowLength: 25)
                let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(request(editor, .apply([draw(editor, [arrow])]))))
                _ = try StudioCommandExecutor.execute(decoded, editor: &editor)
                try require(editor.document.schemaVersion == 26 && editor.document.frames[0].elements[0].shape == arrow.shape, "Arrow command lost canonical geometry")
                _ = try StudioCommandExecutor.execute(request(editor, .undo), editor: &editor)
                try require(content(editor.document) == before, "Arrow command undo lost original document")
                arrow.shape?.arrowLength = 101
                try rejected(request(editor, .apply([draw(editor, [stroke(id: "rollback-arrow"), arrow])])), editor: &editor)
            }
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
                    ["trim": NSNull()], ["trim": ["sourceOffset": 0]],
                    ["trim": ["sourceOffset": true, "duration": 1]], ["trim": ["sourceOffset": 0, "duration": "1"]],
                    ["trim": ["sourceOffset": 0, "duration": 1, "sourceURL": "file:///private"]],
                    ["fades": NSNull()], ["placement": NSNull()],
                    ["placement": ["startTime": 1]], ["placement": ["startTime": 1, "track": 1.5]],
                    ["placement": ["startTime": true, "track": 1]], ["placement": ["startTime": "1", "track": 1]],
                    ["placement": ["startTime": 1, "track": 1, "sourceURL": "file:///private"]]
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
                try require(StudioCommandContext(document: editor.document).supportedAudioEdits == ["clipVolume", "clipMute", "clipFades", "clipPlacement", "clipTrim", "clipDuplicate", "clipSplit", "clipDelete"], "capability context omitted implemented settings")
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
            func rotateImage(_ editor: StudioDocumentEditor, _ direction: StudioImageQuarterTurn = .clockwise,
                             assetID: String = "image-fixture") -> StudioCommand {
                .rotateImage(.init(frame: .id(editor.document.activeFrameID), assetID: assetID, direction: direction))
            }
            try test("linked image commands bind explicit layers and preserve sibling geometry in one transaction") {
                var editor = try imageEditor()
                let originalLayer = editor.document.activeLayerID
                try editor.duplicateLayer(originalLayer)
                let linkedLayer = editor.document.activeLayerID, frameID = editor.document.activeFrameID
                let before = editor.document
                let original = before.frames[0].rasterInstance(on: originalLayer)
                let commands: [StudioCommand] = [
                    .cropImage(.init(frame: .id(frameID), assetID: "image-fixture",
                        crop: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8), layer: .id(linkedLayer))),
                    .rotateImage(.init(frame: .id(frameID), assetID: "image-fixture", direction: .clockwise, layer: .id(linkedLayer))),
                    .reflectImage(.init(frame: .id(frameID), assetID: "image-fixture", axis: .horizontal, layer: .id(linkedLayer))),
                    .updateImagePlacement(.init(frame: .id(frameID), assetID: "image-fixture",
                        placement: .init(x: 10, y: 20, width: 200, height: 100), layer: .id(linkedLayer)))
                ]
                let encoded = try JSONEncoder().encode(request(editor, .apply(commands)))
                let decoded = try StudioCommandExecutor.decode(encoded)
                try StudioCommandExecutor.execute(decoded, editor: &editor)
                let result = editor.document
                try require(result.frames[0].rasterInstance(on: originalLayer) == original, "Linked edit changed original geometry")
                let changed = result.frames[0].rasterInstance(on: linkedLayer)
                try require(changed?.placement?.x == 10 && changed?.quarterTurns == 1 && changed?.reflection?.horizontal == true && changed?.crop != nil,
                    "Explicit layer commands did not reach duplicate")
                try require(result.frames[0].rasterAssetID == "image-fixture", "Linked edit changed immutable source")
                editor.undo(); try require(content(editor.document) == content(before), "Linked command batch was not one Undo")
                editor.redo(); try require(content(editor.document) == content(result), "Linked command Redo lost geometry")
                try rejected(decoded, editor: &editor, expected: .staleRevision)
                let selected = StudioCommandContext(document: editor.document).frames[0]
                try require(selected.imageLayerID == linkedLayer && selected.imagePlacement == changed?.placement, "Context described primary instead of selected copy")
                try StudioCommandExecutor.execute(request(editor, .apply([
                    .deleteImage(.init(frame: .id(frameID), assetID: "image-fixture", layer: .id(originalLayer)))
                ])), editor: &editor)
                try require(editor.document.frames[0].rasterLayerID == linkedLayer && editor.document.frames[0].rasterInstance(on: linkedLayer) == changed,
                    "Deleting primary did not preserve/promote linked copy")
            }
            try test("linked image legacy ambiguity wrong layers strict wire locks and cancellation reject atomically") {
                var editor = try imageEditor(); let primary = editor.document.activeLayerID
                try editor.duplicateLayer(primary)
                let linked = editor.document.activeLayerID, frameID = editor.document.activeFrameID
                let noLayer: [StudioCommand] = [
                    .deleteImage(.init(frame: .id(frameID), assetID: "image-fixture")),
                    .rotateImage(.init(frame: .id(frameID), assetID: "image-fixture", direction: .clockwise)),
                    .reflectImage(.init(frame: .id(frameID), assetID: "image-fixture", axis: .horizontal)),
                    .cropImage(.init(frame: .id(frameID), assetID: "image-fixture", crop: .full)),
                    .updateImagePlacement(.init(frame: .id(frameID), assetID: "image-fixture", placement: .init(x: 0, y: 0, width: 20, height: 20)))
                ]
                for command in noLayer { try rejected(request(editor, .apply([command])), editor: &editor, expected: .invalidReference) }
                let remove = StudioCommand.deleteImage(.init(frame: .id(frameID), assetID: "image-fixture", layer: .id(linked)))
                try rejected(request(editor, .apply([remove])), editor: &editor, cancellation: { throw CancellationError() })
                try rejected(request(editor, .apply([.deleteImage(.init(frame: .id(frameID), assetID: "image-fixture", layer: .id("missing")))])), editor: &editor, expected: .invalidReference)
                let valid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request(editor, .apply([remove])))) as! [String: Any]
                let invalidLayers: [Any] = [true, NSNull(), ["id": linked, "extra": "unsafe"], ["unknown": linked]]
                for invalid in invalidLayers {
                    var object = valid
                    object["action"] = ["apply": [["deleteImage": ["frame": ["id": frameID], "assetID": "image-fixture", "layer": invalid]]]]
                    do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: object)); throw Failure(message: "Malformed image layer accepted") }
                    catch is StudioCommandError { }
                }
                for mode in ["full", "position", "alpha"] {
                    var locked = editor
                    try locked.updateLayer(linked) { $0.lockMode = mode; $0.locked = mode == "full" }
                    try rejected(request(locked, .apply([remove])), editor: &locked)
                }
                var hidden = editor; try hidden.updateLayer(linked) { $0.visible = false }
                try rejected(request(hidden, .apply([remove])), editor: &hidden)
                try rejected(request(editor, .apply([remove, .selectFrame(.id("missing"))])), editor: &editor)
            }
            try test("image quarter turns use strict commands preserve source and reverse full placement history") {
                var editor = try imageEditor(); let before = editor.document
                let wire = try JSONEncoder().encode(request(editor, .apply([rotateImage(editor)])))
                let receipt = try StudioCommandExecutor.execute(StudioCommandExecutor.decode(wire), editor: &editor)
                let after = editor.document
                try require(receipt.outcome == .applied && after.revision == before.revision + 1, "Rotation not one transaction")
                var frame = before.frames[0]; frame.rasterPlacement = .init(x: 0, y: 128, width: 512, height: 256); frame.rasterQuarterTurns = 1
                try require(after.schemaVersion == 16 && after.frames == [frame] && after.layers == before.layers, "Rotation changed unrelated content or bounding box")
                try require(StudioCommandContext(document: after).frames[0].imageQuarterTurns == 1, "Spatter context omitted rotation")
                let decoded = try JSONDecoder().decode(StudioDocument.self, from: JSONEncoder().encode(after))
                try decoded.validate(); try require(decoded == after, "Rotation encoding changed")
                editor.undo(); try require(content(editor.document) == content(before), "Undo failed")
                editor.redo(); try require(content(editor.document) == content(after), "Redo failed")
                try StudioCommandExecutor.execute(request(editor, .apply([rotateImage(editor, .counterclockwise)])), editor: &editor)
                try require(editor.document.frames == before.frames, "Reverse turn did not restore image")
                let original = editor.document
                let noop = try StudioCommandExecutor.execute(request(editor, .apply(Array(repeating: rotateImage(editor), count: 4))), editor: &editor)
                try require(editor.document == original && noop.outcome == .unchanged, "Four centered quarter turns added history")
            }
            try test("rotation rejects invalid wire foreign and historical pictures and clamps only fitting results") {
                var editor = try imageEditor()
                try rejected(request(editor, .apply([rotateImage(editor, assetID: "other")])), editor: &editor, expected: .invalidReference)
                let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request(editor, .apply([rotateImage(editor)])))) as! [String: Any]
                for variant in 0..<4 {
                    var root = base; var action = root["action"] as! [String: Any]; var commands = action["apply"] as! [[String: Any]]
                    var fields = commands[0]["rotateImage"] as! [String: Any]
                    if variant == 0 { fields["direction"] = "arbitrary" }
                    if variant == 1 { fields["degrees"] = 45 }
                    if variant == 2 { fields["direction"] = 1 }
                    if variant == 3 { fields.removeValue(forKey: "assetID") }
                    commands[0]["rotateImage"] = fields; action["apply"] = commands; root["action"] = action
                    var caught = false; do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: root)) } catch { caught = true }
                    try require(caught, "Malformed rotation accepted")
                }
                try editor.change { $0.frames[0].rasterPlacement = .init(x: 0, y: 0, width: 100, height: 200) }
                try StudioCommandExecutor.execute(request(editor, .apply([rotateImage(editor)])), editor: &editor)
                try require(editor.document.frames[0].rasterPlacement == .init(x: 0, y: 50, width: 200, height: 100), "Edge rotation cropped or shrank")
                editor = try imageEditor()
                try editor.change { $0.width = 384 }
                try rejected(request(editor, .apply([rotateImage(editor)])), editor: &editor)
                try editor.change { $0.frames[0].rasterPlacement = nil }
                try rejected(request(editor, .apply([rotateImage(editor)])), editor: &editor, expected: .invalidReference)
            }
            try test("rotation locks visibility stale batches and every cancellation preserve content and history") {
                for mode in ["full", "position", "alpha", "hidden", "zero"] {
                    var editor = try imageEditor()
                    try editor.change { value in
                        if mode == "hidden" { value.layers[0].visible = false }
                        else if mode == "zero" { value.layers[0].opacity = 0 }
                        else { value.layers[0].lockMode = mode }
                    }
                    try rejected(request(editor, .apply([rotateImage(editor)])), editor: &editor)
                }
                var probe = try imageEditor(), checkpoints = 0
                let before = request(probe, .apply([rotateImage(probe)]))
                try StudioCommandExecutor.execute(before, editor: &probe, checkCancellation: { checkpoints += 1 })
                try rejected(before, editor: &probe, expected: .staleRevision)
                try require(checkpoints >= 5, "No bounded cancellation")
                for stop in 1...checkpoints {
                    var editor = try imageEditor(), calls = 0
                    try rejected(request(editor, .apply([rotateImage(editor)])), editor: &editor, cancellation: {
                        calls += 1; if calls == stop { throw CancellationError() }
                    })
                }
                var editor = try imageEditor()
                try rejected(request(editor, .apply([rotateImage(editor), rotateImage(editor, assetID: "missing")])), editor: &editor)
            }
            try test("rotation and canvas flips compose and frame copy delete retain independent metadata") {
                var editor = try imageEditor()
                try editor.reflectImage(frameID: editor.document.activeFrameID, assetID: "image-fixture", axis: .horizontal)
                try StudioCommandExecutor.execute(request(editor, .apply([rotateImage(editor)])), editor: &editor)
                let original = editor.document.frames[0]
                try require(original.rasterReflection == .init(vertical: true), "Quarter turn did not carry reflection")
                try editor.duplicateFrame()
                try require(editor.document.frames[1].rasterQuarterTurns == 1, "Frame duplicate lost rotation")
                try StudioCommandExecutor.execute(request(editor, .apply([rotateImage(editor)])), editor: &editor)
                try require(editor.document.frames[0] == original && editor.document.frames[1].rasterQuarterTurns == 2, "Shared source rotated other frame")
                let beforeDelete = editor.document
                try StudioCommandExecutor.execute(request(editor, .apply([imageDeletion(editor)])), editor: &editor)
                try require(editor.document.frames[1].rasterQuarterTurns == nil, "Image delete left orientation")
                editor.undo(); try require(content(editor.document) == content(beforeDelete), "Delete Undo dropped orientation")
                try editor.addLayer()
                try editor.deleteLayer(original.rasterLayerID!)
                try require(editor.document.frames.allSatisfy { $0.rasterQuarterTurns == nil }, "Layer delete left rotation")
            }
            try test("historical decoding stays untouched and invalid rotation schemas reject") {
                let original = try imageEditor().document
                let decoded = try JSONDecoder().decode(StudioDocument.self, from: JSONEncoder().encode(original))
                try require(decoded == original && decoded.frames[0].rasterQuarterTurns == nil, "Old project migrated on read")
                for variant in 0..<7 {
                    var bad = original; bad.schemaVersion = 16; bad.frames[0].rasterQuarterTurns = 1
                    if variant == 0 { bad.schemaVersion = 15 }
                    if variant == 1 { bad.frames[0].rasterPlacement = nil }
                    if variant == 2 { bad.frames[0].rasterQuarterTurns = 0 }
                    if variant == 3 { bad.frames[0].rasterQuarterTurns = -1 }
                    if variant == 4 { bad.frames[0].rasterQuarterTurns = 4 }
                    if variant == 5 { bad.frames[0].rasterQuarterTurns = Int.max }
                    if variant == 6 { bad.frames[0].rasterAssetID = nil }
                    var caught = false; do { try bad.validate() } catch { caught = true }
                    try require(caught, "Invalid rotation metadata accepted")
                }
            }

            func flipImage(_ editor: StudioDocumentEditor, _ axis: StudioReflectionAxis = .horizontal,
                           assetID: String = "image-fixture") -> StudioCommand {
                .reflectImage(.init(frame: .id(editor.document.activeFrameID), assetID: assetID, axis: axis))
            }
            try test("image reflection strict wire preserves placement and is one complete undo transaction") {
                var editor = try imageEditor(); let before = editor.document
                let wire = try JSONEncoder().encode(request(editor, .apply([flipImage(editor)])))
                let result = try StudioCommandExecutor.execute(StudioCommandExecutor.decode(wire), editor: &editor)
                let after = editor.document
                try require(after.schemaVersion == 15 && after.frames[0].rasterReflection == .init(horizontal: true), "Wrong reflection or schema")
                var expected = before.frames[0]; expected.rasterReflection = .init(horizontal: true)
                try require(after.frames == [expected] && after.layers == before.layers && after.audioClips == before.audioClips, "Reflection changed other content")
                try require(after.revision == before.revision + 1 && result.outcome == .applied, "Not one revision")
                try require(StudioCommandContext(document: after).frames[0].imageReflection == expected.rasterReflection, "Context omitted actual reflection")
                let decoded = try JSONDecoder().decode(StudioDocument.self, from: JSONEncoder().encode(after))
                try decoded.validate(); try require(decoded == after, "Reflection roundtrip changed")
                editor.undo(); try require(content(editor.document) == content(before), "Undo lost original schema/content")
                editor.redo(); try require(content(editor.document) == content(after), "Redo lost reflection")
                try StudioCommandExecutor.execute(request(editor, .apply([flipImage(editor, .vertical)])), editor: &editor)
                try require(editor.document.frames[0].rasterReflection == .init(horizontal: true, vertical: true), "Vertical reset horizontal")
                try StudioCommandExecutor.execute(request(editor, .apply([flipImage(editor), flipImage(editor, .vertical)])), editor: &editor)
                try require(editor.document.frames[0].rasterReflection == nil, "Original orientation not canonical nil")
                let unflipped = editor.document
                let noop = try StudioCommandExecutor.execute(request(editor, .apply([flipImage(editor), flipImage(editor)])), editor: &editor)
                try require(editor.document == unflipped && noop.outcome == .unchanged, "Cancelling flips created history")
            }
            try test("reflections reject foreign images legacy records invalid axes and unknown fields") {
                var editor = try imageEditor()
                try rejected(request(editor, .apply([flipImage(editor, assetID: "foreign")])), editor: &editor, expected: .invalidReference)
                let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request(editor, .apply([flipImage(editor)])))) as! [String: Any]
                for extra in [true, false] {
                    var root = base; var action = root["action"] as! [String: Any]
                    var commands = action["apply"] as! [[String: Any]]
                    var fields = commands[0]["reflectImage"] as! [String: Any]
                    if extra { fields["path"] = "/untrusted" } else { fields["axis"] = "diagonal" }
                    commands[0]["reflectImage"] = fields; action["apply"] = commands; root["action"] = action
                    var rejectedWire = false
                    do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: root)) } catch { rejectedWire = true }
                    try require(rejectedWire, "Invalid reflection wire accepted")
                }
                try editor.change { $0.frames[0].rasterPlacement = nil }
                try rejected(request(editor, .apply([flipImage(editor)])), editor: &editor, expected: .invalidReference)
                try require(editor.document.frames[0].rasterReflection == nil, "Historical original changed")
            }
            try test("image reflection lock visibility stale batch and every cancellation boundary are atomic") {
                for mode in ["full", "position", "alpha", "hidden", "zero"] {
                    var editor = try imageEditor()
                    try editor.change { value in
                        if mode == "hidden" { value.layers[0].visible = false }
                        else if mode == "zero" { value.layers[0].opacity = 0 }
                        else { value.layers[0].lockMode = mode }
                    }
                    try rejected(request(editor, .apply([flipImage(editor)])), editor: &editor)
                }
                var probe = try imageEditor(), checkpoints = 0
                let requestBefore = request(probe, .apply([flipImage(probe)]))
                try StudioCommandExecutor.execute(requestBefore, editor: &probe, checkCancellation: { checkpoints += 1 })
                try rejected(requestBefore, editor: &probe, expected: .staleRevision)
                try require(checkpoints >= 5, "No staged cancellation")
                for stop in 1...checkpoints {
                    var editor = try imageEditor(), count = 0
                    try rejected(request(editor, .apply([flipImage(editor)])), editor: &editor, cancellation: {
                        count += 1; if count == stop { throw CancellationError() }
                    })
                }
                var editor = try imageEditor()
                try rejected(request(editor, .apply([flipImage(editor), flipImage(editor, assetID: "missing")])), editor: &editor)
            }
            try test("reflected frame duplication clipboard and explicit deletion preserve independent orientations") {
                var editor = try imageEditor()
                try StudioCommandExecutor.execute(request(editor, .apply([flipImage(editor)])), editor: &editor)
                let original = editor.document.frames[0]
                try editor.duplicateFrame()
                try require(editor.document.frames[1].rasterReflection == original.rasterReflection, "Duplicate dropped reflection")
                try StudioCommandExecutor.execute(request(editor, .apply([flipImage(editor, .vertical)])), editor: &editor)
                try require(editor.document.frames[0] == original, "Flip mutated another frame sharing asset")
                let beforeDelete = editor.document
                try StudioCommandExecutor.execute(request(editor, .apply([imageDeletion(editor)])), editor: &editor)
                try require(editor.document.frames[1].rasterReflection == nil, "Image deletion left orphan reflection")
                editor.undo(); try require(content(editor.document) == content(beforeDelete), "Delete undo dropped orientation")
                try editor.addLayer()
                let imageLayer = editor.document.frames[0].rasterLayerID!
                try editor.deleteLayer(imageLayer)
                try require(editor.document.frames.allSatisfy { $0.rasterReflection == nil }, "Layer delete left orphan reflections")
            }
            try test("historical image decoding stays unchanged and invalid reflection metadata rejects") {
                let old = try imageEditor().document
                let bytes = try JSONEncoder().encode(old), decoded = try JSONDecoder().decode(StudioDocument.self, from: bytes)
                try require(decoded == old && decoded.schemaVersion == 3 && decoded.frames[0].rasterReflection == nil, "Historical image was migrated on read")
                for variant in 0..<3 {
                    var bad = old
                    bad.frames[0].rasterReflection = .init(horizontal: true)
                    if variant == 1 { bad.schemaVersion = 15; bad.frames[0].rasterPlacement = nil }
                    if variant == 2 { bad.schemaVersion = 15; bad.frames[0].rasterReflection = .init() }
                    var caught = false; do { try bad.validate() } catch { caught = true }
                    try require(caught, "Invalid reflection document accepted")
                }
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
                    .updateLayer(.init(layer: .created("ink"), settings: .init(opacity: 0.5, blend: .multiply, glowEnabled: true, glowColor: "#00FF00", glowRadius: 18, glowStrength: 0.35))),
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
                try require(after.layers[0].glowColor == "#00FF00" && after.layers[0].glowRadius == 18 && after.layers[0].glowStrength == 0.35 && after.schemaVersion == 28,
                            "Typed layer command lost glow style or schema")
                let undo = try StudioCommandExecutor.execute(request(editor, .undo), editor: &editor)
                try require(undo.outcome == .undone && content(editor.document) == content(before) && !editor.canUndo && editor.canRedo,
                            "one undo did not reverse entire mixed transaction")
                let redo = try StudioCommandExecutor.execute(request(editor, .redo), editor: &editor)
                try require(redo.outcome == .redone && content(editor.document) == content(after), "redo did not restore full transaction")
                let beforeBadGlow = editor.document
                for settings in [StudioCommandLayerSettings(glowRadius: 129), StudioCommandLayerSettings(glowStrength: -0.1), StudioCommandLayerSettings(glowColor: "#XYZXYZ")] {
                    var rejected = false
                    do { _ = try StudioCommandExecutor.execute(request(editor, .apply([.updateLayer(.init(layer: .id(after.layers[0].id), settings: settings))])), editor: &editor) }
                    catch { rejected = true }
                    try require(rejected && editor.document == beforeBadGlow, "Invalid typed glow setting committed partial state")
                }
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
                try rejected(request(editor, .apply([draw(editor, Array(repeating: stroke(), count: StudioCommandExecutor.maximumStrokes + 1))])), editor: &editor, expected: .limitExceeded)
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
            try test("plain primitive batches preserve repeated-commit geometry and one transaction history") {
                var editor = try fresh(), repeated = editor
                let before = editor.document
                let values = (0..<10).map { stroke(id: "primitive-\($0)", tool: $0 == 9 ? .circle : .line) }
                for value in values {
                    try repeated.commit(.init(id: value.id, tool: value.tool, points: value.points, color: value.color,
                        width: value.width, opacity: value.opacity, layerID: before.activeLayerID), frameID: before.activeFrameID)
                }
                _ = try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, values)])), editor: &editor)
                try require(content(editor.document) == content(repeated.document), "Batched primitives changed rendering inputs")
                editor.undo(); try require(content(editor.document) == content(before), "Primitive transaction not one Undo")
                editor.redo(); try require(content(editor.document) == content(repeated.document), "Primitive Redo changed geometry")
                for mode in ["alpha", "full"] {
                    var locked = try fresh()
                    try locked.change { $0.layers[0].lockMode = mode }
                    try rejected(request(locked, .apply([draw(locked, values)])), editor: &locked)
                }
                for mode in ["free", "position"] {
                    var allowed = try fresh()
                    try allowed.change { $0.layers[0].lockMode = mode; $0.layers[0].opacity = 0 }
                    _ = try StudioCommandExecutor.execute(request(allowed, .apply([draw(allowed, values)])), editor: &allowed)
                    try require(allowed.document.frames[0].elements.count == 10, "Existing invisible-opacity primitive semantics changed")
                }
                var hidden = try fresh()
                try hidden.change { $0.layers[0].visible = false }
                try rejected(request(hidden, .apply([draw(hidden, values)])), editor: &hidden)
                var duplicate = try fresh()
                try rejected(request(duplicate, .apply([draw(duplicate, [values[0], values[0]])])), editor: &duplicate)
                var invalid = try fresh()
                let late = stroke(tool: .line, color: "invalid")
                try rejected(request(invalid, .apply([draw(invalid, [values[0], late])])), editor: &invalid)
                var cancellationChecks = 0, probe = try fresh()
                _ = try StudioCommandExecutor.execute(request(probe, .apply([draw(probe, values)])), editor: &probe,
                    checkCancellation: { cancellationChecks += 1 })
                for boundary in 1...cancellationChecks {
                    var cancelled = try fresh(), checks = 0
                    try rejected(request(cancelled, .apply([draw(cancelled, values)])), editor: &cancelled,
                        cancellation: { checks += 1; if checks == boundary { throw CancellationError() } })
                }
            }
            try test("expanded command bounds accept 480 real primitives and reject 513 without partial edits") {
                var editor = try fresh()
                let values = (0..<480).map { stroke(id: "bounded-\($0)", tool: .line) }
                let commands = stride(from: 0, to: values.count, by: 10).map { draw(editor, Array(values[$0..<$0+10])) }
                _ = try StudioCommandExecutor.execute(request(editor, .apply(commands)), editor: &editor)
                try require(editor.document.frames[0].elements.count == 480, "480 strokes truncated")
                var exact = try fresh()
                let exactValues = (0..<StudioCommandExecutor.maximumStrokes).map { stroke(id: "exact-\($0)", tool: .line) }
                let exactCommands = stride(from: 0, to: exactValues.count, by: 16).map { draw(exact, Array(exactValues[$0..<min($0+16,exactValues.count)])) }
                _ = try StudioCommandExecutor.execute(request(exact, .apply(exactCommands)), editor: &exact)
                try require(exact.document.frames[0].elements.count == StudioCommandExecutor.maximumStrokes, "Exact stroke limit rejected")
                var commandBoundary = try fresh()
                let selected = StudioCommand.selectFrame(.id(commandBoundary.document.activeFrameID))
                _ = try StudioCommandExecutor.execute(request(commandBoundary, .apply(Array(repeating: selected, count: StudioCommandExecutor.maximumCommands))), editor: &commandBoundary)
                var tooMany = try fresh()
                let excess = (0..<(StudioCommandExecutor.maximumStrokes + 1)).map { stroke(id: "excess-\($0)", tool: .line) }
                try rejected(request(tooMany, .apply([draw(tooMany, excess)])), editor: &tooMany, expected: .limitExceeded)
            }
            try test("audio placement uses strict typed wire and preserves source and fades") {
                var editor = try audioEditor()
                try editor.updateAudioClip("first-audio", settings: .init(fades: .init(fadeIn: 0.1, fadeOut: 0.2)))
                let before = editor.document
                let change = request(editor, .apply([audioCommand(.init(placement: .init(startTime: 1.25, track: 4)))]))
                let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(change))
                let receipt = try StudioCommandExecutor.execute(decoded, editor: &editor)
                var expected = before.audioClips[0]; expected.startTime = 1.25; expected.track = 4
                try require(editor.document.audioClips[0] == expected && editor.document.audioClips[1] == before.audioClips[1]
                    && editor.document.audioTrackVolumes == before.audioTrackVolumes && editor.document.mutedAudioTracks == before.mutedAudioTracks
                    && receipt.changedAudioClipIDs == ["first-audio"], "Placement changed source, fades, another clip or lane settings")
                try rejected(change, editor: &editor, expected: .staleRevision)
                let after = editor.document
                editor.undo(); try require(content(editor.document) == content(before), "Placement Undo failed")
                editor.redo(); try require(content(editor.document) == content(after), "Placement Redo failed")
                for placement in [StudioAudioClipSettings.Placement(startTime: .nan, track: 1), .init(startTime: .infinity, track: 1),
                    .init(startTime: -1, track: 1), .init(startTime: 1001, track: 1), .init(startTime: 1, track: 0), .init(startTime: 1, track: 5)] {
                    try rejected(request(editor, .apply([audioCommand(.init(placement: placement))])), editor: &editor)
                }
                try rejected(request(editor, .apply([audioCommand(.init(placement: .init(startTime: 2, track: 1))),
                    .selectFrame(.id("missing"))])), editor: &editor)
                try rejected(request(editor, .apply([audioCommand(.init(placement: .init(startTime: 2, track: 1)))])),
                    editor: &editor, cancellation: { throw CancellationError() })
            }
            try test("typed audio trim preserves fade source phase and reverses one transaction") {
                var editor = try audioEditor()
                try editor.updateAudioClip("first-audio", settings: .init(fades: .init(fadeIn: 0.2, fadeOut: 0.3)))
                let before = editor.document
                let change = request(editor, .apply([audioCommand(.init(trim: .init(sourceOffset: 0.6, duration: 0.7)))]))
                let receipt = try StudioCommandExecutor.execute(StudioCommandExecutor.decode(JSONEncoder().encode(change)), editor: &editor)
                var expected = before.audioClips[0]; expected.sourceOffset = 0.6; expected.duration = 0.7
                try require(editor.document.audioClips[0] == expected && editor.document.audioClips[1] == before.audioClips[1]
                    && receipt.changedAudioClipIDs == ["first-audio"], "Trim reset fade phase or unrelated settings")
                let after = editor.document
                try rejected(change, editor: &editor, expected: .staleRevision)
                editor.undo(); try require(content(editor.document) == content(before), "Trim Undo failed")
                editor.redo(); try require(content(editor.document) == content(after), "Trim Redo failed")
                for trim in [StudioAudioClipSettings.Trim(sourceOffset: .nan, duration: 1), .init(sourceOffset: -1, duration: 1),
                    .init(sourceOffset: 301, duration: 1), .init(sourceOffset: 0, duration: .infinity),
                    .init(sourceOffset: 0, duration: 0), .init(sourceOffset: 0, duration: 0.000001), .init(sourceOffset: 0, duration: 301)] {
                    try rejected(request(editor, .apply([audioCommand(.init(trim: trim))])), editor: &editor)
                }
                let changed = audioCommand(.init(trim: .init(sourceOffset: 0.75, duration: 0.5)))
                try rejected(request(editor, .apply([changed, .selectFrame(.id("missing"))])), editor: &editor)
                try rejected(request(editor, .apply([changed])), editor: &editor, cancellation: { throw CancellationError() })
                _ = try StudioCommandExecutor.execute(request(editor, .apply([audioCommand(.init(trim: .init(sourceOffset: 0.75, duration: 0.5),
                    fades: .init(fadeIn: 0.1, fadeOut: 0.1)))])), editor: &editor)
                try require(editor.document.audioClips[0].fadeEnvelope == .init(sourceStartFrame: 36_000, frameCount: 24_000,
                    fadeInFrames: 4_800, fadeOutFrames: 4_800), "Explicit trim plus new fades used old source coordinates")
            }
            try test("duplicate audio typed command preserves source metadata identity history and bounds") {
                var editor = try audioEditor()
                try editor.updateAudioClip("first-audio", settings: .init(isMuted: true, fades: .init(fadeIn: 0.1, fadeOut: 0.2)))
                let before = editor.document
                let command = StudioCommand.duplicateAudioClip(.init(clipID: "first-audio", newClipID: "stable-copy"))
                let change = request(editor, .apply([command]))
                let receipt = try StudioCommandExecutor.execute(StudioCommandExecutor.decode(JSONEncoder().encode(change)), editor: &editor)
                let original = before.audioClips[0], copy = editor.document.audioClips.last!
                try require(copy.id == "stable-copy" && copy.assetID == original.assetID && copy.sourceOffset == original.sourceOffset
                    && copy.duration == original.duration && copy.startTime == original.startTime + original.duration
                    && copy.track == original.track && copy.volume == original.volume && copy.isMuted == original.isMuted
                    && copy.fadeEnvelope == original.fadeEnvelope && receipt.changedAudioClipIDs == [copy.id]
                    && receipt.createdFrameIDs.isEmpty, "Duplicate rewrote source settings or invented frames")
                let after = editor.document
                try rejected(change, editor: &editor, expected: .staleRevision)
                try rejected(request(editor, .apply([command])), editor: &editor)
                editor.undo(); try require(content(editor.document) == content(before), "Duplicate Undo failed")
                editor.redo(); try require(content(editor.document) == content(after), "Duplicate Redo regenerated identity")
                let freshCopy = StudioCommand.duplicateAudioClip(.init(clipID: "first-audio", newClipID: "cancel-copy"))
                try rejected(request(editor, .apply([freshCopy])), editor: &editor, cancellation: { throw CancellationError() })
                try rejected(request(editor, .apply([freshCopy, .selectFrame(.id("missing"))])), editor: &editor)
                for id in ["", "stable-copy", String(repeating: "x", count: 121), "bad\nID"] {
                    try rejected(request(editor, .apply([.duplicateAudioClip(.init(clipID: "first-audio", newClipID: id))])), editor: &editor)
                }
                var full = before
                full.audioClips = (0..<128).map { index in
                    AudioClip(id: "full-\(index)", soundName: original.soundName, track: 1, startTime: 0,
                        duration: 1, assetID: original.assetID)
                }
                var capped = try StudioDocumentEditor(document: full)
                try rejected(request(capped, .apply([.duplicateAudioClip(.init(clipID: "full-0", newClipID: "overflow"))])), editor: &capped)
            }
            try test("duplicate audio wire rejects paths missing identities and unknown fields") {
                let editor = try audioEditor()
                let seed = request(editor, .apply([.duplicateAudioClip(.init(clipID: "first-audio", newClipID: "copy"))]))
                let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(seed)) as! [String: Any]
                let invalid: [[String: Any]] = [["clipID": "first-audio"], ["clipID": true, "newClipID": "copy"],
                    ["clipID": "first-audio", "newClipID": "copy", "sourceURL": "file:///private"]]
                for fields in invalid {
                    var object = base; object["action"] = ["apply": [["duplicateAudioClip": fields]]]
                    do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: object)); throw Failure(message: "Malformed duplicate wire accepted") }
                    catch is StudioCommandError { }
                }
            }
            try test("typed audio split and delete preserve source phase stable IDs and one-step history") {
                var editor = try audioEditor()
                try editor.updateAudioClip("first-audio", settings: .init(fades: .init(fadeIn: 0.2, fadeOut: 0.3)))
                let before = editor.document
                let split = StudioCommand.splitAudioClip(.init(clipID: "first-audio", seconds: 0.750014, newClipID: "right"))
                let change = request(editor, .apply([split]))
                let receipt = try StudioCommandExecutor.execute(StudioCommandExecutor.decode(JSONEncoder().encode(change)), editor: &editor)
                let after = editor.document, left = after.audioClips[0], right = after.audioClips[1]
                try require(left.id == "first-audio" && right.id == "right" && left.fadeEnvelope == before.audioClips[0].fadeEnvelope
                    && right.fadeEnvelope == left.fadeEnvelope && right.assetID == left.assetID && right.startTime == 36_001 / 48_000.0
                    && right.sourceOffset == 48_001 / 48_000.0 && after.audioClips[2] == before.audioClips[1]
                    && Set(receipt.changedAudioClipIDs) == ["first-audio", "right"] && receipt.createdFrameIDs.isEmpty,
                    "Split lost source phase or changed unrelated clip")
                try rejected(change, editor: &editor, expected: .staleRevision)
                editor.undo(); try require(content(editor.document) == content(before), "Split Undo failed")
                editor.redo(); try require(content(editor.document) == content(after), "Split Redo changed ID")
                let remove = request(editor, .apply([.deleteAudioClip(.init(clipID: "right"))]))
                let deleted = try StudioCommandExecutor.execute(StudioCommandExecutor.decode(JSONEncoder().encode(remove)), editor: &editor)
                try require(editor.document.audioClips == [left, before.audioClips[1]] && deleted.changedAudioClipIDs == ["right"], "Delete affected other audio")
                editor.undo(); try require(content(editor.document) == content(after), "Delete Undo failed")
                for time in [Double.nan, .infinity, -1, left.startTime, left.startTime + left.duration] {
                    try rejected(request(editor, .apply([.splitAudioClip(.init(clipID: left.id, seconds: time, newClipID: "invalid"))])), editor: &editor)
                }
                let deletion = StudioCommand.deleteAudioClip(.init(clipID: "right"))
                try rejected(request(editor, .apply([deletion])), editor: &editor, cancellation: { throw CancellationError() })
                try rejected(request(editor, .apply([deletion, .selectFrame(.id("missing"))])), editor: &editor)
                try rejected(request(editor, .apply([.deleteAudioClip(.init(clipID: "missing"))])), editor: &editor)
            }
            try test("split delete wire and capacity reject without partial state") {
                let editor = try audioEditor()
                let seed = request(editor, .apply([.deleteAudioClip(.init(clipID: "first-audio"))]))
                let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(seed)) as! [String: Any]
                let invalid: [[String: Any]] = [
                    ["deleteAudioClip": ["clipID": "first-audio", "all": true]],
                    ["deleteAudioClip": ["clipID": true]],
                    ["splitAudioClip": ["clipID": "first-audio", "seconds": 0.5]],
                    ["splitAudioClip": ["clipID": "first-audio", "seconds": "0.5", "newClipID": "copy"]],
                    ["splitAudioClip": ["clipID": "first-audio", "seconds": 0.5, "newClipID": "copy", "sourceURL": "file:///private"]]
                ]
                for fields in invalid {
                    var object = base; object["action"] = ["apply": [fields]]
                    do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: object)); throw Failure(message: "Malformed split/delete accepted") }
                    catch is StudioCommandError { }
                }
                var full = editor.document
                full.audioClips = (0..<128).map { AudioClip(id: "full-\($0)", soundName: "Managed", track: 1,
                    startTime: 0, duration: 1, assetID: editor.document.audioClips[0].assetID) }
                var capped = try StudioDocumentEditor(document: full)
                try rejected(request(capped, .apply([.splitAudioClip(.init(clipID: "full-0", seconds: 0.5, newClipID: "overflow"))])), editor: &capped)
                var current = try audioEditor()
                try rejected(request(current, .apply([.splitAudioClip(.init(clipID: "first-audio", seconds: 0.5, newClipID: "second-audio"))])), editor: &current)
                let sourceID = current.document.audioClips[0].assetID!
                let remove = request(current, .apply([.deleteAudioClip(.init(clipID: "first-audio")), .deleteAudioClip(.init(clipID: "second-audio"))]))
                _ = try StudioCommandExecutor.execute(remove, editor: &current)
                try require(current.document.audioClips.isEmpty && current.referencedAudioAssetIDsIncludingHistory.contains(sourceID), "Delete discarded the only Undo source")
                current.undo(); try require(current.document.audioClips.count == 2, "One Undo did not restore both deleted clips")
            }
            try test("typed project rename shares normalized bounds preserves identity and reverses atomically") {
                var editor = try audioEditor()
                _ = try StudioCommandExecutor.execute(request(editor, .apply([draw(editor, [stroke(id: "rename-selection")])])), editor: &editor)
                editor.selectedElementIDs = ["rename-selection"]
                let before = editor.document, selection = editor.selectedElementIDs
                let change = request(editor, .apply([.renameProject(.init(name: "  Sunset  "))]))
                let receipt = try StudioCommandExecutor.execute(StudioCommandExecutor.decode(JSONEncoder().encode(change)), editor: &editor)
                var expected = before; expected.name = "Sunset"
                try require(content(editor.document) == content(expected) && receipt.outcome == .applied
                    && receipt.changedAudioClipIDs.isEmpty && receipt.createdFrameIDs.isEmpty && editor.selectedElementIDs == selection, "Rename changed artwork/source or false receipt")
                let after = editor.document
                try rejected(change, editor: &editor, expected: .staleRevision)
                editor.undo(); try require(content(editor.document) == content(before), "Rename Undo failed")
                editor.redo(); try require(content(editor.document) == content(after), "Rename Redo failed")
                let beforeNoOp = editor.document, undoBeforeNoOp = editor.canUndo, redoBeforeNoOp = editor.canRedo
                let noOp = try StudioCommandExecutor.execute(request(editor, .apply([.renameProject(.init(name: " Sunset "))])), editor: &editor)
                try require(editor.document == beforeNoOp && editor.canUndo == undoBeforeNoOp && editor.canRedo == redoBeforeNoOp
                    && noOp.outcome == .unchanged, "Same normalized name created revision or changed history")
                for name in ["", "   ", "bad\tname", String(repeating: "a", count: 121), "a" + String(repeating: "\u{0301}", count: 241)] {
                    try rejected(request(editor, .apply([.renameProject(.init(name: name))])), editor: &editor)
                }
                let rename = StudioCommand.renameProject(.init(name: "Another"))
                try rejected(request(editor, .apply([rename])), editor: &editor, cancellation: { throw CancellationError() })
                try rejected(request(editor, .apply([rename, .selectFrame(.id("missing"))])), editor: &editor)
                let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as! [String: Any]
                let invalid: [[String: Any]] = [["name": true], [:], ["name": "Valid", "shell": "execute"]]
                for fields in invalid {
                    var object = base; object["action"] = ["apply": [["renameProject": fields]]]
                    do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: object)); throw Failure(message: "Malformed rename accepted") }
                    catch is StudioCommandError { }
                }
            }
            try test("mixed artwork order strict wire binds image and drawing identities in one reversible edit") {
                var doc = try StudioDocument.new(name: "Mixed order wire", width: 64, height: 64, fps: 12)
                let layer = doc.activeLayerID, frame = doc.activeFrameID, asset = "image-" + UUID().uuidString
                doc.schemaVersion = 3
                doc.frames[0].rasterAssetID = asset; doc.frames[0].rasterLayerID = layer
                doc.frames[0].rasterPlacement = .init(x: 8, y: 8, width: 32, height: 32)
                doc.frames[0].elements = ["unselected", "selected", "top"].map {
                    DrawnElement(id: $0, tool: .line, points: [.init(x: 4, y: 8), .init(x: 40, y: 8)],
                                 color: "#000000", width: 2, opacity: 1, layerID: layer)
                }
                var editor = try StudioDocumentEditor(document: doc)
                let command = StudioCommand.orderSelectedArtwork(.init(frame: .id(frame), elementIDs: ["selected"],
                    image: .init(assetID: asset, layerID: layer), direction: .later))
                let encoded = try JSONEncoder().encode(request(editor, .apply([command])))
                let decoded = try StudioCommandExecutor.decode(encoded)
                let receipt = try StudioCommandExecutor.execute(decoded, editor: &editor)
                try require(receipt.outcome == .applied && editor.document.schemaVersion == 33 &&
                    editor.document.frames[0].elements.map(\.id) == ["unselected", "top", "selected"] &&
                    editor.document.frames[0].rasterStackPosition == 1 && editor.document.frames[0].rasterAssetID == asset,
                    "Mixed order wire lost target identity or image position")
                let changed = editor.document
                editor.undo(); try require(content(editor.document) == content(doc), "Mixed order was not one Undo")
                editor.redo(); try require(content(editor.document) == content(changed), "Mixed order Redo changed identities")
                let wire = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
                let frameRef: [String: Any] = ["id": frame]
                let malformedBodies: [[String: Any]] = [
                    ["frame": frameRef, "elementIDs": ["selected"], "image": ["assetID": asset, "layerID": layer, "shell": "run"], "direction": "later"],
                    ["frame": frameRef, "elementIDs": ["selected"], "image": ["assetID": asset], "direction": "later"],
                    ["frame": frameRef, "elementIDs": ["selected"], "image": NSNull(), "direction": "front"],
                    ["frame": frameRef, "elementIDs": ["selected"], "image": NSNull(), "direction": "later", "script": "run"]
                ]
                for fields in malformedBodies {
                    var malformed = wire; malformed["action"] = ["apply": [["orderSelectedArtwork": fields]]]
                    do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: malformed)); throw Failure(message: "Malformed order accepted") }
                    catch is StudioCommandError { }
                }
                for invalid in [
                    StudioCommand.OrderSelectedArtwork(frame: .id(frame), elementIDs: [], image: nil, direction: .later),
                    .init(frame: .id(frame), elementIDs: ["selected", "selected"], image: nil, direction: .later),
                    .init(frame: .id(frame), elementIDs: ["missing"], image: .init(assetID: asset, layerID: layer), direction: .later),
                    .init(frame: .id(frame), elementIDs: ["selected"], image: .init(assetID: "image-" + UUID().uuidString, layerID: layer), direction: .later)
                ] { try rejected(request(editor, .apply([.orderSelectedArtwork(invalid)])), editor: &editor) }
                try rejected(request(editor, .apply([command, .selectFrame(.id("missing"))])), editor: &editor)
                try rejected(request(editor, .apply([command])), editor: &editor, cancellation: { throw CancellationError() })
            }
            print("STUDIO_COMMAND_TESTS=PASS \(passed) production command cases")
        } catch {
            print("STUDIO_COMMAND_TESTS=FAIL \(error)")
            exit(1)
        }
    }
}
