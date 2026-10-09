import Foundation
import Combine

private struct Failure: Error { let text: String }
private func require(_ condition: @autoclosure () -> Bool, _ text: String) throws {
    if !condition() { throw Failure(text: text) }
}
private func stroke(layer: String, id: String = UUID().uuidString) -> DrawnElement {
    DrawnElement(id: id, tool: .brush, points: [StrokePoint(x: 30, y: 40), StrokePoint(x: 100, y: 150)],
                 color: "#FF0000", width: 5, opacity: 0.7, layerID: layer)
}

private final class VMRevisionSpaceFailureStore: DeviceStorageManager {
    var failingStage: RevisionWriteStage?
    override func synchronizeRevisionFile(_ url: URL, stage: RevisionWriteStage) throws {
        try super.synchronizeRevisionFile(url, stage: stage)
        if failingStage == stage { throw CocoaError(.fileWriteOutOfSpace) }
    }
}

@main @MainActor struct StudioDocumentTests {
    private static func projectConfiguration() throws {
        var original = try StudioDocument.new(name: "Settings", width: 64, height: 64, fps: 12)
        original.schemaVersion = 6
        var fill = DrawnElement(id: "fill", tool: .fill,
            points: [.init(x: 0, y: 0), .init(x: 64, y: 64)],
            color: "#FF0000", width: 1, opacity: 1, layerID: original.activeLayerID)
        fill.fillMask = .init(width: 64, height: 64, spans: [.init(row: 20, start: 10, end: 50, alpha: 255)])
        original.frames[0].elements = [fill]
        var editor = try StudioDocumentEditor(document: original)
        try editor.updateProjectSettings(name: "  Renamed  ", width: 96, height: 80, fps: 24)
        let configured = editor.document
        try require(configured.id == original.id && configured.name == "Renamed" &&
            configured.width == 96 && configured.height == 80 && configured.fps == 24 &&
            configured.frames[0].elements[0].points == fill.points &&
            configured.frames[0].elements[0].fillMask?.spans == fill.fillMask?.spans &&
            configured.durationSeconds == original.durationSeconds / 2,
            "Configuration changed artwork coordinates, fill coverage, identity or tick semantics")
        try configured.validate()
        editor.undo()
        try require(editor.document.frames == original.frames && editor.document.width == 64 &&
            editor.document.fps == 12 && editor.document.name == original.name, "Configuration was not one Undo")
        editor.redo()
        try require(editor.document.frames == configured.frames && editor.document.width == 96, "Configuration Redo changed fill")
        let before = editor.document
        do { try editor.updateProjectSettings(name: "Bad crop", width: 32, height: 32, fps: 24)
            throw Failure(text: "Configuration discarded fill spans")
        } catch is StudioDocumentError { }
        try require(editor.document == before, "Rejected fill crop mutated document")
        let archive = try StudioDocumentArchive(document: configured, rasterFrameIndices: [:]).encoded()
        let decodedConfiguration = try StudioDocumentArchive.decode(archive).document
        try require(decodedConfiguration == configured, "Cold configuration archive changed content")
        var media = try StudioDocument.new(name: "Media settings", width: 64, height: 64, fps: 12)
        media.schemaVersion = 14
        media.frames[0].rasterAssetID = "settings-source"
        media.frames[0].rasterLayerID = media.activeLayerID
        media.frames[0].rasterPlacement = .init(x: 8, y: 8, width: 48, height: 48)
        media.audioClips = [.init(id: "audio", soundName: "Original audio", track: 1, startTime: 0.25, duration: 1)]
        var mediaEditor = try StudioDocumentEditor(document: media)
        try mediaEditor.updateProjectSettings(name: "Media settings", width: 80, height: 80, fps: 24)
        try require(mediaEditor.document.frames == media.frames && mediaEditor.document.audioClips == media.audioClips &&
            mediaEditor.document.referencedRasterAssetIDs == media.referencedRasterAssetIDs,
            "Settings changed image placement/source identity or absolute audio seconds")
        let mediaBefore = mediaEditor.document
        do { try mediaEditor.updateProjectSettings(name: "Clipped image", width: 32, height: 32, fps: 24)
            throw Failure(text: "Out-of-bounds managed image silently refitted")
        } catch is StudioDocumentError { }
        try require(mediaEditor.document == mediaBefore, "Rejected managed image resize changed original")
        var effectDocument = try StudioDocument.new(name: "Effect", width: 64, height: 64, fps: 12)
        effectDocument.schemaVersion = 17
        var effect = DrawnElement(id: "effect", tool: .smudge, points: [.init(x: 20, y: 20), .init(x: 24, y: 24)],
            color: "#000000", width: 8, opacity: 1, layerID: effectDocument.activeLayerID)
        effect.smudge = .init()
        effectDocument.frames[0].elements = [effect]
        var effectEditor = try StudioDocumentEditor(document: effectDocument)
        do { try effectEditor.updateProjectSettings(name: "Effect resized", width: 80, height: 80, fps: 12)
            throw Failure(text: "Pixel-effect resize silently replayed changed dimensions")
        } catch StudioDocumentError.unavailable { }
        try require(effectEditor.document == effectDocument && !effectEditor.canUndo, "Rejected effect resize changed history")
        print("PASS atomic project settings fill extension fixed coordinates timing Undo Redo archive and rejected lossy crop")
    }

