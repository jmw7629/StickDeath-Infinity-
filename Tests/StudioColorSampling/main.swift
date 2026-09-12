import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// UIKit image-container adapter only; the full production compositor and
// sampling service are compiled unchanged, with actual SwiftUI pixels.
typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }

private struct TestFailure: Error { let message: String }
@main @MainActor struct ColorSamplingTests {
    static var count = 0
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw TestFailure(message: message) }
    }
    static func pass(_ name: String) { count += 1; print("PASS \(name)") }
    static func dot(_ id: String, _ layer: String, _ color: String, _ x: Double, _ y: Double) -> DrawnElement {
        .init(id: id, tool: .pen, points: [.init(x: x, y: y)], color: color, width: 12, opacity: 1, layerID: layer)
    }
    static func fixture() throws -> StudioDocument {
        var d = try StudioDocument.new(name: "Sample actual artwork", width: 64, height: 48, fps: 12)
        d.frames[0].elements = [dot("red", d.activeLayerID, "#FF0000", 12, 12),
            dot("green", d.activeLayerID, "#00FF00", 48, 12),
            dot("blue", d.activeLayerID, "#0000FF", 12, 36),
            dot("yellow", d.activeLayerID, "#FFFF00", 48, 36)]
        return d
    }
    static func read(_ d: StudioDocument, _ x: Double, _ y: Double, raster: Data? = nil) throws -> StudioColorSamplingService.Sample {
        try StudioColorSamplingService.sample(document: d, frameID: d.activeFrameID, point: CGPoint(x: x, y: y), rasterData: raster)
    }
    static func rejects(_ name: String, _ expected: StudioColorSamplingService.Failure, _ body: () throws -> Void) throws {
        do { try body(); throw TestFailure(message: name + " unexpectedly succeeded") }
        catch let error as StudioColorSamplingService.Failure { try require(error == expected, name + " wrong failure") }
    }
    static func png() throws -> Data {
        let width = 16, height = 16
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let color: [UInt8] = y < 8 ? (x < 8 ? [255,0,0,255] : [0,255,0,255]) : (x < 8 ? [0,0,255,255] : [255,255,0,255])
            bytes.replaceSubrange((y * width + x) * 4..<(y * width + x) * 4 + 4, with: color)
        } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw TestFailure(message: "PNG fixture image") }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw TestFailure(message: "PNG destination") }
        CGImageDestinationAddImage(dest, image, nil)
        try require(CGImageDestinationFinalize(dest), "PNG encode")
        return data as Data
    }
    static func exportedPixel(_ url: URL, _ x: Int, _ y: Int) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw TestFailure(message: "Real PNG reopen") }
        // Decode the full exported image through an independent top-left buffer,
        // not through the sampler's one-pixel crop.
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ok = bytes.withUnsafeMutableBytes { b -> Bool in
            guard let c = CGContext(data: b.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        try require(ok, "PNG actual pixel decode")
        let i = (y * image.width + x) * 4
        return String(format: "#%02X%02X%02X", bytes[i], bytes[i+1], bytes[i+2])
    }
    static func main() async throws {
        let d = try fixture(), before = d
        for (x,y,color) in [(12.0,12.0,"#FF0000"),(48,12,"#00FF00"),(12,36,"#0000FF"),(48,36,"#FFFF00")] {
            let s = try read(d,x,y); try require(s.hex == color, "Top-left coordinates \(x),\(y): \(s.hex)")
            try require(s.projectID == d.id && s.revision == d.revision && s.frameID == d.activeFrameID, "Sample source receipt")
        }
        pass("four distinct real vector colors and source receipt")
        let fractional = try read(d,12.9,12.8)
        try require(fractional.x == 12 && fractional.y == 12 && fractional.hex == "#FF0000", "Containing pixel")
        for (x,y) in [(0.0,0.0),(63.99,0),(0,47.99),(63.99,47.99)] { try require(try read(d,x,y).hex == "#FFFFFF", "Boundary white") }
        pass("fractional and all four canvas edge coordinates")
        for (x,y) in [(-0.01,0.0),(0,-0.01),(64,0),(0,48),(Double.nan,0),(0,Double.infinity)] {
            try rejects("invalid point", .outsideCanvas) { _ = try read(d,x,y) }
        }
        pass("outside and nonfinite positions reject without clamping")
        try rejects("missing frame", .unavailableFrame) { _ = try StudioColorSamplingService.sample(document: d, frameID: "absent", point: .zero) }
        var huge = d; huge.width = 4096; huge.height = 4096
        try rejects("pixel limit", .limitExceeded) { _ = try read(huge,1,1) }
        pass("missing frame and render size limits")
        var guides = d; guides.gridEnabled = true; guides.onionEnabled = true
        guides.frames.append(.init(id: "onion", elements: [dot("other",d.activeLayerID,"#123456",12,12)]))
        try require(try read(guides,12,12).hex == "#FF0000", "Guides/onion altered artwork")
        pass("grid and onion metadata excluded from actual artwork")
        var hidden = d; hidden.layers[0].visible = false
        try require(try read(hidden,12,12).hex == "#FFFFFF", "Hidden layer sampled")
        hidden.layers[0].visible = true; hidden.layers[0].locked = true; hidden.layers[0].lockMode = "full"
        try require(try read(hidden,12,12).hex == "#FF0000", "Locked visible artwork cannot be read")
        pass("hidden layers excluded; visible locked artwork remains readable")
        var rasterDoc = d; rasterDoc.schemaVersion = 3; rasterDoc.frames[0].elements = []
        rasterDoc.frames[0].rasterAssetID = "managed-image"; rasterDoc.frames[0].rasterLayerID = d.activeLayerID
        rasterDoc.frames[0].rasterPlacement = .init(x: 16,y: 8,width: 32,height: 32)
        let imageBytes = try png()
        for (x,y,color) in [(20.0,12.0,"#FF0000"),(44,12,"#00FF00"),(20,36,"#0000FF"),(44,36,"#FFFF00")] {
            try require(try read(rasterDoc,x,y,raster:imageBytes).hex == color, "Actual imported image coordinate \(x),\(y)")
        }
        try require(try read(rasterDoc,2,2,raster:imageBytes).hex == "#FFFFFF", "Raster placement ignored")
        pass("real PNG quadrants and managed image placement")
        try rejects("missing managed raster", .missingRaster) { _ = try read(rasterDoc,20,12) }
        do { _ = try read(rasterDoc,20,12,raster:Data("invalid".utf8)); throw TestFailure(message:"Corrupt raster accepted") }
        catch is StudioRasterImage.Failure { }
        rasterDoc.layers[0].visible = false
        try require(try read(rasterDoc,20,12).hex == "#FFFFFF", "Missing invisible raster blocks visible artwork")
        pass("missing/corrupt visible raster fails; hidden raster needs no bytes")
        var historical = rasterDoc; historical.layers[0].visible = true; historical.frames[0].rasterPlacement = nil
        try rejects("missing historical pixels", .missingRaster) { _ = try read(historical,20,12) }
        pass("historical missing pixels are not invented")

        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-sampling-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        var composite = d
        composite.layers.insert(.init(id:"overlay",name:"Overlay",opacity:0.5,blendMode:"multiply",glowEnabled:true,glowColor:"#00FF00"),at:0)
        composite.frames[0].elements.append(dot("overlay-dot","overlay","#0000FF",12,12))
        composite.frames[0].elements.append(.init(id:"erasing",tool:.eraser,points:[.init(x:48,y:36)],color:"#000000",width:2,opacity:1,layerID:d.activeLayerID))
        for mode in ["normal","multiply","screen","overlay","darken","lighten"] {
            composite.layers[0].blendMode = mode
            let output = try await StudioExportService().export(document: composite,format:.pngSequence,outputParent:parent)
            for (x,y) in [(12,12),(48,12),(12,36),(48,36),(20,12),(0,0)] {
                let actual = try read(composite,Double(x),Double(y)).hex
                let expected = try exportedPixel(output.imageURLs[0],x,y)
                try require(actual == expected,"\(mode) sample\(actual) PNG\(expected) at\(x),\(y)")
            }
        }
        pass("all six layer blends, opacity, glow and eraser match reopened production PNG pixels")
        var second = d; second.frames[0].elements[0].color = "#0000FF"
        try require(try read(second,12,12).hex == "#0000FF", "Repeated sampling cached stale source")
        try require(d == before, "Sampling changed canonical document/history inputs")
        pass("reused identities use current artwork and leave source unchanged")

        let storage = DeviceStorageManager(documentsDirectory: parent.appendingPathComponent("Documents"),
            cachesDirectory: parent.appendingPathComponent("Caches"))
        let vm = StudioViewModel(storage: storage)
        let created = await vm.createProject(name:"Color session",width:64,height:48,fps:12)
        try require(created, "Production create")
        try require(vm.commitElement(dot("session-blue",vm.activeLayerID,"#0000FF",12,12)), "Production drawing")
        let saved = await vm.save()
        try require(saved, "Production save")
        vm.selectDrawingTool(.eyedropper)
        vm.strokeOpacity = 0.4
        guard let captured = vm.beginColorSample() else { throw TestFailure(message:"No sample context") }
        let originalDocument = vm.document, originalUndo = vm.canUndo, originalRedo = vm.canRedo
        let storedBefore = try storage.loadAnimation(id: vm.document.id)?.editableDocumentData
        try require(vm.sampleArtworkColor(at:CGPoint(x:12,y:12),captured:captured), "Production color setting")
        guard let chosen = NSColor(vm.strokeColor).usingColorSpace(.sRGB) else { throw TestFailure(message:"Actual chosen color") }
        try require(chosen.blueComponent > 0.99 && chosen.redComponent < 0.01 && chosen.greenComponent < 0.01, "Chosen color is not blue")
        try require(vm.strokeOpacity == 0.4 && vm.selectedTool == .eyedropper, "Picker changed unrelated brush settings")
        try require(vm.document == originalDocument && vm.canUndo == originalUndo && vm.canRedo == originalRedo,
            "Picker changed document or undo/redo")
        try require(try storage.loadAnimation(id: vm.document.id)?.editableDocumentData == storedBefore, "Picker wrote storage")
        pass("actual view model chooses sampled color while preserving document, history and persisted bytes")
        let chosenBefore = vm.strokeColor
        try require(!vm.sampleArtworkColor(at:CGPoint(x:-1,y:12),captured:captured) && vm.strokeColor == chosenBefore,
            "Rejected sample replaced drawing color")
        vm.selectDrawingTool(.pen)
        try require(vm.beginColorSample() == nil && !vm.sampleArtworkColor(at:.zero,captured:captured), "Wrong tool accepted sample")
        vm.selectDrawingTool(.eyedropper)
        try require(vm.beginStrokeInput(id:"active"), "Begin actual input guard")
        try require(vm.beginColorSample() == nil && !vm.sampleArtworkColor(at:.zero,captured:captured), "Active stroke allowed sampling")
        vm.finishStrokeInput(id:"active")
        vm.addFrame()
        try require(!vm.sampleArtworkColor(at:.zero,captured:captured) && vm.strokeColor == chosenBefore, "Stale frame accepted sample")
        pass("actual view model rejects failed, wrong-tool, active-input and stale-frame requests")
        vm.togglePlayback()
        try require(vm.beginColorSample() == nil, "Playback allowed sampling")
        vm.stopPlayback()
        await vm.backToProjects()
        try require(vm.beginColorSample() == nil && !vm.sampleArtworkColor(at:.zero,captured:captured), "Closed editor accepted sample")
        pass("playback and closed editor cannot accept picker input")
        let layout = StudioColorSampleGesture.Layout(viewport: CGSize(width:128,height:96), scale:2,
            offset:CGSize(width:19,height:-7))
        let location = CGPoint(x:24,y:24)
        var unavailable = StudioColorSampleGesture()
        unavailable.update(context:nil,layout:layout,foreground:true)
        unavailable.update(context:captured,layout:layout,foreground:true)
        try require(unavailable.resolve(location:location,context:captured,layout:layout,foreground:true) == nil,
            "Unavailable/Hand start became a picker after a tool/playback change")
        var background = StudioColorSampleGesture()
        background.update(context:captured,layout:layout,foreground:false)
        background.update(context:captured,layout:layout,foreground:true)
        try require(background.resolve(location:location,context:captured,layout:layout,foreground:true) == nil,
            "Background-start gesture became eligible")
        pass("production gesture captures eligibility once and never retries an unavailable start")

        var stable = StudioColorSampleGesture()
        stable.update(context:captured,layout:layout,foreground:true)
        guard let mapped = stable.resolve(location:location,context:captured,layout:layout,foreground:true) else {
            throw TestFailure(message:"Stable transformed canvas rejected")
        }
        try require(mapped.context == captured && mapped.point == CGPoint(x:12,y:12),
            "Transformed local point did not map to the original document")
        let layouts = [
            StudioColorSampleGesture.Layout(viewport:layout.viewport,scale:3,offset:layout.offset),
            .init(viewport:layout.viewport,scale:layout.scale,offset:.zero),
            .init(viewport:CGSize(width:129,height:96),scale:layout.scale,offset:layout.offset),
            .init(viewport:.zero,scale:layout.scale,offset:layout.offset),
            .init(viewport:layout.viewport,scale:.nan,offset:layout.offset)]
        for changed in layouts {
            try require(stable.resolve(location:location,context:captured,layout:changed,foreground:true) == nil,
                "Final changed/invalid canvas layout accepted")
            var gesture = stable
            gesture.update(context:captured,layout:changed,foreground:true)
            gesture.update(context:captured,layout:layout,foreground:true)
            try require(gesture.resolve(location:location,context:captured,layout:layout,foreground:true) == nil,
                "Observed transform change became eligible after restoration")
        }
        pass("zoom pan and viewport are captured, mapped once, and changes permanently invalidate")

        for foreground in [true,false] {
            var gesture = stable
            gesture.update(context:nil,layout:layout,foreground:foreground)
            gesture.update(context:captured,layout:layout,foreground:true)
            try require(gesture.resolve(location:location,context:captured,layout:layout,foreground:true) == nil,
                "Observed interrupted context became eligible again")
        }
        for point in [CGPoint(x:-1,y:1),CGPoint(x:128,y:1),CGPoint(x:1,y:96),CGPoint(x:CGFloat.nan,y:1)] {
            try require(stable.resolve(location:point,context:captured,layout:layout,foreground:true) == nil,
                "Out of bounds local point accepted")
        }
        var newGesture = StudioColorSampleGesture()
        newGesture.update(context:captured,layout:layout,foreground:true)
        try require(newGesture.resolve(location:location,context:captured,layout:layout,foreground:true) != nil,
            "Fresh gesture did not reset its own capture")
        pass("tool scene and input interruption stay invalid; only a new gesture may capture again")
        print("STUDIO_COLOR_SAMPLING_TESTS=PASS count=\(count)")
    }
}
