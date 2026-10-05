import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum TestFailure: Error { case failed(String), cancelled }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}
func fixture(_ width: Int = 64, _ height: Int = 48,
             _ color: (Int, Int) -> [UInt8]) throws -> StudioBlur.Pixels {
    var bytes: [UInt8] = []
    for y in 0..<height { for x in 0..<width { bytes += color(x,y) } }
    return try StudioBlur.Pixels(width: width, height: height, rgba: bytes)
}
func pixel(_ image: StudioBlur.Pixels, _ x: Int, _ y: Int, _ channel: Int = 0) -> Int {
    Int(image.rgba[(y*image.width+x)*4+channel])
}
func rejected(_ expected: StudioBlur.Failure, _ operation: () throws -> Void) throws {
    do { try operation(); throw TestFailure.failed("Expected \(expected)") }
    catch let failure as StudioBlur.Failure { try expect(failure == expected, "Wrong error: \(failure)") }
}
let source = try fixture { x,_ in x < 32 ? [0,0,0,255] : [255,255,255,255] }
let original = source.rgba
let tap = [StudioBlur.Point(x:32,y:24)]
let full = StudioBlur.Settings(diameter:32,hardness:1,radius:4,strength:1)
var groups = 0
func check(_ name: String, _ body: () throws -> Void) throws {
    try body(); groups += 1; print("PASS \(name)")
}