    private static func mixedImageOrdering() throws {
        func requireOrder(_ frame: AnimationFrame, _ layer: String, _ expected: [LayerContentToken], _ message: String) throws {
            let actual = try frame.orderedContent(on: layer)
            try require(actual == expected, message)
        }
        var original = try StudioDocument.new(name: "Mixed stacking", width: 128, height: 128, fps: 12)
        original.schemaVersion = 3
        let layer = original.activeLayerID, frameID = original.activeFrameID
        let asset = "image-" + UUID().uuidString
        original.frames[0].rasterAssetID = asset; original.frames[0].rasterLayerID = layer
        original.frames[0].rasterPlacement = .init(x: 10, y: 10, width: 60, height: 40)
        original.frames[0].elements = [stroke(layer: layer, id: "U"), stroke(layer: layer, id: "D"), stroke(layer: layer, id: "V")]
        let start: [LayerContentToken] = [.image, .drawing("U"), .drawing("D"), .drawing("V")]
        try requireOrder(original.frames[0], layer, start, "Legacy image bottom order changed")
        var editor = try StudioDocumentEditor(document: original)
        var checkpoints = 0
        try editor.orderSelectedArtwork(frameID: frameID, elementIDs: ["D"], imageAssetID: asset, imageLayerID: layer,
            forward: true, checkCancellation: { checkpoints += 1 })
        let forward = editor.document
        let expected: [LayerContentToken] = [.drawing("U"), .image, .drawing("V"), .drawing("D")]
        try requireOrder(forward.frames[0], layer, expected, "Selected block or unselected relative order changed")
        try require(forward.schemaVersion == 33 && forward.frames[0].rasterStackPosition == 1 &&
            forward.layers == original.layers && forward.referencedRasterAssetIDs == original.referencedRasterAssetIDs,
            "Ordering changed source/layers or failed additive schema")
        let decoded = try StudioDocumentArchive.decode(StudioDocumentArchive(document: forward, rasterFrameIndices: [asset: 0]).encoded())
        try require(decoded.document == forward, "Cold schema33 archive lost stacking")
        editor.undo(); try require(editor.document.frames == original.frames && editor.document.schemaVersion == 3, "Ordering was not one reversible transaction")
        editor.redo(); try require(editor.document.frames == forward.frames, "Ordering Redo lost combined tokens")
        for stop in 1...checkpoints {
            var cancelled = try StudioDocumentEditor(document: original), calls = 0
            do {
                try cancelled.orderSelectedArtwork(frameID: frameID, elementIDs: ["D"], imageAssetID: asset, imageLayerID: layer,
                    forward: true, checkCancellation: { calls += 1; if calls == stop { throw CancellationError() } })
                throw Failure(text: "Mixed ordering ignored cancellation")
            } catch is CancellationError { }
            try require(cancelled.document == original && !cancelled.canUndo, "Cancelled order published partial changes/history")
        }
        try editor.orderSelectedArtwork(frameID: frameID, elementIDs: ["D"], imageAssetID: asset, imageLayerID: layer, forward: false)
        try requireOrder(editor.document.frames[0], layer, start, "Backward order did not restore member order")
        let atBottom = editor.document
        try editor.orderSelectedArtwork(frameID: frameID, elementIDs: [], imageAssetID: asset, imageLayerID: layer, forward: false)
        try require(editor.document == atBottom, "Boundary no-op created a revision")
        print("PASS mixed image/drawing stable ordering schema33 cold archive one Undo and every cancellation boundary")

        var deleted = try StudioDocumentEditor(document: forward)
        deleted.selectedElementIDs = ["U"]; try deleted.deleteSelected()
        try requireOrder(deleted.document.frames[0], layer, [.image, .drawing("V"), .drawing("D")],
                    "Deleting below image did not remap its slot")
        deleted.undo(); try require(deleted.document.frames == forward.frames, "Deletion Undo lost image slot")
        deleted.selectedElementIDs = ["V"]; try deleted.deleteSelected()
        try require(deleted.document.frames[0].rasterStackPosition == 1, "Deleting above image moved it")
        var append = try StudioDocumentEditor(document: forward)
        try append.commit(stroke(layer: layer, id: "new"), frameID: frameID)
        try requireOrder(append.document.frames[0], layer, expected + [.drawing("new")], "Append inserted drawing below image")
        try append.orderElements(frameID: frameID, ids: ["U"], forward: true)
        try requireOrder(append.document.frames[0], layer, [.image, .drawing("U"), .drawing("V"), .drawing("D"), .drawing("new")],
                    "Drawing-only order ignored the image neighbor")
        var copies = try StudioDocumentEditor(document: original)
        try copies.orderSelectedArtwork(frameID: frameID, elementIDs: ["D"], imageAssetID: asset, imageLayerID: layer, forward: true)
        copies.copyFrame(); copies.undo(); try copies.pasteFrame()
        let pasted = copies.document.frames.first { $0.id == copies.document.activeFrameID }!
        try require(copies.document.schemaVersion == 33 && pasted.id != frameID && pasted.rasterStackPosition == 1 &&
            Set(pasted.elements.map(\.id)).isDisjoint(with: Set(original.frames[0].elements.map(\.id))),
            "Frame clipboard paste lost schema/slot or regenerated IDs were mistaken for deletion")
        var linked = try StudioDocumentEditor(document: forward)
        try linked.duplicateLayer(layer)
        let alias = linked.document.activeLayerID
        try require(linked.document.frames[0].rasterInstance(on: alias)?.stackPosition == 1, "Layer clone lost image order")
        try linked.deleteLayer(layer)
        try require(linked.document.frames[0].rasterLayerID == alias && linked.document.frames[0].rasterStackPosition == 1 &&
            linked.document.frames[0].rasterAssetID == asset, "Primary promotion lost image order/source")
        try require(linked.document.frames[0].projectedRasterFrame(on: alias)?.rasterStackPosition == 1, "Projected image frame lost order")
        print("PASS image slots survive drawing append/delete/order frame copy ID regeneration layer clone and primary promotion")

        for position in [-1, 4, Int.max] {
            var invalid = original; invalid.schemaVersion = 33; invalid.frames[0].rasterStackPosition = position
            do { try invalid.validate(); throw Failure(text: "Invalid image position accepted") } catch StudioDocumentError.invalid { }
        }
        var oldSchema = original; oldSchema.frames[0].rasterStackPosition = 1
        do { try oldSchema.validate(); throw Failure(text: "Legacy schema accepted nonzero image order") } catch StudioDocumentError.invalid { }
        var zero = original; zero.frames[0].rasterStackPosition = 0; try zero.validate()
        var malformed = forward.frames[0]; let beforeMalformed = malformed
        do { try malformed.setOrderedContent([.image, .drawing("U"), .drawing("U"), .drawing("D")], on: layer)
            throw Failure(text: "Duplicate combined token accepted") } catch StudioRasterLayerInstance.Failure.invalid { }
        try require(malformed == beforeMalformed, "Malformed token list partially mutated frame")
        for mode in ["hidden", "zero", "full", "position", "alpha", "stale", "unpaired"] {
            var doc = original
            switch mode {
            case "hidden": doc.layers[0].visible = false
            case "zero": doc.layers[0].opacity = 0
            case "full": doc.layers[0].locked = true; doc.layers[0].lockMode = "full"
            case "position", "alpha": doc.layers[0].lockMode = mode
            default: break
            }
            var rejected = try StudioDocumentEditor(document: doc)
            var denied = false
            do { try rejected.orderSelectedArtwork(frameID: frameID, elementIDs: ["D"],
                imageAssetID: mode == "stale" ? "missing" : asset, imageLayerID: mode == "unpaired" ? nil : layer, forward: true) }
            catch { denied = true }
            try require(denied && rejected.document == doc && !rejected.canUndo, "Invalid mixed order changed content/history: \(mode)")
        }

        // Model-only callers must reject stale Wand input without depending on
        // the command transport target or changing document/history.
        var staleRegion = try StudioDocumentEditor(document: original)
        let expectedImage = original.frames[0].rasterInstance(on: layer)!
        let mask = StudioImageRegionMask(width: 1, height: 1, spans: [.init(row: 0, start: 0, end: 1)])
        do {
            try staleRegion.editImageRegion(frameID: frameID, layerID: layer, sourceID: "image-" + UUID().uuidString,
                expected: expectedImage, fragment: expectedImage, remainderMask: mask,
                fragmentLayerID: UUID().uuidString, action: .delete)
            throw Failure(text: "Stale image-region source was accepted")
        } catch StudioDocumentError.unavailable(let message) {
            try require(message == "The selected image changed. Select it again before editing its region.",
                        "Stale region rejection lost factual model error")
        }
        try require(staleRegion.document == original && !staleRegion.canUndo && !staleRegion.canRedo,
                    "Stale image-region rejection changed document or history")
        print("PASS malformed image order tokens schema bounds locks visibility and stale source fail without mutation")
    }

    private static func imageMaskHistoryBudget() throws {
        var value = try StudioDocument.new(name: "Wand history budget", width: 320, height: 240, fps: 12)
        value.schemaVersion = 32
        let primary = value.activeLayerID, alias = UUID().uuidString
        value.layers.append(CanvasLayer(id: alias, name: "Linked region"))
        let placement = StudioRasterPlacement(x: 0, y: 0, width: 320, height: 240)
        let instance = StudioRasterLayerInstance(layerID: primary, placement: placement)
        let geometry = StudioImageRegionMask.Geometry(instance)!
        let sources = (0...8).map { _ in "image-" + UUID().uuidString }
        // Each revision allocates distinct valid span arrays, not a transform
        // retaining the same copy-on-write mask. Together both masks cost ~6MiB.
        @MainActor func mask(_ revision: Int, inverted: Bool) -> StudioImageRegionMask {
            let spans = (0..<(131_072 - revision)).map {
                StudioImageRegionMask.Span(row: $0 / 1024, start: ($0 % 1024) * 4, end: ($0 % 1024) * 4 + 1)
            }
            return StudioImageRegionMask(width: 4096, height: 128, spans: spans, inverted: inverted,
                samplingGeometry: geometry, placementGeometry: geometry)
        }
        value.frames[0].rasterAssetID = sources[0]
        value.frames[0].rasterLayerID = primary
        value.frames[0].rasterPlacement = placement
        value.frames[0].rasterRegionMask = mask(0, inverted: false)
        value.frames[0].rasterAliases = [.init(layerID: alias, placement: placement, regionMask: mask(0, inverted: true))]
        var editor = try StudioDocumentEditor(document: value)
        for revision in 1...8 {
            try editor.change {
                $0.frames[0].rasterAssetID = sources[revision]
                $0.frames[0].rasterRegionMask = mask(revision, inverted: false)
                $0.frames[0].rasterAliases![0].regionMask = mask(revision, inverted: true)
            }
        }
        let final = editor.document
        try require(final.frames[0].rasterAssetID == sources[8] && final.frames[0].rasterRegionMask == mask(8, inverted: false),
                    "History pruning changed the current image or mask")
        try require(editor.referencedRasterAssetIDsIncludingHistoryAndClipboard == Set(sources[3...8]),
                    "Primary and alias mask bytes did not bound history, or discarded a retained Undo source")
        let beforeInvalid = editor.document
        // Invalid mask dimensions are rejected without consuming history.
        do {
            try editor.change {
                $0.frames[0].rasterRegionMask = StudioImageRegionMask(width: 0, height: 128, spans: [])
            }
            throw Failure(text: "Invalid image mask committed")
        } catch StudioDocumentError.invalid { }
        try require(editor.document == beforeInvalid, "Rejected mask changed document/history")
        var undos = 0
        while editor.canUndo {
            editor.undo(); undos += 1
            let expected = 8 - undos
            try require(editor.document.frames[0].rasterAssetID == sources[expected]
                && editor.document.frames[0].rasterRegionMask == mask(expected, inverted: false)
                && editor.document.frames[0].rasterAliases?[0].regionMask == mask(expected, inverted: true),
                "Undo lost a primary/alias mask or managed source identity")
        }
        try require(undos == 5, "Image-mask history did not retain the bounded five reversible snapshots")
        try require(editor.referencedRasterAssetIDsIncludingHistoryAndClipboard == Set(sources[3...8]),
                    "Undo discarded a source still required by Redo")
        for _ in 0..<undos { editor.redo() }
        try require(editor.document.frames == final.frames && editor.document.layers == final.layers && !editor.canRedo,
                    "Redo did not restore exact final region geometry and source")
        editor.undo()
        try editor.renameProject("Branch after Undo")
        try require(!editor.canRedo && !editor.referencedRasterAssetIDsIncludingHistoryAndClipboard.contains(sources[8]),
                    "New edit retained stale Redo or evicted the wrong source")
        var small = try StudioDocumentEditor(document: StudioDocument.new(name: "Small history", width: 320, height: 240, fps: 12))
        for index in 1...55 { try small.renameProject("Small history \(index)") }
        var smallUndos = 0
        while small.canUndo { small.undo(); smallUndos += 1 }
        try require(smallUndos == 50, "Image mask accounting changed ordinary history depth")
        print("PASS bounded distinct primary/alias image-mask history, source lifetime, Undo/Redo and invalid-mask rollback")
    }

