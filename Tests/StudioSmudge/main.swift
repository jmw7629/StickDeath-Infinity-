import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum TestFailure: Error { case failed(String), cancelled }
func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure.failed(message) }
}
func rejects(_ expected: StudioSmudge.Failure, _ work: () throws -> Void) throws {
    do { try work() } catch let error as StudioSmudge.Failure {
        try require(error == expected, "Wrong rejection: \(error)"); return
    }
    throw TestFailure.failed("Invalid input succeeded")
}
var passed = 0
func pass(_ text: String) { passed += 1; print("PASS \(text)") }
typealias Pixels = StudioSmudge.Pixels
typealias Point = StudioSmudge.Point
typealias Settings = StudioSmudge.Settings
func image(_ width: Int = 64, _ height: Int = 32, _ pixel: (Int,Int)->[UInt8]) throws -> Pixels {
    var result: [UInt8] = []
    for y in 0..<height { for x in 0..<width { result += pixel(x,y) } }
    return try Pixels(width:width,height:height,rgba:result)
}
func pixel(_ p: Pixels, _ x: Int, _ y: Int) -> [UInt8] {
    Array(p.rgba[((y*p.width+x)*4)..<((y*p.width+x)*4+4)])
}
func png(_ p: Pixels, _ destination: URL) throws {
    let provider = CGDataProvider(data: Data(p.rgba) as CFData)!
    let cg = CGImage(width:p.width,height:p.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:p.width*4,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    let output = CGImageDestinationCreateWithURL(destination as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(output,cg,nil); try require(CGImageDestinationFinalize(output),"PNG encoding")
    let source = CGImageSourceCreateWithURL(destination as CFURL,nil)!
    let decoded = CGImageSourceCreateImageAtIndex(source,0,nil)!
    try require(decoded.width == p.width && decoded.height == p.height,"PNG reopens with original dimensions")
    var reopened = [UInt8](repeating:0,count:p.rgba.count)
    let success = reopened.withUnsafeMutableBytes { bytes -> Bool in
        guard let context = CGContext(data:bytes.baseAddress,width:p.width,height:p.height,bitsPerComponent:8,
            bytesPerRow:p.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        context.draw(decoded,in:CGRect(x:0,y:0,width:p.width,height:p.height));return true
    }
    try require(success && zip(reopened,p.rgba).allSatisfy{abs(Int($0)-Int($1)) <= 1},"PNG roundtrip changes colors, coverage or orientation")
}
do {
    let split = try image { x,_ in x < 24 ? [255,0,0,255] : [0,0,255,255] }
    let path = [Point(x:20.5,y:16.5),Point(x:42.5,y:16.5)]
    let settings = Settings(diameter:16,strength:1,opacity:1)
    let result = try StudioSmudge.apply(to:split,path:path,settings:settings)
    try require(result != split,"Drag must change pixels")
    try require(pixel(result,25,16)[0] > 0 && pixel(result,25,16)[2] < 255,"Red crosses the source boundary")
    try require(pixel(result,25,0) == pixel(split,25,0),"Pixels outside footprint changed")
    try require(pixel(result,12,16) == pixel(split,12,16),"Pixels behind initial footprint changed")
    try require(result.rgba.enumerated().filter{$0.offset%4==3}.allSatisfy{$0.element==255},"Opaque interior gained alpha holes")
    try require(split == image { x,_ in x < 24 ? [255,0,0,255] : [0,0,255,255] },"Source was mutated")
    pass("real color drag crosses an edge and preserves source, coverage and outside pixels")

    let transparent = try image { x,_ in x < 24 ? [128,0,0,128] : [0,0,0,0] }
    let dragged = try StudioSmudge.apply(to:transparent,path:path,settings:settings)
    try require(pixel(dragged,25,16)[3] > 0 && pixel(dragged,25,16)[0] == pixel(dragged,25,16)[3],"Premultiplied color/alpha do not move together")
    try require(dragged.rgba.enumerated().filter{$0.offset%4==1 || $0.offset%4==2}.allSatisfy{$0.element==0},"Color not present in source was invented")
    let empty = try image { _,_ in [0,0,0,0] }
    try require(StudioSmudge.apply(to:empty,path:path,settings:settings) == empty,"Empty layer painted")
    let opaque = try image { _,_ in [255,0,0,255] }
    let edge = try StudioSmudge.apply(to:opaque,path:[.init(x:0.5,y:16.5),.init(x:8.5,y:16.5)],settings:settings)
    try require(pixel(edge,0,16)[3] < 255 && pixel(edge,0,16)[0] == pixel(edge,0,16)[3],"Canvas edge replicates border color instead of transparent outside")
    pass("transparent and partially covered pixels move without invented paint or halos")

    for value in [Settings(diameter:16,strength:0,opacity:1),Settings(diameter:16,strength:1,opacity:0)] {
        try require(StudioSmudge.apply(to:split,path:path,settings:value) == split,"Zero strength/opacity changes pixels")
    }
    try require(StudioSmudge.apply(to:split,path:[path[0]],settings:settings) == split,"A tap paints")
    try require(StudioSmudge.apply(to:split,path:[path[0],path[0]],settings:settings) == split,"Stationary input changes pixels")
    let weak = try StudioSmudge.apply(to:split,path:path,settings:Settings(diameter:16,strength:0.25,opacity:1))
    let small = try StudioSmudge.apply(to:split,path:path,settings:Settings(diameter:4,strength:1,opacity:1))
    try require(weak != result && small != result,"Size/strength settings do not affect pixels")
    try require(pixel(small,25,20) == pixel(split,25,20) && pixel(result,25,20) != pixel(split,25,20),"Brush size has no meaningful footprint")
    pass("diameter strength and zero/stationary operations have distinct real behavior")

    let crossed = path + [path[0],path[1]]
    let full = try StudioSmudge.apply(to:split,path:crossed,settings:settings)
    let half = try StudioSmudge.apply(to:split,path:crossed,settings:Settings(diameter:16,strength:1,opacity:0.5))
    for i in half.rgba.indices {
        try require(half.rgba[i] == UInt8(((Double(split.rgba[i])+Double(full.rgba[i]))/2).rounded()),"Opacity compounds instead of blending once")
    }
    pass("gesture opacity applies exactly once including self-crossings")

    // Single diameter-4 stamp centered on pixel(4,3), moves exactly0.5px.
    // Linear source red=20*x makes the center's bilinear golden exactly75.
    let ramp = try image(8,8) { x,_ in [UInt8(20*x),0,0,255] }
    let golden = try StudioSmudge.apply(to:ramp,path:[.init(x:4,y:3.5),.init(x:4.5,y:3.5)],
        settings:.init(diameter:4,strength:0.5,opacity:1))
    try require(pixel(golden,4,3) == [75,0,0,255],"Independent bilinear center golden")
    try require(pixel(golden,4,2) == [77,0,0,255],"Independent squared-falloff golden")
    try require(pixel(golden,4,1) == pixel(ramp,4,1),"Radius boundary golden")
    let mirror = try image(64,32) { x,y in pixel(split,63-x,y) }
    let mirroredResult = try StudioSmudge.apply(to:mirror,path:path.map{.init(x:64-$0.x,y:$0.y)},settings:settings)
    for y in 0..<32 { for x in 0..<64 {
        try require(pixel(mirroredResult,x,y) == pixel(result,63-x,y),"Read/write iteration introduces direction bias")
    } }
    let dense = (0...44).map{ Point(x:20.5+Double($0)*0.5,y:16.5) }
    try require(StudioSmudge.apply(to:split,path:dense,settings:settings) == result,"Input sampling density changes straight drag")
    pass("independent numeric goldens, reflection symmetry and touch-density invariance")

    for bad in [Settings(diameter:.nan),Settings(diameter:0),Settings(diameter:257),Settings(strength:-1),Settings(opacity:.infinity)] {
        try rejects(.invalidSettings) { _ = try StudioSmudge.apply(to:split,path:path,settings:bad) }
    }
    for bad in [[Point](),[.init(x:-1,y:0)],[.init(x:.nan,y:0)],Array(repeating:Point(x:0,y:0),count:4097)] {
        try rejects(.invalidPath) { _ = try StudioSmudge.apply(to:split,path:bad,settings:settings) }
    }
    try rejects(.invalidImage) { _ = try Pixels(width:Int.max,height:1,rgba:[]) }
    try rejects(.invalidImage) { _ = try Pixels(width:4096,height:4096,rgba:[]) }
    try rejects(.invalidImage) { _ = try Pixels(width:1,height:1,rgba:[255,0,0,10]) }
    let long = (0..<512).map{ Point(x:$0%2==0 ? 0 : 64,y:16) }
    try rejects(.workLimit) { _ = try StudioSmudge.apply(to:split,path:long,settings:.init(diameter:1)) }
    let huge = try image(512,512) { _,_ in [0,0,0,0] }
    let hugePath = (0..<40).map{ Point(x:$0%2==0 ? 128 : 384,y:256) }
    try rejects(.workLimit) { _ = try StudioSmudge.apply(to:huge,path:hugePath,settings:.init(diameter:256)) }
    pass("invalid settings paths images and excessive stamp/pixel workloads reject before output")

    let planned = try StudioSmudge.validateWork(width:8,height:8,
        path:[.init(x:4,y:3.5),.init(x:4.5,y:3.5)],settings:.init(diameter:4,strength:0.5))
    try require(planned.stampCount == 1 && planned.touchedPixels == 36,"Independent preflight work-count golden")
    try require(StudioSmudge.validateWork(width:64,height:32,path:path,settings:settings)
        == StudioSmudge.validateWork(width:64,height:32,path:dense,settings:settings),"Preflight depends on touch density")
    try require(StudioSmudge.validateWork(width:64,height:32,path:path,
        settings:.init(strength:0)) == .init(stampCount:0,touchedPixels:0),"Zero effect consumes a render budget")
    try rejects(.invalidImage) { _ = try StudioSmudge.validateWork(width:Int.max,height:1,path:path,settings:settings) }
    try rejects(.workLimit) { _ = try StudioSmudge.validateWork(width:512,height:512,path:hugePath,settings:.init(diameter:256)) }
    var preflightChecks=0
    do {
        _ = try StudioSmudge.validateWork(width:512,height:512,path:hugePath,settings:.init(diameter:256)) {
            preflightChecks+=1;if preflightChecks==2 { throw TestFailure.cancelled }
        }
        throw TestFailure.failed("Preflight cancellation ignored")
    } catch TestFailure.cancelled { try require(preflightChecks==2,"Preflight cancellation kept processing") }
    pass("allocation-free canonical preflight shares exact pixel-work bounds, identity and cancellation")

    for cutoff in [1,5,20,80] {
        var calls=0
        do {
            _ = try StudioSmudge.apply(to:split,path:path,settings:settings) {
                calls+=1; if calls==cutoff { throw TestFailure.cancelled }
            }
            throw TestFailure.failed("Cancellation ignored")
        } catch TestFailure.cancelled { try require(calls==cutoff,"Cancellation keeps processing") }
        try require(split == image { x,_ in x < 24 ? [255,0,0,255] : [0,0,255,255] },"Cancelled source mutated")
    }
    try require(StudioSmudge.apply(to:split,path:path,settings:settings) == result,"Cancelled invocation changes future results")
    let finalSettings = Settings(diameter:16,strength:1,opacity:0.5)
    var totalChecks = 0
    _ = try StudioSmudge.apply(to:split,path:path,settings:finalSettings) { totalChecks+=1 }
    for cutoff in [totalChecks-1,totalChecks] {
        var checks=0
        do {
            _ = try StudioSmudge.apply(to:split,path:path,settings:finalSettings) {
                checks+=1;if checks==cutoff { throw TestFailure.cancelled }
            }
            throw TestFailure.failed("Final opacity/publication cancellation ignored")
        } catch TestFailure.cancelled { try require(checks==cutoff,"Late cancellation kept processing") }
    }
    pass("cancellation before/during processing preserves original and allows deterministic recovery")

    let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
    try png(split,root.appendingPathComponent("before.png"))
    try png(result,root.appendingPathComponent("smudged.png"))
    try png(dragged,root.appendingPathComponent("transparent.png"))
    try png(image(32,32){x,y in [UInt8(x*7),UInt8(y*7),0,255]},root.appendingPathComponent("orientation.png"))
    pass("real ImageIO PNG files encode and reopen; these are operation fixtures, not native UI captures")
    print("All \(passed) smudge operation groups passed")
} catch { print("FAIL \(error)"); exit(1) }
