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
    static func render(_ d: StudioDocument, size: Int = 128, height: Int = 128, sources: [String: Data] = [:]) throws -> [UInt8] {
        let frame = d.frames[0], brushes = try StudioFrameRenderer.prepare(frame: frame)
        let rasters = try StudioFrameRenderer.prepareRasters(frame: frame, layers: d.layers, sourceData: sources)
        var failure: Error?
        let content = Canvas { context, actual in
            failure = StudioFrameRenderer.draw(context: &context, frame: frame, layers: d.layers,
                canvasSize: CGSize(width: d.width, height: d.height), size: actual, preparedBrushes: brushes, rasterSources: sources, preparedRasters: rasters)
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
    static func imageTweenChecks(_ root: URL) async throws {
        // Original asymmetric pixels, decoded by the production importer.
        var rgba = [UInt8](repeating: 0, count: 16 * 12 * 4)
        for y in 0..<12 { for x in 0..<16 {
            let i = (y * 16 + x) * 4
            rgba[i + (x < 8 ? 0 : 2)] = 255; rgba[i + 3] = 255
        } }
        let cg = CGImage(width: 16, height: 12, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(rgba) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg, nil)
        try require(CGImageDestinationFinalize(destination), "Original image fixture encoding")
        let originalBytes = encoded as Data, input = root.appendingPathComponent("tween-source.png")
        try originalBytes.write(to: input, options: .withoutOverwriting)
        for mixed in [false, true] {
            let store = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("image-tween-\(mixed)"))
            let vm = StudioViewModel(storage: store)
            let made = await vm.createProject(name: "Managed image tween", width: 128, height: 128, fps: 12)
            try require(made, "Image tween project creation")
            if mixed {
                try require(vm.commitElement(.init(id: UUID().uuidString, tool: .rectangle,
                    points: [.init(x: 52, y: 48), .init(x: 60, y: 64)], color: "#00FF00", width: 1,
                    opacity: 1, layerID: vm.activeLayerID, shape: .init(fillColor: "#00FF00"))), "Mixed drawing creation")
            }
            let imported = try await StudioImageImportService().importImage(from: input, name: "Original two colors", scratchParent: root)
            let asset = try vm.attachImportedImage(imported, expectedProjectID: vm.document.id,
                expectedRevision: vm.document.revision, frameID: vm.document.activeFrameID, layerID: vm.activeLayerID)
            vm.selectedTool = .move
            guard let initial = vm.prepareImagePlacement() else { throw Failure(message: "Initial image placement") }
            vm.selectLayer(initial.layerID)
            guard let placement = vm.prepareImagePlacement() else { throw Failure(message: "Selected image placement") }
            try require(vm.placeImage(placement, at: .init(x: 16, y: 40, width: 32, height: 24)), "First image pose")
            let first = vm.document.activeFrameID
            vm.duplicateFrame(first)
            let last = vm.document.activeFrameID
            guard let endpoint = vm.prepareImagePlacement() else { throw Failure(message: "Endpoint image placement") }
            try require(vm.placeImage(endpoint, at: .init(x: 64, y: 48, width: 48, height: 32)), "Second image pose")
            let before = vm.document, bytesBefore = vm.rasterSources(for: vm.currentFrame)
            guard let capture = vm.prepareTween(first) else { throw Failure(message: "Image tween capture unavailable") }
            try vm.applyTween(capture, count: 1, easing: .linear)
            let generated = vm.document, middle = generated.frames[1]
            try require(generated.frames.count == 3 && generated.frames[0] == before.frames[0] && generated.frames[2] == before.frames[1], "Image endpoints changed")
            try require(generated.revision == before.revision + 1 && middle.durationTicks == 1 && middle.rasterAssetID == asset &&
                middle.rasterPlacement == .init(x: 40, y: 44, width: 40, height: 28), "Image midpoint geometry/source/timing")
            try require(vm.rasterSources(for: middle) == bytesBefore && vm.originalImageSource(asset)?.originalData == originalBytes,
                "Tween duplicated or rewrote managed original image bytes")
            var expected = before; expected.frames = [before.frames[0]]; expected.activeFrameID = first
            expected.frames[0].rasterPlacement = .init(x: 40, y: 44, width: 40, height: 28)
            var probe = generated; probe.frames = [middle]; probe.activeFrameID = middle.id
            let actual = try render(probe, sources: bytesBefore)
            try require(actual == render(expected, sources: bytesBefore), "Tween pixels differ from independently authored midpoint")
            try require(actual != render(before, sources: bytesBefore), "Moving/scaling image produced unchanged pixels")
            let redXs = stride(from: 0, to: actual.count, by: 4).filter { actual[$0] > 240 && actual[$0 + 1] < 10 && actual[$0 + 2] < 10 && actual[$0 + 3] > 240 }.map { ($0 / 4) % 128 }
            try require((redXs.min() ?? -1) >= 39 && (redXs.max() ?? 999) <= 60 && redXs.count > 300, "Actual red source coverage did not move to midpoint")
            if mixed {
                try require(middle.elements.count == 1 && middle.elements[0].id != before.frames[0].elements[0].id &&
                    stride(from: 0, to: actual.count, by: 4).contains { actual[$0 + 1] > 240 && actual[$0] < 10 && actual[$0 + 2] < 10 }, "Mixed drawing lost fresh identity or visible foreground pixels")
            }
            vm.undo(); try require(vm.document.frames == before.frames && vm.document.activeFrameID == last, "One image tween Undo")
            vm.redo(); try require(vm.document.frames == generated.frames, "Image tween Redo identities")
            let saved = await vm.save(); try require(saved, "Image tween durable save")
            let cold = StudioViewModel(storage: store); await cold.loadProjects()
            guard let record = cold.savedProjects.first(where: { $0.id == vm.document.id }) else { throw Failure(message: "Image tween saved record") }
            let opened = await cold.openProject(record)
            try require(opened && cold.document == vm.document && cold.originalImageSource(asset)?.originalData == originalBytes &&
                cold.rasterSources(for: cold.frames[1]) == bytesBefore, "Cold image tween source/geometry changed")
            let output = try await StudioExportService().export(document: cold.document, format: .pngSequence,
                outputParent: root, background: .transparent, rasterData: { cold.rasterData($0) })
            try require(output.imageURLs.count == 3, "Image tween PNG count")
            for (i, url) in output.imageURLs.enumerated() {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "Image tween exported PNG") }
                var frame = cold.document; frame.frames = [cold.frames[i]]; frame.activeFrameID = cold.frames[i].id
                try require(pixels(image) == render(frame, sources: bytesBefore), "Exported image tween pixels disagree with cold canonical renderer")
            }
            if !mixed {
                let movie = try await StudioMovieExportService().export(snapshot: .init(document: cold.document,
                    retainedAudioTracks: [], rasterDataByID: bytesBefore), outputParent: root, background: .white)
                let urls = try movie.checkedURLs(), asset = AVURLAsset(url: urls[0])
                let duration = try await asset.load(.duration)
                try require(abs(duration.seconds - cold.document.durationSeconds) < 0.002, "Image MP4 exposure duration")
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                var decodedTime = CMTime.zero
                let image = try generator.copyCGImage(at: CMTime(value: 1, timescale: 12), actualTime: &decodedTime)
                try require(image.width == 128 && image.height == 128 && abs(decodedTime.seconds - 1.0 / 12) < 0.002,
                    "Image MP4 middle frame time/geometry")
                let moviePixels = try pixels(image)
                // `actual` already equals the independently authored middle pose;
                // composite its transparent pixels onto the movie's white backing.
                var reference = actual, totalError = 0, largeErrors = 0
                for i in stride(from: 0, to: reference.count, by: 4) {
                    for c in 0..<3 { reference[i + c] = UInt8(min(255, Int(reference[i + c]) + 255 - Int(reference[i + 3]))) }
                    reference[i + 3] = 255
                    let differences = (0..<3).map { abs(Int(moviePixels[i + $0]) - Int(reference[i + $0])) }
                    totalError += differences.reduce(0, +)
                    if differences.max()! > 48 { largeErrors += 1 }
                }
                try require(Double(totalError) / Double(128 * 128 * 3) < 8 && Double(largeErrors) / Double(128 * 128) < 0.03,
                    "Image tween MP4 lost the midpoint raster content")
                let red = (64 * 128 + 45) * 4, blue = (64 * 128 + 75) * 4, outside = (64 * 128 + 20) * 4
                try require(moviePixels[red] > 200 && moviePixels[red + 2] < 35 && moviePixels[blue + 2] > 200 && moviePixels[blue] < 35 &&
                    (0..<3).allSatisfy { moviePixels[outside + $0] > 230 }, "MP4 midpoint colored interiors or moved-away background wrong")
                print("PASS image-only MP4 source map, decoded middle tick, lossy pixels, bounds and timeline duration")
            }
            if !mixed {
                try imageTweenRejectionChecks(before, sources: bytesBefore)
                try imageQuarterTweenChecks(before, sources: bytesBefore)
            }
        }
        print("PASS image-only and mixed actual VM tween, midpoint pixels, source bytes, one Undo/Redo, cold reopen and PNG exports")
    }

    static func imageQuarterTweenChecks(_ original: StudioDocument, sources: [String: Data]) throws {
        // Independent expected angles, with a non-square source scale held constant.
        let cases: [(Int, Int, Double, Double, Double)] = [
            (0, 1, 0, 0, 45), (0, 3, 0, 0, -45), (0, 2, 0, 0, 90),
            (3, 0, 0, 0, 45), (0, 1, 20, 40, 75)
        ]
        for (fromTurn, toTurn, fromAngle, toAngle, midpointAngle) in cases {
            for reflected in [false, true] {
                var poses = original
                let legacy = !reflected && fromAngle == 0 && toAngle == 0
                poses.schemaVersion = legacy ? 16 : (fromAngle == 0 && toAngle == 0 ? 22 : 30)
                for i in 0..<2 {
                    let turn = i == 0 ? fromTurn : toTurn
                    let width: Double = turn % 2 == 0 ? 32 : 16
                    let height: Double = turn % 2 == 0 ? 16 : 32
                    poses.frames[i].rasterPlacement = .init(x: 64 - width / 2, y: 64 - height / 2, width: width, height: height)
                    poses.frames[i].rasterQuarterTurns = turn == 0 ? nil : turn
                    let angle = i == 0 ? fromAngle : toAngle
                    poses.frames[i].rasterRotationDegrees = angle == 0 ? nil : angle
                    poses.frames[i].rasterReflection = reflected ? .init(horizontal: turn % 2 == 0, vertical: turn % 2 != 0) : nil
                    poses.frames[i].rasterCrop = reflected ? .init(x: 0.25, y: 0, width: 0.5, height: 1) : nil
                    poses.frames[i].holdTicks = legacy ? nil : (i == 0 ? 3 : 4)
                }
                var editor = try StudioDocumentEditor(document: poses)
                _ = try editor.tweenFrames(after: poses.frames[0].id, to: poses.frames[1].id, inbetweenCount: 1, easing: .linear)
                let middle = editor.document.frames[1]
                try require(editor.document.schemaVersion >= 30, "Quarter-turn tween did not promote new additional angle schema")
                try require(middle.rasterPlacement == poses.frames[0].rasterPlacement &&
                    middle.rasterQuarterTurns == poses.frames[0].rasterQuarterTurns &&
                    middle.rasterReflection == poses.frames[0].rasterReflection &&
                    abs((middle.rasterRotationDegrees ?? 0) - midpointAngle) < 0.000001,
                    "Quarter-turn midpoint changed non-square scale, center, carried reflection or shortest angle")
                try require(editor.document.frames[0] == poses.frames[0] && editor.document.frames[2] == poses.frames[1] &&
                    editor.document.totalTimelineTicks == (legacy ? 3 : 8) && middle.rasterAssetID == poses.frames[0].rasterAssetID &&
                    middle.rasterCrop == poses.frames[0].rasterCrop && middle.rasterRegionMask == poses.frames[0].rasterRegionMask,
                    "Quarter-turn tween changed original endpoint, hold or source metadata")
                var expected = poses; expected.schemaVersion = 30; expected.frames = [poses.frames[0]]; expected.activeFrameID = expected.frames[0].id
                expected.frames[0].rasterRotationDegrees = midpointAngle
                var actual = editor.document; actual.frames = [middle]; actual.activeFrameID = middle.id
                let actualPixels = try render(actual, sources: sources)
                try require(actualPixels == render(expected, sources: sources), "Quarter-turn midpoint differs from independently authored angle pixels")
                var endpoint = poses; endpoint.frames = [poses.frames[1]]; endpoint.activeFrameID = endpoint.frames[0].id
                var normalizedEndpoint = expected
                var endpointAngle = (toAngle + Double(toTurn - fromTurn) * 90).truncatingRemainder(dividingBy: 360)
                if endpointAngle > 180 { endpointAngle -= 360 }; if endpointAngle < -180 { endpointAngle += 360 }
                normalizedEndpoint.frames[0].rasterRotationDegrees = endpointAngle == 0 ? nil : endpointAngle
                let endpointPixels = try render(endpoint, sources: sources)
                let normalizedPixels = try render(normalizedEndpoint, sources: sources)
                let changed = zip(endpointPixels, normalizedPixels).enumerated().filter { $0.element.0 != $0.element.1 }
                let maximum = changed.map { abs(Int($0.element.0) - Int($0.element.1)) }.max() ?? 0
                print("QUARTER_ENDPOINT from=\(fromTurn) to=\(toTurn) a=\(fromAngle) b=\(toAngle) reflected=\(reflected) crop=\(String(describing: endpoint.frames[0].rasterCrop)) changed=\(changed.count) max=\(maximum)")
                if !changed.isEmpty {
                    print("QUARTER_FIRST_CHANNELS \(changed.prefix(24).map { [ $0.offset, Int($0.element.0), Int($0.element.1) ] })")
                    let originalPrepared = try StudioFrameRenderer.prepareRasters(frame: endpoint.frames[0], layers: endpoint.layers, sourceData: sources)
                    let normalizedPrepared = try StudioFrameRenderer.prepareRasters(frame: normalizedEndpoint.frames[0], layers: normalizedEndpoint.layers, sourceData: sources)
                    let source = endpoint.frames[0].rasterAssetID!
                    if let a = originalPrepared[source], let b = normalizedPrepared[source] {
                        let sameDecoded = try pixels(a.image) == pixels(b.image)
                        print("QUARTER_DECODE original=\(a.image.width)x\(a.image.height) normalized=\(b.image.width)x\(b.image.height) sameDecoded=\(sameDecoded)")
                    }
                    print("QUARTER_GEOMETRY original=\(endpoint.frames[0].rasterLayerInstances) normalized=\(normalizedEndpoint.frames[0].rasterLayerInstances)")
                }
                try require(endpointPixels == normalizedPixels,
                    "Source-basis normalization changed endpoint pixels")
                // Compare against an unrotated pose too: the pixel oracle must detect motion.
                expected.frames[0].rasterRotationDegrees = fromAngle
                try require(actualPixels != render(expected, sources: sources), "Quarter-turn fixture did not visibly rotate")
                let generated = editor.document.frames
                editor.undo(); try require(editor.document.frames == poses.frames, "Quarter-turn Undo lost endpoint geometry")
                editor.redo(); try require(editor.document.frames == generated, "Quarter-turn Redo changed frames")
                var checkpoints = 0, measured = try StudioDocumentEditor(document: poses)
                _ = try measured.tweenFrames(after: poses.frames[0].id, to: poses.frames[1].id, inbetweenCount: 1, easing: .linear,
                    checkCancellation: { checkpoints += 1 })
                for stop in 1...checkpoints {
                    var cancelled = try StudioDocumentEditor(document: poses), seen = 0
                    do {
                        _ = try cancelled.tweenFrames(after: poses.frames[0].id, to: poses.frames[1].id, inbetweenCount: 1, easing: .linear,
                            checkCancellation: { seen += 1; if seen == stop { throw CancellationError() } })
                        throw Failure(message: "Quarter-turn cancellation accepted")
                    } catch is CancellationError { }
                    try require(cancelled.document == poses && !cancelled.canUndo, "Quarter-turn cancellation partially committed")
                }
            }
        }
        try compactMaskQuarterTweenChecks(original, sources: sources)
        print("PASS quarter-turn 90/270/180, shortest arc, additional angle, non-square carried reflection, real pixels and atomic history/cancellation")
    }

    static func compactMaskQuarterTweenChecks(_ original: StudioDocument, sources: [String: Data]) throws {
        var poses = original; poses.schemaVersion = 32
        var full = poses.frames[0].rasterLayerInstances[0]
        full.placement = .init(x: 32, y: 52, width: 64, height: 24)
        full.crop = nil; full.quarterTurns = nil; full.rotationDegrees = nil; full.reflection = nil
        guard let sampling = StudioImageRegionMask.Geometry(full) else { throw Failure(message: "Full mask geometry") }
        let compact = try sampling.reframed(crop: .init(x: 0, y: 0, width: 0.5, height: 1))
        let mask = StudioImageRegionMask(width: 16, height: 12,
            spans: (0..<12).map { .init(row: $0, start: 0, end: 8) },
            samplingGeometry: sampling, placementGeometry: compact)
        var instance = compact.applying(to: full); instance.regionMask = mask
        try require(sampling != compact, "Compact mask fixture never lifts sampling geometry")
        for i in 0..<2 { try poses.frames[i].updateRasterInstance(instance) }
        let source = poses.frames[0].rasterAssetID!
        var endpoints = try StudioDocumentEditor(document: poses)
        try endpoints.rotateImage(frameID: poses.frames[1].id, assetID: source, direction: .clockwise, layerID: instance.layerID)
        let before = endpoints.document
        var editor = try StudioDocumentEditor(document: before)
        _ = try editor.tweenFrames(after: before.frames[0].id, to: before.frames[1].id, inbetweenCount: 1, easing: .linear)
        let middle = editor.document.frames[1]
        var expected = before; expected.frames = [before.frames[0]]; expected.activeFrameID = expected.frames[0].id
        expected.frames[0].rasterRotationDegrees = 45
        var actual = editor.document; actual.frames = [middle]; actual.activeFrameID = middle.id
        let rendered = try render(actual, sources: sources)
        try require(rendered == render(expected, sources: sources), "Compact masked midpoint differs from authored 45-degree pose")
        let red = stride(from: 0, to: rendered.count, by: 4).filter { rendered[$0] > 200 && rendered[$0 + 2] < 10 && rendered[$0 + 3] > 200 }.count
        let blue = stride(from: 0, to: rendered.count, by: 4).filter { rendered[$0 + 2] > 200 && rendered[$0 + 3] > 200 }.count
        try require(red > 100 && blue == 0, "Masked quarter tween restored excluded blue source or lost red coverage")
        var endpoint = before; endpoint.frames = [before.frames[1]]; endpoint.activeFrameID = endpoint.frames[0].id
        expected.frames[0].rasterRotationDegrees = 90
        try require(render(endpoint, sources: sources) == render(expected, sources: sources), "Masked endpoint normalization changes lifted pixels")
        try require(middle.rasterRegionMask == mask && middle.rasterCrop == instance.crop && middle.rasterAssetID == source &&
            editor.document.frames[0] == before.frames[0] && editor.document.frames[2] == before.frames[1], "Masked quarter tween changed reference/source/endpoints")
        let generated = editor.document.frames
        editor.undo(); try require(editor.document.frames == before.frames, "Masked quarter tween Undo")
        editor.redo(); try require(editor.document.frames == generated, "Masked quarter tween Redo")
    }

    static func imageTweenRejectionChecks(_ original: StudioDocument, sources: [String: Data]) throws {
        var poses = original; poses.schemaVersion = max(33, poses.schemaVersion)
        poses.frames[0].holdTicks = 3; poses.frames[1].holdTicks = 4
        for i in poses.frames.indices {
            poses.frames[i].rasterPlacement = .init(x: 40, y: 40, width: 32, height: 24)
            poses.frames[i].rasterRotationDegrees = i == 0 ? 170 : -170
        }
        var editor = try StudioDocumentEditor(document: poses)
        _ = try editor.tweenFrames(after: poses.frames[0].id, to: poses.frames[1].id, inbetweenCount: 1, easing: .linear)
        let middle = editor.document.frames[1]
        try require(abs(abs(middle.rasterRotationDegrees ?? 0) - 180) < 0.000001 &&
            editor.document.frames[0] == poses.frames[0] && editor.document.frames[2] == poses.frames[1] &&
            editor.document.totalTimelineTicks == 8, "Shortest image angle crossed zero or endpoint holds changed")
        var expected = poses; expected.frames = [poses.frames[0]]; expected.activeFrameID = expected.frames[0].id
        expected.frames[0].rasterRotationDegrees = 180
        var actual = editor.document; actual.frames = [middle]; actual.activeFrameID = middle.id
        try require(render(actual, sources: sources) == render(expected, sources: sources), "Shortest-arc image pixels")
        for mode in 0..<9 {
            var invalid = poses
            let layer = invalid.layers.firstIndex { $0.id == invalid.frames[0].rasterLayerID }!
            switch mode {
            case 0: invalid.layers[layer].locked = true
            case 1: invalid.layers[layer].lockMode = "position"
            case 2: invalid.layers[layer].visible = false
            case 3: invalid.layers[layer].opacity = 0
            case 4: invalid.frames[1].rasterAssetID = "image-" + UUID().uuidString
            case 5: invalid.frames[1].rasterReflection = .init(horizontal: true)
            case 6: invalid.frames[1].rasterCrop = .init(x: 0, y: 0, width: 0.5, height: 1)
            case 7:
                invalid.frames[0].rasterReflection = .init(horizontal: true)
                invalid.frames[1].rasterReflection = .init(horizontal: true)
                invalid.frames[1].rasterQuarterTurns = 1 // A carried flip must swap axes.
            default:
                guard let geometry = StudioImageRegionMask.Geometry(invalid.frames[1].rasterLayerInstances[0]) else {
                    throw Failure(message: "Mismatch mask source geometry")
                }
                invalid.frames[1].rasterRegionMask = .init(width: 16, height: 12,
                    spans: [.init(row: 0, start: 0, end: 8)], samplingGeometry: geometry, placementGeometry: geometry)
            }
            var rejected = try StudioDocumentEditor(document: invalid)
            try rejects { _ = try rejected.tweenFrames(after: invalid.frames[0].id, to: invalid.frames[1].id, inbetweenCount: 1, easing: .linear) }
            try require(rejected.document == invalid && !rejected.canUndo, "Rejected image tween changed document/history")
        }
        // Matching independent and linked instances keep their own source/layer,
        // including an image between same-layer persisted drawings.
        var multi = original; multi.schemaVersion = 33
        let primary = multi.frames[0].rasterLayerID!
        let linked = CanvasLayer(id: UUID().uuidString, name: "Linked twin")
        let independent = CanvasLayer(id: UUID().uuidString, name: "Independent original")
        multi.layers.append(contentsOf: [linked, independent])
        let extraID = "image-" + UUID().uuidString
        var extraBytes = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for i in stride(from: 0, to: extraBytes.count, by: 4) { extraBytes[i + 1] = 255; extraBytes[i + 3] = 255 }
        let extraCG = CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(extraBytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let extraPNG = NSMutableData(), writer = CGImageDestinationCreateWithData(extraPNG, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, extraCG, nil); try require(CGImageDestinationFinalize(writer), "Independent original fixture")
        var allSources = sources; allSources[extraID] = extraPNG as Data
        for i in multi.frames.indices {
            multi.frames[i].elements = [.init(id: UUID().uuidString, tool: .rectangle,
                points: [.init(x: 12, y: 30), .init(x: 115, y: 90)], color: "#FFFF00", width: 1,
                opacity: 1, layerID: primary, shape: .init(fillColor: "#FFFF00"))]
            multi.frames[i].rasterStackPosition = 1
            try multi.frames[i].appendRasterInstance(.init(layerID: linked.id,
                placement: .init(x: i == 0 ? 8 : 24, y: 8, width: 16, height: 12)), assetID: original.frames[0].rasterAssetID!)
            try multi.frames[i].appendRasterInstance(.init(layerID: independent.id,
                placement: .init(x: i == 0 ? 80 : 96, y: 100, width: 16, height: 16)), assetID: extraID)
        }
        var multiple = try StudioDocumentEditor(document: multi)
        _ = try multiple.tweenFrames(after: multi.frames[0].id, to: multi.frames[1].id, inbetweenCount: 1, easing: .linear)
        let combined = multiple.document.frames[1]
        try require(combined.rasterStackPosition == 1 && combined.rasterAssetID(on: linked.id) == original.frames[0].rasterAssetID &&
            combined.rasterAssetID(on: independent.id) == extraID && combined.rasterLayerInstances.count == 3, "Image tween flattened source identities or stack")
        var authored = multi; authored.frames = [multi.frames[0]]; authored.activeFrameID = authored.frames[0].id
        authored.frames[0].rasterPlacement = .init(x: 40, y: 44, width: 40, height: 28)
        var linkedPose = authored.frames[0].rasterInstance(on: linked.id)!
        linkedPose.placement = .init(x: 16, y: 8, width: 16, height: 12); try authored.frames[0].updateRasterInstance(linkedPose)
        var extraPose = authored.frames[0].rasterInstance(on: independent.id)!
        extraPose.placement = .init(x: 88, y: 100, width: 16, height: 16); try authored.frames[0].updateRasterInstance(extraPose)
        var composite = multiple.document; composite.frames = [combined]; composite.activeFrameID = combined.id
        try require(render(composite, sources: allSources) == render(authored, sources: allSources), "Independent/linked midpoint or stack pixels wrong")
        var wrongStack = multi; wrongStack.frames[1].rasterStackPosition = nil
        var rejectedStack = try StudioDocumentEditor(document: wrongStack)
        try rejects { _ = try rejectedStack.tweenFrames(after: wrongStack.frames[0].id, to: wrongStack.frames[1].id, inbetweenCount: 1, easing: .linear) }
        try require(rejectedStack.document == wrongStack && !rejectedStack.canUndo, "Mismatched image stack partially committed")
        print("PASS independent and linked image sources, real midpoint composite and preserved same-layer stack")

        var masked = original; masked.schemaVersion = max(32, masked.schemaVersion)
        guard let referenceGeometry = StudioImageRegionMask.Geometry(masked.frames[0].rasterLayerInstances[0]) else {
            throw Failure(message: "Matched mask source geometry")
        }
        // Both endpoints retain the original mask reference geometry. Their
        // current placement changes, and production sampledInstance lifts it.
        let half = StudioImageRegionMask(width: 16, height: 12,
            spans: (0..<12).map { .init(row: $0, start: 0, end: 8) },
            samplingGeometry: referenceGeometry, placementGeometry: referenceGeometry)
        for i in masked.frames.indices { masked.frames[i].rasterRegionMask = half }
        try masked.validate()
        var maskEditor = try StudioDocumentEditor(document: masked)
        _ = try maskEditor.tweenFrames(after: masked.frames[0].id, to: masked.frames[1].id, inbetweenCount: 1, easing: .linear)
        let maskedMiddle = maskEditor.document.frames[1]
        try require(half.sampledInstance(maskedMiddle.rasterLayerInstances[0]).placement == maskedMiddle.rasterPlacement,
            "Transformed matched mask sampled the original endpoint placement")
        try require(maskedMiddle.rasterRegionMask == half && maskedMiddle.rasterAssetID == masked.frames[0].rasterAssetID,
            "Matched image region mask/source changed")
        var maskExpected = masked; maskExpected.frames = [masked.frames[0]]; maskExpected.activeFrameID = maskExpected.frames[0].id
        maskExpected.frames[0].rasterPlacement = .init(x: 40, y: 44, width: 40, height: 28)
        var maskActual = maskEditor.document; maskActual.frames = [maskedMiddle]; maskActual.activeFrameID = maskedMiddle.id
        let clipped = try render(maskActual, sources: sources)
        try require(clipped == render(maskExpected, sources: sources) && clipped[(64 * 128 + 45) * 4 + 3] > 240 &&
            clipped[(64 * 128 + 75) * 4 + 3] == 0, "Matched region tween restored excluded source pixels")
        // Valid compressed masks can fit before tween yet exceed the aggregate
        // span limit if copied into a new frame. No renderer allocation required.
        var spans: [StudioImageRegionMask.Span] = []
        for row in 0..<256 { for column in 0..<352 { spans.append(.init(row: row, start: column * 2, end: column * 2 + 1)) } }
        let largeMask = StudioImageRegionMask(width: 1024, height: 256, spans: spans,
            samplingGeometry: referenceGeometry, placementGeometry: referenceGeometry)
        var overBudget = original; overBudget.schemaVersion = max(32, overBudget.schemaVersion)
        for i in overBudget.frames.indices { overBudget.frames[i].rasterRegionMask = largeMask }
        try overBudget.validate()
        var budgetEditor = try StudioDocumentEditor(document: overBudget)
        try rejects { _ = try budgetEditor.tweenFrames(after: overBudget.frames[0].id, to: overBudget.frames[1].id, inbetweenCount: 1, easing: .linear) }
        try require(budgetEditor.document == overBudget && !budgetEditor.canUndo, "Mask-budget rejection committed partial image frames")
        print("PASS matched image masks preserve actual coverage; aggregate span overflow rejects atomically")

        var checkpoints = 0, measured = try StudioDocumentEditor(document: poses)
        _ = try measured.tweenFrames(after: poses.frames[0].id, to: poses.frames[1].id, inbetweenCount: 2, easing: .linear,
            checkCancellation: { checkpoints += 1 })
        for stop in 1...checkpoints {
            var cancelled = try StudioDocumentEditor(document: poses), seen = 0
            do {
                _ = try cancelled.tweenFrames(after: poses.frames[0].id, to: poses.frames[1].id, inbetweenCount: 2, easing: .linear,
                    checkCancellation: { seen += 1; if seen == stop { throw CancellationError() } })
                throw Failure(message: "Image tween cancellation accepted")
            } catch is CancellationError { }
            try require(cancelled.document == poses && !cancelled.canUndo, "Cancelled image tween published partial frames")
        }
        print("PASS shortest image rotation/holds, source/crop/reflection/turn/lock mismatches and every cancellation checkpoint")
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
        try await imageTweenChecks(root)
        print("STUDIO_TWEEN_TESTS=PASS")
    }
    static func main() async { do { try await run() } catch { print("STUDIO_TWEEN_TESTS=FAIL \(error)"); exit(1) } }
}