    private static func linkedRasterJourneys() throws {
        var original = try StudioDocument.new(name: "Linked pictures", width: 320, height: 240, fps: 12)
        let primary = original.activeLayerID, frameID = original.activeFrameID
        original.schemaVersion = 22
        original.frames[0].rasterAssetID = "immutable-original"
        original.frames[0].rasterLayerID = primary
        original.frames[0].rasterPlacement = .init(x: 20, y: 30, width: 80, height: 60)
        original.frames[0].elements = [stroke(layer: primary)]
        try original.validate()
        var editor = try StudioDocumentEditor(document: original)
        try editor.duplicateLayer(primary)
        let alias = editor.document.activeLayerID
        let duplicated = editor.document
        try require(duplicated.schemaVersion == 27 && duplicated.frames[0].rasterLayerInstances.count == 2,
                    "Image layer duplication did not create versioned linked instances")
        try require(duplicated.referencedRasterAssetIDs == ["immutable-original"] && duplicated.frames[0].elements.count == 2,
                    "Duplicate changed source identity or omitted vector content")
        editor.undo()
        try require(editor.document.frames == original.frames && editor.document.layers == original.layers,
                    "Linked duplicate was not one undo transaction")
        editor.redo()
        try require(editor.document.frames == duplicated.frames && editor.document.layers == duplicated.layers,
                    "Linked duplicate redo lost descriptors")
        print("PASS linked imported-layer duplication shares one source and one vector/image undo transaction")

        let unchanged = editor.document
        do { try editor.reflectImage(frameID: frameID, assetID: "immutable-original", axis: .horizontal)
            throw Failure(text: "Ambiguous legacy image operation edited the primary") }
        catch StudioDocumentError.invalid { }
        try require(editor.document == unchanged, "Ambiguous operation changed history/document")
        let originalDescriptor = editor.document.frames[0].rasterInstance(on: primary)
        try editor.updateImagePlacement(frameID: frameID, assetID: "immutable-original",
            placement: .init(x: 130, y: 60, width: 80, height: 60), layerID: alias)
        try editor.reflectImage(frameID: frameID, assetID: "immutable-original", axis: .horizontal, layerID: alias)
        try editor.rotateImage(frameID: frameID, assetID: "immutable-original", direction: .clockwise, layerID: alias)
        try editor.cropImage(frameID: frameID, assetID: "immutable-original", crop: .init(x: 0, y: 0, width: 0.5, height: 1), layerID: alias)
        try require(editor.document.frames[0].rasterInstance(on: primary) == originalDescriptor,
                    "Alias transform mutated primary image")
        let transformed = editor.document.frames[0].rasterInstance(on: alias)!
        try require(transformed.quarterTurns == 1 && transformed.reflection?.vertical == true && transformed.crop?.width == 0.5,
                    "Selected alias lost real crop/rotation/reflection")
        try editor.updateLayer(primary) { $0.visible = false }
        try require(editor.document.frames[0].visibleRasterInstances(in: editor.document.layers).map(\.layerID) == [alias],
                    "Hidden primary suppressed visible linked image")
        let projected = editor.document.frames[0].projectedRasterFrame(on: alias)!
        try require(projected.rasterAliases == nil && projected.rasterPlacement == transformed.placement && projected.elements == editor.document.frames[0].elements,
                    "Projection lost chosen image geometry or altered drawing content")
        print("PASS explicit linked-image transforms preserve siblings and resolve visible alias with hidden primary")

        try editor.updateLayer(alias) { $0.lockMode = "position" }
        let locked = editor.document
        do { try editor.deleteImage(frameID: frameID, assetID: "immutable-original", layerID: alias)
            throw Failure(text: "Locked linked image accepted deletion") }
        catch StudioDocumentError.locked { }
        try require(editor.document == locked, "Rejected linked edit changed project")
        try editor.updateLayer(alias) { $0.lockMode = "free" }
        let beforeCancel = editor.document
        var checks = 0
        do { try editor.deleteImage(frameID: frameID, assetID: "immutable-original", layerID: alias, checkCancellation: {
            checks += 1; if checks == 3 { throw CancellationError() }
        }); throw Failure(text: "Cancelled deletion succeeded") } catch is CancellationError { }
        try require(editor.document == beforeCancel, "Cancelled linked deletion partially committed")
        try editor.deleteLayer(primary)
        try require(editor.document.frames[0].rasterLayerID == alias && editor.document.frames[0].rasterAliases == nil &&
                    editor.document.frames[0].rasterInstance(on: alias) == transformed && editor.document.frames[0].rasterAssetID == "immutable-original",
                    "Deleting primary did not preserve and promote linked source/geometry")
        editor.undo()
        try require(editor.document.frames == beforeCancel.frames && editor.document.layers == beforeCancel.layers,
                    "Undo did not recover deleted primary and alias")
        editor.redo()
        try editor.deleteImage(frameID: frameID, assetID: "immutable-original", layerID: alias)
        try require(editor.document.frames[0].rasterLayerInstances.isEmpty && editor.document.frames[0].rasterAssetID == nil && editor.document.frames[0].rasterCrop == nil,
                    "Removing last linked image did not clear source and geometry")
        print("PASS linked deletion lock/cancellation rollback primary promotion last-image removal and undo")

        var frameCopies = try StudioDocumentEditor(document: duplicated)
        try frameCopies.duplicateFrame()
        frameCopies.copyFrame(); try frameCopies.pasteFrame()
        try require(frameCopies.document.frames.count == 3 && frameCopies.document.frames.allSatisfy { $0.rasterAliases == duplicated.frames[0].rasterAliases },
                    "Timeline duplicate/paste lost linked instances")
        try require(Set(frameCopies.document.frames.map(\.id)).count == 3 && frameCopies.document.referencedRasterAssetIDs.count == 1,
                    "Frame copies reused frame identity or manufactured source assets")
        let encoded = try JSONEncoder().encode(frameCopies.document)
        let reopened = try JSONDecoder().decode(StudioDocument.self, from: encoded)
        try reopened.validate()
        try require(reopened == frameCopies.document, "Version27 document roundtrip lost linked images")
        try frameCopies.deleteLayer(primary)
        try require(frameCopies.document.frames.allSatisfy { $0.rasterLayerID == alias && $0.rasterAliases == nil },
                    "Layer deletion did not promote copies across every frame")
        print("PASS linked timeline duplication frame clipboard version27 roundtrip and all-frame promotion")

        let mutations: [(inout StudioDocument) -> Void] = [
            { $0.schemaVersion = 26 },
            { $0.frames[0].rasterAliases![0].layerID = primary },
            { $0.frames[0].rasterAliases![0].layerID = "missing" },
            { $0.frames[0].rasterAliases![0].placement = nil },
            { $0.frames[0].rasterAliases![0].placement = .init(x: -1, y: 0, width: 10, height: 10) },
            { $0.frames[0].rasterAliases![0].quarterTurns = 4 },
            { $0.frames[0].rasterAliases![0].reflection = .init() },
            { $0.frames[0].rasterAliases![0].crop = .init(x: 0, y: 0, width: 0, height: 1) },
            { $0.frames[0].rasterAliases = Array(repeating: $0.frames[0].rasterAliases![0], count: 128) },
            { $0.frames[0].rasterAssetID = nil }
        ]
        for mutation in mutations {
            var invalid = duplicated; mutation(&invalid)
            var rejected = false
            do { try invalid.validate() } catch { rejected = true }
            try require(rejected, "Malformed linked descriptor/version/source/ownership accepted")
        }
        var limited = duplicated
        while limited.layers.count < 128 { limited.layers.append(.init(id: UUID().uuidString, name: "Spare")) }
        var cap = try StudioDocumentEditor(document: limited)
        do { try cap.duplicateLayer(primary); throw Failure(text: "Layer cap bypassed") }
        catch StudioDocumentError.invalid { }
        try require(cap.document == limited, "Layer-cap rejection changed document")
        print("PASS linked geometry ownership schema bounds and layer-cap rejection preserve document")

        var legacy = original; legacy.schemaVersion = 1; legacy.frames[0].rasterPlacement = nil
        let legacyBytes = try JSONEncoder().encode(legacy)
        let oldDecoded = try JSONDecoder().decode(StudioDocument.self, from: legacyBytes)
        try oldDecoded.validate()
        try require(oldDecoded.frames[0].rasterAliases == nil, "Old singular project manufactured aliases")
        var opaque = try StudioDocumentEditor(document: oldDecoded)
        try opaque.duplicateLayer(primary)
        let opaqueCopy = opaque.document.activeLayerID
        try require(opaque.document.frames[0].rasterLayerInstances.allSatisfy { $0.placement == nil } && opaque.document.referencedRasterAssetIDs == ["immutable-original"],
                    "Legacy opaque original was converted or lost")
        try opaque.deleteLayer(primary)
        try require(opaque.document.frames[0].rasterLayerID == opaqueCopy && opaque.document.frames[0].rasterPlacement == nil,
                    "Legacy full-canvas copy did not survive primary deletion")
        print("PASS historical singular opaque images duplicate and promote without fabricated managed geometry")
    }

