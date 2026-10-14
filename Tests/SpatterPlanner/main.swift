import Foundation

// Spatter planner, impact-primitive, registry-extension and quality-gate suite
// (#204, #205, #206, #213, #214, #279, #280). It runs the production parsers,
// the production StudioCommandExecutor and StudioDocumentEditor, with no view
// model, renderer, provider or network. Foundation only, so it also runs on
// Linux with stub SwiftUI/UIKit/CoreGraphics modules (developer check) and on
// macOS CI with the real frameworks.
//
// Compile with the SpatterMotionRecipe source list minus the view model:
//   Models/Models.swift, Models/StudioBrush.swift, Services/StudioBrushRenderer.swift,
//   Models/StudioDocument.swift, Models/StudioCommands.swift, Models/StudioCraftAudio.swift,
//   Models/StudioCraftLayers.swift, Models/StudioSmudge.swift, Models/StudioBlur.swift,
//   Models/StudioSharpen.swift, Models/StudioDodgeBurn.swift, the four *Descriptor.swift files,
//   App/AppConfig.swift, App/SpatterBackendClient.swift, Models/SpatterMotionRecipe.swift,
//   Services/Spatter/SpatterKnowledgeBase.swift, Services/Spatter/SpatterStudioControlRegistry.swift,
//   Tests/SpatterPlanner/main.swift

private struct Failure: Error, CustomStringConvertible { let message: String; var description: String { message } }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
}
private func rejects(_ label: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw Failure(message: "Accepted input that must be refused: \(label)")
}

/// Golden fingerprints of quantized geometry. Any deliberate change to the pose
/// tables, impact palette or planner layout must update these together with the
/// style spec; an accidental drift fails here.
private enum Golden {
    static let briefExample: UInt64 = 0xD645_B007_B38B_1978
    static let impactBlood: UInt64 = 0x8FB5_445E_1A0C_901F
    static let explosionBrief: UInt64 = 0xAC96_CC26_8DA1_8AF5
}

@main struct SpatterPlannerTests {
    static func document(width: Int = 256, height: Int = 192, fps: Int = 24, frames: Int = 1) throws -> StudioDocument {
        var doc = try StudioDocument.new(name: "Planner", width: width, height: height, fps: fps)
        doc.schemaVersion = 35
        let layer = doc.activeLayerID
        for index in 0..<frames {
            let w = CGFloat(width), h = CGFloat(height)
            let line = DrawnElement(id: "seed-\(index)", tool: .line, points: [.init(x: w * 0.05, y: h * 0.05 + CGFloat(index)), .init(x: w * 0.25, y: h * 0.1 + CGFloat(index))],
                                    color: "#000000", width: 2, opacity: 1, layerID: layer)
            if index == 0 { doc.frames[0].elements = [line] } else { doc.frames.append(.init(id: "frame-\(index)", elements: [line])) }
        }
        try doc.validate()
        return doc
    }
    static func content(_ value: StudioDocument) -> StudioDocument { var copy = value; copy.revision = 0; copy.modifiedAt = copy.createdAt; return copy }
    static func execute(_ request: StudioCommandRequest, on editor: inout StudioDocumentEditor) throws -> StudioCommandReceipt {
        // Round-trip through the strict wire decoder exactly like the view model does.
        let decoded = try StudioCommandExecutor.decode(JSONEncoder().encode(request))
        return try StudioCommandExecutor.execute(decoded, editor: &editor, checkCancellation: {})
    }
    static func primitives(_ doc: StudioDocument, layerID: String) -> [[SpatterPrimitive]] {
        doc.frames.map { frame in
            frame.elements.filter { $0.layerID == layerID }.map { element in
                SpatterPrimitive(kind: element.tool == .circle ? .circle : .line, x0: Double(element.points[0].x), y0: Double(element.points[0].y),
                                 x1: Double(element.points[1].x), y1: Double(element.points[1].y), color: element.color, width: Double(element.width), opacity: element.opacity)
            }
        }
    }

