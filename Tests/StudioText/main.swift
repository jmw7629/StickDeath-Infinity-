import AppKit
import SwiftUI
import ImageIO
import AVFoundation

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }

@main @MainActor struct TextTests {
    static var passed = 0
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message: message) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }; throw Failure(message: "Invalid operation succeeded")
    }
    static func pass(_ name: String) { passed += 1; print("PASS " + name) }
    static func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let worked = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        try require(worked, "Actual native image decode"); return bytes
    }
    static func text(_ layer: String, content: String = "SDI\nBoom!") -> DrawnElement {
        .init(id: UUID().uuidString, tool: .text, points: [.init(x: 12, y: 12)],
            color: "#FF0000", width: 1, opacity: 1, layerID: layer,
            text: .init(content: content, style: .init(size: 20, boxWidth: 104, boxHeight: 80)))
    }
    static func document() throws -> StudioDocument {
        var doc = try StudioDocument.new(name: "Editable Unicode text", width: 128, height: 128, fps: 12)
        doc.schemaVersion = 10; doc.frames[0].elements = [text(doc.activeLayerID)]
        try doc.validate(); return doc
    }
    static func render(_ doc: StudioDocument) throws -> [UInt8] {
        let frame = doc.frames[0], prepared = try StudioFrameRenderer.prepare(frame: frame)
        var error: Error?
        let renderer = ImageRenderer(content: Canvas { context, size in
            error = StudioFrameRenderer.draw(context: &context, frame: frame, layers: doc.layers,
                canvasSize: CGSize(width: doc.width, height: doc.height), size: size, preparedBrushes: prepared)
        }.frame(width: CGFloat(doc.width), height: CGFloat(doc.height)))
        renderer.scale = 1
        guard let image = renderer.cgImage else { throw Failure(message: "No actual text image") }
        if let error { throw error }; return try pixels(image)
    }
    static func ink(_ bytes: [UInt8]) -> Int { stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 8 }.count }
    static func minX(_ bytes: [UInt8]) -> Int {
        (0..<128).first { x in (0..<128).contains { y in bytes[(y*128+x)*4+3] > 8 } } ?? 128
    }
    static func request(_ doc: StudioDocument, _ commands: [StudioCommand]) -> StudioCommandRequest {
        .init(requestID: UUID(), projectID: doc.id, expectedRevision: doc.revision, action: .apply(commands))
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let original = try document(), base = try render(original)
        try require(ink(base) > 100, "New text rendered no real glyphs")
        let unicode = "Café e\u{301} 漢字 مرحبا 🦴\nSDI"
        var unicodeDoc = original; unicodeDoc.frames[0].elements[0].text?.content = unicode
        let data = try StudioDocumentArchive(document: unicodeDoc, rasterFrameIndices: [:]).encoded()
        try require(try StudioDocumentArchive.decode(data).document == unicodeDoc && render(unicodeDoc) != base,
                    "Unicode was flattened, normalized or lost in encoding")
        var legacy = original; legacy.schemaVersion = 1; legacy.frames[0].elements[0].text = nil
        legacy.frames[0].elements[0].fillColor = "Legacy"; legacy.frames[0].elements[0].width = 7
        let legacyBytes = try JSONEncoder().encode(legacy)
        try require(try JSONDecoder().decode(StudioDocument.self, from: legacyBytes) == legacy && ink(render(legacy)) > 40,
                    "Historical fillColor text no longer renders/decodes")
        var crlf = original; crlf.frames[0].elements[0].text?.content = "SDI\r\nBoom!"
        try require(try render(crlf) == base && crlf.frames[0].elements[0].text?.content == "SDI\r\nBoom!", "CRLF layout changed source content or line spacing")
        var unicodeBreak = original; unicodeBreak.frames[0].elements[0].text?.content = "SDI\u{2028}Boom!"
        try require(try render(unicodeBreak) == base, "Unicode line separator changed line layout")
        pass("editable Unicode and legacy text preserve original source content and real glyphs")

        var variants = [[UInt8]]()
        for option in 0..<6 {
            var d = original
            switch option {
            case 0: d.frames[0].elements[0].text?.style.size = 30
            case 1: d.frames[0].elements[0].text?.style.bold = true
            case 2: d.frames[0].elements[0].text?.style.italic = true
            case 3: d.frames[0].elements[0].text?.style.font = .serif
            case 4: d.frames[0].elements[0].text?.style.rotation = 35
            default: d.frames[0].elements[0].text?.style.boxWidth = 40
            }
            let bytes = try render(d); try require(bytes != base && ink(bytes) > 20, "Typography option \(option) did not render")
            variants.append(bytes)
        }
        try require(variants[1] != variants[2], "Bold and italic produce same glyphs")
        var left = original; left.frames[0].elements[0].text?.content = "I\nII"
        var right = left; right.frames[0].elements[0].text?.style.alignment = .right
        var center = left; center.frames[0].elements[0].text?.style.alignment = .center
        let lx = minX(try render(left)), cx = minX(try render(center)), rx = minX(try render(right))
        print("TEXT_ALIGNMENT left=\(lx) center=\(cx) right=\(rx)")
        try require(lx + 15 < cx && cx + 15 < rx, "Alignment does not move actual glyph pixels")
        pass("size weight italic fallback fonts rotation width and all alignments alter actual pixels")

        var clipped = original; clipped.frames[0].elements[0].text?.style.boxHeight = 16
        let crop = try render(clipped)
        try require(ink(crop) > 20 && ink(crop) < ink(base), "Text box height does not clip actual pixels")
        for y in 0..<128 { for x in 0..<128 where x < 12 || x >= 116 || y < 12 || y >= 28 {
            try require(crop[(y*128+x)*4+3] == 0, "Text escaped clipping box")
        } }
        var half = original; half.frames[0].elements[0].opacity = 0.5; half.layers[0].opacity = 0.5
        let halfPixels = try render(half)
        try require((stride(from: 3, to: base.count, by: 4).map { Int(halfPixels[$0]) }.max() ?? 0) <= 65, "Layer/text alpha applied incorrectly")
        var hidden = original; hidden.layers[0].visible = false
        try require(ink(render(hidden)) == 0, "Hidden text layer rendered")
        pass("text box clipping layer visibility and nested opacity affect actual output")

        for mutation in 0..<10 {
            var d = original
            switch mutation {
            case 0: d.schemaVersion = 9
            case 1: d.frames[0].elements[0].text?.content = "  \n"
            case 2: d.frames[0].elements[0].text?.content = String(repeating: "a", count: 2049)
            case 3: d.frames[0].elements[0].text?.style.size = .nan
            case 4: d.frames[0].elements[0].text?.style.rotation = 181
            case 5: d.frames[0].elements[0].eraser = .init()
            case 6: d.frames[0].elements[0].tool = .rectangle
            case 7: d.frames[0].elements[0].points.append(.init(x: 10,y:10))
            case 8: d.frames[0].elements[0].text?.version = 99
            default: d.frames[0].elements[0].text?.content = String(repeating: "a\r\n", count: 65)
            }
            try rejects { try d.validate() }
        }
        var tooMany = original
        tooMany.frames[0].elements = (0..<257).map { _ in text(original.activeLayerID) }
        try rejects { try tooMany.validate() }
        pass("invalid schema content styles geometry combinations and rendering budgets reject atomically")

        for mode in ["full", "alpha", "position"] {
            var d = original; d.layers[0].lockMode = mode; var editor = try StudioDocumentEditor(document: d)
            try rejects { try editor.updateText(frameID: d.activeFrameID, elementID: d.frames[0].elements[0].id,
                text: .init(content: "Changed"), color: "#0000FF", opacity: 1) }
            try require(editor.document == d && !editor.canUndo, "Locked text changed")
        }
        pass("text updates honor full alpha and position locks without history mutation")

        var editor = try StudioDocumentEditor(document: original)
        let id = original.frames[0].elements[0].id
        try editor.updateText(frameID: original.activeFrameID, elementID: id, text: .init(content: "EDIT", style: .init(size: 24, boxWidth:104, boxHeight:80)),color:"#0000FF",opacity:0.8)
        let edited = editor.document, editedPixels = try render(edited)
        try require(editedPixels != base && edited.frames[0].elements[0].id == id, "Editing replaced identity or retained old pixels")
        editor.undo(); try require(try render(editor.document) == base, "Text Undo pixels")
        editor.redo(); try require(try render(editor.document) == editedPixels, "Text Redo pixels")
        try editor.copyElements(frameID: original.activeFrameID, ids: [id]); let pasted = try editor.pasteElements(frameID: original.activeFrameID, layerID: original.activeLayerID)
        try require(pasted.count == 1 && !pasted.contains(id) && editor.document.frames[0].elements.count == 2,
                    "Text clipboard did not assign fresh identity")
        try require(editor.document.frames[0].elements[1].text == edited.frames[0].elements[0].text, "Copy lost editable text")
        try editor.translateElements(frameID: original.activeFrameID, ids: pasted, dx: 5, dy: 7)
        try editor.reflectElements(frameID: original.activeFrameID, ids: pasted, axis: .horizontal)
        try require(editor.document.frames[0].elements[1].text == edited.frames[0].elements[0].text, "Transform flattened text")
        pass("text edit history clipboard fresh identities and transforms preserve editable data")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-text-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "sdi-text-"+UUID().uuidString, defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"),cachesDirectory:root.appendingPathComponent("Cache"))
        let vm = StudioViewModel(storage: storage, toolDefaults: defaults)
        let created = await vm.createProject(name:"Text actual persistence",width:128,height:128,fps:12)
        try require(created, "Actual project creation")
        vm.selectedTool = .text; vm.textStyle = .init(size:20,boxWidth:104,boxHeight:80)
        try require(vm.beginTextEditing(), "Begin text draft")
        vm.textInput = "HELLO\nSDI"
        let before = vm.document; vm.addFrame()
        try require(vm.document == before && vm.isDirty, "Open draft allowed unrelated mutation or false Saved")
        let draftSave = await vm.save(); try require(!draftSave && vm.textDraft != nil, "Save dropped/acknowledged open draft")
        try require(vm.applyTextEditing() && vm.currentFrame.elements.count == 1, "Actual VM text apply")
        let savedPixels = try render(vm.document), savedDescriptor = vm.currentFrame.elements[0].text
        vm.undo(); try require(vm.currentFrame.elements.isEmpty, "VM Undo text")
        vm.redo(); try require(try render(vm.document) == savedPixels, "VM Redo text")
        let elementID = vm.currentFrame.elements[0].id
        vm.selectedTool = .move; _ = vm.selectElement(at: CGPoint(x:64,y:64))
        try require(vm.selectedElementIDs == [elementID], "Actual Move cannot select text box")
        try require(vm.beginTextEditing(selected:true), "Edit selected text")
        vm.textInput = "CANCEL ME"; let cancelBefore = vm.document; vm.cancelTextEditing()
        try require(vm.document == cancelBefore && vm.textDraft == nil, "Cancel changed saved text")
        try require(vm.beginTextEditing(selected:true), "Edit selected reopened text")
        vm.textInput = "FINISHED"; try require(vm.applyTextEditing(), "Apply text edit")
        try require(vm.currentFrame.elements[0].id == elementID && vm.currentFrame.elements[0].text?.content == "FINISHED", "Edit replaced wrong text")
        vm.undo(); try require(vm.currentFrame.elements[0].text == savedDescriptor, "Editable old text history")
        let saved = await vm.save(); try require(saved, "Actual device save")
        let reopened = StudioViewModel(storage:storage,toolDefaults:UserDefaults(suiteName:suite))
        let listing = try storage.listAnimationsReportingFailures(); try require(listing.failures.isEmpty && listing.animations.count == 1,"Actual storage listing")
        let opened = await reopened.openProject(listing.animations[0]); reopened.selectedTool = .text
        try require(opened && reopened.currentFrame.elements[0].text == savedDescriptor && render(reopened.document) == savedPixels,
                    "Cold reopen changed editable text or glyphs")
        try require(reopened.textStyle.size == 20 && reopened.textStyle.boxWidth == 104, "Text settings did not persist")
        pass("production VM drafts cancel save refusal selection edit undo and actual cold reopen preserve text")

        let output = try await StudioExportService().export(document:reopened.document,format:.pngSequence,outputParent:root,background:.transparent)
        guard let source = CGImageSourceCreateWithURL(output.imageURLs[0] as CFURL,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw Failure(message:"Text PNG cannot reopen") }
        try require(try pixels(image) == savedPixels, "PNG text differs from actual canvas")
        pass("real PNG export reopens with exact saved text glyphs")

        let movie = try await StudioMovieExportService().export(snapshot:.init(document:reopened.document,
            retainedAudioTracks:[],rasterDataByID:[:]),outputParent:root,background:.white)
        let asset = AVURLAsset(url:try movie.checkedURLs()[0])
        let tracks = try await asset.loadTracks(withMediaType:.video)
        try require(tracks.count == 1, "Actual text MP4 video track")
        let reader = try AVAssetReader(asset:asset)
        let trackOutput = AVAssetReaderTrackOutput(track:tracks[0],outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(trackOutput); try require(reader.startReading(), "Actual MP4 decode starts")
        var frames = 0
        while let sample = trackOutput.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw Failure(message:"MP4 lacks decoded pixels") }
            try require(CVPixelBufferGetWidth(buffer) == 128 && CVPixelBufferGetHeight(buffer) == 128, "MP4 dimensions")
            CVPixelBufferLockBaseAddress(buffer,.readOnly)
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to:UInt8.self), row = CVPixelBufferGetBytesPerRow(buffer)
            var totalError = 0
            for y in 0..<128 { for x in 0..<128 {
                let offset = (y*128+x)*4, decoded = y*row+x*4
                let white = 255-Int(savedPixels[offset+3])
                for c in 0..<3 { totalError += abs(Int(bytes[decoded+2-c])-Int(savedPixels[offset+c])-white) }
            } }
            CVPixelBufferUnlockBaseAddress(buffer,.readOnly)
            let mean = Double(totalError)/Double(128*128*3)
            print("TEXT_MP4_MEAN_RGB_ERROR=\(mean)")
            try require(mean < 8, "Actual MP4 text differs from saved glyphs")
            try require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),.zero) == 0, "MP4 frame timestamp")
            frames += 1
        }
        let duration = try await asset.load(.duration)
        try require(reader.status == .completed && frames == 1 && CMTimeCompare(duration,CMTime(value:1,timescale:12)) == 0, "Actual MP4 complete frames and timing")
        try movie.cleanup()
        pass("real H264 MP4 decodes saved text glyphs with correct dimensions and timing")

        var commands = try StudioDocumentEditor(document:StudioDocument.new(name:"Text commands",width:128,height:128,fps:12))
        let stroke = text(commands.document.activeLayerID,content:"Spatter text")
        let draw = StudioCommand.draw(.init(frame:.id(commands.document.activeFrameID),layer:.id(commands.document.activeLayerID),strokes:[
            .init(id:stroke.id,tool:.text,points:stroke.points,color:stroke.color,width:1,opacity:1,text:stroke.text)]))
        let wire = try JSONEncoder().encode(request(commands.document,[draw]))
        let invalid = String(decoding:wire,as:UTF8.self).replacingOccurrences(of:"\"boxHeight\":80",with:"\"boxHeight\":80,\"shell\":true")
        try require(invalid != String(decoding:wire,as:UTF8.self), "Unknown field fixture")
        try rejects { _ = try StudioCommandExecutor.decode(Data(invalid.utf8)) }
        _ = try StudioCommandExecutor.execute(StudioCommandExecutor.decode(wire),editor:&commands)
        let prior = commands.document
        let change = StudioCommand.updateText(.init(frame:.id(prior.activeFrameID),elementID:stroke.id,text:.init(content:"Updated"),color:"#FF0000",opacity:1))
        var completedChecks = 0, probe = commands
        _ = try StudioCommandExecutor.execute(request(prior,[change]),editor:&probe,checkCancellation:{ completedChecks += 1 })
        try require(completedChecks >= 3, "Missing pre-stage/final cancellation checks")
        for cancelledAt in 1...completedChecks {
            var calls = 0
            try rejects { _ = try StudioCommandExecutor.execute(request(prior,[change]),editor:&commands,checkCancellation:{ calls += 1; if calls == cancelledAt { throw CancellationError() } }) }
            try require(commands.document == prior && calls == cancelledAt, "Cancelled command changed text")
        }
        _ = try StudioCommandExecutor.execute(StudioCommandExecutor.decode(JSONEncoder().encode(request(prior,[change]))),editor:&commands)
        try require(commands.document.frames[0].elements[0].text?.content == "Updated", "Typed update did not edit real text")
        try rejects { _ = try StudioCommandExecutor.execute(request(prior,[change]),editor:&commands) }
        pass("strict Spatter text creation update cancellation and stale revision use production transactions")
        print("TEXT_PRODUCTION_GROUPS=\(passed)")
    }
}