    static func main() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-studio-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let old = Data(#"{"id":"historical-string-id","name":"Original","visible":true,"locked":true,"opacity":0.75}"#.utf8)
            let layer = try JSONDecoder().decode(CanvasLayer.self, from: old)
            try require(layer.id == "historical-string-id" && layer.isFullyLocked && layer.lockMode == "full" && layer.blendMode == "normal", "historical layer identity/lock defaults lost")
            print("PASS historical canonical layer decoder preserves string IDs and locked compatibility")

            var editor = try StudioDocumentEditor(document: .new(name: "Commands", width: 1080, height: 1920, fps: 12))
            let firstLayer = editor.document.activeLayerID
            try editor.commit(stroke(layer: firstLayer), frameID: editor.document.activeFrameID)
            let noSelection = editor.document
            try editor.deleteSelected()
            try require(editor.document == noSelection, "delete without explicit selection changed content")
            editor.selectedElementIDs = [editor.document.frames[0].elements[0].id]
            try editor.deleteSelected()
            try require(editor.document.frames[0].elements.isEmpty, "explicit selected deletion failed")
            editor.undo()
            try require(editor.document.frames[0].elements.count == 1 && editor.selectedElementIDs.isEmpty, "undo failed selected deletion")
            print("PASS explicit selected deletion and undo; unselected deletion is a no-op")
            try editor.addLayer()
            let secondLayer = editor.document.activeLayerID
            try editor.commit(stroke(layer: secondLayer), frameID: editor.document.activeFrameID)
            try editor.updateLayer(secondLayer) { $0.opacity = 0.4; $0.visible = false }
            let hidden = editor.document
            do { try editor.commit(stroke(layer: secondLayer), frameID: editor.document.activeFrameID); throw Failure(text: "hidden layer accepted drawing") }
            catch StudioDocumentError.locked { }
            try require(editor.document == hidden, "rejected command partially changed document")
            editor.undo()
            try require(editor.document.layers[0].visible && editor.document.layers[0].opacity == 1, "undo failed layer state")
            editor.redo()
            try require(!editor.document.layers[0].visible && editor.document.layers[0].opacity == 0.4, "redo failed layer state")
            try editor.updateLayer(secondLayer) { $0.visible = true; $0.locked = true; $0.lockMode = "full" }
            do { try editor.commit(stroke(layer: secondLayer), frameID: editor.document.activeFrameID); throw Failure(text: "full lock accepted drawing") }
            catch StudioDocumentError.locked { }
            try editor.moveLayer(secondLayer, offset: 1)
            try require(editor.document.layers[1].id == secondLayer, "canonical layer reorder failed")
            try editor.duplicateLayer(firstLayer)
            try require(editor.document.frames[0].elements.count == 3, "layer duplicate did not copy real elements")
            print("PASS full-document undo/redo, canonical layers, visibility/full-lock rejection and transactional rollback")

            let count = editor.document.frames.count
            editor.copyFrame()
            try require(editor.document.frames.count == count, "copy mutated frames")
            try editor.pasteFrame()
            try require(editor.document.frames.count == count + 1 && editor.document.frames[0].id != editor.document.frames[1].id,
                        "paste did not create distinct frame identity")
            try require(editor.document.frames[0].elements[0].id != editor.document.frames[1].elements[0].id, "paste reused element IDs")
            try editor.addFrame()
            editor.undo(); editor.redo()
            try require(editor.document.frames.count == count + 2, "frame undo/redo failed")
            let archive = StudioDocumentArchive(document: editor.document, rasterFrameIndices: [:])
            let decoded = try StudioDocumentArchive.decode(archive.encoded())
            try require(decoded.document == editor.document, "complete editable roundtrip lost document fields")
            var invalid = editor.document; invalid.fps = 0
            do { try invalid.validate(); throw Failure(text: "invalid FPS accepted") } catch StudioDocumentError.invalid { }
            invalid = editor.document; invalid.schemaVersion = 99
            do { try invalid.validate(); throw Failure(text: "future version accepted") } catch StudioDocumentError.invalid { }
            print("PASS real frame clipboard, full editable archive roundtrip and validation")

            for version in [23, 24, 25, 26] {
                var clipboardEditor = try StudioDocumentEditor(document: .new(name: "Schema clipboard", width: 256, height: 256, fps: 12))
                var element = stroke(layer: clipboardEditor.document.activeLayerID)
                if version == 26 {
                    element.tool = .line; element.shape = .init(version: 2, arrowEnds: .both, arrowLength: 12)
                } else {
                    element.brush = .init(family: version == 25 ? .neon : version == 23 ? .calligraphy : .round, seed: 42)
                    if version == 23 { element.brush?.version = 2; element.brush?.tiltEnabled = true }
                    if version == 24 { element.preservesLayerAlpha = true }
                }
                try clipboardEditor.commit(element, frameID: clipboardEditor.document.activeFrameID)
                clipboardEditor.copyFrame(); clipboardEditor.undo()
                try require(clipboardEditor.document.schemaVersion < version, "Fixture did not undo to an older schema")
                try clipboardEditor.pasteFrame()
                try require(clipboardEditor.document.schemaVersion == version && clipboardEditor.document.frames.count == 2,
                    "Frame paste lost schema upgrade \(version)")
                let copied = clipboardEditor.document.frames[1].elements[0]
                try require(copied.id != element.id && copied.brush == element.brush && copied.shape == element.shape &&
                    copied.preservesLayerAlpha == element.preservesLayerAlpha && copied.points == element.points,
                    "Frame paste lost modern descriptor or reused identity")
                try clipboardEditor.document.validate()
                let reopened = try StudioDocumentArchive.decode(StudioDocumentArchive(document: clipboardEditor.document, rasterFrameIndices: [:]).encoded())
                try require(reopened.document == clipboardEditor.document, "Modern pasted frame failed archive roundtrip")
            }
            print("PASS copied frames restore tilt/alpha/new-brush/arrow schema after Undo to older document")

            var lockEditor = try StudioDocumentEditor(document: .new(name: "Alpha deletion", width: 256, height: 256, fps: 12))
            let lockedLayer = lockEditor.document.activeLayerID
            let lockedStroke = stroke(layer: lockedLayer)
            try lockEditor.commit(lockedStroke, frameID: lockEditor.document.activeFrameID)
            try lockEditor.updateLayer(lockedLayer) { $0.lockMode = "alpha" }
            lockEditor.selectedElementIDs = [lockedStroke.id]
            let lockedBefore = lockEditor.document, undoBefore = lockEditor.canUndo, redoBefore = lockEditor.canRedo
            do { try lockEditor.deleteSelected(); throw Failure(text: "Alpha-locked deletion accepted") }
            catch StudioDocumentError.locked { }
            try require(lockEditor.document == lockedBefore && lockEditor.selectedElementIDs == [lockedStroke.id] &&
                lockEditor.canUndo == undoBefore && lockEditor.canRedo == redoBefore, "Alpha deletion changed document/history/selection")
            lockEditor.undo()
            try require(lockEditor.document.layers[0].lockMode == "free" && lockEditor.document.frames[0].elements.count == 1,
                "Rejected deletion inserted an Undo entry")
            try lockEditor.updateLayer(lockedLayer) { $0.lockMode = "position" }
            lockEditor.selectedElementIDs = [lockedStroke.id]; try lockEditor.deleteSelected()
            try require(lockEditor.document.frames[0].elements.isEmpty, "Position lock deletion semantics changed")
            print("PASS alpha lock prevents selected deletion atomically; position-lock behavior preserved")

            var high = try StudioDocument.new(name: "Revision edge", width: 256, height: 256, fps: 12)
            high.revision = Int.max - 3
            var edge = try StudioDocumentEditor(document: high)
            try edge.addFrame()
            try require(edge.document.revision == Int.max - 2 && edge.canUndo, "Last valid revision could not commit")
            try edge.document.validate()
            let atLimit = edge.document
            edge.selectedElementIDs = ["selection-must-survive"]
            do { try edge.addFrame(); throw Failure(text: "Revision overflow edit accepted") }
            catch StudioDocumentError.invalid { }
            edge.undo()
            try require(edge.document == atLimit && edge.canUndo && !edge.canRedo && edge.selectedElementIDs == ["selection-must-survive"],
                "Exhausted change/Undo consumed history, selection or published invalid revision")
            high.revision = Int.max - 4
            var redoEdge = try StudioDocumentEditor(document: high)
            try redoEdge.addFrame(); redoEdge.undo()
            let beforeRedo = redoEdge.document
            try require(beforeRedo.revision == Int.max - 2 && redoEdge.canRedo, "Redo edge fixture")
            redoEdge.selectedElementIDs = ["selection-must-survive"]; redoEdge.redo()
            try require(redoEdge.document == beforeRedo && redoEdge.canRedo && !redoEdge.canUndo && redoEdge.selectedElementIDs == ["selection-must-survive"],
                "Exhausted Redo consumed history or selection")
            try redoEdge.document.validate()
            print("PASS revision boundary preserves valid documents/history/selection for change, Undo and Redo")

            let documents = root.appendingPathComponent("Documents")
            let store = DeviceStorageManager(documentsDirectory: documents, cachesDirectory: root.appendingPathComponent("Caches"))
            let vm = StudioViewModel(storage: store)
            let created = await vm.createProject(name: "Offline A", width: 1080, height: 1920, fps: 12)
            try require(created && vm.isEditing && !vm.isDirty, "offline create failed")
            vm.commitElement(stroke(layer: vm.activeLayerID))
            vm.addLayer(); vm.commitElement(stroke(layer: vm.activeLayerID))
            vm.addFrame(); vm.commitElement(stroke(layer: vm.activeLayerID))
            vm.setLayerOpacity(vm.activeLayerID, opacity: 0.5)
            let firstID = vm.document.id
            let beforeSave = vm.document
            let saved = await vm.save()
            try require(saved && !vm.isDirty, "offline save failed")
            await vm.backToProjects()
            try require(!vm.isEditing && vm.savedProjects.count == 1, "saved project missing from real local library")
            let reopened = StudioViewModel(storage: store)
            let opened = await reopened.openProject(vm.savedProjects[0])
            try require(opened && reopened.document == beforeSave && reopened.layers.count == 2 && reopened.frames.count == 2,
                        "reopen lost actual production command document")
            await reopened.backToProjects()
            let secondCreated = await reopened.createProject(name: "Offline B", width: 512, height: 512, fps: 24)
            try require(secondCreated && reopened.document.id != firstID && reopened.frames.count == 1 && reopened.frames[0].elements.isEmpty && reopened.layers.count == 1,
                        "new project leaked old identity/content/layers")
            await reopened.backToProjects()
            guard let firstMetadata = reopened.savedProjects.first(where: { $0.id == firstID }) else { throw Failure(text: "first project lost") }
            _ = await reopened.openProject(firstMetadata)
            try require(reopened.document == beforeSave, "opening A after B leaked content")
            print("PASS production VM + atomic store: offline create, two layers/two frames, save/list/reopen and project isolation")

            let firstFrame = reopened.frames[0].id, originalLayer = reopened.layers.last!.id
            reopened.currentFrameIndex = 0
            reopened.selectLayer(originalLayer)
            try require(reopened.isDirty, "user selection did not mark persisted editor state dirty")
            await reopened.flush()
            let selectionRecord = try store.loadAnimation(id: firstID)!
            let savedSelection = try StudioDocumentArchive.decode(selectionRecord.editableDocumentData!).document
            try require(savedSelection.activeFrameID == firstFrame && savedSelection.activeLayerID == originalLayer && !reopened.isDirty,
                        "selection-only flush lost active frame or layer")
            let selectedRevision = reopened.document.revision
            reopened.togglePlayback()
            for _ in 0..<5 { reopened.advancePlaybackFrame() }
            try require(reopened.document.revision == selectedRevision && !reopened.isDirty && reopened.document.activeFrameID == firstFrame,
                        "playback changed persisted selection or dirtied every tick")
            reopened.stopPlayback()
            try require(reopened.currentFrameIndex == 0, "playback did not restore user-selected frame")
            print("PASS persisted user frame/layer selection and transient playback playhead")

            let timelineVM = StudioViewModel(storage: store)
            let timelineCreated = await timelineVM.createProject(name: "Stable frame targets", width: 512, height: 512, fps: 12)
            try require(timelineCreated, "Timeline fixture could not be created")
            let originalFrame = timelineVM.currentFrame.id
            let originalDrawing = stroke(layer: timelineVM.activeLayerID)
            try require(timelineVM.commitElement(originalDrawing), "Timeline source drawing was rejected")
            timelineVM.addFrame()
            let blankFrame = timelineVM.currentFrame.id
            let beforeDuplicate = timelineVM.document
            timelineVM.duplicateFrame(originalFrame)
            let duplicated = timelineVM.document, copyID = timelineVM.currentFrame.id
            try require(duplicated.frames.count == 3 && duplicated.frames[0].id == originalFrame
                && duplicated.frames[1].id == copyID && duplicated.frames[2].id == blankFrame,
                "Context duplication used the active index rather than the explicit source identity")
            try require(duplicated.revision == beforeDuplicate.revision + 1
                && timelineVM.currentFrame.elements.count == 1
                && timelineVM.currentFrame.elements[0].id != originalDrawing.id
                && timelineVM.currentFrame.elements[0].points == originalDrawing.points,
                "Context duplication lost real content or committed more than one document revision")
            timelineVM.undo()
            try require(timelineVM.document.frames == beforeDuplicate.frames
                && timelineVM.document.activeFrameID == blankFrame,
                "Undo of context duplication failed to restore the previously selected frame")
            timelineVM.redo()
            try require(timelineVM.document.frames == duplicated.frames && timelineVM.currentFrame.id == copyID,
                "Redo lost the duplicate's stable identity or content")
            timelineVM.moveFrame(originalFrame, offset: 1)
            timelineVM.selectFrame(originalFrame)
            try require(timelineVM.currentFrame.id == originalFrame && timelineVM.currentFrameIndex == 1,
                "Reordering retargeted a retained frame identity")
            timelineVM.deleteFrame(copyID)
            let afterDelete = timelineVM.document
            timelineVM.duplicateFrame(copyID)
            try require(timelineVM.document == afterDelete && timelineVM.message != nil,
                "A stale deleted context target duplicated an unrelated frame")
            timelineVM.selectFrame("missing-frame")
            try require(timelineVM.document == afterDelete, "Stale selection changed the document")
            timelineVM.undo()
            try require(timelineVM.document.frames.count == 3 && timelineVM.currentFrame.id == originalFrame,
                "Rejected context command damaged the previous undo entry")
            let timelineSaved = await timelineVM.save(), timelineSnapshot = timelineVM.document
            try require(timelineSaved, "Timeline fixture save failed")
            let timelineReopen = StudioViewModel(storage: store)
            await timelineReopen.loadProjects()
            guard let timelineMetadata = timelineReopen.savedProjects.first(where: { $0.id == timelineSnapshot.id }) else {
                throw Failure(text: "Saved timeline project missing")
            }
            let timelineOpened = await timelineReopen.openProject(timelineMetadata)
            try require(timelineOpened && timelineReopen.document == timelineSnapshot,
                "Stable frame identities, order, selection or real drawing content failed cold reopen")
            print("PASS explicit frame context identity, one-step duplication undo, stale-target rejection and cold reopen")

            let clipboardStore = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("ClipboardDocuments"),
                cachesDirectory: root.appendingPathComponent("ClipboardCaches"))
            let clipboardVM = StudioViewModel(storage: clipboardStore)
            let clipboardCreated = await clipboardVM.createProject(name: "Explicit frame clipboard", width: 512, height: 512, fps: 12)
            try require(clipboardCreated, "Frame clipboard fixture could not be created")
            let copiedFrameID = clipboardVM.currentFrame.id
            let copiedStroke = stroke(layer: clipboardVM.activeLayerID)
            try require(clipboardVM.commitElement(copiedStroke), "Frame clipboard source drawing failed")
            clipboardVM.addFrame()
            let selectedBlankID = clipboardVM.currentFrame.id
            let clipboardSaved = await clipboardVM.save()
            try require(clipboardSaved, "Frame clipboard fixture did not save")
            let beforeCopy = clipboardVM.document
            clipboardVM.copyFrame(copiedFrameID)
            try require(clipboardVM.document == beforeCopy && !clipboardVM.isDirty && clipboardVM.canPaste,
                "Copying a non-active timeline frame changed selection, history or persisted content")
            clipboardVM.pasteClipboard()
            let pastedID = clipboardVM.currentFrame.id
            let pastedSnapshot = clipboardVM.document
            try require(clipboardVM.frames.map(\.id) == [copiedFrameID, selectedBlankID, pastedID]
                && clipboardVM.currentFrame.elements.count == 1
                && clipboardVM.currentFrame.elements[0].id != copiedStroke.id
                && clipboardVM.currentFrame.elements[0].points == copiedStroke.points,
                "Explicit frame copy pasted the active blank frame or reused element identity")
            clipboardVM.undo()
            try require(clipboardVM.document.frames == beforeCopy.frames && clipboardVM.currentFrame.id == selectedBlankID,
                "Paste Undo did not restore the prior frame selection and content")
            clipboardVM.redo()
            try require(clipboardVM.document.frames == pastedSnapshot.frames && clipboardVM.currentFrame.id == pastedID,
                "Paste Redo changed the copied frame identity or drawing")
            clipboardVM.deleteFrame(copiedFrameID)
            let afterSourceDelete = clipboardVM.document
            clipboardVM.copyFrame(copiedFrameID)
            try require(clipboardVM.document == afterSourceDelete && clipboardVM.message != nil,
                "Stale frame copy changed the document or failed to report rejection")
            clipboardVM.pasteClipboard()
            try require(clipboardVM.currentFrame.elements.count == 1
                && clipboardVM.currentFrame.elements[0].points == copiedStroke.points,
                "Deleting the source or rejecting a stale copy lost the previously copied snapshot")
            let clipboardFinalSaved = await clipboardVM.save(), clipboardSnapshot = clipboardVM.document
            try require(clipboardFinalSaved, "Explicit clipboard result did not save")
            let clipboardReopen = StudioViewModel(storage: clipboardStore)
            await clipboardReopen.loadProjects()
            let clipboardOpened = await clipboardReopen.openProject(clipboardReopen.savedProjects[0])
            try require(clipboardOpened && clipboardReopen.document == clipboardSnapshot && !clipboardReopen.canPaste,
                "Clipboard result failed real cold reopen or leaked the transient clipboard")
            print("PASS non-active frame copy, immutable snapshot, stale rejection, paste history and actual cold reopen")

