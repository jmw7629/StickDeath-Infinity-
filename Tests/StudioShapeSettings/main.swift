import AppKit
import SwiftUI
import ImageIO
import AVFoundation

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }

@main @MainActor struct ShapeSettingsTests {
    static var passed = 0
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message: message) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw Failure(message: "Invalid operation succeeded")
    }
    static func pass(_ name: String) { passed += 1; print("PASS " + name) }
    static func shape(_ layer: String, tool: DrawingTool = .rectangle,
                      fill: String? = "#FF0000", radius: Double = 0, opacity: Double = 1) -> DrawnElement {
        .init(id: UUID().uuidString, tool: tool,
              points: [.init(x: 16, y: 16), .init(x: 112, y: 112)], color: "#FF0000",
              width: 8, opacity: opacity, layerID: layer,
              shape: .init(fillColor: fill, cornerRadius: radius))
    }
    static func document(_ element: DrawnElement? = nil) throws -> StudioDocument {
        var d = try StudioDocument.new(name: "Real shape settings", width: 128, height: 128, fps: 12)
        if var element { element.layerID = d.activeLayerID; d.frames[0].elements = [element]; d.schemaVersion = 5 }
        return d
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
    static func render(_ d: StudioDocument, size: Int = 128) throws -> [UInt8] {
        let frame = d.frames[0], brushes = try StudioFrameRenderer.prepare(frame: frame)
        var failure: Error?
        let content = Canvas { context, actual in
            failure = StudioFrameRenderer.draw(context: &context, frame: frame, layers: d.layers,
                canvasSize: CGSize(width: d.width, height: d.height), size: actual, preparedBrushes: brushes)
        }.frame(width: CGFloat(size), height: CGFloat(size))
        let renderer = ImageRenderer(content: content); renderer.scale = 1
        guard let image = renderer.cgImage else { throw Failure(message: "Actual canonical shape renderer") }
        if let failure { throw failure }
        return try pixels(image)
    }
    static func channel(_ pixels: [UInt8], _ x: Int, _ y: Int, _ c: Int = 3, width: Int = 128) -> UInt8 {
        pixels[(y * width + x) * 4 + c]
    }
    static func main() async throws {
        setbuf(stdout, nil)
        var legacy = shape("legacy"); legacy.shape = nil
        let encoded = try JSONEncoder().encode(legacy)
        try require(!String(decoding: encoded, as: UTF8.self).contains("\"shape\""), "Historical element did not gain metadata")
        try require(JSONDecoder().decode(DrawnElement.self, from: encoded) == legacy, "Historical shape roundtrip")
        var old = try document(); legacy.layerID = old.activeLayerID; old.frames[0].elements = [legacy]
        try old.validate(); let oldPixels = try render(old)
        try require(channel(oldPixels, 64, 64) == 0 && channel(oldPixels, 64, 16) > 240, "Historical outline pixels")
        pass("historical schema1 shape encoding and actual outline pixels remain intact")

        let solid = try document(shape("x")), outline = try document(shape("x", fill: nil))
        let solidPixels = try render(solid), outlinePixels = try render(outline)
        try require(channel(solidPixels, 64, 64, 0) == 255 && channel(solidPixels, 64, 64) == 255, "Real filled center")
        try require(channel(outlinePixels, 64, 64) == 0 && channel(outlinePixels, 64, 16) == 255, "Real no-fill center and stroke")
        try require(channel(solidPixels, 4, 4) == 0 && solidPixels != outlinePixels, "Fill changes only shape artwork")
        pass("solid and no-fill settings change actual rectangle pixels")

        let round = try document(shape("x", radius: 40)), roundPixels = try render(round)
        try require(channel(solidPixels, 18, 18) > 240 && channel(roundPixels, 18, 18) == 0, "Real corner radius removes square corner")
        try require(channel(roundPixels, 64, 64) == 255 && channel(roundPixels, 64, 18) == 255, "Rounded interior and edge retained")
        let scaled = try render(round, size: 256)
        try require(channel(scaled, 36, 36, width: 256) == 0 && channel(scaled, 128, 128, width: 256) == 255,
                    "Radius uses document geometry at another viewport size")
        pass("real corner radius scales with document geometry")

        let oval = try document(shape("x", tool: .circle)), ovalPixels = try render(oval)
        try require(channel(ovalPixels, 18, 18) == 0 && channel(ovalPixels, 64, 64) == 255 && channel(ovalPixels, 64, 16) > 240,
                    "Filled ellipse has curved boundary and real interior")
        pass("circle fill produces the actual elliptical region")

        var translucent = try document(shape("x", opacity: 0.5))
        let translucentPixels = try render(translucent)
        for (x,y) in [(64,64),(18,64),(14,64)] {
            let alpha = channel(translucentPixels,x,y)
            print("SHAPE_ALPHA \(x),\(y)=\(alpha)")
            try require((126...129).contains(Int(alpha)), "Opacity applied once to fill and overlapping stroke")
        }
        translucent.layers[0].opacity = 0.5
        let layerPixels = try render(translucent)
        try require((62...65).contains(Int(channel(layerPixels,64,64))) && (62...65).contains(Int(channel(layerPixels,18,64))),
                    "Canonical layer opacity applies once after shape opacity")
        translucent.layers[0].visible = false
        try require(try render(translucent).allSatisfy { $0 == 0 }, "Hidden shape layer contributes no pixels")
        pass("shape opacity, overlapping border, layer opacity and visibility compose once")

        var reversed = solid; reversed.frames[0].elements[0].points.reverse()
        try require(try render(reversed) == solidPixels, "Reverse drag produces identical rectangle")
        var small = try document(shape("x", radius: 50))
        small.frames[0].elements[0].points = [.init(x: 48,y: 48),.init(x: 80,y: 64)]
        let smallPixels = try render(small)
        try require(channel(smallPixels,64,56) == 255 && channel(smallPixels,32,32) == 0, "Large radius bounded by shape dimensions")
        pass("reverse drags and oversized corner radius remain within real shape bounds")

        for descriptor in [StudioShapeDescriptor(version: 99), .init(cornerRadius: -1), .init(cornerRadius: 51),
                           .init(cornerRadius: .infinity), .init(cornerRadius: .nan), .init(fillColor: "red"), .init(fillColor: "#FFFFFFFF")] {
            try rejects { try descriptor.validate(tool: .rectangle) }
        }
        try rejects { try StudioShapeDescriptor(cornerRadius: 1).validate(tool: .circle) }
        try rejects { try StudioShapeDescriptor().validate(tool: .brush) }
        var wrongVersion = solid; wrongVersion.schemaVersion = 4
        try rejects { try wrongVersion.validate() }
        var wrongPoints = solid; wrongPoints.frames[0].elements[0].points.removeLast()
        try rejects { try wrongPoints.validate() }
        var mixedMetadata = solid; mixedMetadata.frames[0].elements[0].brush = .init(family: .round,seed: 1)
        try rejects { try mixedMetadata.validate() }
        pass("invalid style versions colors geometry and incompatible metadata fail explicitly")

        var editor = try StudioDocumentEditor(document: document())
        let captured = shape(editor.document.activeLayerID, radius: 24)
        try editor.commit(captured, frameID: editor.document.activeFrameID)
        try require(editor.document.schemaVersion == 5, "Styled commit upgrades schema")
        editor.copyFrame(); try require(editor.canUndo, "Styled commit has undo history"); editor.undo()
        try require(editor.document.schemaVersion == 1 && editor.document.frames[0].elements.isEmpty, "Full-document undo restores original schema")
        try editor.pasteFrame()
        try require(editor.document.schemaVersion == 5 && editor.document.frames[1].elements[0].shape == captured.shape,
                    "Clipboard survives undo and restores shape schema")
        try require(editor.document.frames[1].elements[0].id != captured.id, "Pasted shape receives unique identity")
        let copiedID = editor.document.activeLayerID; try editor.duplicateLayer(copiedID)
        try require(editor.document.frames[1].elements.count == 2 && editor.document.frames[1].elements.allSatisfy { $0.shape == captured.shape },
                    "Layer duplication preserves complete shape settings")
        let archived = try StudioDocumentArchive(document: editor.document,rasterFrameIndices: [:]).encoded()
        try require(StudioDocumentArchive.decode(archived).document == editor.document, "Actual production archive roundtrip")
        pass("schema5 full-document undo clipboard layer copy and production archive preserve styles")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-shape-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"),cachesDirectory: root.appendingPathComponent("Cache"))
        let vm = StudioViewModel(storage: storage)
        let created = await vm.createProject(name: "Saved shapes",width: 128,height: 128,fps: 12)
        try require(created, "Actual VM creates project")
        vm.selectedTool = .rectangle; vm.shapeFilled = true; vm.shapeCornerRadius = 30; vm.strokeColor = .red
        let start = Date(timeIntervalSince1970: 100)
        var input = StudioStrokeInput(id: "captured-shape",frameID: vm.currentFrame.id,layerID: vm.activeLayerID,
            tool: .rectangle,color: vm.strokeColorHex,width: 8,opacity: 1,brush: nil,
            documentSize: CGSize(width: 128,height: 128),viewportSize: CGSize(width: 256,height: 256),
            startedAt: start,shape: try vm.shapeDescriptor())
        try input.append(location: CGPoint(x:32,y:32),time: start)
        try input.append(location: CGPoint(x:224,y:224),time: start.addingTimeInterval(0.2))
        vm.shapeFilled = false; vm.shapeCornerRadius = 0
        try require(input.element.shape?.cornerRadius == 30 && input.element.shape?.fillColor == "#FF0000", "Gesture retains captured settings")
        try require(vm.commitElement(input.element,frameID: input.frameID), "Actual VM commits shape")
        let drawn = try render(vm.document)
        vm.undo(); try require(vm.currentFrame.elements.isEmpty, "Actual VM undoes shape")
        vm.redo(); try require(try render(vm.document) == drawn, "Actual VM redo restores exact shape pixels")
        let saved = await vm.save(); try require(saved, "Actual production save succeeds")
        let reopened = StudioViewModel(storage: storage); await reopened.loadProjects()
        guard let metadata = reopened.savedProjects.first else { throw Failure(message:"Actual saved project listing") }
        let opened = await reopened.openProject(metadata); try require(opened, "Actual cold reopen succeeds")
        try require(reopened.currentFrame.elements[0].shape == input.element.shape && render(reopened.document) == drawn,
                    "Cold reopened shape settings and pixels match")
        pass("actual touch settings VM undo redo save list and cold reopen preserve shape pixels")

        let output = try await StudioExportService().export(document: reopened.document,format: .pngSequence,outputParent: root,background: .transparent)
        guard let source = CGImageSourceCreateWithURL(output.imageURLs[0] as CFURL,nil),
              let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw Failure(message:"Real exported PNG reopens") }
        try require(try pixels(image) == drawn, "Actual PNG matches canonical live pixels exactly")
        pass("actual exported transparent PNG reopens with identical shape pixels")

        let movieSnapshot = StudioMovieExportService.Snapshot(document: reopened.document,
            retainedAudioTracks: [], rasterDataByID: [:])
        let movie = try await StudioMovieExportService().export(snapshot: movieSnapshot, outputParent: root, background: .white)
        let movieURL = try movie.checkedURLs()[0], asset = AVURLAsset(url: movieURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try require(videoTracks.count == 1 && audioTracks.isEmpty, "Actual shape MP4 track count")
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(videoOutput); try require(reader.startReading(), "Shape MP4 decoder starts")
        var decodedFrames = 0
        while let sample = videoOutput.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw Failure(message: "Shape MP4 has actual pixels") }
            try require(CVPixelBufferGetWidth(buffer) == 128 && CVPixelBufferGetHeight(buffer) == 128, "Shape MP4 canvas dimensions")
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure(message: "Shape MP4 pixel buffer") }
            let bytes = base.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(buffer)
            var totalError = 0
            for y in 0..<128 { for x in 0..<128 {
                let offset = (y * 128 + x) * 4, decoded = y * row + x * 4
                let whiteContribution = 255 - Int(drawn[offset + 3])
                for c in 0..<3 {
                    let actual = Int(bytes[decoded + 2 - c])
                    let expected = Int(drawn[offset + c]) + whiteContribution
                    totalError += abs(actual - expected)
                }
            } }
            let centerOffset = 64 * row + 64 * 4, cornerOffset = 18 * row + 18 * 4
            let realCenter = [bytes[centerOffset+2],bytes[centerOffset+1],bytes[centerOffset]]
            let realCorner = [bytes[cornerOffset+2],bytes[cornerOffset+1],bytes[cornerOffset]]
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            let meanError = Double(totalError) / Double(128 * 128 * 3)
            print("SHAPE_MP4_MEAN_RGB_ERROR=\(meanError)")
            try require(meanError < 8 && realCenter[0] > 220 && realCenter[1] < 30 && realCenter[2] < 30,
                        "Actual encoded shape matches canonical fill and rounded geometry")
            try require(realCorner.allSatisfy { $0 > 230 }, "Actual MP4 retains the rounded white corner")
            try require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), .zero) == 0, "Actual shape frame timestamp")
            decodedFrames += 1
        }
        let movieDuration = try await asset.load(.duration)
        try require(reader.status == .completed && decodedFrames == 1 && CMTimeCompare(movieDuration, CMTime(value:1,timescale:12)) == 0,
                    "Full shape MP4 frame and rational duration reopen")
        try movie.cleanup()
        pass("actual H264 MP4 preserves saved shape fill radius full pixels and timing")

        var commands = try StudioDocumentEditor(document: document())
        let shapeStroke = StudioCommandStroke(id: "command-shape",tool: .circle,
            points: [.init(x:16,y:16),.init(x:112,y:112)],color:"#FF0000",width:8,opacity:1,shape:.init(fillColor:"#FF0000"))
        func request(_ strokes: [StudioCommandStroke]) -> StudioCommandRequest {
            .init(requestID: UUID(),projectID: commands.document.id,expectedRevision: commands.document.revision,
                action: .apply([.draw(.init(frame:.id(commands.document.activeFrameID),layer:.id(commands.document.activeLayerID),strokes:strokes))]))
        }
        let wire = try JSONEncoder().encode(request([shapeStroke]))
        var badWire = try JSONSerialization.jsonObject(with: wire) as! [String: Any]
        var wireAction = badWire["action"] as! [String: Any]
        var wireCommands = wireAction["apply"] as! [[String: Any]]
        var wireDraw = wireCommands[0]["draw"] as! [String: Any]
        var wireStrokes = wireDraw["strokes"] as! [[String: Any]]
        var wireShape = wireStrokes[0]["shape"] as! [String: Any]
        wireShape["unrecognizedOperation"] = "not an instruction"
        wireStrokes[0]["shape"] = wireShape; wireDraw["strokes"] = wireStrokes
        wireCommands[0]["draw"] = wireDraw; wireAction["apply"] = wireCommands; badWire["action"] = wireAction
        try rejects { _ = try StudioCommandExecutor.decode(JSONSerialization.data(withJSONObject: badWire)) }
        let decoded = try StudioCommandExecutor.decode(wire)
        _ = try StudioCommandExecutor.execute(decoded,editor:&commands)
        try require(commands.document.schemaVersion == 5 && render(commands.document) == ovalPixels,
                    "Typed Spatter command reaches same saved style and actual pixels")
        let before = commands.document, undo = commands.canUndo, redo = commands.canRedo
        var valid = shapeStroke; valid = .init(id:"next-shape",tool:valid.tool,points:valid.points,color:valid.color,width:valid.width,opacity:valid.opacity,shape:valid.shape)
        var bad = valid; bad = .init(id:"invalid-shape",tool:bad.tool,points:bad.points,color:bad.color,width:bad.width,opacity:bad.opacity,shape:.init(cornerRadius:2))
        let invalidRequest = request([valid,bad])
        try rejects { _ = try StudioCommandExecutor.execute(invalidRequest,editor:&commands) }
        try require(commands.document == before && commands.canUndo == undo && commands.canRedo == redo, "Invalid batch is transactional")
        pass("typed validated shape commands share rendering and reject invalid batches transactionally")
        print("STUDIO_SHAPE_SETTINGS_TESTS=PASS \(passed)/\(passed)")
    }
}