    static func main() {
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { print("FAIL \(name): \(error)"); throw error }
        }
        do {
            try test("multi-clause brief grammar parses the documented forms and rejects hostile or impossible briefs") {
                let brief = try SpatterMultiClauseBrief.parse(SpatterMultiClauseBrief.example)
                try require(brief.actors.count == 1 && brief.actors[0].color == "#FF0000" && brief.seconds == 3
                    && brief.actors[0].clauses.map(\.action) == [.walk, .punch, .fall]
                    && brief.actors[0].clauses[0].direction == 1 && brief.actors[0].clauses[0].seconds == 1
                    && brief.actors[0].clauses[1].seconds == nil, "Example brief parsed incorrectly")
                try require(try SpatterMultiClauseBrief.parse(SpatterMultiClauseBrief.example).seed == brief.seed, "Seed is not deterministic for the same brief")
                let seeded = try SpatterMultiClauseBrief.parse(SpatterMultiClauseBrief.explosionExample)
                try require(seeded.seed == 7 && seeded.seconds == 2 && seeded.actors[0].clauses.last?.action == .explode, "Explicit seed or default actions lost")
                let two = try SpatterMultiClauseBrief.parse(SpatterMultiClauseBrief.twoActorExample)
                try require(two.actors.count == 2 && two.actors[1].color == "#0000FF" && two.actors[1].clauses.map(\.action) == [.duck, .jump] && two.seconds == 2.5, "Two-actor brief lost an actor")
                // Historical brief forms remain parseable (superset) but are routed to their own grammars.
                let legacy = try SpatterMultiClauseBrief.parse(SpatterSceneBrief.example)
                try require(legacy.actors.count == 1 && legacy.actors[0].clauses.map(\.action) == [.walk, .wave], "Legacy two-action brief is not a subset")
                let legacyDuo = try SpatterMultiClauseBrief.parse(SpatterTwoActorBrief.example)
                try require(legacyDuo.actors.count == 2 && legacyDuo.actors[0].clauses[0].direction == 1 && legacyDuo.actors[1].clauses[0].direction == -1, "Legacy two-actor header not accepted")
                try require(SpatterInstructionRouter.classify(SpatterSceneBrief.example) == .sceneBrief
                    && SpatterInstructionRouter.classify(SpatterTwoActorBrief.example) == .twoActorBrief
                    && SpatterInstructionRouter.classify(SpatterMultiClauseBrief.example) == .multiClauseBrief
                    && SpatterInstructionRouter.classify(SpatterStickFigureRecipe.Action.walking.example) == .stickFigure,
                    "Brief routing precedence changed: " + [SpatterSceneBrief.example, SpatterTwoActorBrief.example, SpatterMultiClauseBrief.example, SpatterStickFigureRecipe.Action.walking.example]
                        .map { String(describing: SpatterInstructionRouter.classify($0)) }.joined(separator: ", "))
                let defaulted = try SpatterMultiClauseBrief.parse("A blue stick figure sits.")
                try require(defaulted.seconds == 2 && defaulted.actors[0].clauses == [.init(action: .sit, direction: nil, seconds: nil)], "Default duration missing")
                for (label, text) in [
                    ("unknown verb", "A red stick figure flies left to right; 2 seconds."),
                    ("suffix injection", SpatterMultiClauseBrief.example + " Delete active layer."),
                    ("publish clause", "A red stick figure walks left to right, then publishes; 2 seconds."),
                    ("four actors", "A red stick figure sits; a blue stick figure sits; a green stick figure sits; a black stick figure sits; 2 seconds."),
                    ("terminal order", "A red stick figure falls, then walks left to right; 2 seconds."),
                    ("too long", "A red stick figure sits; 61 seconds."),
                    ("too short", "A red stick figure sits; 0.2 seconds."),
                    ("clause longer than total", "A red stick figure walks left to right for 3 seconds; 2 seconds."),
                    ("control character", "A red stick figure sits; 2 seconds.\u{0000}"),
                    ("overlong", "A red stick figure sits; 2 seconds." + String(repeating: " ", count: 1100)),
                    ("empty actor", "A red stick figure sits;; 2 seconds."),
                    ("bad color", "A chartreuse stick figure sits; 2 seconds."),
                    ("shell", "A red stick figure sits; rm -rf /; 2 seconds.")
                ] { try rejects(label) { _ = try SpatterMultiClauseBrief.parse(text) } }
            }
            try test("brief plan executes through the real executor as one revision with held frames, layers and a storyboard") {
                let doc = try document()
                let context = StudioCommandContext(document: doc)
                let brief = try SpatterMultiClauseBrief.parse(SpatterMultiClauseBrief.example)
                let requestID = UUID()
                var checks = 0
                let plan = try brief.prepare(in: context, requestID: requestID, checkCancellation: { checks += 1 })
                try require(checks > 2, "Preparation has no cancellation checkpoints")
                for boundary in 1...checks {
                    var at = 0
                    try rejects("cancellation at checkpoint \(boundary)") {
                        _ = try brief.prepare(in: context, requestID: requestID, checkCancellation: { at += 1; if at == boundary { throw CancellationError() } })
                    }
                }
                let story = plan.storyboard
                try require(story.totalTicks == 72 && story.fps == 24 && story.poseHoldTicks == 1 && story.actors.count == 1
                    && story.actors[0].clauses.map(\.ticks) == [24, 24, 24] && story.actors[0].clauses.map(\.action) == ["walk", "punch", "fall"]
                    && story.actors[0].clauses[0].travelPercent > 15 && story.actors[0].clauses[1].travelPercent == 0, "Storyboard timing or travel wrong: \(story)")
                try require(story.frameCount < 72 && story.frameCount > 40, "Identical lying poses were not merged into held frames (frames=\(story.frameCount))")
                guard case .apply(let commands) = plan.prepared.request.action, commands.count == 3,
                      case .addLayer = commands[0], case .appendFrames(let batch) = commands[1], case .selectFrame = commands[2] else { throw Failure(message: "Plan shape is not addLayer + appendFrames + selectFrame") }
                try require(batch.frames.reduce(0) { $0 + $1.holdTicks } == 72 && batch.frames.count == story.frameCount, "Frame holds do not cover the requested ticks")
                let again = try brief.prepare(in: context, requestID: requestID, checkCancellation: {})
                let sortedEncoder = JSONEncoder(); sortedEncoder.outputFormatting = [.sortedKeys]
                let first = try sortedEncoder.encode(plan.prepared.request), second = try sortedEncoder.encode(again.prepared.request)
                if first != second {
                    let index = zip(first, second).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(first.count, second.count)
                    let window = String(decoding: first[max(0, index - 80)..<min(first.count, index + 80)], as: UTF8.self)
                    throw Failure(message: "Same brief, seed and request produced different commands at byte \(index) of \(first.count)/\(second.count): …\(window)…")
                }
                let json = try story.json()
                let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
                try require(object?["schema"] as? String == "spatter_storyboard" && object?["version"] as? Int == 1 && (object?["actors"] as? [Any])?.count == 1, "Storyboard JSON shape wrong")

                var editor = try StudioDocumentEditor(document: doc)
                let before = editor.document
                let receipt = try execute(plan.prepared.request, on: &editor)
                try require(receipt.outcome == .applied && receipt.revision == before.revision + 1 && receipt.createdLayerIDs.count == 1
                    && receipt.createdFrameIDs.count == story.frameCount && receipt.createdElementIDs.count == story.generatedElementCount
                    && receipt.deletedFrameIDs.isEmpty && receipt.deletedElementIDs.isEmpty, "Receipt does not match the plan")
                let after = editor.document
                try require(after.frames[0] == before.frames[0] && after.frames.count == before.frames.count + story.frameCount
                    && after.activeFrameID == receipt.createdFrameIDs[0] && after.layers.count == 2 && after.schemaVersion >= 21, "Original frame changed or selection wrong")
                let layerID = receipt.createdLayerIDs[0]
                let generated = Array(after.frames.dropFirst())
                try require(generated.allSatisfy { $0.elements.count == 10 && $0.elements.allSatisfy { $0.layerID == layerID && $0.color == "#FF0000" } }, "Generated poses are not ten editable primitives on the actor layer")
                try require(Set(generated.flatMap { $0.elements.map(\.id) }).count == story.generatedElementCount, "Element identities collide")
                let fingerprint = SpatterPrimitive.fingerprint(primitives(after, layerID: layerID))
                print("fingerprint brief-example 0x\(String(fingerprint, radix: 16, uppercase: true))")
                try require(fingerprint == Golden.briefExample, "Golden geometry drifted for the example brief")
                let report = SpatterQualityReport.analyze(after, requestedTicks: before.frames[0].durationTicks + 72, generatedLayerIDs: [layerID])
                try require(report.blankFrameCount == 0 && report.frozenFrameCount == 0 && report.outOfCanvasCount == 0
                    && !report.findings.contains { $0.kind == .timingMismatch || $0.kind == .limbVariance }, "Quality findings on a clean plan: \(report.findings)")
                try require(report.verdict().passes, "Verdict failed a clean plan")
                editor.undo()
                try require(content(editor.document) == content(before), "One Undo did not restore the original document")
                editor.redo()
                try require(content(editor.document) == content(after), "Redo lost the generated scene")
                // Revert path: deleteFrameRange + deleteLayer in one later request.
                let revert = StudioCommandRequest(requestID: UUID(), projectID: doc.id, expectedRevision: editor.document.revision,
                    action: .apply([.deleteFrameRange(.init(frameIDs: receipt.createdFrameIDs)), .deleteLayer(.id(layerID))]))
                let reverted = try execute(revert, on: &editor)
                try require(reverted.outcome == .applied && reverted.deletedFrameIDs.count == story.frameCount && reverted.deletedLayerIDs == [layerID]
                    && content(editor.document) == content(before), "Typed revert did not restore the prior content")
            }
            try test("every action in the vocabulary plans, executes and keeps bone lengths across frames") {
                for action in SpatterBriefAction.allCases {
                    let doc = try document()
                    let direction = action.speedPercentPerSecond > 0 ? " left to right" : ""
                    let verb = action.rawValue + (action == .punch ? "es" : "s")
                    let brief = try SpatterMultiClauseBrief.parse("A black stick figure \(verb)\(direction); 1.5 seconds; seed 3.")
                    let plan: SpatterMultiClauseBrief.Plan
                    do { plan = try brief.prepare(in: StudioCommandContext(document: doc)) }
                    catch { throw Failure(message: "\(action) failed to plan: \(type(of: error)).\(error)") }
                    var editor = try StudioDocumentEditor(document: doc)
                    let receipt = try execute(plan.prepared.request, on: &editor)
                    try require(receipt.outcome == .applied && receipt.createdFrameIDs.count == plan.storyboard.frameCount, "\(action) did not apply")
                    let layerID = receipt.createdLayerIDs[0]
                    let frames = editor.document.frames.dropFirst()
                    let sum = frames.reduce(0) { $0 + $1.durationTicks }
                    try require(sum == 36, "\(action) frames do not cover 36 ticks (\(sum))")
                    if action == .explode {
                        try require(frames.first!.elements.count == 10 && frames.last!.elements.count != 10, "Explosion did not replace the figure with a burst")
                        try require(frames.last!.elements.contains { $0.tool == .circle && $0.color != "#000000" }, "Blood did not pool at the baseline")
                    } else {
                        // IK keeps bones exact; endpoints are quantized to 1/64 px, so allow 1% on 13–17 px bones.
                        let report = SpatterQualityReport.analyze(editor.document, generatedLayerIDs: [layerID], limbVarianceTolerance: 0.01)
                        let limbFindings = report.findings.filter { $0.kind == .limbVariance && !$0.detail.contains("limb 1 ") }
                        try require(limbFindings.isEmpty, "\(action) changed a bone length: \(limbFindings)")
                        try require(report.frozenFrameCount == 0 && report.blankFrameCount == 0 && report.outOfCanvasCount == 0, "\(action) produced blank, frozen or off-canvas frames")
                        // Cyclic actions revisit poses at non-consecutive ticks; consecutive repeats are merged into holds (frozenFrameCount above).
                        let poses = Set(frames.map { $0.elements.map(\.points).description })
                        try require(poses.count >= max(2, frames.count / 2), "\(action) is mostly static (\(poses.count) distinct of \(frames.count))")
                        if action == .throw { try require(frames.contains { $0.elements.count == 11 }, "Throw produced no projectile") }
                    }
                    if action.speedPercentPerSecond > 0 {
                        let first = frames.first!.elements[0].points[0].x, last = frames.last!.elements[0].points[0].x
                        try require(last > first, "\(action) did not travel left to right")
                    }
                }
            }
            try test("three actors share one request on separate layers and long briefs hold poses or refuse without flattening") {
                let doc = try document(width: 320, height: 240, fps: 24)
                let three = try SpatterMultiClauseBrief.parse("A red stick figure walks left to right; a blue stick figure jumps, then waves; a green stick figure runs right to left, then sits; 4 seconds; seed 11.")
                let plan = try three.prepare(in: StudioCommandContext(document: doc))
                // 96 ticks × 30 elements per frame exceeds the 1,008-element budget, so the
                // planner holds each pose for 3 ticks (32 frames) and says so in the storyboard.
                try require(plan.storyboard.actors.count == 3 && plan.storyboard.poseHoldTicks == 3 && plan.storyboard.frameCount == 32
                    && plan.storyboard.totalTicks == 96 && plan.storyboard.generatedElementCount <= StudioCommandExecutor.maximumGeneratedElements,
                    "Three-actor plan shape wrong: hold=\(plan.storyboard.poseHoldTicks) frames=\(plan.storyboard.frameCount)")
                var editor = try StudioDocumentEditor(document: doc)
                let receipt = try execute(plan.prepared.request, on: &editor)
                try require(receipt.createdLayerIDs.count == 3 && editor.document.layers.count == 4, "Three actors did not get three layers")
                for layer in receipt.createdLayerIDs {
                    let own = editor.document.frames.dropFirst().filter { $0.elements.contains { $0.layerID == layer } }
                    try require(own.count == plan.storyboard.frameCount, "An actor is missing from some frames")
                }
                let colors = Set(editor.document.frames.dropFirst().flatMap { $0.elements.map(\.color) })
                try require(colors == ["#FF0000", "#0000FF", "#00FF00"], "Actor colors were not preserved")
                let long = try SpatterMultiClauseBrief.parse("A red stick figure walks left to right; 12 seconds.")
                let held = try long.prepare(in: StudioCommandContext(document: doc))
                try require(held.storyboard.poseHoldTicks == 3 && held.storyboard.frameCount == 96 && held.storyboard.totalTicks == 288, "Long brief did not hold poses honestly: \(held.storyboard.poseHoldTicks)/\(held.storyboard.frameCount)")
                let tooLong = try SpatterMultiClauseBrief.parse("A red stick figure walks left to right; a blue stick figure runs right to left; a green stick figure jumps; 60 seconds.")
                do { _ = try tooLong.prepare(in: StudioCommandContext(document: doc)); throw Failure(message: "Over-budget brief accepted") }
                catch SpatterMultiClauseBrief.Failure.budget(let seconds) { try require(seconds >= 4 && seconds < 60, "Budget message does not state a shorter supported length") }
                // Figures scale with the canvas, so even the smallest canvas plans; every point must still be inside it.
                let tiny = try document(width: 32, height: 24, fps: 12)
                let tinyPlan = try SpatterMultiClauseBrief.parse("A red stick figure jumps; 1 second.").prepare(in: StudioCommandContext(document: tiny))
                var tinyEditor = try StudioDocumentEditor(document: tiny)
                _ = try execute(tinyPlan.prepared.request, on: &tinyEditor)
                try require(SpatterQualityReport.analyze(tinyEditor.document).outOfCanvasCount == 0, "Tiny canvas plan left the canvas")
            }
            try test("impact primitive is deterministic, bounded, pools blood and matches its golden fingerprint") {
                // A hit that sprays forward and slightly down from chest height: streaks land within the 0.5 s burst.
                let burst = SpatterImpactPrimitive(seed: 42, originX: 128, originY: 120, directionRadians: 0.4, intensity: 1, palette: .blood, frameCount: 12, fps: 24, scale: 60, groundY: 150)
                let frames = try burst.frames(canvasWidth: 256, canvasHeight: 192, lineWidth: 3)
                try require(frames.count == 12 && frames[0].count >= 20 && frames.allSatisfy { $0.allSatisfy { $0.fits(width: 256, height: 192) } }, "Burst frame shape wrong")
                try require(frames.last!.contains { $0.kind == .circle } && !frames[0].contains { $0.kind == .circle }, "Pooling did not appear after streaks landed")
                try require(frames[0].contains { $0.color == "#B3001B" } && frames[0].allSatisfy { $0.opacity == 1 } && frames.last!.contains { $0.opacity < 1 }, "Palette or fade wrong")
                let fingerprint = SpatterPrimitive.fingerprint(frames)
                print("fingerprint impact-blood 0x\(String(fingerprint, radix: 16, uppercase: true))")
                try require(fingerprint == Golden.impactBlood, "Impact golden fingerprint drifted")
                try require(try burst.frames(canvasWidth: 256, canvasHeight: 192, lineWidth: 3) == frames, "Same seed produced different geometry")
                let other = SpatterImpactPrimitive(seed: 43, originX: 128, originY: 120, directionRadians: 0.4, intensity: 1, palette: .blood, frameCount: 12, fps: 24, scale: 60, groundY: 150)
                try require(SpatterPrimitive.fingerprint(try other.frames(canvasWidth: 256, canvasHeight: 192, lineWidth: 3)) != fingerprint, "Different seeds produced identical geometry")
                let sparks = SpatterImpactPrimitive(seed: 42, originX: 128, originY: 96, directionRadians: 0, intensity: 0.4, palette: .spark, frameCount: 6, fps: 24, scale: 60, groundY: nil)
                let sparkFrames = try sparks.frames(canvasWidth: 256, canvasHeight: 192, lineWidth: 2)
                try require(sparkFrames.allSatisfy { $0.allSatisfy { $0.kind == .line } } && sparkFrames[2].count <= frames[2].count, "Sparks pooled or exceeded blood intensity")
                for (label, bad) in [
                    ("one frame", SpatterImpactPrimitive(seed: 1, originX: 0, originY: 0, directionRadians: 0, intensity: 1, palette: .dust, frameCount: 1, fps: 24, scale: 10, groundY: nil)),
                    ("intensity", SpatterImpactPrimitive(seed: 1, originX: 0, originY: 0, directionRadians: 0, intensity: 1.5, palette: .dust, frameCount: 4, fps: 24, scale: 10, groundY: nil)),
                    ("nan origin", SpatterImpactPrimitive(seed: 1, originX: .nan, originY: 0, directionRadians: 0, intensity: 1, palette: .dust, frameCount: 4, fps: 24, scale: 10, groundY: nil)),
                    ("zero scale", SpatterImpactPrimitive(seed: 1, originX: 0, originY: 0, directionRadians: 0, intensity: 1, palette: .dust, frameCount: 4, fps: 24, scale: 0, groundY: nil))
                ] { try rejects(label) { _ = try bad.frames(canvasWidth: 64, canvasHeight: 64, lineWidth: 2) } }
                let doc = try document()
                let plan = try SpatterMultiClauseBrief.parse(SpatterMultiClauseBrief.explosionExample).prepare(in: StudioCommandContext(document: doc))
                var editor = try StudioDocumentEditor(document: doc)
                let receipt = try execute(plan.prepared.request, on: &editor)
                let explosion = SpatterPrimitive.fingerprint(primitives(editor.document, layerID: receipt.createdLayerIDs[0]))
                print("fingerprint explosion-brief 0x\(String(explosion, radix: 16, uppercase: true))")
                try require(explosion == Golden.explosionBrief, "Explosion brief golden drifted")
            }
            try test("tween clipboard project-settings and brush grammars reach their typed commands and the real editor") {
                var doc = try document(frames: 2)
                doc.activeFrameID = doc.frames[0].id
                let context = StudioCommandContext(document: doc)
                let tween = try SpatterTweenInstruction.parse(SpatterTweenInstruction.example)
                try require(tween.inbetweens == 4 && tween.firstFrame == 1 && tween.easing == .easeInOut, "Tween capture wrong")
                try require(try SpatterTweenInstruction.parse(SpatterTweenInstruction.linearExample).easing == .linear, "Default easing wrong")
                var editor = try StudioDocumentEditor(document: doc)
                let tweened = try execute(try tween.prepare(in: context), on: &editor)
                try require(tweened.createdFrameIDs.count == 4 && editor.document.frames.count == 6, "Tween did not add four in-betweens")
                for text in ["Tween 25 in-betweens between frames 1 and 2.", "Tween 4 in-betweens between frames 1 and 3.", "Tween 4 in-betweens between frames 1 and 2 with bounce easing.",
                             SpatterTweenInstruction.example + " Delete active layer."] { try rejects(text) { _ = try SpatterTweenInstruction.parse(text) } }
                try rejects("tween past the last frame") { _ = try SpatterTweenInstruction.parse("Tween 2 in-betweens between frames 2 and 3.").prepare(in: context) }

                let clip = try SpatterFrameClipboardInstruction.parse(SpatterFrameClipboardInstruction.copyPasteExample)
                try require(clip.source == .number(1) && clip.destination == .number(2), "Clipboard capture wrong")
                let pasteOnly = try SpatterFrameClipboardInstruction.parse(SpatterFrameClipboardInstruction.pasteExample)
                let copyOnly = try SpatterFrameClipboardInstruction.parse(SpatterFrameClipboardInstruction.copyExample)
                try require(pasteOnly == .init(source: nil, destination: .active) && copyOnly == .init(source: .number(1), destination: nil), "Single-step clipboard forms wrong")
                editor = try StudioDocumentEditor(document: doc)
                let pasted = try execute(try clip.prepare(in: context), on: &editor)
                try require(pasted.createdFrameIDs.count == 1 && editor.document.frames.count == 3 && editor.document.frames[2].elements.count == 1
                    && editor.document.frames[2].elements[0].id != "seed-0" && editor.document.frames[2].elements[0].points == doc.frames[0].elements[0].points, "Copy+paste did not insert a fresh editable copy after frame 2")
                editor = try StudioDocumentEditor(document: doc)
                try rejects("paste without a clipboard frame") { _ = try execute(try SpatterFrameClipboardInstruction.parse(SpatterFrameClipboardInstruction.pasteExample).prepare(in: context), on: &editor) }
                try require(editor.document == doc, "Failed paste changed the document")
                try rejects("copy missing frame") { _ = try SpatterFrameClipboardInstruction.parse("Copy frame 9.").prepare(in: context) }
                try rejects("clipboard suffix") { _ = try SpatterFrameClipboardInstruction.parse("Copy frame 1 and paste it after frame 2 and delete frame 1.") }

                let settings = try SpatterProjectSettingsInstruction.parse(SpatterProjectSettingsInstruction.bothExample)
                try require(settings == .init(width: 640, height: 480, fps: 24), "Settings capture wrong")
                try require(try SpatterProjectSettingsInstruction.parse(SpatterProjectSettingsInstruction.fpsExample) == .init(width: nil, height: nil, fps: 24), "FPS-only capture wrong")
                editor = try StudioDocumentEditor(document: doc)
                let resized = try execute(try SpatterProjectSettingsInstruction.parse("Set project size to 300 by 200 pixels at 12 FPS.").prepare(in: context), on: &editor)
                try require(resized.outcome == .applied && editor.document.width == 300 && editor.document.height == 200 && editor.document.fps == 12
                    && editor.document.frames[0].elements == doc.frames[0].elements, "Settings edit changed artwork or was not applied")
                editor.undo(); try require(editor.document.width == 256 && editor.document.fps == 24, "Settings undo failed")
                for text in ["Set project size to 15 by 480 pixels.", "Set project size to 640 by 480 pixels at 61 FPS.", "Set project frame rate to 0 FPS.", "Set project size to 640 by 480 pixels; rm"] {
                    try rejects(text) { _ = try SpatterProjectSettingsInstruction.parse(text) }
                }

                for family in StudioBrushFamily.allCases {
                    let text = SpatterBrushStrokeInstruction.example(family)
                    let brush = try SpatterBrushStrokeInstruction.parse(text)
                    try require(brush.family == family && (family == .gradient) == (brush.endColor != nil), "Brush family \(family) capture wrong")
                    try require(SpatterInstructionRouter.classify(text) == .brushStroke, "Brush example routed elsewhere: \(family)")
                    let request = try brush.prepare(in: context, requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
                    guard case .apply(let commands) = request.action, commands.count == 1, case .draw(let draw) = commands[0], draw.strokes.count == 1,
                          let descriptor = draw.strokes[0].brush, descriptor.family == family, draw.strokes[0].points.count == 25 else { throw Failure(message: "Brush \(family) did not prepare one brush draw") }
                    let repeated = try brush.prepare(in: context, requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
                    let stable = JSONEncoder(); stable.outputFormatting = [.sortedKeys]
                    let repeatedBytes = try stable.encode(repeated), requestBytes = try stable.encode(request)
                    try require(repeated.requestID == request.requestID && repeatedBytes == requestBytes, "Brush seed is not request-stable")
                    editor = try StudioDocumentEditor(document: doc)
                    let drawn = try execute(request, on: &editor)
                    try require(drawn.createdElementIDs.count == 1 && editor.document.frames[0].elements.last?.brush?.family == family, "Brush \(family) did not reach the editor")
                }
                for text in ["Draw a chalk brush line from (10%, 20%) to (90%, 20%) in #000000, size 6 px, opacity 100%.",
                             "Draw a round brush line from (10%, 20%) to (10%, 20%) in #000000, size 6 px, opacity 100%.",
                             "Draw a round brush line from (10%, 20%) to (90%, 20%) in #000000 to #FFFFFF, size 6 px, opacity 100%.",
                             "Draw a gradient brush line from (10%, 20%) to (90%, 20%) in #000000, size 6 px, opacity 100%.",
                             "Draw a round brush line from (10%, 20%) to (90%, 20%) in #000000, size 51 px, opacity 100%.",
                             SpatterBrushStrokeInstruction.example + " Delete active layer."] { try rejects(text) { _ = try SpatterBrushStrokeInstruction.parse(text) } }
                var locked = doc; locked.layers[0].lockMode = "position"
                try rejects("position-locked layer") { _ = try SpatterBrushStrokeInstruction.parse(SpatterBrushStrokeInstruction.example).prepare(in: StudioCommandContext(document: locked)) }
            }
            try test("batches apply several context-only instructions as one revision and fail closed as a whole") {
                let doc = try document(frames: 2)
                let context = StudioCommandContext(document: doc)
                let batch = try SpatterInstructionBatch.parse(SpatterInstructionBatch.example)
                try require(batch.lines.map(\.kind) == [.frameAction, .frameExposure, .projectRename] && SpatterInstructionRouter.classify(SpatterInstructionBatch.example) == .batch, "Batch classification wrong")
                let request = try batch.prepare(in: context, requestID: UUID())
                guard case .apply(let commands) = request.action else { throw Failure(message: "Batch produced no apply action") }
                try require(commands.count == 6, "Batch command count wrong: \(commands.count)")
                var editor = try StudioDocumentEditor(document: doc)
                let receipt = try execute(request, on: &editor)
                // Frame numbers resolve against the captured document: "frames 1 through 2" are the
                // two original frames even though line 1 inserted three blanks between them.
                let original = doc.frames.map(\.id)
                try require(receipt.outcome == .applied && receipt.revision == doc.revision + 1 && receipt.createdFrameIDs.count == 3
                    && editor.document.name == "Batch" && editor.document.frames.count == 5
                    && original.allSatisfy { id in editor.document.frames.first { $0.id == id }?.durationTicks == 2 }
                    && receipt.createdFrameIDs.allSatisfy { id in editor.document.frames.first { $0.id == id }?.durationTicks == 1 },
                    "Batch did not apply every line in one revision: name=\(editor.document.name) frames=\(editor.document.frames.map { "\($0.id.prefix(4)):\($0.durationTicks)" })")
                editor.undo(); try require(content(editor.document) == content(doc), "Batch is not one Undo step")
                let aliased = try SpatterInstructionBatch.parse("Add 2 blank frames.\nAdd layer named \"Ink\".\nDuplicate active frame 2 times.").prepare(in: context)
                guard case .apply(let aliasedCommands) = aliased.action else { throw Failure(message: "no commands") }
                let aliases = aliasedCommands.compactMap { command -> String? in
                    switch command { case .addFrame(let v): return v.result; case .addLayer(let v): return v.result; case .duplicateFrame(let v): return v.result; default: return nil }
                }
                try require(Set(aliases).count == aliases.count && aliases.allSatisfy { $0.hasPrefix("b") }, "Batch aliases collide: \(aliases)")
                editor = try StudioDocumentEditor(document: doc)
                try require(try execute(aliased, on: &editor).createdFrameIDs.count == 4, "Namespaced batch did not execute")
                for (label, text) in [
                    ("selection line", "Add 2 blank frames.\nMove selected drawings by (10%, -5%)."),
                    ("brief line", "Add 2 blank frames.\nA red stick figure sits; 2 seconds."),
                    ("single line", "Add 2 blank frames."),
                    ("nine lines", Array(repeating: "Add blank frame.", count: 9).joined(separator: "\n")),
                    ("hostile line", "Add 2 blank frames.\nrm -rf /")
                ] { try rejects(label) { _ = try SpatterInstructionBatch.parse(text) } }
                editor = try StudioDocumentEditor(document: doc)
                try rejects("failing second line") { _ = try SpatterInstructionBatch.parse("Add 2 blank frames.\nSelect frame 9.").prepare(in: context) }
                try require(editor.document == doc, "A failing batch line left partial edits")
                let overflow = Array(repeating: "Add 96 blank frames.", count: 2).joined(separator: "\n")
                do { _ = try SpatterInstructionBatch.parse(overflow).prepare(in: context); throw Failure(message: "Oversized batch accepted") }
                catch SpatterInstructionBatch.Failure.tooManyCommands { }
            }
            try test("batch commit failures cancellation and intervening edits roll back the whole batch") {
                // Two layers so a single "Delete active layer." is valid when prepared.
                var editor = try StudioDocumentEditor(document: try document(frames: 2))
                let seed = editor.document
                _ = try execute(.init(requestID: UUID(), projectID: seed.id, expectedRevision: seed.revision,
                                      action: .apply([.addLayer(.init(name: "Ink", result: "ink"))])), on: &editor)
                let before = editor.document, beforeClipboard = editor.clipboardVersion
                try require(before.layers.count == 2 && editor.canUndo, "Fixture layer was not added")
                // Every line prepares against the captured document; the third deletes the
                // layer the second already deleted, so the combined request fails while committing.
                let conflicting = try SpatterInstructionBatch.parse("Add 2 blank frames.\nDelete active layer.\nDelete active layer.")
                let request = try conflicting.prepare(in: StudioCommandContext(document: before), requestID: UUID())
                var failure: Error?
                do { _ = try execute(request, on: &editor) } catch { failure = error }
                guard let failure else { throw Failure(message: "Conflicting batch committed") }
                try require(editor.document == before && editor.clipboardVersion == beforeClipboard && editor.canUndo && !editor.canRedo,
                            "Failed batch left partial edits or history")
                let notice = SpatterInstructionBatch.rollbackNotice(failure)
                try require(notice.contains("rolled back") && notice.contains("nothing changed") && notice.count < 400, "Rollback notice wrong: \(notice)")
                editor.undo()
                try require(content(editor.document) == content(seed), "Failed batch disturbed the prior Undo step")
                _ = try execute(.init(requestID: UUID(), projectID: seed.id, expectedRevision: editor.document.revision,
                                      action: .apply([.addLayer(.init(name: "Ink", result: "ink"))])), on: &editor)
                // Cancellation at every executor checkpoint of a valid batch leaves no trace.
                let valid = try SpatterInstructionBatch.parse("Add 2 blank frames.\nAdd layer named \"Paint\".\nRename project to \"Cancelled\".")
                let current = editor.document
                let validRequest = try valid.prepare(in: StudioCommandContext(document: current), requestID: UUID())
                var probe = editor, checkpoints = 0
                _ = try StudioCommandExecutor.execute(validRequest, editor: &probe, checkCancellation: { checkpoints += 1 })
                try require(checkpoints >= 4 && probe.document.name == "Cancelled", "Batch has too few cancellation checkpoints: \(checkpoints)")
                for boundary in 1...checkpoints {
                    var calls = 0, refused = false
                    do {
                        _ = try StudioCommandExecutor.execute(validRequest, editor: &editor, checkCancellation: {
                            calls += 1; if calls == boundary { throw CancellationError() }
                        })
                    } catch { refused = true }
                    try require(refused, "Batch ignored cancellation at checkpoint \(boundary)")
                    try require(editor.document == current && editor.clipboardVersion == beforeClipboard, "Cancelled batch at checkpoint \(boundary) changed the editor")
                }
                // Cancellation while preparing a later line also prepares nothing.
                var prepared = 0
                try rejects("cancel while preparing line 3") {
                    _ = try valid.prepare(in: StudioCommandContext(document: current), checkCancellation: { prepared += 1; if prepared == 3 { throw CancellationError() } })
                }
                // An intervening user edit after preparation makes the batch stale; the user's edit survives.
                _ = try execute(.init(requestID: UUID(), projectID: current.id, expectedRevision: current.revision,
                                      action: .apply([.renameProject(.init(name: "User edit"))])), on: &editor)
                let userEdited = editor.document
                do { _ = try execute(validRequest, on: &editor); throw Failure(message: "Stale batch committed over a user edit") }
                catch StudioCommandError.staleRevision { }
                try require(editor.document == userEdited && editor.document.name == "User edit", "Stale batch overwrote the intervening edit")
                editor.undo()
                try require(content(editor.document) == content(current), "User edit is not its own Undo step after the refused batch")
            }
            try test("control registry covers every drawing tool panel and catalog grammar with truthful routes") {
                let problems = SpatterStudioControlRegistry.validate()
                try require(problems.isEmpty, "Registry drift: \(problems)")
                for tool in DrawingTool.allCases {
                    guard let control = SpatterStudioControlRegistry.control(for: tool) else { throw Failure(message: "Tool \(tool.rawValue) unmapped") }
                    try require(!control.explanation.isEmpty, "Tool \(tool.rawValue) has no explanation")
                }
                for control in SpatterStudioControlRegistry.controls {
                    for name in control.grammars {
                        try require(SpatterInstructionRouter.Kind(rawValue: name) != nil, "\(control.id) names \(name), which the router cannot dispatch")
                    }
                }
                try require(SpatterStudioControlRegistry.control(for: .brush)?.grammars == ["brushStroke"]
                    && SpatterStudioControlRegistry.control(for: .pencil)?.grammars.isEmpty == true
                    && SpatterStudioControlRegistry.control(for: .hand)?.grammars.isEmpty == true, "Tool routes overclaim or underclaim")
                for key in ["export", "addImage"] {
                    guard let control = SpatterStudioControlRegistry.control(forPanel: key), case .blocked = control.route else { throw Failure(message: "\(key) must be blocked") }
                    try require(control.explanation.contains("will not"), "Blocked explanation unclear for \(key)")
                }
                try require(Set(SpatterStudioControlRegistry.panelKeys).count == SpatterStudioControlRegistry.panelKeys.count, "Panel keys repeat")
                // The validator catches drift in both directions.
                try require(SpatterStudioControlRegistry.validate(catalogNames: SpatterInstructionCatalog.names + ["ghostGrammar"])
                    .contains("grammar ghostGrammar is reachable from no control"), "Unreachable grammar not reported")
                try require(SpatterStudioControlRegistry.validate(catalogNames: SpatterInstructionCatalog.names.filter { $0 != "tween" })
                    .contains { $0.contains("unknown grammar tween") }, "Unknown grammar not reported")
            }
            try test("context snapshot reports exact bounded screen document and selection facts and detects stale context") {
                var editor = try StudioDocumentEditor(document: try document(frames: 3))
                let seed = editor.document
                let longName = String(repeating: "N", count: 100)
                _ = try execute(.init(requestID: UUID(), projectID: seed.id, expectedRevision: seed.revision, action: .apply([
                    .setFrameHold(.init(frame: .id(seed.frames[0].id), ticks: 4)),
                    .addLayer(.init(name: longName, result: "ink")),
                    .selectFrame(.id(seed.frames[1].id))])), on: &editor)
                let doc = editor.document
                let screen = SpatterContextSnapshot.Screen(toolRawValue: "move", panelKey: "spatterAI", selectedDrawingCount: 2,
                    selectedImageCount: 0, selectedAudioClipID: "ghost", displayedFrameID: seed.frames[1].id,
                    isPlaying: false, isDirty: true, isSaving: false, canUndo: true, canRedo: false)
                let snapshot = SpatterContextSnapshot(document: StudioCommandContext(document: doc), screen: screen)
                let layerIndex = doc.layers.firstIndex { $0.id == doc.activeLayerID }.map { $0 + 1 }
                try require(snapshot.frameCount == 3 && snapshot.activeFrameNumber == 2 && snapshot.displayedFrameNumber == 2
                    && snapshot.totalTicks == 6 && snapshot.durationSeconds == 0.25 && snapshot.fps == 24
                    && snapshot.layerCount == 2 && snapshot.activeLayerNumber == layerIndex && snapshot.activeLayerName.count == 80
                    && snapshot.activeLayerVisible && snapshot.activeLayerLockMode == "free"
                    && snapshot.activeFrameElementCount == 1 && snapshot.documentElementCount == 3 && snapshot.framesWithImages == 0
                    && snapshot.audioClipCount == 0 && !snapshot.selectedAudioClipKnown && snapshot.tool == "move" && snapshot.panel == "spatterAI"
                    && snapshot.selectedDrawingCount == 2 && snapshot.revision == doc.revision, "Snapshot facts wrong: \(snapshot)")
                try require(snapshot.summary.contains("Frame 2 of 3") && snapshot.summary.contains("2 drawings selected")
                    && snapshot.summary.contains("Move tool") && snapshot.summary.contains("revision \(doc.revision)")
                    && !snapshot.summary.contains(longName), "Snapshot summary wrong: \(snapshot.summary)")
                try require(snapshot.readiness(of: "selectionTranslate") == .ready && snapshot.readiness(of: "frameAction") == .ready
                    && snapshot.readiness(of: "brushStroke") == .ready && snapshot.readiness(of: "imageCrop") != .ready
                    && snapshot.readiness(of: "audioClip") != .ready && snapshot.readiness(of: "textUpdate") != .ready, "Readiness wrong")
                try require(snapshot.readyGrammars().allSatisfy { SpatterInstructionCatalog.names.contains($0) } && snapshot.readyGrammars().contains("batch"), "Ready grammars wrong")
                // Hostile or oversized screen facts are bounded, never trusted.
                var hostile = screen
                hostile.toolRawValue = "laser"; hostile.panelKey = "shell"; hostile.selectedDrawingCount = 99_999; hostile.selectedImageCount = 5
                let bounded = SpatterContextSnapshot(document: StudioCommandContext(document: doc), screen: hostile)
                try require(bounded.tool == nil && bounded.panel == "unknown" && bounded.selectedDrawingCount == SpatterContextSnapshot.maximumSelection
                    && bounded.selectedImageCount == 1, "Snapshot trusted unbounded screen facts")
                let data = try JSONEncoder().encode(snapshot)
                try require(data.count <= 4096 && (try JSONDecoder().decode(SpatterContextSnapshot.self, from: data)) == snapshot, "Snapshot is not a bounded round trip")
                // Stale detection: same state is current; any edit, selection or playback change is stale.
                try require(!snapshot.isStale(comparedTo: SpatterContextSnapshot(document: StudioCommandContext(document: doc), screen: screen)), "Identical context reported stale")
                var reselected = screen; reselected.selectedDrawingCount = 3
                var playing = screen; playing.isPlaying = true
                let playingSnapshot = SpatterContextSnapshot(document: StudioCommandContext(document: doc), screen: playing)
                try require(snapshot.isStale(comparedTo: SpatterContextSnapshot(document: StudioCommandContext(document: doc), screen: reselected))
                    && snapshot.isStale(comparedTo: playingSnapshot) && playingSnapshot.readiness(of: "frameAction") == .needs("Stop playback first."), "Selection or playback change not detected")
                _ = try execute(.init(requestID: UUID(), projectID: doc.id, expectedRevision: doc.revision,
                                      action: .apply([.renameProject(.init(name: "Later"))])), on: &editor)
                try require(snapshot.isStale(comparedTo: SpatterContextSnapshot(document: StudioCommandContext(document: editor.document), screen: screen)), "Later revision not detected")
                let other = try document()
                try require(snapshot.isStale(comparedTo: SpatterContextSnapshot(document: StudioCommandContext(document: other), screen: screen)), "Switched project not detected")
            }
            try test("router owns every catalog example exactly once and quoted or imported text never changes the route") {
                let names: [String: SpatterInstructionRouter.Kind] = [
                    "circleMotion": .circleMotion, "stickFigure": .stickFigure, "sceneBrief": .sceneBrief, "twoActorBrief": .twoActorBrief, "multiClauseBrief": .multiClauseBrief,
                    "frameAction": .frameAction, "frameCut": .frameCut, "frameExposure": .frameExposure, "frameReverse": .frameReverse, "frameDuplicateRange": .frameDuplicateRange,
                    "navigation": .navigation, "layerStructure": .layerStructure, "layerDuplicate": .layerDuplicate, "layerUpdate": .layerUpdate, "layerGlow": .layerGlow,
                    "layerOrder": .layerOrder, "projectRename": .projectRename, "grid": .grid, "onionSkin": .onionSkin, "selectedErasure": .selectedErasure,
                    "drawingDuplicate": .drawingDuplicate, "artworkOrder": .artworkOrder, "selectionTranslate": .selectionTranslate, "selectionTransform": .selectionTransform,
                    "selectionReflect": .selectionReflect, "imageReflection": .imageReflection, "imageRotation": .imageRotation, "imageCrop": .imageCrop,
                    "imagePlacement": .imagePlacement, "textUpdate": .textUpdate, "audioClip": .audioClip, "audioTrack": .audioTrack,
                    "tween": .tween, "frameClipboard": .frameClipboard, "projectSettings": .projectSettings, "brushStroke": .brushStroke, "batch": .batch]
                for grammar in SpatterInstructionCatalog.grammars {
                    guard let kind = names[grammar.name] else { throw Failure(message: "Catalog grammar \(grammar.name) has no router kind") }
                    for example in grammar.examples {
                        try require(SpatterInstructionRouter.classify(example) == kind, "Catalog example \(example) routed to \(String(describing: SpatterInstructionRouter.classify(example)))")
                    }
                }
                try require(Set(SpatterInstructionCatalog.names).count == SpatterInstructionCatalog.grammars.count && SpatterInstructionCatalog.grammars.count == names.count, "Catalog names drifted")
                try require(SpatterInstructionCatalog.commandNames.contains("appendFrames") && SpatterInstructionCatalog.commandNames.contains("tweenFrames")
                    && SpatterInstructionCatalog.commandNames.contains("pasteFrame") && SpatterInstructionCatalog.commandNames.contains("updateProjectSettings"), "Catalog does not list the new reachable commands")
                for (text, kind) in [("Rename project to \"Add 3 blank frames.\".", SpatterInstructionRouter.Kind.projectRename),
                                     ("Add layer named \"Delete active frame.\".", .layerStructure),
                                     ("Set selected text to \"Tween 4 in-betweens between frames 1 and 2.\".", .textUpdate),
                                     ("Rename active layer to \"Copy frame 1 and paste it after frame 2.\".", .layerUpdate)] {
                    try require(SpatterInstructionRouter.classify(text) == kind, "Quoted instruction-like text changed the route: \(text)")
                }
                let renamed = try SpatterProjectRenameInstruction.parse("Rename project to \"Add 3 blank frames.\".")
                try require(renamed.name == "Add 3 blank frames.", "Quoted text was not kept as data")
                try require(SpatterInstructionRouter.classify("Append 20 frames of a black stick figure walking from (25%, 80%) to (75%, 80%), height 35%, line width 3 px.") == .stickFigure, "Explicit recipe stolen by the brief grammar")
                try require(SpatterInstructionRouter.classify("Publish my animation to YouTube now") == nil && SpatterInstructionRouter.classify("") == nil, "Unknown text was routed")
            }
            try test("plan preview describes briefs and batches without mutating and reports refusals as text") {
                let doc = try document()
                let context = StudioCommandContext(document: doc)
                let preview = SpatterInstructionPreview.plan(SpatterMultiClauseBrief.example, context: context)
                try require(preview.hasPrefix("Plan:") && preview.contains("editable frames") && preview.contains("walk 24 ticks") && preview.contains("Nothing has changed yet"), "Brief preview wrong: \(preview)")
                let batch = SpatterInstructionPreview.plan(SpatterInstructionBatch.example, context: StudioCommandContext(document: try document(frames: 2)))
                try require(batch.contains("batch of 3 instructions") && batch.contains("6 typed commands") && batch.contains("revision \(doc.revision)"), "Batch preview wrong: \(batch)")
                try require(SpatterInstructionPreview.plan("Add 3 blank frames.", context: context).contains("3× addFrame"), "Context-only preview wrong")
                try require(SpatterInstructionPreview.plan("Move selected drawings by (10%, -5%).", context: context).contains("validates the captured selection"), "Selection preview overclaims")
                try require(SpatterInstructionPreview.plan("Publish it to YouTube", context: context).contains("No supported instruction"), "Unknown preview wrong")
                try require(SpatterInstructionPreview.plan("A red stick figure flies; 2 seconds.", context: context).hasPrefix("Plan unavailable:"), "Refusal preview wrong")
                try require(SpatterInstructionPreview.plan(SpatterMultiClauseBrief.example, context: nil).contains("Open the project"), "Preview without a project overclaims")
            }
            try test("source references pass the rights gate only with a recorded basis and export bounds are stated honestly") {
                let now = Date(timeIntervalSince1970: 1_760_300_000)
                let licensed = SpatterSourceReference(url: URL(string: "https://www.youtube.com/watch?v=abc123")!, rightsBasis: .licensed, recordedAt: now.addingTimeInterval(-60))
                let decision = SpatterSourceRightsGate.evaluate(licensed, now: now)
                try require(decision.allowed && decision.reason.contains("licensed") && decision.reason.contains("independently generated"), "Licensed source refused or overclaimed")
                try require(SpatterSourceRightsGate.evaluate(nil, now: now).allowed, "Original briefs need no source")
                let unknown = SpatterSourceReference(url: URL(string: "https://example.com/clip")!, rightsBasis: .unknown, recordedAt: now)
                try require(!SpatterSourceRightsGate.evaluate(unknown, now: now).allowed, "Unknown rights basis passed the gate")
                let future = SpatterSourceReference(url: URL(string: "https://example.com/clip")!, rightsBasis: .ownerAuthorized, recordedAt: now.addingTimeInterval(3600))
                try require(!SpatterSourceRightsGate.evaluate(future, now: now).allowed, "Future-dated record passed")
                for bad in ["http://example.com/clip", "https://user:pw@example.com/clip", "https://", "https://example.com/" + String(repeating: "a", count: 2100)] {
                    if let url = URL(string: bad) {
                        try rejects(bad) { try SpatterSourceReference(url: url, rightsBasis: .licensed, recordedAt: now).validate() }
                    }
                }
                var noted = licensed; noted.note = String(repeating: "n", count: 501)
                try rejects("oversized note") { try noted.validate() }
                let encoded = try JSONEncoder().encode(licensed)
                try require(try JSONDecoder().decode(SpatterSourceReference.self, from: encoded) == licensed, "Source reference round trip failed")
                try require(SpatterSourceVideoBounds.check(seconds: 19.9) == .tooShort && SpatterSourceVideoBounds.check(seconds: 20) == .inRange
                    && SpatterSourceVideoBounds.check(seconds: 60) == .inRange && SpatterSourceVideoBounds.check(seconds: 60.1) == .tooLong, "Bounds check wrong")
                let note = SpatterSourceVideoBounds.frameCapNote(fps: 24)
                try require(note.contains("240-frame cap") && note.contains("10.0 s") && note.contains("2–6 ticks") && note.contains("not promised"), "Frame cap note wrong: \(note)")
            }
            try test("project digest input changes with any edit and quality verdict applies thresholds including movie measurements") {
                let doc = try document()
                let a = try SpatterProjectDigest.canonicalData(doc), b = try SpatterProjectDigest.canonicalData(doc)
                try require(a == b, "Canonical document bytes are not stable")
                var edited = doc; edited.frames[0].holdTicks = 3; edited.schemaVersion = 35
                try require(try SpatterProjectDigest.canonicalData(edited) != a, "Canonical bytes ignore a timing edit")
                var renamed = doc; renamed.name = "Other"
                try require(try SpatterProjectDigest.canonicalData(renamed) != a, "Canonical bytes ignore a rename")
                let clean = SpatterQualityReport.analyze(doc, requestedTicks: 1,
                    movie: .init(decodedFrameCount: 2, decodedDurationSeconds: 2.0 / 24, audioOffsetSeconds: 0.01, expectedFrameCount: 2, expectedDurationSeconds: 2.0 / 24))
                try require(clean.unmeasured.isEmpty && clean.verdict().passes, "Measured movie left items unmeasured or failed: \(clean.findings)")
                let drifted = SpatterQualityReport.analyze(doc, requestedTicks: 1,
                    movie: .init(decodedFrameCount: 3, decodedDurationSeconds: 1.0, audioOffsetSeconds: 0.2, expectedFrameCount: 2, expectedDurationSeconds: 2.0 / 24))
                let verdict = drifted.verdict()
                try require(!verdict.passes && verdict.failures.count == 3 && drifted.findings.map(\.kind).contains(.movieFrameCount)
                    && drifted.findings.map(\.kind).contains(.movieDuration) && drifted.findings.map(\.kind).contains(.audioOffset), "Movie drift not caught: \(verdict)")
                var blank = doc; blank.frames.append(.init(id: "blank", elements: []))
                let blankReport = SpatterQualityReport.analyze(blank, requestedTicks: 2)
                try require(!blankReport.verdict().passes && blankReport.verdict(.init(maximumBlankFrames: 1)).passes
                    && blankReport.unmeasured == ["decodedMovieFrameCount", "decodedMovieDuration", "audioOffsetSeconds"], "Threshold override or unmeasured list wrong")
                try require(SpatterQualityReport.Verdict.note.contains("owner approval"), "Verdict note must keep the human gate")
            }
            print("SPATTER_PLANNER_TESTS=PASS \(passed) production parser-command-editor cases")
        } catch {
            print("SPATTER_PLANNER_TESTS=FAIL \(error)")
            exit(1)
        }
    }
}