            let settingsRoot = documents.appendingPathComponent("settings-fixture")
            let settingsStore = DeviceStorageManager(documentsDirectory: settingsRoot, cachesDirectory: settingsRoot)
            let settingsVM = StudioViewModel(storage: settingsStore)
            let settingsCreated = await settingsVM.createProject(name: "Settings VM", width: 64, height: 64, fps: 12)
            try require(settingsCreated, "Settings VM project creation failed")
            settingsVM.commitElement(stroke(layer: settingsVM.activeLayerID))
            let settingsBefore = settingsVM.document
            try require(settingsVM.updateProjectSettings(name: "Configured", width: 96, height: 80, fps: 24,
                expectedProjectID: settingsBefore.id, expectedRevision: settingsBefore.revision), "Actual settings apply failed")
            let settingsAfter = settingsVM.document
            try require(settingsAfter.frames == settingsBefore.frames && settingsAfter.id == settingsBefore.id &&
                settingsAfter.width == 96 && settingsAfter.fps == 24, "Settings VM rescaled artwork or changed identity")
            try require(!settingsVM.updateProjectSettings(name: "Stale", width: 128, height: 128, fps: 30,
                expectedProjectID: settingsBefore.id, expectedRevision: settingsBefore.revision) &&
                settingsVM.document == settingsAfter, "Stale settings changed document")
            settingsVM.undo()
            try require(settingsVM.document.width == 64 && settingsVM.document.frames == settingsBefore.frames,
                "Settings VM Undo failed")
            settingsVM.redo()
            let settingsSaved = await settingsVM.save()
            try require(settingsSaved, "Configured project save failed")
            let settingsCold = StudioViewModel(storage: settingsStore)
            await settingsCold.loadProjects()
            let settingsOpened = await settingsCold.openProject(settingsCold.savedProjects[0])
            try require(settingsOpened && settingsCold.document == settingsVM.document, "Settings cold reopen lost configuration")
            print("PASS real VM settings transaction stale guard Undo Redo save and cold reopen")

