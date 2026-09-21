import Foundation

private struct Failure: Error { let text: String }
private func require(_ condition: @autoclosure () -> Bool, _ text: String) throws {
    if !condition() { throw Failure(text: text) }
}
private func stroke(layer: String, id: String = UUID().uuidString) -> DrawnElement {
    DrawnElement(id: id, tool: .brush, points: [StrokePoint(x: 30, y: 40), StrokePoint(x: 100, y: 150)],
                 color: "#FF0000", width: 5, opacity: 0.7, layerID: layer)
}

@main @MainActor struct StudioDocumentTests {
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

            let preserved = documents.appendingPathComponent("Animations-preserved")
            try fm.moveItem(at: store.animationsDir, to: preserved)
            try Data("blocked directory fixture".utf8).write(to: store.animationsDir)
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
            print("STUDIO_DOCUMENT_TESTS=PASS 12 journeys")
        } catch {
            print("STUDIO_DOCUMENT_TESTS=FAIL \(error)")
            exit(1)
        }
    }
}
