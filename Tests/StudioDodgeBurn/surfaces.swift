import AppKit
import SwiftUI
import AVFoundation
import ImageIO
import CoreImage

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
enum SurfaceFailure: Error { case failed(String) }
@main @MainActor struct SurfaceTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw SurfaceFailure.failed(message) }
    }
    static func raster(_ d: StudioDocument, background: StudioExportService.Background) throws -> StudioSmudge.Pixels {
        try StudioSmudgeReplay.pixels(StudioExportService().render(d.frames.last!,document:d,background:background,raster:nil))
    }
    static func near(_ a:[UInt8],_ b:[UInt8], tolerance:Int = 1) -> Bool {
        a.count == b.count && zip(a,b).allSatisfy { abs(Int($0)-Int($1)) <= tolerance }
    }
    // Fill compares straight RGBA; the compositor exports premultiplied RGBA.
    // Compare decoded color, rather than equating the two encodings at edges.
    static func straightRGBA(_ pixels: [UInt8]) -> [UInt8] {
        var result = pixels
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let coverage = Double(pixels[i + 3]) / 255
            for channel in 0..<3 {
                result[i + channel] = coverage == 0 ? 0 : UInt8(min(255, (Double(pixels[i + channel]) / coverage).rounded()))
            }
        }
        return result
    }
    static func decodeMovie(_ url: URL) async throws -> [[UInt8]] {
        let asset = AVURLAsset(url:url)
        let tracks = try await asset.loadTracks(withMediaType:.video)
        try require(tracks.count == 1,"Missing real video stream")
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:tracks[0],outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output);try require(reader.startReading(),"Real movie decoder did not start")
        var frames:[[UInt8]] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw SurfaceFailure.failed("No decoded frame") }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            try require(width == 128 && height == 64,"Movie dimensions changed")
            // The decoder returns tagged HDTV/Rec.709 RGB values. Compare in
            // the lossless reference's sRGB space, as a color-managed viewer does.
            // Comparing raw transfer-encoded bytes falsely darkens neutral grays.
            let image = CIImage(cvPixelBuffer:buffer)
            try require(image.colorSpace != nil,"Decoded video lost color metadata")
            let space = CGColorSpace(name:CGColorSpace.sRGB)!
            let context = CIContext(options:[.workingColorSpace:space,.outputColorSpace:space,.useSoftwareRenderer:true])
            var rgba = [UInt8](repeating:0,count:width*height*4)
            rgba.withUnsafeMutableBytes { data in
                context.render(image,toBitmap:data.baseAddress!,rowBytes:width*4,
                    bounds:CGRect(x:0,y:0,width:width,height:height),format:.RGBA8,colorSpace:space)
            }
            frames.append(rgba)
        }
        try require(reader.status == .completed,"Movie decode did not complete")
        let duration = try await asset.load(.duration)
        try require(abs(duration.seconds-0.5)<0.001,"Movie frame timing changed")
        return frames
    }
    static func main() async throws {
        setbuf(stdout,nil)
        let fm=FileManager.default, root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("artifacts")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        // Keep diagnostic inputs/output privately if an assertion fails.
        let store=DeviceStorageManager(documentsDirectory:root.appendingPathComponent("Documents"),cachesDirectory:root.appendingPathComponent("Caches"))
        let vm=StudioViewModel(storage:store)
        let created=await vm.createProject(name:"DodgeBurn surfaces",width:128,height:64,fps:4)
        try require(created,"Actual Studio creation failed")
        let red=DrawnElement(id:"red",tool:.rectangle,points:[.init(x:8,y:8),.init(x:64,y:56)],
            color:"#646464",width:1,opacity:1,layerID:vm.activeLayerID,shape:.init(fillColor:"#646464"))
        try require(vm.commitElement(red),"Actual source drawing failed")
        let backdrop=DrawnElement(id:"backdrop",tool:.rectangle,points:[.init(x:64,y:0),.init(x:128,y:64)],
            color:"#9C9C9C",width:1,opacity:1,layerID:vm.activeLayerID,shape:.init(fillColor:"#9C9C9C"))
        try require(vm.commitElement(backdrop),"Actual source backdrop failed")
        let before=vm.document
        let mode: DrawingTool = CommandLine.arguments.count>2 && CommandLine.arguments[2]=="burn" ? .burn : .dodge
        let effect=DrawnElement(id:"dodgeBurn",tool:mode,points:[.init(x:64,y:32)],
            color:"#0000FF",width:40,opacity:1,layerID:vm.activeLayerID,dodgeBurn:.init(hardness:1,exposure:0.8,range:.all,protectTones:false))
        try require(vm.commitElement(effect),"Actual DodgeBurn commit failed")
        let document=vm.document
        let transparent=try raster(document,background:.transparent), white=try raster(document,background:.white)
        for point in [CGPoint(x:16,y:16),CGPoint(x:64,y:32),CGPoint(x:66,y:32),CGPoint(x:80,y:32),CGPoint(x:124,y:60)] {
            let sample=try StudioColorSamplingService.sample(document:document,frameID:document.activeFrameID,point:point)
            let index=(Int(point.y)*document.width+Int(point.x))*4
            try require(near([sample.red,sample.green,sample.blue],Array(white.rgba[index..<index+3])),"Eyedropper missed the actual effect pixels")
        }
        print("PASS real eyedropper samples post-dodgeBurn canvas color at source boundary effect and empty pixels")

        for allLayers in [false,true] {
            let capture=try StudioFillService.capture(document:document,frameID:document.activeFrameID,layerID:document.activeLayerID,
                point:.init(x:66,y:32),color:"#00FF00",opacity:1,settings:.init(),sampleAllLayers:allLayers)
            try require(near(Array(capture.rgba),allLayers ? white.rgba : straightRGBA(transparent.rgba)),"Bucket-fill capture omitted dodgeBurn or changed transparency")
        }
        print("PASS actual bucket fill reads identical post-effect transparent active-layer and white composite pixels")

        let view=StudioFrameThumbnail(vm:vm,frame:document.frames[0]).frame(width:128,height:64)
        let renderer=ImageRenderer(content:view);renderer.scale=1
        guard let image=renderer.cgImage else { throw SurfaceFailure.failed("Actual thumbnail view failed to render") }
        try require(near(try StudioSmudgeReplay.pixels(image).rgba,white.rgba),"Actual timeline thumbnail diverged from exported pixels")
        print("PASS actual SwiftUI timeline thumbnail renders the same dodgeBurned frame as PNG export")

        var movie=document
        movie.frames.insert(before.frames[0],at:0)
        // Whole-frame copies need globally unique editable identities.
        movie.frames[0]=AnimationFrame(id:"before",elements:before.frames[0].elements.map { e in
            DrawnElement(id:"before-"+e.id,tool:e.tool,points:e.points,color:e.color,width:e.width,
                opacity:e.opacity,layerID:e.layerID,shape:e.shape)
        })
        try movie.validate()
        let output=try await StudioMovieExportService().export(snapshot:.init(document:movie,retainedAudioTracks:[],rasterDataByID:[:]),outputParent:root,background:.white)
        let decoded=try await decodeMovie(output.movieURL)
        try require(decoded.count == 2,"Actual MP4 dropped a frame")
        let baseline=try raster(before,background:.white).rgba
        for (actual,expected) in zip(decoded,[baseline,white.rgba]) {
            let difference=zip(actual,expected).reduce(0) { $0+abs(Int($1.0)-Int($1.1)) }
            print("MOVIE_FIDELITY average=\(Double(difference)/Double(actual.count)) samples=" + [16*128+16,32*128+32,32*128+62,32*128+66,32*128+100,60*128+4].map { i in
                "\(i):\(Array(expected[i*4..<i*4+4]))->\(Array(actual[i*4..<i*4+4]))"
            }.joined(separator:" "))
            try require(Double(difference)/Double(actual.count)<7,"Decoded H264 does not resemble the actual rendered frame")
        }
        let strongest=white.rgba.indices.max { abs(Int(white.rgba[$0])-Int(baseline[$0])) < abs(Int(white.rgba[$1])-Int(baseline[$1])) }!
        let expectedDelta=Int(white.rgba[strongest])-Int(baseline[strongest])
        let actualDelta=Int(decoded[1][strongest])-Int(decoded[0][strongest])
        let affected = white.rgba.indices.filter { $0 % 4 != 3 && abs(Int(white.rgba[$0])-Int(baseline[$0])) > 40 }
        let expectedError = affected.map { abs(Int(decoded[1][$0])-Int(white.rgba[$0])) }.reduce(0,+)
        let baselineError = affected.map { abs(Int(baseline[$0])-Int(white.rgba[$0])) }.reduce(0,+)
        let details: [String:Any] = ["strongestIndex":strongest,"expectedDelta":expectedDelta,"actualDelta":actualDelta,
            "affectedChannels":affected.count,"expectedError":expectedError,"baselineError":baselineError,
            "moviePath":output.movieURL.path]
        let diagnostic = try JSONSerialization.data(withJSONObject:details,options:[.prettyPrinted,.sortedKeys])
        try diagnostic.write(to:root.appendingPathComponent("movie-pixels.json"))
        print(String(data:diagnostic,encoding:.utf8)!)
        for (name,data) in [("baseline",baseline),("dodgeBurned",white.rgba),("decoded",decoded[1])] {
            let image = try StudioSmudgeReplay.cgImage(.init(width:128,height:64,rgba:data))
            let dest = CGImageDestinationCreateWithURL(root.appendingPathComponent(name+".png") as CFURL,"public.png" as CFString,1,nil)!
            CGImageDestinationAddImage(dest,image,nil)
            try require(CGImageDestinationFinalize(dest),"Diagnostic PNG failed")
        }
        // H.264 chroma subsampling changes individual edge channels in both
        // frames. Judge all changed channels against the lossless reference,
        // and require the actual encoded no-effect frame to fail this oracle.
        let noEffectError = affected.map { abs(Int(decoded[0][$0])-Int(white.rgba[$0])) }.reduce(0,+)
        try require(affected.count >= 64 && expectedError * 3 < baselineError,
                    "H264 does not preserve the changed DodgeBurn region")
        try require(noEffectError * 3 >= baselineError,
                    "Negative control without DodgeBurn incorrectly passes the pixel oracle")
        print("PASS H264 changed-region oracle rejects actual encoded no-effect frame; changed channels=\(affected.count)")
        try output.cleanup()
        try require(!fm.fileExists(atPath:output.directory.path),"Movie cleanup failed")
        try require(vm.document == document,"Preview/export modified the user's original document")
        print("PASS real two-frame H264 MP4 reopens with correct timing effect pixels and owned-output cleanup")
        print("All 4 production \(mode.rawValue) surface groups passed; iOS gestures and runtime remain unverified")
    }
}