            // A failed optional thumbnail refresh must not imprison already saved work.
            let cleanExitVM = StudioViewModel(storage: store)
            let cleanExitOpened = await cleanExitVM.openProject(firstMetadata)
            try require(cleanExitOpened, "Clean exit fixture failed to open")
            let cleanExitDocument = cleanExitVM.document
            var introducedStroke = false
            let backObserver = cleanExitVM.$savedProjects.dropFirst().sink { _ in
                if !introducedStroke { introducedStroke = cleanExitVM.beginStrokeInput(id: "reentrant-back-stroke") }
            }
            await cleanExitVM.backToProjects()
            backObserver.cancel()
            try require(introducedStroke && cleanExitVM.isEditing &&
                cleanExitVM.activeStrokeID == "reentrant-back-stroke" && cleanExitVM.document == cleanExitDocument,
                "Reentrant save observer lost an in-flight stroke while leaving")
            cleanExitVM.finishStrokeInput(id: "reentrant-back-stroke")

            let preserved = documents.appendingPathComponent("Animations-preserved")
            try fm.moveItem(at: store.animationsDir, to: preserved)
            try Data("blocked directory fixture".utf8).write(to: store.animationsDir)
            await cleanExitVM.backToProjects()
            try require(!cleanExitVM.isEditing && !cleanExitVM.isDirty &&
                cleanExitVM.document == cleanExitDocument,
                "Optional save failure trapped or changed already saved artwork")

            reopened.commitElement(stroke(layer: reopened.activeLayerID))
            let unsaved = reopened.document
            let failedSave = await reopened.save()
            await reopened.backToProjects()
            try require(!failedSave && reopened.isEditing && reopened.isDirty && reopened.document == unsaved && reopened.message?.contains("Save failed") == true,
                        "failed save/back discarded dirty work or claimed success")
            try fm.removeItem(at: store.animationsDir)
            try fm.moveItem(at: preserved, to: store.animationsDir)
            let recovered = await reopened.save()
            try require(recovered && !reopened.isDirty, "retry after storage recovery failed")
            await reopened.backToProjects()
            print("PASS production storage failure preserves edits, dirty status and editor; retry succeeds")

            let raster = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jfN0AAAAASUVORK5CYII=")!
            let audio = Data("RIFF fixture preserved without claiming playback".utf8)
            let legacyID = UUID(), now = Date()
            let metadata = AnimationMetadata(id: legacyID, title: "Imported", fps: 12, canvasWidth: 512, canvasHeight: 512,
                frameCount: 1, layerCount: 1, createdAt: now, modifiedAt: now, thumbnailData: nil)
            try store.saveAnimation(AnimationProject(id: legacyID, metadata: metadata, frames: [StoredAnimationFrame(imageData: raster, layerData: nil)],
                audioTracks: [AudioTrack(id: UUID(), name: "Original audio", format: "wav", audioData: audio, startTime: 0, duration: 1)]))
            let imported = StudioViewModel(storage: store)
            let importOpened = await imported.openProject(metadata)
            try require(importOpened && imported.layers.last?.isFullyLocked == true && imported.rasterData(imported.frames[0].rasterAssetID) == raster,
                        "legacy image was not preserved with flattened locked layer")
            imported.commitElement(stroke(layer: imported.activeLayerID))
            imported.copyFrame(); imported.pasteFrame()
            let importSaved = await imported.save()
            let storedImport = try store.loadAnimation(id: legacyID)
            try require(importSaved && storedImport?.frames.count == 2 && storedImport?.frames.allSatisfy({ $0.imageData == raster }) == true,
                        "legacy image bytes lost on editable save/copy")
            try require(storedImport?.audioTracks.first?.audioData == audio && storedImport?.editableDocumentData != nil,
                        "original audio or editable payload lost")
            print("PASS production imported raster/audio byte preservation alongside editable frames")

