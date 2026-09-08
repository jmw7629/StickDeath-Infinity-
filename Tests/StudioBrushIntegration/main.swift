import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// Only the UIKit image container is adapted for native macOS pixel checks.
// The complete production models, editor, store, VM and renderers are compiled.
typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }

private struct Failure: Error { let message: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
}
private func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw Failure(message: "Expected explicit rejection")
}

@main @MainActor struct StudioBrushIntegrationTests {
    static func stroke(_ layer: String, id: String = UUID().uuidString, family: StudioBrushFamily = .round,
                       width: Double = 10, opacity: Double = 1) -> DrawnElement {
        DrawnElement(id: id, tool: .brush,
            points: [StrokePoint(x: 8, y: 32, timestamp: 0), StrokePoint(x: 56, y: 32, timestamp: 0.2)],
            color: "#FF0000", width: width, opacity: opacity, layerID: layer,
            brush: StudioBrushDescriptor(family: family, seed: 71, smoothing: 0,
                gradientEndColor: family == .gradient ? StudioBrushColor(red: 0, green: 0, blue: 1) : nil))
    }
    static func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let worked = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        try require(worked, "Pixel decode unavailable")
        return bytes
    }
    static func render(_ frame: AnimationFrame, layers: [CanvasLayer], edge: Int = 64,
                       outerOpacity: Double = 1) throws -> [UInt8] {
        let prepared = try StudioFrameRenderer.prepare(frame: frame)
        var error: Error?
        let renderer = ImageRenderer(content: Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            context.opacity = outerOpacity
            error = StudioFrameRenderer.draw(context: &context, frame: frame, layers: layers,
                canvasSize: CGSize(width: 64, height: 64), size: size, preparedBrushes: prepared)
        }.frame(width: CGFloat(edge), height: CGFloat(edge)))
        renderer.scale = 1
        guard let image = renderer.cgImage else { throw Failure(message: "Actual native renderer produced no image") }
        if let error { throw error }
        return try pixels(image)
    }
    static func sortedData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func main() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-brush-integration-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            var editor = try StudioDocumentEditor(document: .new(name: "Brush journey", width: 64, height: 64, fps: 12))
            let firstLayer = editor.document.activeLayerID, firstFrame = editor.document.activeFrameID
            var legacy = stroke(firstLayer); legacy.brush = nil
            let legacyBytes = try sortedData(legacy)
            try require(!String(decoding: legacyBytes, as: UTF8.self).contains("\"brush\":"), "Legacy encoding gained brush metadata")
            let decodedLegacy = try JSONDecoder().decode(DrawnElement.self, from: legacyBytes)
            try require(decodedLegacy.brush == nil && decodedLegacy == legacy, "Historical optional brush decoding changed")
            try editor.commit(legacy, frameID: firstFrame)
            let oldPixels = try render(editor.document.frames[0], layers: editor.document.layers)
            try require(editor.document.schemaVersion == 1, "Unstyled historical commit upgraded schema")
            print("PASS legacy optional decoding/encoding and schema1 remain unchanged")

            let styled = stroke(firstLayer, family: .grain)
            try editor.commit(styled, frameID: firstFrame)
            try require(editor.document.schemaVersion == 2, "First styled commit did not upgrade schema")
            let archive = try StudioDocumentArchive(document: editor.document, rasterFrameIndices: [:]).encoded()
            try require(StudioDocumentArchive.decode(archive).document == editor.document, "Brush descriptor archive roundtrip changed data")
            var wrong = editor.document; wrong.schemaVersion = 1
            try rejects { try wrong.validate() }
            wrong.schemaVersion = 3; try rejects { try wrong.validate() }
            editor.undo()
            try require(editor.document.schemaVersion == 1 && render(editor.document.frames[0], layers: editor.document.layers) == oldPixels,
                        "Undo failed to restore historical schema/pixels")
            editor.redo()
            print("PASS schema2 upgrade/archive and full-document undo preserve exact legacy pixels")

            editor.copyFrame(); try editor.pasteFrame()
            let copied = editor.document.frames[1]
            try require(copied.elements[1].id != styled.id && copied.elements[1].brush == styled.brush, "Copy lost seed or retained duplicate element identity")
            try require(render(copied, layers: editor.document.layers) == render(editor.document.frames[0], layers: editor.document.layers), "Copied texture pixels changed")
            try editor.duplicateLayer(firstLayer)
            let duplicateLayer = editor.document.activeLayerID
            let layerCopy = editor.document.frames[0].elements.first { $0.layerID == duplicateLayer && $0.brush != nil }!
            try require(layerCopy.brush == styled.brush && layerCopy.id != styled.id, "Layer duplication lost brush descriptor/seed")
            print("PASS actual frame clipboard and layer duplication preserve seeded texture")

            let started = Date(timeIntervalSince1970: 100)
            var input = StudioStrokeInput(id: "captured", frameID: firstFrame, layerID: firstLayer,
                tool: .brush, color: "#FF0000", width: 7, opacity: 0.4,
                brush: StudioBrushDescriptor(family: .dipPen, seed: 999),
                documentSize: CGSize(width: 64, height: 64), viewportSize: CGSize(width: 128, height: 128), startedAt: started)
            try input.append(location: CGPoint(x: 16, y: 20), time: started)
            try input.append(location: CGPoint(x: 100, y: 88), time: started.addingTimeInterval(0.125))
            try require(input.element.id == "captured" && input.element.brush?.seed == 999 && input.points[1].timestamp == 0.125,
                        "Input identity, seed or actual elapsed time changed")
            try require(input.points[1].x == 50 && input.points[1].y == 44 && input.points.allSatisfy { $0.pressure == nil }, "Input geometry or unavailable force was invented")
            let beforeTimingError = input.element
            try rejects { try input.append(location: .zero, time: started.addingTimeInterval(0.01)) }
            try require(input.element == beforeTimingError, "Invalid event timing mutated captured stroke")
            print("PASS production touch capture uses measured timestamps/stable identity and no invented pressure")

            var halfLayer = CanvasLayer(id: "half", name: "Half"); halfLayer.opacity = 0.5
            let halfStroke = stroke(halfLayer.id, opacity: 0.5)
            let halfFrame = AnimationFrame(id: "half-frame", elements: [halfStroke])
            let rgba = try render(halfFrame, layers: [halfLayer], outerOpacity: 0.5)
            let center = Array(rgba[(32 * 64 + 32) * 4..<(32 * 64 + 32) * 4 + 4])
            try require(zip(center, [255, 223, 223, 255]).allSatisfy { abs(Int($0.0) - $0.1) <= 2 }, "Brush/layer/onion opacity applied more than once: \(center)")
            halfLayer.visible = false
            try require(render(halfFrame, layers: [halfLayer]).allSatisfy { $0 == 255 }, "Hidden styled layer rendered pixels")
            print("PASS actual shared renderer applies brush/layer/onion opacity once and honors visibility")

            let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("documents"), cachesDirectory: root.appendingPathComponent("cache"))
            var persisted = editor.document
            persisted.audioClips = [AudioClip(id: "original-audio-clip", soundName: "Original", track: 0, startTime: 0, duration: 1)]
            let originalAudio = AudioTrack(id: UUID(), name: "Original audio", format: "wav", audioData: Data([1, 2, 3, 4]), startTime: 0, duration: 1, legacySourceFilename: "audio_7.wav")
            let originalAudioBytes = try sortedData(persisted.audioClips)
            let metadata = AnimationMetadata(id: persisted.id, title: persisted.name, fps: persisted.fps,
                canvasWidth: persisted.width, canvasHeight: persisted.height, frameCount: persisted.frames.count,
                layerCount: persisted.layers.count, createdAt: persisted.createdAt, modifiedAt: persisted.modifiedAt, thumbnailData: nil)
            try storage.saveAnimation(AnimationProject(id: persisted.id, metadata: metadata,
                frames: persisted.frames.map { _ in StoredAnimationFrame(imageData: nil, layerData: nil) }, audioTracks: [originalAudio],
                editableDocumentData: StudioDocumentArchive(document: persisted, rasterFrameIndices: [:]).encoded()))
            let vm = StudioViewModel(storage: storage)
            let opened = await vm.openProject(metadata); try require(opened, "Actual VM could not reopen brush document")
            try require(vm.document == persisted && sortedData(vm.audioClips) == originalAudioBytes, "VM open altered brush/audio document")
            vm.addFrame(); vm.addLayer()
            let drawn = stroke(vm.activeLayerID, family: .halftone)
            try require(vm.commitElement(drawn), "Actual VM brush commit failed")
            let saved = await vm.save(); try require(saved, "Actual atomic brush save failed")
            let reopened = StudioViewModel(storage: storage)
            let reopenedOK = await reopened.openProject(metadata); try require(reopenedOK, "Saved brush project failed reopen")
            try require(reopened.currentFrame.elements.last?.brush == drawn.brush && sortedData(reopened.audioClips) == originalAudioBytes,
                        "Save/reopen lost brush or canonical audio data")
            try require(reopened.projectAudioTracks.first?.audioData == originalAudio.audioData,
                        "Opaque historical audio bytes were lost")
            print("PASS real production VM/store create layers/frames/save/reopen retains brush and original audio")

            var invalid = stroke(vm.activeLayerID); invalid.width = 0.1
            let prior = vm.document
            try require(!vm.commitElement(invalid) && vm.pendingBrushStroke?.element == invalid && vm.document == prior,
                        "Rejected brush mutated document or discarded draft")
            try require(!vm.commandScreenContext.canApplyCommands, "Pending draft still advertises command availability")
            try rejects { try vm.applyStudioCommands(Data()) }
            await vm.backToProjects(); try require(vm.isEditing && vm.pendingBrushStroke != nil, "Leaving discarded pending draft")
            let pendingSave = await vm.save(); try require(!pendingSave && vm.isDirty, "Save falsely claimed rejected draft persisted")
            vm.strokeWidth = 8; vm.brushFamily = .round; vm.retryRejectedBrush()
            try require(vm.pendingBrushStroke == nil && vm.document.frames.last?.elements.last?.id == invalid.id,
                        "Retry did not preserve captured identity or apply current settings")
            vm.undo(); try require(vm.document.frames.last?.elements.last?.id != invalid.id, "Retry was not reversible")
            vm.retainRejectedBrush(invalid, frameID: vm.currentFrame.id, reason: "capture limit", inputComplete: false)
            vm.retryRejectedBrush(); try require(vm.pendingBrushStroke != nil, "Incomplete rejected capture was silently committed")
            vm.discardRejectedBrush(); try require(vm.pendingBrushStroke == nil, "Explicit discard failed")
            print("PASS rejected draft retry/undo/explicit discard and save/close/command gates")

            var lifecycle = StudioStrokeInput(id: "lifecycle", frameID: vm.currentFrame.id, layerID: vm.activeLayerID,
                tool: .brush, color: "#FF0000", width: 7, opacity: 0.5,
                brush: StudioBrushDescriptor(family: .round, seed: 17), documentSize: CGSize(width: 64, height: 64),
                viewportSize: CGSize(width: 64, height: 64), startedAt: started)
            try lifecycle.append(location: CGPoint(x: 12, y: 18), time: started)
            let beforeActive = vm.document
            try require(vm.beginStrokeInput(id: lifecycle.id) && vm.isDirty && !vm.commandScreenContext.canApplyCommands,
                        "Ongoing touch capture was advertised as saved/command-ready")
            vm.addLayer(); vm.currentFrameIndex = 0; vm.undo(); vm.togglePlayback()
            try require(vm.document == beforeActive && !vm.isPlaying, "A second input mutated the captured frame/document")
            await vm.backToProjects(); try require(vm.isEditing && vm.activeStrokeID == lifecycle.id, "Back discarded ongoing capture")
            let activeSaved = await vm.save(); try require(!activeSaved && vm.isDirty, "Save falsely acknowledged an ongoing stroke")
            vm.interruptStrokeInput(lifecycle, reason: "Native gesture/scene interrupted")
            try require(vm.activeStrokeID == nil && vm.pendingBrushStroke?.element == lifecycle.element && vm.pendingBrushStroke?.inputComplete == false,
                        "Scene/gesture interruption lost captured input or treated it as complete")
            vm.discardRejectedBrush()
            try require(vm.beginStrokeInput(id: lifecycle.id), "Explicitly discarded interruption blocked later input")
            try lifecycle.append(location: CGPoint(x: 36, y: 32), time: started.addingTimeInterval(0.1))
            try require(vm.commitElement(lifecycle.element, frameID: lifecycle.frameID), "Owned completed stroke could not commit")
            vm.finishStrokeInput(id: lifecycle.id)
            try require(vm.activeStrokeID == nil && vm.canUndo, "Completed input did not release lifecycle ownership/history")
            print("PASS actual VM input ownership guards second-input/save/close and preserves interrupted drafts")

            var distinct = Set<Data>()
            let exportService = StudioExportService()
            for family in StudioBrushFamily.allCases {
                var doc = try StudioDocument.new(name: "Brush \(family.rawValue)", width: 64, height: 64, fps: 12)
                let element = stroke(doc.activeLayerID, family: family)
                doc.schemaVersion = 2; doc.frames[0].elements = [element]
                let expected = try render(doc.frames[0], layers: doc.layers)
                distinct.insert(Data(expected))
                let output = try await exportService.export(document: doc, format: .pngSequence, outputParent: root)
                guard let source = CGImageSourceCreateWithURL(output.imageURLs[0] as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "Actual exported PNG could not reopen") }
                try require(image.width == 64 && image.height == 64 && pixels(image) == expected,
                            "PNG output differs from shared live renderer for \(family.rawValue)")
                let small = try render(doc.frames[0], layers: doc.layers, edge: 16)
                try require(small.contains { $0 < 240 }, "Thumbnail lost actual brush ink")
            }
            try require(distinct.count == StudioBrushFamily.allCases.count, "Exposed brush families do not produce distinct shared-renderer pixels")
            print("PASS all ten families share distinct actual native/thumbnail/export pixels; real PNGs reopen")

            var collision = stroke("cache", id: "same-id")
            let first = try StudioBrushGeometryCache.geometry(for: collision)
            collision.width = 20
            let second = try StudioBrushGeometryCache.geometry(for: collision)
            try require(first != second, "Cache reused an ID without comparing complete source")
            let frame = AnimationFrame(id: "prepared", elements: [collision])
            let prepared = try StudioFrameRenderer.prepare(frame: frame)
            var changed = frame; changed.elements[0].width = 25
            var mismatch: Error?
            let check = ImageRenderer(content: Canvas { context, size in
                mismatch = StudioFrameRenderer.draw(context: &context, frame: changed,
                    layers: [CanvasLayer(id: "cache", name: "Cache")], canvasSize: size, size: size, preparedBrushes: prepared)
            }.frame(width: 64, height: 64))
            _ = check.cgImage
            try require(mismatch != nil, "Stale prepared geometry was silently accepted")
            print("PASS cache exact source equality and explicit stale preparation failure")

            var large = try StudioDocument.new(name: "Budget", width: 64, height: 64, fps: 12)
            large.schemaVersion = 2
            var dense = stroke(large.activeLayerID, width: 2)
            dense.points = [StrokePoint(x: 0, y: 32), StrokePoint(x: 1800, y: 32)]
            let markCount = try StudioBrushGeometryCache.geometry(for: dense).marks.count
            let needed = StudioBrushGeometryCache.maximumFrameMarks / markCount + 1
            large.frames[0].elements = (0..<needed).map { n in
                var item = dense
                item = DrawnElement(id: "budget-\(n)", tool: item.tool, points: item.points, color: item.color,
                    width: item.width, opacity: item.opacity, layerID: item.layerID, brush: item.brush)
                return item
            }
            try rejects { try large.validate() }
            large.layers[0].visible = false; try rejects { try large.validate() }
            var aggregate = large
            aggregate.layers[0].visible = true
            aggregate.frames = (0..<(StudioBrushGeometryCache.maximumDocumentMarks / markCount + 1)).map { n in
                AnimationFrame(id: "aggregate-frame-\(n)", elements: [DrawnElement(id: "aggregate-stroke-\(n)",
                    tool: dense.tool, points: dense.points, color: dense.color, width: dense.width,
                    opacity: dense.opacity, layerID: dense.layerID, brush: dense.brush)])
            }
            aggregate.activeFrameID = aggregate.frames[0].id
            try rejects { try aggregate.validate() }
            aggregate.frames = [AnimationFrame(id: "element-limit", elements: (0...StudioBrushGeometryCache.maximumDocumentElements).map { n in
                DrawnElement(id: "element-limit-\(n)", tool: .brush, points: [StrokePoint(x: 16, y: 16)],
                    color: "#FF0000", width: 2, opacity: 1, layerID: aggregate.activeLayerID, brush: dense.brush)
            })]
            aggregate.activeFrameID = "element-limit"
            try rejects { try aggregate.validate() }
            var manyPoints = dense
            manyPoints.points = (0..<8_192).map { _ in StrokePoint(x: 16, y: 16) }
            aggregate.frames = (0..<13).map { n in
                AnimationFrame(id: "sample-frame-\(n)", elements: [DrawnElement(id: "sample-stroke-\(n)",
                    tool: manyPoints.tool, points: manyPoints.points, color: manyPoints.color, width: manyPoints.width,
                    opacity: manyPoints.opacity, layerID: manyPoints.layerID, brush: manyPoints.brush)])
            }
            aggregate.activeFrameID = aggregate.frames[0].id
            try rejects { try aggregate.validate() }
            var badColor = dense; badColor.color = "+12345"; try rejects { _ = try StudioBrushGeometryCache.geometry(for: badColor) }
            print("PASS frame/document mark and sample budgets cannot be bypassed by hidden layers or malformed RGB")

            for index in 0..<(StudioBrushGeometryCache.maximumCacheEntries + 80) {
                _ = try StudioBrushGeometryCache.geometry(for: stroke("cache", id: "eviction-\(index)"))
            }
            for index in 0..<80 {
                let item = DrawnElement(id: "byte-eviction-\(index)", tool: dense.tool, points: dense.points,
                    color: dense.color, width: dense.width, opacity: dense.opacity, layerID: dense.layerID, brush: dense.brush)
                _ = try StudioBrushGeometryCache.geometry(for: item)
            }
            let footprint = StudioBrushGeometryCache.footprint
            try require(footprint.entries <= StudioBrushGeometryCache.maximumCacheEntries && footprint.bytes <= StudioBrushGeometryCache.maximumCacheBytes,
                        "Cache exceeded combined key/sample/mark memory or entry bound")
            print("PASS bounded LRU cache includes retained source samples and geometry")

            var near = try StudioDocument.new(name: "Near-limit", width: 64, height: 64, fps: 12)
            near.schemaVersion = 2
            let perFrame = StudioBrushGeometryCache.maximumFrameMarks / markCount
            near.frames = (0..<2).map { frameIndex in
                AnimationFrame(id: "near-frame-\(frameIndex)", elements: (0..<perFrame).map { index in
                    DrawnElement(id: "near-\(frameIndex)-\(index)", tool: dense.tool, points: dense.points,
                        color: dense.color, width: dense.width, opacity: dense.opacity,
                        layerID: near.activeLayerID, brush: dense.brush)
                })
            }
            near.activeFrameID = near.frames[0].id
            let coldStart = Date(); try near.validate()
            let coldSeconds = Date().timeIntervalSince(coldStart)
            var warmed: [Double] = []
            for _ in 0..<3 {
                let start = Date(); try near.validate(); warmed.append(Date().timeIntervalSince(start))
            }
            var boundedEditor = try StudioDocumentEditor(document: near)
            try rejects { try boundedEditor.duplicateFrame() }
            try require(boundedEditor.document == near && !boundedEditor.canUndo, "Capacity failure partially changed history/document")
            try require((warmed.max() ?? 0) < 2, "Near-limit cached document validation stalled for seconds")
            print("BRUSH_NEAR_DOCUMENT_METRICS marks=\(2 * perFrame * markCount) cold=\(coldSeconds)s warm=\(warmed)s cacheBytes=\(StudioBrushGeometryCache.footprint.bytes)")
            print("PASS near-limit full-document validation stays cached and failed duplication remains atomic")

            var rapid = stroke("rapid", id: "rapid-input", family: .grain, width: 4)
            rapid.points = []
            var durations: [Double] = []
            for batch in 0..<60 {
                for index in 0..<100 {
                    let count = batch * 100 + index
                    rapid.points.append(StrokePoint(x: CGFloat(count) / 10, y: 32 + sin(Double(count) / 100) * 8,
                        timestamp: Double(count) / 120))
                }
                let started = Date()
                _ = try StudioBrushGeometryCache.geometry(for: rapid)
                durations.append(Date().timeIntervalSince(started))
            }
            var measured = try StudioDocument.new(name: "Measured", width: 1024, height: 1024, fps: 12)
            measured.schemaVersion = 2
            rapid.layerID = measured.activeLayerID
            measured.frames[0].elements = [rapid]
            try measured.validate()
            let validationStart = Date(); try measured.validate()
            let validationSeconds = Date().timeIntervalSince(validationStart)
            print("BRUSH_INTEGRATION_METRICS rapid60Total=\(durations.reduce(0,+))s rapidWorst=\(durations.max() ?? 0)s cachedDocumentValidation=\(validationSeconds)s cacheBytes=\(footprint.bytes)")
            try require((durations.max() ?? 0) < 2 && validationSeconds < 2, "Bounded preparation unexpectedly stalled for seconds")
            print("PASS actual rapid input preparation and full production document validation benchmark")
            print("STUDIO_BRUSH_INTEGRATION_TESTS=PASS 14 production groups")
        } catch {
            fputs("STUDIO_BRUSH_INTEGRATION_TESTS=FAIL \(error)\n", stderr)
            exit(1)
        }
    }
}
