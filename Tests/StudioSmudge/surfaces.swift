import AppKit
import SwiftUI
import AVFoundation
import ImageIO

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
            CVPixelBufferLockBaseAddress(buffer,.readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
            guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw SurfaceFailure.failed("No decoded pixels") }
            let width = CVPixelBufferGetWidth(buffer),height = CVPixelBufferGetHeight(buffer),row = CVPixelBufferGetBytesPerRow(buffer)
            try require(width == 128 && height == 64,"Movie dimensions changed")
            let bytes = address.assumingMemoryBound(to:UInt8.self)
            var rgba:[UInt8] = [];rgba.reserveCapacity(width*height*4)
            for y in 0..<height { for x in 0..<width {
                let i=y*row+x*4;rgba += [bytes[i+2],bytes[i+1],bytes[i],255]
            } }
            frames.append(rgba)
        }
        try require(reader.status == .completed,"Movie decode did not complete")
        let duration = try await asset.load(.duration)
        try require(abs(duration.seconds-0.5)<0.001,"Movie frame timing changed")
        return frames
    }
    static func main() async throws {
        setbuf(stdout,nil)
        let fm=FileManager.default, root=fm.temporaryDirectory.appendingPathComponent("sdi-smudge-surfaces-\(UUID().uuidString)")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let store=DeviceStorageManager(documentsDirectory:root.appendingPathComponent("Documents"),cachesDirectory:root.appendingPathComponent("Caches"))
        let vm=StudioViewModel(storage:store)
        let created=await vm.createProject(name:"Smudge surfaces",width:128,height:64,fps:4)
        try require(created,"Actual Studio creation failed")
        let red=DrawnElement(id:"red",tool:.rectangle,points:[.init(x:8,y:8),.init(x:64,y:56)],
            color:"#FF0000",width:1,opacity:1,layerID:vm.activeLayerID,shape:.init(fillColor:"#FF0000"))
        try require(vm.commitElement(red),"Actual source drawing failed")
        let before=vm.document
        let effect=DrawnElement(id:"smudge",tool:.smudge,points:[.init(x:60.5,y:32.5),.init(x:106.5,y:32.5)],
            color:"#0000FF",width:40,opacity:1,layerID:vm.activeLayerID,smudge:.init(strength:1))
        try require(vm.commitElement(effect),"Actual color drag commit failed")
        let document=vm.document
        let transparent=try raster(document,background:.transparent), white=try raster(document,background:.white)
        for point in [CGPoint(x:16,y:16),CGPoint(x:64,y:32),CGPoint(x:66,y:32),CGPoint(x:80,y:32),CGPoint(x:124,y:60)] {
            let sample=try StudioColorSamplingService.sample(document:document,frameID:document.activeFrameID,point:point)
            let index=(Int(point.y)*document.width+Int(point.x))*4
            try require(near([sample.red,sample.green,sample.blue],Array(white.rgba[index..<index+3])),"Eyedropper missed the actual effect pixels")
        }
        print("PASS real eyedropper samples post-smudge canvas color at source boundary effect and empty pixels")

        for allLayers in [false,true] {
            let capture=try StudioFillService.capture(document:document,frameID:document.activeFrameID,layerID:document.activeLayerID,
                point:.init(x:66,y:32),color:"#00FF00",opacity:1,settings:.init(),sampleAllLayers:allLayers)
            try require(near(Array(capture.rgba),allLayers ? white.rgba : straightRGBA(transparent.rgba)),"Bucket-fill capture omitted smudge or changed transparency")
        }
        print("PASS actual bucket fill reads identical post-effect transparent active-layer and white composite pixels")

        let view=StudioFrameThumbnail(vm:vm,frame:document.frames[0]).frame(width:128,height:64)
        let renderer=ImageRenderer(content:view);renderer.scale=1
        guard let image=renderer.cgImage else { throw SurfaceFailure.failed("Actual thumbnail view failed to render") }
        try require(near(try StudioSmudgeReplay.pixels(image).rgba,white.rgba),"Actual timeline thumbnail diverged from exported pixels")
        print("PASS actual SwiftUI timeline thumbnail renders the same smudged frame as PNG export")

        var movie=document
        movie.frames.insert(before.frames[0],at:0)
        // Whole-frame copies need globally unique editable identities.
        movie.frames[0]=AnimationFrame(id:"before",elements:[DrawnElement(id:"before-red",tool:red.tool,
            points:red.points,color:red.color,width:red.width,opacity:red.opacity,layerID:red.layerID,shape:red.shape)])
        try movie.validate()
        let output=try await StudioMovieExportService().export(snapshot:.init(document:movie,retainedAudioTracks:[],rasterDataByID:[:]),outputParent:root,background:.white)
        let decoded=try await decodeMovie(output.movieURL)
        try require(decoded.count == 2,"Actual MP4 dropped a frame")
        let baseline=try raster(before,background:.white).rgba
        for (actual,expected) in zip(decoded,[baseline,white.rgba]) {
            let difference=zip(actual,expected).reduce(0) { $0+abs(Int($1.0)-Int($1.1)) }
            try require(Double(difference)/Double(actual.count)<7,"Decoded H264 does not resemble the actual rendered frame")
        }
        let strongest=white.rgba.indices.max { abs(Int(white.rgba[$0])-Int(baseline[$0])) < abs(Int(white.rgba[$1])-Int(baseline[$1])) }!
        let expectedDelta=Int(white.rgba[strongest])-Int(baseline[strongest])
        let actualDelta=Int(decoded[1][strongest])-Int(decoded[0][strongest])
        try require(abs(expectedDelta)>40 && abs(actualDelta-expectedDelta)<28,"H264 lost or substituted the smudge's strongest real pixel change")
        try output.cleanup()
        try require(!fm.fileExists(atPath:output.directory.path),"Movie cleanup failed")
        try require(vm.document == document,"Preview/export modified the user's original document")
        print("PASS real two-frame H264 MP4 reopens with correct timing effect pixels and owned-output cleanup")
        print("All 4 production Smudge surface groups passed; iOS gestures and runtime remain unverified")
    }
}