            let gapID = UUID()
            let gapMetadata = AnimationMetadata(id: gapID, title: "Historical gaps", fps: 12, canvasWidth: 512, canvasHeight: 512,
                frameCount: 11, layerCount: 1, createdAt: now, modifiedAt: now, thumbnailData: nil)
            let gapDirectory = store.animationsDir.appendingPathComponent(gapID.uuidString)
            try fm.createDirectory(at: gapDirectory, withIntermediateDirectories: true)
            let originalMetadataBytes = try JSONEncoder().encode(gapMetadata)
            try originalMetadataBytes.write(to: gapDirectory.appendingPathComponent("metadata.json"))
            for index in [0, 2, 10] { try raster.write(to: gapDirectory.appendingPathComponent("frame_\(index).png")) }
            let gaps = StudioViewModel(storage: store)
            let gapsOpened = await gaps.openProject(gapMetadata)
            let gapsSaved = await gaps.save()
            let unchangedGaps = try store.loadAnimation(id: gapID)!
            try require(!gapsOpened && !gaps.isEditing && !gapsSaved && gaps.message?.contains("Recovery is required") == true,
                        "gapped historical project entered editor or silently saved compacted timing")
            try require(unchangedGaps.metadata.frameCount == 11 && unchangedGaps.frames.compactMap(\.legacyFrameIndex) == [0, 2, 10]
                        && unchangedGaps.editableDocumentData == nil, "gapped project timing or provenance was rewritten")
            let unchangedMetadataBytes = try Data(contentsOf: gapDirectory.appendingPathComponent("metadata.json"))
            try require(unchangedMetadataBytes == originalMetadataBytes, "original gapped metadata bytes changed")
            print("PASS incomplete historical frame positions fail closed with original timing/files intact")