try check("Actual edge pixels; exact unaffected footprint; immutable original") {
    let output = try StudioBlur.apply(to:source,path:tap,settings:full)
    try expect(pixel(output,31,24) > 20 && pixel(output,31,24) < 128, "Dark edge did not soften")
    try expect(pixel(output,32,24) > 127 && pixel(output,32,24) < 235, "Light edge did not soften")
    for y in 0..<48 { for x in 0..<64 where hypot(Double(x)+0.5-32,Double(y)+0.5-24) >= 16 {
        for c in 0..<4 { try expect(pixel(output,x,y,c) == pixel(source,x,y,c), "Outside brush changed") }
    } }
    try expect(source.rgba == original, "Mutated input")
}
try check("Independent size hardness radius and strength change real output") {
    let baseline = try StudioBlur.apply(to:source,path:tap,settings:full)
    for settings in [StudioBlur.Settings(diameter:12,hardness:1,radius:4,strength:1),
                     StudioBlur.Settings(diameter:32,hardness:0,radius:4,strength:1),
                     StudioBlur.Settings(diameter:32,hardness:1,radius:1,strength:1),
                     StudioBlur.Settings(diameter:32,hardness:1,radius:4,strength:0.5)] {
        let result = try StudioBlur.apply(to:source,path:tap,settings:settings)
        try expect(result != baseline && result != source, "Setting has no actual effect")
    }
    var half = full; half.strength = 0.5
    let result = try StudioBlur.apply(to:source,path:tap,settings:half)
    for i in original.indices {
        try expect(abs(Int(result.rgba[i])*2-Int(original[i])-Int(baseline.rgba[i])) <= 1, "Strength not applied once")
    }
    half.strength = 0
    let zero = try StudioBlur.apply(to:source,path:tap,settings:half)
    try expect(zero == source, "Zero strength changes pixels")
}
try check("Canvas clamp and premultiplied transparency") {
    let plane = try fixture { _,_ in [32,64,96,128] }
    let output = try StudioBlur.apply(to:plane,path:[.init(x:0,y:0),.init(x:64,y:48)],settings:full)
    for i in plane.rgba.indices { try expect(abs(Int(output.rgba[i])-Int(plane.rgba[i])) <= 1, "Canvas border fades") }
    let transparent = try fixture { x,_ in x < 32 ? [128,0,0,128] : [0,0,0,0] }
    let spread = try StudioBlur.apply(to:transparent,path:tap,settings:full)
    try expect(pixel(spread,33,24,3) > 0, "Transparent artwork edge did not soften")
    for i in stride(from:0,to:spread.rgba.count,by:4) {
        try expect(spread.rgba[i] == spread.rgba[i+3] && spread.rgba[i+1] == 0 && spread.rgba[i+2] == 0,
                   "Transparency introduced color fringe")
    }
}
try check("Selection coverage and exact protection outside selection") {
    var selection = [UInt8](repeating:0,count:64*48)
    for y in 0..<48 { for x in 0..<32 { selection[y*64+x] = 128 } }
    let output = try StudioBlur.apply(to:source,path:tap,settings:full,selection:selection)
    let baseline = try StudioBlur.apply(to:source,path:tap,settings:full)
    for y in 0..<48 { for x in 32..<64 { for c in 0..<4 {
        try expect(pixel(output,x,y,c) == pixel(source,x,y,c), "Outside selection altered")
    } } }
    try expect(abs(pixel(output,31,24)-Int((Double(pixel(baseline,31,24))*128/255).rounded())) <= 1, "Partial selection coverage incorrect")
    let zero = try StudioBlur.apply(to:source,path:tap,settings:full,selection:[UInt8](repeating:0,count:64*48))
    try expect(zero == source, "Empty selection changes pixels")
    try rejected(.invalidSelection) { _ = try StudioBlur.apply(to:source,path:tap,settings:full,selection:[0]) }
}
try check("Uniform stroke sampling; repeated samples do not accumulate blur") {
    let sparse = [StudioBlur.Point(x:32,y:8),.init(x:32,y:40)]
    let dense = (8...40).map { StudioBlur.Point(x:32,y:Double($0)) }
    let a = try StudioBlur.apply(to:source,path:sparse,settings:full)
    let b = try StudioBlur.apply(to:source,path:dense,settings:full)
    let c = try StudioBlur.apply(to:source,path:tap+tap+tap,settings:full)
    let d = try StudioBlur.apply(to:source,path:tap,settings:full)
    try expect(a == b && c == d, "Input event density changes result")
}
try check("Asymmetric coordinates and real PNG round-trip") {
    let asymmetric = try fixture { x,y in y < 12 && x < 32 ? [255,0,0,255] : [0,0,0,255] }
    let output = try StudioBlur.apply(to:asymmetric,path:[.init(x:32,y:6)],settings:full)
    try expect(pixel(output,31,6) < 245 && pixel(output,32,6) > 5, "Brush processed wrong vertical region")
    try expect(pixel(output,31,42) == 0, "Reflected vertical coordinates")
    let space = CGColorSpace(name:CGColorSpace.sRGB)!
    let provider = CGDataProvider(data:Data(output.rgba) as CFData)!
    let image = CGImage(width:64,height:48,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:256,
        space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
        provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    let url = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("blur-roundtrip.png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,image,nil)
    try expect(CGImageDestinationFinalize(destination), "PNG did not finalize")
    let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL,nil)!,0,nil)!
    try expect(decoded.width == 64 && decoded.height == 48, "PNG dimensions changed")
    var bytes = [UInt8](repeating:0,count:64*48*4)
    bytes.withUnsafeMutableBytes { data in
        let context = CGContext(data:data.baseAddress,width:64,height:48,bitsPerComponent:8,bytesPerRow:256,
            space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(decoded,in:CGRect(x:0,y:0,width:64,height:48))
    }
    for i in bytes.indices { try expect(abs(Int(bytes[i])-Int(output.rgba[i])) <= 1,"PNG changed pixels/orientation") }
}
try check("Reject invalid values and excessive work before rendering") {
    try rejected(.invalidImage) { _ = try StudioBlur.Pixels(width:Int.max,height:2,rgba:[]) }
    try rejected(.invalidImage) { _ = try StudioBlur.Pixels(width:1,height:1,rgba:[255,0,0,0]) }
    for value in [Double.nan,Double.infinity,-1,257] {
        var settings = full; settings.diameter = value
        try rejected(.invalidSettings) { _ = try StudioBlur.apply(to:source,path:tap,settings:settings) }
    }
    for path in [[],[StudioBlur.Point(x:Double.nan,y:1)],[.init(x:-1,y:2)],Array(repeating:tap[0],count:4097)] {
        try rejected(.invalidPath) { _ = try StudioBlur.apply(to:source,path:path,settings:full) }
    }
    let zigzag = (0..<100).map { StudioBlur.Point(x:$0%2 == 0 ? 0 : 2048,y:1024) }
    try rejected(.workLimit) { _ = try StudioBlur.validateWork(width:2048,height:2048,path:zigzag,
        settings:.init(diameter:256,hardness:1,radius:4,strength:1)) }
    try rejected(.workLimit) { _ = try StudioBlur.validateWork(width:2048,height:2048,path:zigzag,
        settings:.init(diameter:1,hardness:1,radius:4,strength:1)) }
}
try check("Cancellation before work during mask and after native rendering") {
    var count = 0
    _ = try StudioBlur.apply(to:source,path:tap,settings:full,checkCancellation:{ count += 1 })
    for stop in [1,10,count-1,count] {
        var calls = 0, returned = false
        do {
            _ = try StudioBlur.apply(to:source,path:tap,settings:full,checkCancellation:{
                calls += 1; if calls == stop { throw TestFailure.cancelled }
            })
            returned = true
        } catch TestFailure.cancelled { }
        try expect(!returned && calls == stop, "Cancellation returned edited output")
        try expect(source.rgba == original, "Cancelled work mutated original")
    }
}
print("BLUR_CORE=PASS groups=\(groups)")
