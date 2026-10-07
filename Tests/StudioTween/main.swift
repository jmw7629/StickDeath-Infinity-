import AppKit
import SwiftUI
import ImageIO
import AVFoundation

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }
@main @MainActor struct StudioTweenTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message: message) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch is StudioDocumentError { return }
        throw Failure(message: "Unsupported operation accepted")
    }
    static func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = bytes.withUnsafeMutableBytes { data -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: data.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        try require(success, "Actual image pixel decode")
        return bytes
    }
    static func render(_ d: StudioDocument, size: Int = 128, height: Int = 128) throws -> [UInt8] {
        let frame = d.frames[0], brushes = try StudioFrameRenderer.prepare(frame: frame)
        var failure: Error?
        let content = Canvas { context, actual in
            failure = StudioFrameRenderer.draw(context: &context, frame: frame, layers: d.layers,
                canvasSize: CGSize(width: d.width, height: d.height), size: actual, preparedBrushes: brushes)
        }.frame(width: CGFloat(size), height: CGFloat(height))
        let renderer = ImageRenderer(content: content); renderer.scale = 1
        guard let image = renderer.cgImage else { throw Failure(message: "Actual canonical shape renderer") }
        if let failure { throw failure }
        return try pixels(image)
    }
    static func fixture() throws -> StudioDocument {
        var d = try StudioDocument.new(name: "Authored poses", width: 128, height: 128, fps: 12)
        d.schemaVersion = 21
        let a = DrawnElement(id: UUID().uuidString, tool: .rectangle,
            points: [.init(x: 12, y: 30), .init(x: 32, y: 50)], color: "#FF0000", width: 2,
            opacity: 0.8, layerID: d.activeLayerID, shape: .init(fillColor: "#FF0000"))
        let b = DrawnElement(id: UUID().uuidString, tool: a.tool, points: a.points, color: a.color,
            width: a.width, opacity: a.opacity, layerID: a.layerID, shape: a.shape,
            translation: .init(x: 64, y: 0))
        d.frames[0].elements = [a]; d.frames[0].holdTicks = 3
        d.frames.append(.init(id: UUID().uuidString, elements: [b], holdTicks: 4))
        return d
    }
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-tween-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = try fixture()
        for easing in StudioTweenEasing.allCases {
            var editor = try StudioDocumentEditor(document: original)
            let ids = try editor.tweenFrames(after: original.frames[0].id, to: original.frames[1].id, inbetweenCount: 3, easing: easing)
            try require(ids.count == 3 && Set(ids).count == 3 && editor.document.frames.first == original.frames.first &&
                editor.document.frames.last == original.frames.last, "Endpoint identities/artwork/holds changed")
            try require(editor.document.totalTimelineTicks == original.totalTimelineTicks + 3 &&
                editor.document.audioClips == original.audioClips && editor.document.revision == original.revision + 1,
                "Timing, audio or one-transaction contract failed")
            for (i, frame) in editor.document.frames.dropFirst().dropLast().enumerated() {
                let t = easing.progress(Double(i + 1) / 4), e = frame.elements[0]
                let point = e.transform!.point(CGPoint(x: e.points[0].x, y: e.points[0].y))
                try require(abs(point.x - (12 + 64 * t)) < 0.000001 && e.shape == original.frames[0].elements[0].shape &&
                    e.color == "#FF0000" && e.opacity == 0.8 && frame.durationTicks == 1, "Interpolated pose/style/timing wrong")
            }
            let created = editor.document.frames
            editor.undo(); try require(editor.document.frames == original.frames, "One Undo failed")
            editor.redo(); try require(editor.document.frames == created, "Redo changed generated identities")
            var last = -1.0
            for step in 0...100 {
                let t = easing.progress(Double(step) / 100)
                try require((0...1).contains(t) && t >= last, "Easing overshoots or reverses"); last = t
            }
            try require(easing.progress(0) == 0 && easing.progress(1) == 1, "Easing endpoints are not exact")
        }
        print("PASS authored endpoints, easing, holds, style, fresh IDs and atomic Undo/Redo")
        var rotation = original
        rotation.frames[1].elements[0].translation = nil
        rotation.frames[1].elements[0].transform = try .scaleRotation(x: 2, y: 0.5, degrees: 180, center: .zero)
        var rotated = try StudioDocumentEditor(document: rotation)
        _ = try rotated.tweenFrames(after: rotation.frames[0].id, to: rotation.frames[1].id, inbetweenCount: 1, easing: .linear)
        let matrix = rotated.document.frames[1].elements[0].transform!
        try matrix.validate()
        try require(abs(matrix.a) < 0.000001 && abs(abs(matrix.b) - 1.5) < 0.000001 &&
            abs(abs(matrix.c) - 0.75) < 0.000001, "Rotation/scale interpolation collapsed at half-turn")
        print("PASS shortest-arc half-turn rotation and nonsingular scale interpolation")
        for family in [StudioBrushFamily.round, .stipple, .grain, .roughPen] {
            var painted = original
            let brush = StudioBrushDescriptor(family: family, seed: 9471)
            for i in painted.frames.indices {
                painted.frames[i].elements[0].tool = .brush
                painted.frames[i].elements[0].shape = nil
                painted.frames[i].elements[0].brush = brush
                painted.frames[i].elements[0].translation = nil
            }
            var editor = try StudioDocumentEditor(document: painted)
            let originalPixels = try render(painted)
            _ = try editor.tweenFrames(after: painted.frames[0].id, to: painted.frames[1].id, inbetweenCount: 3, easing: .linear)
            for frame in editor.document.frames.dropFirst().dropLast() {
                var probe = editor.document; probe.frames = [frame]; probe.activeFrameID = frame.id
                try require(frame.elements[0].brush == brush && render(probe) == originalPixels,
                    "Identical brush poses jittered or changed effective seed")
            }
        }
        print("PASS identical textured brush endpoints retain source seed and actual rendered pixels")

        for mode in 0..<6 {
            var invalid = original
            switch mode {
            case 0: invalid.layers[0].lockMode = "alpha"
            case 1: invalid.layers[0].visible = false
            case 2: invalid.layers[0].opacity = 0
            case 3: invalid.frames[1].elements[0].color = "#00FF00"
            case 4: invalid.frames[1].elements[0].tool = .circle
            default: invalid.layers[0].lockMode = "position"
            }
            var editor = try StudioDocumentEditor(document: invalid)
            try rejects { _ = try editor.tweenFrames(after: invalid.frames[0].id, to: invalid.frames[1].id,
                inbetweenCount: 3, easing: .linear) }
            try require(editor.document == invalid && !editor.canUndo, "Rejected tween mutated history")
        }
        var cancelled = try StudioDocumentEditor(document: original), checkpoints = 0
        do {
            _ = try cancelled.tweenFrames(after: original.frames[0].id, to: original.frames[1].id,
                inbetweenCount: 24, easing: .linear, checkCancellation: {
                    checkpoints += 1; if checkpoints == 8 { throw CancellationError() }
                })
            throw Failure(message: "Cancelled tween succeeded")
        } catch is CancellationError { }
        try require(cancelled.document == original && !cancelled.canUndo, "Cancelled tween changed document/history")
        print("PASS incompatible styles, locks, hidden/transparent layers and cancellation remain atomic")

        let store = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"))
        let vm = StudioViewModel(storage: store)
        let made = await vm.createProject(name: "Native editable tween", width: 128, height: 128, fps: 12)
        try require(made, "Create failed")
        let first = vm.document.activeFrameID, layer = vm.activeLayerID
        let element = DrawnElement(id: UUID().uuidString, tool: .rectangle,
            points: [.init(x: 12, y: 30), .init(x: 32, y: 50)], color: "#FF0000", width: 2,
            opacity: 1, layerID: layer, shape: .init(fillColor: "#FF0000"))
        try require(vm.commitElement(element), "Actual drawing failed")
        vm.duplicateFrame(first)
        let end = vm.document.activeFrameID
        try require(end != first, "Duplicate did not select endpoint")
        let id = vm.currentFrame.elements[0].id
        _ = try vm.applyStudioCommands(.init(requestID: UUID(), projectID: vm.document.id, expectedRevision: vm.document.revision,
            action: .apply([.translateElements(.init(frame: .id(end), elementIDs: [id], dx: 64, dy: 0))])))
        guard let capture = vm.prepareTween(first) else { throw Failure(message: "Tween capture unavailable") }
        let before = vm.document
        try require(before.activeFrameID == end && vm.document == before, "Preparing explicit endpoints changed selection")
        try vm.applyTween(capture, count: 3, easing: .easeInOut)
        try require(vm.frames.count == 5 && vm.frames[0] == before.frames[0] && vm.frames[4] == before.frames[1], "VM altered endpoints")
        let generated = vm.document.frames
        vm.undo(); try require(vm.frames == before.frames && vm.document.activeFrameID == end, "VM Undo failed to restore pre-menu frame")
        vm.redo(); try require(vm.frames == generated, "VM Redo failed")
        let saved = await vm.save(); try require(saved, "Actual save failed")
        let reopened = StudioViewModel(storage: store); await reopened.loadProjects()
        guard let record = reopened.savedProjects.first(where: { $0.id == vm.document.id }) else { throw Failure(message: "Saved project missing") }
        let opened = await reopened.openProject(record)
        try require(opened && reopened.document == vm.document, "Cold reopen changed tween")
        let png = try await StudioExportService().export(document: reopened.document, format: .pngSequence, outputParent: root, background: .transparent)
        try require(png.imageURLs.count == 5, "PNG sequence frame count wrong")
        for (i, url) in png.imageURLs.enumerated() {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "Exported PNG cannot reopen") }
            var probe = reopened.document; probe.frames = [reopened.frames[i]]; probe.activeFrameID = probe.frames[0].id
            try require(pixels(image) == render(probe), "Reopened PNG differs from real canonical tween frame")
        }
        let movie = try await StudioMovieExportService().export(snapshot: .init(document: reopened.document,
            retainedAudioTracks: [], rasterDataByID: [:]), outputParent: root, background: .white)
        let url = try movie.checkedURLs()[0], asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        try require(abs(duration.seconds - reopened.document.durationSeconds) < 0.002, "MP4 timing disagrees with editable frames")
        print("PASS actual VM edit, save/cold reopen, reopened PNG sequence and MP4 duration")
        reopened.selectFrame(first)
        guard let stale = reopened.prepareTween(first) else { throw Failure(message: "Race capture unavailable") }
        let prior = reopened.document
        var callbacks = 0
        do {
            try reopened.applyTween(stale, count: 2, easing: .linear, checkCancellation: {
                callbacks += 1
                if callbacks == 2 { reopened.copyFrame() }
            })
            throw Failure(message: "Reentrant clipboard accepted")
        } catch is StudioDocumentError { }
        try require(reopened.document == prior && reopened.canPaste, "Rejected tween lost newer clipboard")
        try require(reopened.beginTextEditing(), "Draft fixture failed")
        reopened.textInput = "Retained text"
        try require(reopened.prepareTween(first) == nil && reopened.applyTextEditing(), "Tween stranded text draft")
        print("PASS clipboard callback and draft ownership fences")
        print("STUDIO_TWEEN_TESTS=PASS")
    }
    static func main() async { do { try await run() } catch { print("STUDIO_TWEEN_TESTS=FAIL \(error)"); exit(1) } }
}