            let opaqueID = UUID()
            let opaqueMetadata = AnimationMetadata(id: opaqueID, title: "Opaque layer frame", fps: 12, canvasWidth: 512, canvasHeight: 512,
                frameCount: 1, layerCount: 1, createdAt: now, modifiedAt: now, thumbnailData: nil)
            let originalOpaqueLayer = LayerData(id: UUID(), name: "Unrendered original metadata", opacity: 0.4, blendMode: "multiply", locked: true, visible: false)
            let originalRecord = StoredAnimationFrame(imageData: nil, layerData: [originalOpaqueLayer])
            try store.saveAnimation(AnimationProject(id: opaqueID, metadata: opaqueMetadata, frames: [originalRecord], audioTracks: []))
            let opaque = StudioViewModel(storage: store), opaqueAgain = StudioViewModel(storage: store)
            let opaqueOpened = await opaque.openProject(opaqueMetadata)
            let sameOpened = await opaqueAgain.openProject(opaqueMetadata)
            try require(opaqueOpened && sameOpened && opaque.frames.map(\.id) == opaqueAgain.frames.map(\.id)
                        && opaque.layers.map(\.id) == opaqueAgain.layers.map(\.id), "legacy frame/layer identities changed between read-only opens")
            let opaqueSaved = await opaque.save()
            let preservedOpaque = try store.loadAnimation(id: opaqueID)!
            let originalRecordBytes = try JSONEncoder().encode(originalRecord.layerData)
            let preservedRecordBytes = try JSONEncoder().encode(preservedOpaque.frames[0].layerData)
            // Compare decoded values, since JSON dictionary key order is not guaranteed.
            let originalObject = try JSONSerialization.jsonObject(with: originalRecordBytes) as! NSArray
            let preservedObject = try JSONSerialization.jsonObject(with: preservedRecordBytes) as! NSArray
            try require(opaqueSaved && preservedOpaque.frames[0].imageData == nil && originalObject.isEqual(preservedObject),
                        "nil-image original lost opaque layer metadata")
            let opaqueReopened = StudioViewModel(storage: store)
            let reopenOpaque = await opaqueReopened.openProject(preservedOpaque.metadata)
            let resavedOpaque = await opaqueReopened.save()
            let opaqueFinal = try store.loadAnimation(id: opaqueID)!
            try require(reopenOpaque && resavedOpaque && opaqueFinal.frames[0].layerData?.first?.id == originalOpaqueLayer.id,
                        "opaque frame record failed repeated editable reopen/save")
            print("PASS nil-image opaque frame metadata and deterministic legacy IDs survive open/save/reopen")
            let onionStore = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Onion"))
            let onion = StudioViewModel(storage: onionStore)
            let madeOnion = await onion.createProject(name: "Onion controls", width: 128, height: 128, fps: 12)
            try require(madeOnion, "Onion project")
            for _ in 0..<4 { onion.addFrame() }
            onion.selectFrame(onion.frames[2].id)
            onion.showOnionSkin = true
            try require(onion.visibleOnionGhosts.map(\.frame.id) == [onion.frames[1].id], "Legacy one-previous default changed")
            onion.onionPreviousCount = 2; onion.onionNextCount = 2; onion.onionOpacity = 0.6; onion.onionTinted = true
            let ghosts = onion.visibleOnionGhosts
            try require(ghosts.map(\.frame.id) == [0,4,1,3].map { onion.frames[$0].id } && ghosts.map(\.opacity) == [0.3,0.3,0.6,0.6], "Ghost range/order/fade wrong")
            try require(ghosts.map(\.previous) == [true,false,true,false] && ghosts.allSatisfy(\.tinted), "Tint directions wrong")
            onion.togglePlayback(); try require(onion.visibleOnionGhosts.isEmpty, "Playback retained editor ghosts"); onion.togglePlayback()
            let savedOnion = await onion.save(); try require(savedOnion, "Onion save")
            let onionMetadata = try onionStore.loadAnimation(id: onion.document.id)!.metadata
            let reopenedOnion = StudioViewModel(storage: onionStore)
            let loadedOnion = await reopenedOnion.openProject(onionMetadata)
            try require(loadedOnion && reopenedOnion.document.onionSettings == onion.document.onionSettings, "Onion cold reopen lost settings")
            onion.selectFrame(onion.frames[0].id)
            try require(onion.visibleOnionGhosts.count == 2 && onion.visibleOnionGhosts.allSatisfy { !$0.previous }, "Ghosts wrapped around first frame")
            onion.showOnionSkin = false; try require(onion.visibleOnionGhosts.isEmpty, "Disabled onion produced ghosts")
            var invalidOnion = onion.document; invalidOnion.onionSettings?.previousCount = 3
            var rejectedOnion = false
            do { try invalidOnion.validate() } catch { rejectedOnion = true }
            try require(rejectedOnion, "Unbounded onion range accepted")
            print("PASS real onion range direction opacity playback suppression and cold reopen")
            onion.gridEnabled = true; onion.gridSpacing = 24; onion.gridOpacity = 0.4; onion.gridTint = .red
            let grid = onion.document.gridSettings!
            try require(grid.positions(length: 80) == [0,24,48,72] && grid.positions(length: .infinity).isEmpty, "Grid geometry ignores spacing or accepts infinite work")
            try require(StudioGridSettings(spacing: 8).positions(length: 8192).count == 1025, "Grid work is not bounded")
            let settingsRequest = StudioCommandRequest(requestID: UUID(), projectID: onion.document.id, expectedRevision: onion.document.revision,
                action: .apply([.canvasOptions(.init(gridSettings: .init(spacing: 32, opacity: 0.3, tint: .gray),
                    onionSettings: .init(previousCount: 1, nextCount: 1, opacity: 0.4, tinted: true)))]))
            let wire = try JSONEncoder().encode(settingsRequest)
            let decodedSettings = try StudioCommandExecutor.decode(wire)
            let beforeSettings = onion.document
            _ = try onion.applyStudioCommands(decodedSettings)
            try require(onion.document.revision == beforeSettings.revision + 1 && onion.gridSpacing == 32 && onion.onionNextCount == 1 && onion.frames == beforeSettings.frames, "Typed editor settings failed atomic artwork-preserving update")
            onion.undo(); try require(onion.document.gridSettings == beforeSettings.gridSettings && onion.document.onionSettings == beforeSettings.onionSettings, "One undo did not restore both settings")
            var malformed = try JSONSerialization.jsonObject(with: wire) as! [String: Any]
            var action = malformed["action"] as! [String: Any]
            var commands = action["apply"] as! [[String: Any]]
            var options = commands[0]["canvasOptions"] as! [String: Any]
            var fields = options["gridSettings"] as! [String: Any]
            fields["unrecognized"] = true; options["gridSettings"] = fields; commands[0]["canvasOptions"] = options
            action["apply"] = commands; malformed["action"] = action
            var rejectedFields = false
            do { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: malformed)) } catch { rejectedFields = true }
            try require(rejectedFields, "Unknown nested settings bypassed strict command decoder")
            let beforeInvalid = onion.document
            var invalidSettingsRejected = false
            do {
                _ = try onion.applyStudioCommands(.init(requestID: UUID(), projectID: onion.document.id, expectedRevision: onion.document.revision,
                    action: .apply([.canvasOptions(.init(gridSettings: .init(spacing: 0), onionSettings: .init(nextCount: 1)))])))
            } catch { invalidSettingsRejected = true }
            try require(invalidSettingsRejected && onion.document == beforeInvalid, "Invalid grid partially committed editor settings")
            let savedGrid = await onion.save(); try require(savedGrid, "Grid save failed")
            let gridReopened = StudioViewModel(storage: onionStore)
            let openedGrid = await gridReopened.openProject(try onionStore.loadAnimation(id: onion.document.id)!.metadata)
            try require(openedGrid && gridReopened.document.gridSettings == onion.document.gridSettings, "Grid cold reopen lost controls")
            print("PASS bounded grid geometry typed settings strict decoding atomic rollback undo and cold reopen")
            try projectConfiguration()
            try mixedImageOrdering()
            try imageMaskHistoryBudget()
            try linkedRasterJourneys()
            // Historical disabled colors were opaque metadata, including eight-digit and
            // noncanonical strings. Opening and editing unrelated content must preserve them.
            for historicalColor in ["#FF000080", "legacy-custom-color"] {
                var historicalGlow = try StudioDocument.new(name: "Historical glow", width: 128, height: 128, fps: 12)
                historicalGlow.layers[0].glowEnabled = false
                historicalGlow.layers[0].glowColor = historicalColor
                let bytes = try JSONEncoder().encode(historicalGlow)
                var reopenedHistorical = try StudioDocumentEditor(document: JSONDecoder().decode(StudioDocument.self, from: bytes))
                try reopenedHistorical.updateLayer(historicalGlow.activeLayerID) { $0.name = "Renamed without rewriting color" }
                let roundtrip = try JSONDecoder().decode(StudioDocument.self, from: JSONEncoder().encode(reopenedHistorical.document))
                try roundtrip.validate()
                try require(roundtrip.layers[0].glowColor == historicalColor && !roundtrip.layers[0].glowEnabled && roundtrip.schemaVersion == historicalGlow.schemaVersion,
                            "Unrelated legacy edit rejected, rewrote or migrated opaque disabled glow color")
            }
            let glowStore = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("GlowDocuments"), cachesDirectory: root.appendingPathComponent("GlowCaches"))
            let glowVM = StudioViewModel(storage: glowStore)
            let glowCreated = await glowVM.createProject(name: "Glow persistence", width: 128, height: 128, fps: 12)
            try require(glowCreated, "Glow project failed to create")
            let glowID = glowVM.activeLayerID
            try require(glowVM.layers[0].effectiveGlowRadius == 5 && glowVM.layers[0].effectiveGlowStrength == 1,
                        "Legacy glow defaults changed")
            glowVM.commitElement(stroke(layer: glowID))
            glowVM.setLayerGlow(glowID, enabled: true)
            let beforeGlow = glowVM.document
            glowVM.setLayerGlowStyle(glowID, color: "#00FF00", radius: 24, strength: 0.4)
            let afterGlow = glowVM.document
            try require(afterGlow.schemaVersion == 28 && afterGlow.layers[0].glowColor == "#00FF00" && afterGlow.layers[0].glowRadius == 24 && afterGlow.layers[0].glowStrength == 0.4,
                        "Actual VM did not commit the complete glow style")
            glowVM.undo()
            try require(glowVM.layers == beforeGlow.layers, "Glow style was not one undo transaction")
            glowVM.redo()
            try require(glowVM.layers == afterGlow.layers, "Glow style redo lost appearance")
            glowVM.duplicateLayer(glowID)
            try require(glowVM.layers.allSatisfy { $0.glowColor == "#00FF00" && $0.glowRadius == 24 && $0.glowStrength == 0.4 }, "Layer duplication lost glow appearance")
            let beforeInvalidGlow = glowVM.document
            for invalid in [Double.nan, Double.infinity, -1, 129] {
                glowVM.setLayerGlowStyle(glowID, radius: invalid)
                try require(glowVM.document == beforeInvalidGlow, "Invalid glow radius partially changed document")
            }
            glowVM.setLayerGlowStyle(glowID, strength: 1.1)
            glowVM.setLayerGlowStyle(glowID, color: "#GG0000")
            glowVM.setLayerGlowStyle(glowID, color: "#FF000080")
            glowVM.setLayerGlowStyle(glowID, color: "FF0000")
            try require(glowVM.document == beforeInvalidGlow, "Invalid glow color/strength changed document")
            let savedGlow = await glowVM.save(); try require(savedGlow, "Glow save failed")
            let expectedGlow = glowVM.document
            let glowReopened = StudioViewModel(storage: glowStore)
            await glowReopened.loadProjects()
            guard let glowProject = glowReopened.savedProjects.first(where: { $0.id == expectedGlow.id }) else { throw Failure(text: "Saved glow project absent") }
            let openedGlow = await glowReopened.openProject(glowProject)
            try require(openedGlow && glowReopened.document == expectedGlow, "Cold reopen lost exact glow document")
            var legacyVersionWithNewFields = expectedGlow; legacyVersionWithNewFields.schemaVersion = 27
            var invalidVersionRejected = false
            do { try legacyVersionWithNewFields.validate() } catch { invalidVersionRejected = true }
            try require(invalidVersionRejected, "New glow metadata accepted in unsupported old schema")
            print("PASS actual glow VM transaction, duplication, invalid rollback, atomic save and cold reopen")
            for stage in [DeviceStorageManager.RevisionWriteStage.payload, .lineageReceipt] {
                let spaceStore = VMRevisionSpaceFailureStore(documentsDirectory: root.appendingPathComponent("Space-\(UUID().uuidString)"))
                let spaceVM = StudioViewModel(storage: spaceStore)
                let createdSpace = await spaceVM.createProject(name: "Space recovery", width: 128, height: 128, fps: 12)
                try require(createdSpace, "Disk-full VM fixture failed")
                let savedBefore = spaceVM.document
                spaceVM.commitElement(stroke(layer: spaceVM.activeLayerID))
                let dirtyBefore = spaceVM.document
                spaceStore.failingStage = stage
                let failedSpace = await spaceVM.save()
                await spaceVM.backToProjects()
                try require(!failedSpace && spaceVM.isDirty && spaceVM.isEditing && spaceVM.document == dirtyBefore && spaceVM.message?.contains("Save failed") == true,
                            "Durable-stage disk-full failure discarded dirty editor or claimed success")
                let reopenedSpace = StudioViewModel(storage: spaceStore)
                await reopenedSpace.loadProjects()
                guard let savedSpace = reopenedSpace.savedProjects.first(where: { $0.id == savedBefore.id }) else { throw Failure(text: "Published project disappeared after disk-full save") }
                let openedSpace = await reopenedSpace.openProject(savedSpace)
                try require(openedSpace && reopenedSpace.document == savedBefore, "Cold reader adopted failed durable revision")
                spaceStore.failingStage = nil
                let retriedSpace = await spaceVM.save()
                try require(retriedSpace && !spaceVM.isDirty && spaceVM.document == dirtyBefore, "Retry did not save exact retained edits")
                let finalSpace = StudioViewModel(storage: spaceStore)
                await finalSpace.loadProjects()
                guard let finalMetadata = finalSpace.savedProjects.first(where: { $0.id == dirtyBefore.id }) else { throw Failure(text: "Retried project absent") }
                let openedFinal = await finalSpace.openProject(finalMetadata)
                try require(openedFinal && finalSpace.document == dirtyBefore, "Retry cold reopen lost dirty artwork")
            }
            print("PASS actual VM payload/receipt disk-full dirty retention, old cold reader, retry and final cold reopen")
            print("STUDIO_DOCUMENT_TESTS=PASS 26 journeys")
        } catch {
            print("STUDIO_DOCUMENT_TESTS=FAIL \(error)")
            exit(1)
        }
    }
}
