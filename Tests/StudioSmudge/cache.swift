import AppKit
import SwiftUI
import ImageIO

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
enum CacheFailure: Error { case failed(String), cancelled }
@main @MainActor struct CacheTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw CacheFailure.failed(message) }
    }
    static func rejects(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw CacheFailure.failed("Invalid/cancelled render succeeded")
    }
    static func prepare(_ cache: StudioSmudgeReplay.Cache, _ d: StudioDocument,
                        live: DrawnElement? = nil, raster: Data? = nil) throws -> StudioSmudgeReplay.Prepared {
        try cache.prepare(frame:d.frames[0],layers:d.layers,
            canvasSize:.init(width:d.width,height:d.height),rasterData:raster,liveElement:live)
    }
    static func png(_ image: CGImage) throws -> Data {
        let data=NSMutableData()
        guard let target=CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil) else { throw CacheFailure.failed("PNG writer missing") }
        CGImageDestinationAddImage(target,image,nil)
        try require(CGImageDestinationFinalize(target),"PNG finalization failed")
        return data as Data
    }
    static func render(_ d:StudioDocument,_ p:StudioSmudgeReplay.Prepared,live:DrawnElement?=nil,raster:Data?=nil) throws -> CGImage {
        let size=CGSize(width:d.width,height:d.height);var failure:Error?
        let canvas=Canvas { context,actual in
            failure=StudioFrameRenderer.draw(context:&context,frame:d.frames[0],layers:d.layers,
                canvasSize:size,size:actual,rasterData:raster,liveElement:live,preparedSmudges:p)
        }.frame(width:size.width,height:size.height)
        let renderer=ImageRenderer(content:canvas);renderer.scale=1
        guard let image=renderer.cgImage else { throw CacheFailure.failed("Actual compositor unavailable") }
        if let failure { throw failure };return image
    }
    static func main() async throws {
        setbuf(stdout,nil)
        var document=try StudioDocument.new(name:"Cache pixel contract",width:64,height:32,fps:12)
        document.schemaVersion=17
        let red=DrawnElement(id:"source",tool:.rectangle,points:[.init(x:4,y:4),.init(x:24,y:28)],color:"#FF0000",width:1,opacity:1,
            layerID:document.activeLayerID,shape:.init(fillColor:"#FF0000"))
        let smudge=DrawnElement(id:"effect",tool:.smudge,points:[.init(x:20.5,y:16.5),.init(x:42.5,y:16.5)],color:"#0000FF",width:16,opacity:1,
            layerID:document.activeLayerID,smudge:.init(strength:1))
        document.frames[0].elements=[red,smudge];try document.validate()
        let cache=StudioSmudgeReplay.Cache(),first=try prepare(cache,document),second=try prepare(cache,document)
        try require(first.images["effect"] === second.images["effect"],"Unchanged input recomputed pixels")
        let expected=try StudioSmudgeReplay.prepare(frame:document.frames[0],layers:document.layers,canvasSize:.init(width:64,height:32),rasterData:nil)
        try require(try StudioSmudgeReplay.pixels(render(document,second)) == StudioSmudgeReplay.pixels(render(document,expected)),"Cache changed real composite pixels")
        print("PASS cache reuses the actual CGImage and matches uncached production-compositor pixels")

        var changed=document;changed.frames[0].elements[0].color="#00FF00";changed.frames[0].elements[0].shape?.fillColor="#00FF00"
        let green=try prepare(cache,changed)
        try require(first.images["effect"] !== green.images["effect"],"Same frame ID concealed source edits")
        try require(try StudioSmudgeReplay.pixels(render(changed,green)) != StudioSmudgeReplay.pixels(render(document,first)),"Changed source did not change rendered colors")
        try rejects { _ = try render(changed,first) }
        print("PASS same-ID source edits invalidate pixels and stale prepared output is rejected")

        var faded=document;faded.layers[0].opacity=0.25;let quarter=try prepare(cache,faded)
        try require(first.images["effect"] !== quarter.images["effect"],"Layer settings reused a stale context")
        let pixels=try StudioSmudgeReplay.pixels(render(faded,quarter))
        try require(abs(Int(pixels.rgba[(16*64+10)*4+3])-64)<=1,"Cached layer opacity is incorrect")
        faded.layers[0].visible=false;let hidden=try prepare(cache,faded)
        try require(try StudioSmudgeReplay.pixels(render(faded,hidden)).rgba.allSatisfy{$0==0},"Hidden artwork leaked from cache")
        var wider=document;wider.width=128;let resized=try prepare(cache,wider)
        try require(resized.images["effect"]?.width==128,"Canvas resize reused the wrong bitmap dimensions")
        print("PASS layer opacity visibility and resized canvas invalidate the exact render context")

        var live=DrawnElement(id:"live",tool:.smudge,points:[.init(x:24.5,y:16.5),.init(x:50.5,y:16.5)],
            color:smudge.color,width:smudge.width,opacity:smudge.opacity,layerID:smudge.layerID,smudge:smudge.smudge)
        let liveA=try prepare(cache,document,live:live);live.smudge?.strength=0.1
        let liveB=try prepare(cache,document,live:live)
        try require(liveA.images["live"] !== liveB.images["live"],"Live strength change reused stale pixels")
        try require(try StudioSmudgeReplay.pixels(liveA.images["live"]!) != StudioSmudgeReplay.pixels(liveB.images["live"]!),"Live input change did not affect actual effect pixels")
        try rejects { _ = try render(document,liveA,live:live) }
        try rejects { _ = try prepare(cache,document,live:smudge) }
        print("PASS live input settings invalidate pixels and duplicate IDs cannot enter through a cache hit")

        var source=document;source.frames[0].elements=[red]
        let originalPNG=try png(StudioExportService().render(source.frames[0],document:source,background:.transparent,raster:nil))
        source.frames[0].elements[0]=changed.frames[0].elements[0]
        let changedPNG=try png(StudioExportService().render(source.frames[0],document:source,background:.transparent,raster:nil))
        var imported=document;imported.frames[0].elements=[smudge];imported.frames[0].rasterAssetID="same-original-id";imported.frames[0].rasterLayerID=imported.activeLayerID
        imported.frames[0].rasterPlacement = .init(x:0,y:0,width:64,height:32)
        let importedA=try prepare(cache,imported,raster:originalPNG),importedB=try prepare(cache,imported,raster:changedPNG)
        try require(try StudioSmudgeReplay.pixels(importedA.images["effect"]!) != StudioSmudgeReplay.pixels(importedB.images["effect"]!),"Replacement PNG bytes reused the old original")
        try rejects { _ = try render(imported,importedA,raster:changedPNG) }
        print("PASS actual managed PNG byte changes invalidate the cache even with identical asset identity")

        let cost=first.images["effect"]!.bytesPerRow*32
        let limited=StudioSmudgeReplay.Cache(maximumEntries:2,maximumPayloadBytes:cost*2)
        let a=try prepare(limited,document),b=try prepare(limited,changed)
        _ = try prepare(limited,document);_ = try prepare(limited,wider)
        try require(limited.retainedPayloadBytes<=cost*2 && limited.entryCount<=2,"Cache exceeded its payload/entry bound")
        // The double-width frame consumes the entire budget, evicting both.
        let newA=try prepare(limited,document),newB=try prepare(limited,changed)
        try require(newA.images["effect"] !== a.images["effect"] && newB.images["effect"] !== b.images["effect"],"Budget eviction retained old images")
        let hit=try prepare(limited,document);_ = try prepare(limited,faded)
        try require(hit.images["effect"] === newA.images["effect"],"Retained entry was recomputed")
        var third=document;third.layers[0].name="Renamed layer"
        _ = try prepare(limited,third)
        let stillA=try prepare(limited,document),evictedB=try prepare(limited,changed)
        try require(stillA.images["effect"] === newA.images["effect"] && evictedB.images["effect"] !== newB.images["effect"],
            "Least-recently-used eviction discarded the recently viewed frame")
        print("PASS byte accounting and eviction honor bounded retention without changing output")

        let tooSmall=StudioSmudgeReplay.Cache(maximumPayloadBytes:cost-1)
        let largeA=try prepare(tooSmall,document),largeB=try prepare(tooSmall,document)
        try require(tooSmall.entryCount==0 && tooSmall.retainedPayloadBytes==0 && largeA.images["effect"] !== largeB.images["effect"],"Oversized result was retained")
        try require(try StudioSmudgeReplay.pixels(largeA.images["effect"]!) == StudioSmudgeReplay.pixels(first.images["effect"]!),"Uncached oversized output changed")
        let disabled=StudioSmudgeReplay.Cache(maximumEntries:0);_ = try prepare(disabled,document)
        try require(disabled.entryCount==0,"Disabled cache retained a frame")
        print("PASS oversized and disabled caching preserve correct pixels without retaining results")

        let beforeEntries=cache.entryCount,beforeBytes=cache.retainedPayloadBytes
        try rejects { _ = try cache.prepare(frame:imported.frames[0],layers:imported.layers,canvasSize:.init(width:64,height:32),rasterData:changedPNG,checkCancellation:{throw CacheFailure.cancelled}) }
        var polls=0
        try rejects { _ = try cache.prepare(frame:imported.frames[0],layers:imported.layers,canvasSize:.init(width:64,height:32),rasterData:changedPNG,checkCancellation:{polls+=1;if polls==2 {throw CacheFailure.cancelled}}) }
        try require(polls==2,"Cache hit skipped its final cancellation check")
        var invalid=document;invalid.frames[0].elements[1].smudge?.strength=2
        try rejects { _ = try prepare(cache,invalid) }
        try rejects { _ = try prepare(cache,imported,raster:Data([0,1,2])) }
        try require(cache.entryCount==beforeEntries && cache.retainedPayloadBytes==beforeBytes,"Cancelled or failed work mutated the cache")
        cache.clear();try require(cache.entryCount==0 && cache.retainedPayloadBytes==0,"Clear retained old entries")
        print("PASS cancellation and invalid input never poison cache; explicit clear releases retained entries")

        var stress=document;stress.width=1024;stress.height=512
        let timed=StudioSmudgeReplay.Cache();let start=ProcessInfo.processInfo.systemUptime
        let cold=try prepare(timed,stress);let coldSeconds=ProcessInfo.processInfo.systemUptime-start
        let warmStart=ProcessInfo.processInfo.systemUptime
        for _ in 0..<200 { let value=try prepare(timed,stress);try require(value.images["effect"] === cold.images["effect"],"Warm redraw rendered another bitmap") }
        let warmSeconds=ProcessInfo.processInfo.systemUptime-warmStart
        print("MEASURE 1024x512 cold replay \(coldSeconds)s; 200 unchanged redraws \(warmSeconds)s; retained payload \(timed.retainedPayloadBytes) bytes")
        print("All 8 cache correctness groups passed; measured warm reuse is not a native gesture or whole-app performance claim")
    }
}
