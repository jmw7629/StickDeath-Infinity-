import Foundation

private struct TestFailure: Error { let message: String }
@main @MainActor struct FillRegionTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw TestFailure(message: message) }
    }
    static func reject(_ failure: StudioFillRegion.Failure, _ body: () throws -> Void) throws {
        do { try body() } catch let error as StudioFillRegion.Failure { try require(error == failure,"Unexpected rejection"); return }
        throw TestFailure(message:"Expected rejection")
    }
    static func image(_ width: Int, _ height: Int, _ color: (Int,Int) -> [UInt8]) -> Data {
        var data = Data(); data.reserveCapacity(width*height*4)
        for y in 0..<height { for x in 0..<width { data.append(contentsOf:color(x,y)) } }
        return data
    }
    static func coverage(_ mask: StudioFillRegion.Mask) throws -> [UInt8] {
        var values = [UInt8](repeating:0,count:mask.width*mask.height), previousRow = -1, previousEnd = 0, count = 0
        for span in mask.spans {
            try require(span.row>=0 && span.row<mask.height && span.start>=0 && span.start<span.end && span.end<=mask.width && span.alpha>0,"Valid bounded span")
            try require(span.row>previousRow || (span.row==previousRow && span.start>=previousEnd),"Sorted nonoverlapping rows")
            for x in span.start..<span.end { values[span.row*mask.width+x]=span.alpha;count+=1 }
            previousRow=span.row;previousEnd=span.end
        }
        try require(count==mask.coveredPixels,"Factual covered-pixel count")
        return values
    }
    static func main() async throws {
        var passed=0
        func test(_ name:String,_ body:() throws->Void) throws { try body();passed+=1;print("PASS "+name) }
        let white:[UInt8]=[255,255,255,255], black:[UInt8]=[0,0,0,255]
        let hard = StudioFillRegion.Settings(tolerance:0,antiAlias:false)
        let box=image(9,9) { x,y in ((x==1 || x==7) && (1...7).contains(y)) || ((y==1 || y==7) && (1...7).contains(x)) ? black:white }
        func fill(_ image:Data,_ w:Int,_ h:Int,_ x:Int,_ y:Int,_ settings:StudioFillRegion.Settings=StudioFillRegion.Settings(tolerance:0,antiAlias:false)) throws->StudioFillRegion.Mask {
            try StudioFillRegion.compute(rgba:image,width:w,height:h,x:x,y:y,settings:settings)
        }
        try test("closed outline contains the exact25-pixel interior and preserves source bytes") {
            let before=box, mask=try fill(box,9,9,4,4), values=try coverage(mask)
            try require(mask.coveredPixels==25 && mask.spans.count==5 && box==before,"Exact enclosed square/source ownership")
            try require(values[0]==0 && values[4*9+4]==255 && values[1*9+4]==0,"Interior excludes wall and outside")
        }
        try test("all-similar selects disconnected matching exterior too") {
            var settings=hard;settings.contiguous=false
            let mask=try fill(box,9,9,4,4,settings), values=try coverage(mask)
            try require(mask.coveredPixels==57 && values[0]==255 && values[1*9+4]==0,"All matching regions selected")
        }
        try test("four-neighbour connection does not jump across diagonal walls") {
            let diagonal=image(2,2) { x,y in x==y ? white:black }
            try require(try fill(diagonal,2,2,0,0).coveredPixels==1,"Diagonal regions disconnected")
        }
        try test("tolerance is inclusive and anchored to seed instead of color drift") {
            let ramp=image(5,1) { x,_ in [UInt8(x*10),0,0,255] }
            var settings=hard;settings.tolerance=20
            let mask=try fill(ramp,5,1,0,0,settings);try require(mask.coveredPixels==3,"No gradual color chase")
        }
        try test("alpha participates in tolerance and every supplied channel matters") {
            let ramp=image(3,1) { x,_ in [0,0,0,[UInt8(0),64,129][x]] }
            var settings=hard;settings.tolerance=64
            try require(try fill(ramp,3,1,0,0,settings).coveredPixels==2,"Alpha threshold respected")
        }
        let gap=image(9,9) { x,y in x==4 && y==1 ? white : Array(box[(y*9+x)*4..<(y*9+x)*4+4]) }
        try test("gap close seals the real one-pixel opening without changing original image") {
            try require(try fill(gap,9,9,4,4).coveredPixels==58,"Open gap reaches exterior")
            var settings=hard;settings.gapClose=1
            let mask=try fill(gap,9,9,4,4,settings)
            try require(mask.coveredPixels==25 && gap[(1*9+4)*4]==255,"Gap barrier is temporary and preserves source")
        }
        let island=image(9,9) { x,y in (3...5).contains(x) && (3...5).contains(y) ? white:black }
        try test("positive expansion grows exact square region") {
            var settings=hard;settings.expand=1
            try require(try fill(island,9,9,4,4,settings).coveredPixels==25,"One-pixel expansion in both axes")
        }
        try test("negative expansion shrinks and empty result rejects explicitly") {
            var settings=hard;settings.expand = -1
            try require(try fill(island,9,9,4,4,settings).coveredPixels==1,"One-pixel erosion")
            settings.expand = -2
            try reject(.emptyRegion) { _ = try fill(island,9,9,4,4,settings) }
        }
        try test("anti-alias produces real fractional coverage on a single-pixel boundary") {
            let point=image(5,5) { x,y in x==2 && y==2 ? white:black }
            var settings=hard;settings.antiAlias=true
            let mask=try fill(point,5,5,2,2,settings), values=try coverage(mask)
            try require(mask.coveredPixels==9 && values[12]==28 && values[6]==28 && values[0]==0,"Actual smooth boundary coverage")
        }
        try test("anti-alias keeps a full-canvas fill opaque up to all edges") {
            var settings=hard;settings.antiAlias=true
            let mask=try fill(image(7,4) { _,_ in white },7,4,0,0,settings)
            try require(try coverage(mask).allSatisfy{$0==255},"No artificial faded canvas border")
        }
        try test("shrinking honors the clipped canvas boundary") {
            var settings=hard;settings.expand = -1
            try require(try fill(image(7,4) { _,_ in white },7,4,0,0,settings).coveredPixels==10,"Erosion has outside-empty boundary")
        }
        try test("coordinates use top-left origin and remain deterministic") {
            let band=image(9,6) { x,y in (1...3).contains(x) && (1...4).contains(y) ? white:black }
            let one=try fill(band,9,6,2,2),two=try fill(band,9,6,2,2),values=try coverage(one)
            try require(one==two && one.coveredPixels==12 && values[1*9+1]==255 && values[4*9+3]==255 && values[1*9+5]==0,"Stable top-left region")
        }
        try test("invalid dimensions buffers coordinates and settings fail before a result") {
            try reject(.invalidImage) { _ = try fill(box,Int.max,9,0,0) }
            try reject(.invalidImage) { _ = try fill(box,9,Int.max,0,0) }
            try reject(.invalidImage) { _ = try fill(Data(box.dropLast()),9,9,0,0) }
            for (x,y) in [(-1,0),(0,-1),(9,0),(0,9)] { try reject(.outsideCanvas) { _ = try fill(box,9,9,x,y) } }
            for settings in [StudioFillRegion.Settings(tolerance:129),.init(expand:6),.init(gapClose:-1)] {
                try reject(.invalidSettings) { _ = try fill(box,9,9,4,4,settings) }
            }
        }
        try test("mid-operation cancellation returns no partial mask and leaves bytes intact") {
            var checkpoints=0,cancelled=false;let before=box
            do { _ = try StudioFillRegion.compute(rgba:box,width:9,height:9,x:4,y:4,settings:hard,checkCancellation:{
                checkpoints+=1;if checkpoints==4 {throw CancellationError()}
            }) } catch is CancellationError {cancelled=true}
            try require(cancelled && checkpoints==4 && box==before,"Cancellation reached bounded checkpoint")
        }
        try test("fragmented regions cannot exceed bounded returned span count") {
            let checker=image(1024,1024) { x,y in (x+y).isMultiple(of:2) ? white:black }
            var settings=hard;settings.contiguous=false
            try reject(.spanLimit) { _ = try fill(checker,1024,1024,0,0,settings) }
        }
        let task=Task { try fill(box,9,9,4,4) };task.cancel()
        var cancelled=false
        do { _ = try await task.value } catch is CancellationError {cancelled=true}
        try require(cancelled,"Actual cancelled Swift Task rejects before allocation")
        passed+=1;print("PASS actual Swift Task cancellation")
        print("STUDIO_FILL_REGION_CORE_TESTS=PASS \(passed)/\(passed)")
    }
}
