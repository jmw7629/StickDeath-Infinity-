import Foundation

// Compiles the production gradient, selection-mask, wand-region and fill-region
// sources (#149, #153). Foundation only: real pixel buffers, no mocks, no
// network. Build:
//   swiftc -swift-version 5 -parse-as-library \
//     StickDeathInfinity/Services/StudioFillRegion.swift \
//     StickDeathInfinity/Services/StudioGradientFill.swift \
//     StickDeathInfinity/Services/StudioSelectionMask.swift \
//     Tests/StudioPixelTools/main.swift -o sdi-pixel-tools-tests
private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(description: message) }
}

@main struct StudioPixelToolTests {
    static var groups = 0
    static func pass(_ message: String) { groups += 1; print("PASS \(message)") }
    static func expectFailure<E: Error & Equatable>(_ expected: E, _ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch let error as E {
            try require(error == expected, "\(message): wrong error \(error)")
            return
        }
        throw Failure(description: "Accepted invalid input: " + message)
    }

    typealias G = StudioGradientFill
    static func stops(_ a: G.Color, _ b: G.Color) -> [G.Stop] { [G.Stop(location: 0, color: a), G.Stop(location: 1, color: b)] }
    static let black = G.Color(red: 0, green: 0, blue: 0), white = G.Color(red: 1, green: 1, blue: 1)
    static let red = G.Color(red: 1, green: 0, blue: 0), green = G.Color(red: 0, green: 1, blue: 0)

    /// Straight RGBA canvas with a callback per pixel.
    static func image(_ width: Int, _ height: Int, _ pixel: (Int, Int) -> [UInt8]) -> Data {
        var bytes = [UInt8](); bytes.reserveCapacity(width * height * 4)
        for y in 0..<height { for x in 0..<width { bytes += pixel(x, y) } }
        return Data(bytes)
    }

    static func main() {
        do {
            try gradientTests()
            try selectionTests()
            try wandTests()
            try hitTests()
            print("STUDIO_PIXEL_TOOL_TESTS=PASS \(groups) production pixel groups")
        } catch { print("STUDIO_PIXEL_TOOL_TESTS=FAIL \(error)"); exit(1) }
    }

    static func gradientTests() throws {
        // Linear black -> white over transparent, no dither: exact ramp.
        let width = 101, height = 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var settings = G.Settings(start: .init(x: 0, y: 0), end: .init(x: Double(width), y: 0), stops: stops(black, white))
        settings.dither = false
        let result = try G.apply(to: &pixels, width: width, height: height, settings: settings)
        try require(result.changedPixels == width * height, "Opaque gradient should paint every pixel: \(result.changedPixels)")
        var previous = -1
        for x in 0..<width {
            let value = Int(pixels[x * 4])
            let expected = (Double(x) + 0.5) / Double(width) * 255
            try require(abs(Double(value) - expected) <= 1.01, "Linear ramp off at x=\(x): \(value) vs \(expected)")
            try require(value >= previous, "Linear ramp is not monotonic at x=\(x)")
            try require(pixels[x * 4 + 3] == 255 && pixels[x * 4] == pixels[x * 4 + 1] && pixels[x * 4 + 1] == pixels[x * 4 + 2],
                        "Gray ramp is not opaque/neutral at x=\(x)")
            try require(pixels[(3 * width + x) * 4] == pixels[x * 4], "Rows perpendicular to the gradient differ at x=\(x)")
            previous = value
        }
        // Positions beyond the endpoints clamp to the end colours.
        var wide = [UInt8](repeating: 0, count: 40 * 1 * 4)
        var clamp = G.Settings(start: .init(x: 10, y: 0), end: .init(x: 30, y: 0), stops: stops(red, green)); clamp.dither = false
        try G.apply(to: &wide, width: 40, height: 1, settings: clamp)
        try require(Array(wide[0..<4]) == [255, 0, 0, 255] && Array(wide[39 * 4..<40 * 4]) == [0, 255, 0, 255], "Endpoints do not clamp")
        pass("linear gradient paints an exact monotonic ramp along its axis and clamps beyond the endpoints")

        // Radial: centre equals start colour, outside the radius equals end.
        var disc = [UInt8](repeating: 0, count: 64 * 64 * 4)
        var radial = G.Settings(shape: .radial, start: .init(x: 32, y: 32), end: .init(x: 52, y: 32), stops: stops(white, black)); radial.dither = false
        try G.apply(to: &disc, width: 64, height: 64, settings: radial)
        func px(_ buffer: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> [UInt8] { Array(buffer[(y * w + x) * 4..<(y * w + x) * 4 + 4]) }
        try require(px(disc, 64, 31, 31)[0] >= 240 && px(disc, 64, 31, 31)[0] >= px(disc, 64, 41, 31)[0], "Radial centre is not the start colour: \(px(disc, 64, 31, 31))")
        try require(px(disc, 64, 0, 0) == [0, 0, 0, 255], "Radial outside is not the end colour")
        try require(px(disc, 64, 41, 31)[0] == px(disc, 64, 31, 41)[0] && px(disc, 64, 41, 31)[0] == px(disc, 64, 22, 31)[0],
                    "Radial gradient is not rotationally symmetric")
        try require(px(disc, 64, 41, 31)[0] > 100 && px(disc, 64, 41, 31)[0] < 160, "Radial midpoint is wrong: \(px(disc, 64, 41, 31))")
        pass("radial gradient is centred, symmetric and clamps outside its radius")

        // Coverage limits painting; unselected pixels stay byte-identical.
        var canvas = [UInt8](repeating: 0, count: 8 * 8 * 4)
        for i in stride(from: 0, to: canvas.count, by: 4) { canvas[i] = 10; canvas[i + 1] = 20; canvas[i + 2] = 30; canvas[i + 3] = 255 }
        let before = canvas
        var coverage = [UInt8](repeating: 0, count: 64)
        for y in 2..<6 { for x in 2..<4 { coverage[y * 8 + x] = 255 } ; for x in 4..<6 { coverage[y * 8 + x] = 128 } }
        var solidRed = G.Settings(start: .init(x: 0, y: 0), end: .init(x: 8, y: 0), stops: stops(red, red)); solidRed.dither = false
        let limited = try G.apply(to: &canvas, width: 8, height: 8, coverage: coverage, settings: solidRed)
        try require(limited.changedPixels == 16 && limited.minX == 2 && limited.minY == 2 && limited.maxX == 6 && limited.maxY == 6,
                    "Coverage bounds/count wrong: \(limited)")
        for index in 0..<64 where coverage[index] == 0 {
            try require(Array(canvas[index * 4..<index * 4 + 4]) == Array(before[index * 4..<index * 4 + 4]), "Unselected pixel \(index) changed")
        }
        try require(px(canvas, 8, 2, 2) == [255, 0, 0, 255], "Fully selected pixel is not the gradient colour: \(px(canvas, 8, 2, 2))")
        let halfway = px(canvas, 8, 4, 2) // 128/255 red over (10,20,30)
        try require(abs(Int(halfway[0]) - 133) <= 1 && abs(Int(halfway[1]) - 10) <= 1 && halfway[3] == 255, "Partial coverage blend wrong: \(halfway)")
        pass("selection coverage limits the gradient; unselected pixels are byte-identical and partial coverage blends proportionally")

        // Layer alpha lock: transparent pixels stay transparent, alpha kept.
        var locked = [UInt8](repeating: 0, count: 3 * 1 * 4)
        locked[4] = 0; locked[5] = 0; locked[6] = 128; locked[7] = 128     // half-alpha blue
        locked[8] = 255; locked[9] = 255; locked[10] = 255; locked[11] = 255 // opaque white
        var atop = G.Settings(start: .init(x: 0, y: 0), end: .init(x: 3, y: 0), stops: stops(red, red)); atop.dither = false; atop.preserveTransparency = true
        try G.apply(to: &locked, width: 3, height: 1, settings: atop)
        try require(Array(locked[0..<4]) == [0, 0, 0, 0], "Alpha lock painted a transparent pixel")
        try require(Array(locked[4..<8]) == [128, 0, 0, 128], "Alpha lock changed coverage of a half-alpha pixel: \(Array(locked[4..<8]))")
        try require(Array(locked[8..<12]) == [255, 0, 0, 255], "Alpha lock did not recolour opaque paint")
        pass("alpha-locked gradient recolours existing paint only and preserves every pixel's alpha")

        // Opacity, interpolation space and dithering are real controls.
        var over = [UInt8](repeating: 255, count: 4)
        var halfOpacity = G.Settings(start: .init(x: 0, y: 0), end: .init(x: 1, y: 0), stops: stops(black, black)); halfOpacity.opacity = 0.5; halfOpacity.dither = false
        try G.apply(to: &over, width: 1, height: 1, settings: halfOpacity)
        try require(abs(Int(over[0]) - 128) <= 1 && over[3] == 255, "Opacity does not scale the gradient: \(over)")
        let srgbMid = G.color(at: 0.5, settings: G.Settings(start: .init(x: 0, y: 0), end: .init(x: 1, y: 0), stops: stops(red, green)))
        let linearMid = G.color(at: 0.5, settings: G.Settings(start: .init(x: 0, y: 0), end: .init(x: 1, y: 0), stops: stops(red, green), interpolation: .linearLight))
        try require(abs(srgbMid.green - 0.5) < 0.001 && linearMid.green > srgbMid.green + 0.15,
                    "Linear-light interpolation does not brighten the complement midpoint: \(srgbMid) \(linearMid)")
        let multi = G.Settings(start: .init(x: 0, y: 0), end: .init(x: 1, y: 0),
                               stops: [G.Stop(location: 0, color: red), G.Stop(location: 0.5, color: white), G.Stop(location: 1, color: green)])
        try require(G.color(at: 0.5, settings: multi) == white && G.color(at: 0.25, settings: multi).red == 1, "Middle stop is ignored")
        var ramp = G.Settings(start: .init(x: 0, y: 0), end: .init(x: 256, y: 0), stops: stops(black, G.Color(red: 0.1, green: 0.1, blue: 0.1)))
        ramp.dither = false
        var plain = [UInt8](repeating: 0, count: 256 * 4 * 4)
        try G.apply(to: &plain, width: 256, height: 4, settings: ramp)
        ramp.dither = true
        var dithered = [UInt8](repeating: 0, count: 256 * 4 * 4), again = dithered
        try G.apply(to: &dithered, width: 256, height: 4, settings: ramp)
        try G.apply(to: &again, width: 256, height: 4, settings: ramp)
        try require(dithered == again, "Dither is not deterministic")
        try require(dithered != plain, "Dither had no effect on a shallow ramp")
        try require(zip(dithered, plain).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "Dither moved a value by more than one level")
        let plainSum = stride(from: 0, to: plain.count, by: 4).reduce(0) { $0 + Int(plain[$1]) }
        let ditherSum = stride(from: 0, to: dithered.count, by: 4).reduce(0) { $0 + Int(dithered[$1]) }
        try require(abs(plainSum - ditherSum) <= 64, "Dither changed average brightness: \(plainSum) vs \(ditherSum)")
        pass("opacity, sRGB/linear-light interpolation, multi-stop colours and deterministic ordered dither change real pixels")

        // Invalid input and cancellation leave the bitmap unchanged.
        let original = [UInt8](repeating: 7, count: 16 * 16 * 4)
        var target = original
        let good = G.Settings(start: .init(x: 0, y: 0), end: .init(x: 16, y: 0), stops: stops(red, green))
        var bad = good; bad.end = bad.start
        try expectFailure(G.Failure.degenerate, "zero-length gradient") { _ = try G.apply(to: &target, width: 16, height: 16, settings: bad) }
        bad = good; bad.stops = [G.Stop(location: 0, color: red)]
        try expectFailure(G.Failure.invalidSettings, "single stop") { _ = try G.apply(to: &target, width: 16, height: 16, settings: bad) }
        bad = good; bad.stops = [G.Stop(location: 0.8, color: red), G.Stop(location: 0.2, color: green)]
        try expectFailure(G.Failure.invalidSettings, "unsorted stops") { _ = try G.apply(to: &target, width: 16, height: 16, settings: bad) }
        bad = good; bad.opacity = .nan
        try expectFailure(G.Failure.invalidSettings, "NaN opacity") { _ = try G.apply(to: &target, width: 16, height: 16, settings: bad) }
        bad = good; bad.stops[1].color.green = 2
        try expectFailure(G.Failure.invalidSettings, "colour out of range") { _ = try G.apply(to: &target, width: 16, height: 16, settings: bad) }
        try expectFailure(G.Failure.invalidImage, "coverage size mismatch") {
            _ = try G.apply(to: &target, width: 16, height: 16, coverage: [UInt8](repeating: 255, count: 10), settings: good)
        }
        try expectFailure(G.Failure.invalidImage, "oversized canvas") {
            var huge = [UInt8](); _ = try G.apply(to: &huge, width: 5000, height: 5000, settings: good)
        }
        try expectFailure(G.Failure.emptyCoverage, "empty coverage") {
            _ = try G.apply(to: &target, width: 16, height: 16, coverage: [UInt8](repeating: 0, count: 256), settings: good)
        }
        var checks = 0
        do {
            _ = try G.apply(to: &target, width: 16, height: 16, settings: good) { checks += 1; if checks == 5 { throw CancellationError() } }
            throw Failure(description: "Cancellation was ignored")
        } catch is CancellationError {}
        try require(target == original, "A failed or cancelled gradient changed the bitmap")
        pass("degenerate/invalid gradients, bad coverage, empty selections and cancellation fail without touching pixels")

        // Gradient confined to a real fill region (bucket-style gradient).
        let regionImage = image(16, 8) { x, _ in x < 8 ? [255, 255, 255, 255] : [0, 0, 255, 255] }
        let region = try StudioFillRegion.compute(rgba: regionImage, width: 16, height: 8, x: 2, y: 2,
                                                  settings: StudioFillRegion.Settings(tolerance: 0, contiguous: true, expand: 0, gapClose: 0, antiAlias: false))
        let regionCoverage = try StudioSelectionMask.coverage(from: region)
        var layer = [UInt8](repeating: 0, count: 16 * 8 * 4)
        let painted = try G.apply(to: &layer, width: 16, height: 8, coverage: regionCoverage, settings: good)
        try require(painted.changedPixels == 64 && painted.maxX == 8, "Region gradient leaked past the fill region: \(painted)")
        try require(layer[(0 * 16 + 9) * 4 + 3] == 0, "Pixel outside the fill region was painted")
        pass("gradient confined to a computed fill region paints exactly that region")
    }

    static func selectionTests() throws {
        let width = 32, height = 32
        var square = [UInt8](repeating: 0, count: width * height)
        for y in 8..<24 { for x in 8..<24 { square[y * width + x] = 255 } }
        let sparse = try StudioSelectionMask.spans(of: square, width: width, height: height)
        try require(sparse.spans.count == 16 && sparse.coveredPixels == 256, "Sparse encoding wrong: \(sparse.spans.count)")
        try require(try StudioSelectionMask.coverage(from: sparse) == square, "Sparse mask does not roundtrip")
        let box = try StudioSelectionMask.bounds(of: square, width: width, height: height)
        try require(box.map { $0.minX == 8 && $0.minY == 8 && $0.maxX == 24 && $0.maxY == 24 } == true, "Selection bounds wrong")
        try require(try StudioSelectionMask.bounds(of: [UInt8](repeating: 0, count: 1024), width: width, height: height) == nil, "Empty bounds")
        pass("dense and sparse selection masks roundtrip with exact bounds")

        var other = [UInt8](repeating: 0, count: width * height)
        for y in 16..<32 { for x in 16..<32 { other[y * width + x] = 255 } }
        let added = try StudioSelectionMask.combine(square, other, mode: .add)
        let removed = try StudioSelectionMask.combine(square, other, mode: .subtract)
        let shared = try StudioSelectionMask.combine(square, other, mode: .intersect)
        func count(_ m: [UInt8]) -> Int { m.filter { $0 > 0 }.count }
        try require(count(added) == 256 + 256 - 64 && count(removed) == 256 - 64 && count(shared) == 64, "Mode arithmetic wrong")
        try require(removed[20 * width + 20] == 0 && removed[10 * width + 10] == 255 && shared[20 * width + 20] == 255, "Mode pixels wrong")
        try require(try StudioSelectionMask.combine(square, other, mode: .replace) == other, "Replace kept the old selection")
        try require(try StudioSelectionMask.combine(nil, other, mode: .subtract) == [UInt8](repeating: 0, count: 1024), "Subtract from nothing selected pixels")
        var half = [UInt8](repeating: 0, count: width * height); half[10 * width + 10] = 128
        try require(try StudioSelectionMask.combine(square, half, mode: .subtract)[10 * width + 10] == 127, "Feathered subtract is not proportional")
        try expectFailure(StudioSelectionMask.Failure.invalidMask, "mismatched combine") { _ = try StudioSelectionMask.combine(square, [0], mode: .add) }
        pass("New/Add/Subtract/Intersect combine real masks, including fractional feathered weights")

        let feathered = try StudioSelectionMask.feather(square, width: width, height: height, radius: 4)
        try require(feathered[16 * width + 16] == 255 && feathered[0] == 0, "Feather changed the interior or far exterior")
        let edge = Int(feathered[16 * width + 8])
        try require(edge > 90 && edge < 170, "Feather edge is not soft: \(edge)")
        var last = 256
        for x in 16..<32 {
            let value = Int(feathered[16 * width + x])
            try require(value <= last, "Feather is not monotonic outward at x=\(x)")
            last = value
        }
        try require(feathered[16 * width + 5] > 0 && feathered[16 * width + 9] < 255, "Feather does not spread both ways")
        try require(try StudioSelectionMask.feather(square, width: width, height: height, radius: 0) == square, "Radius 0 changed the mask")
        let wider = try StudioSelectionMask.feather(square, width: width, height: height, radius: 8)
        try require(wider[16 * width + 3] > feathered[16 * width + 3], "Feather radius has no effect")
        try expectFailure(StudioSelectionMask.Failure.invalidSettings, "feather radius") {
            _ = try StudioSelectionMask.feather(square, width: width, height: height, radius: 65)
        }
        pass("feather softens selection edges symmetrically and monotonically, scales with radius and is bounded")

        // Selection-limited effect: exact outside, exact inside, blended edge.
        var original = [UInt8](repeating: 0, count: width * height * 4), effected = original
        var seed: UInt64 = 0x5d1
        for index in 0..<(width * height) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let alpha = UInt8(truncatingIfNeeded: seed >> 56)
            let value = UInt8(Int((seed >> 40) & 0xff) % (Int(alpha) + 1))
            original[index * 4] = value; original[index * 4 + 1] = value / 2; original[index * 4 + 2] = alpha; original[index * 4 + 3] = alpha
            effected[index * 4] = alpha - value; effected[index * 4 + 1] = 0; effected[index * 4 + 2] = alpha / 3; effected[index * 4 + 3] = alpha
        }
        let clipped = try StudioSelectionMask.clip(original: original, effected: effected, coverage: feathered, width: width, height: height)
        for index in 0..<(width * height) {
            let o = index * 4, weight = feathered[index]
            let out = Array(clipped[o..<o + 4])
            if weight == 0 { try require(out == Array(original[o..<o + 4]), "Effect leaked outside the selection at \(index)") }
            if weight == 255 { try require(out == Array(effected[o..<o + 4]), "Effect missing inside the selection at \(index)") }
            for channel in 0..<3 { try require(out[channel] <= out[3], "Clipped pixel is not valid premultiplied RGBA at \(index)") }
        }
        try require(clipped != original && clipped != effected, "Clip had no blended edge")
        try expectFailure(StudioSelectionMask.Failure.invalidMask, "clip size mismatch") {
            _ = try StudioSelectionMask.clip(original: original, effected: [0], coverage: feathered, width: width, height: height)
        }
        pass("selection-limited effects keep unselected pixels exact, apply fully inside and blend valid premultiplied edges")
    }

    static func wandTests() throws {
        // White field, black ring, white island inside, light-gray patch, and
        // a transparent corner.
        let width = 48, height = 48
        let rgba = image(width, height) { x, y in
            if x < 4 && y < 4 { return [0, 0, 0, 0] }
            let d = hypot(Double(x) - 24, Double(y) - 24)
            if d >= 10 && d < 13 { return [0, 0, 0, 255] }
            if x >= 40 && y >= 40 { return [210, 210, 210, 255] }
            return [255, 255, 255, 255]
        }
        func count(_ m: [UInt8]) -> Int { m.filter { $0 > 0 }.count }
        var settings = StudioWandRegion.Settings(); settings.tolerance = 10
        let outer = try StudioWandRegion.select(rgba: rgba, width: width, height: height, x: 2, y: 30, settings: settings, previous: nil)
        try require(outer[24 * width + 24] == 0 && outer[30 * width + 2] == 255, "Contiguous wand crossed the ring")
        try require(outer[44 * width + 44] == 0, "Tolerance 10 included the gray patch")
        settings.contiguous = false
        let global = try StudioWandRegion.select(rgba: rgba, width: width, height: height, x: 2, y: 30, settings: settings, previous: nil)
        try require(global[24 * width + 24] == 255 && count(global) > count(outer), "Global sampling missed the enclosed island")
        settings.contiguous = true; settings.tolerance = 60
        let loose = try StudioWandRegion.select(rgba: rgba, width: width, height: height, x: 2, y: 30, settings: settings, previous: nil)
        try require(loose[44 * width + 44] == 255 && loose[24 * width + 24] == 0, "Tolerance 60 should reach the gray patch only")
        pass("wand tolerance and contiguous/global sampling select real colour-connected regions of a drawing surface")

        settings.tolerance = 10
        try expectFailure(StudioSelectionMask.Failure.transparentSeed, "transparent active-layer seed") {
            _ = try StudioWandRegion.select(rgba: rgba, width: width, height: height, x: 1, y: 1, settings: settings, previous: nil)
        }
        var composite = settings; composite.rejectTransparentSeed = false
        let clear = try StudioWandRegion.select(rgba: rgba, width: width, height: height, x: 1, y: 1, settings: composite, previous: nil)
        try require(count(clear) == 16, "Composited sampling should select the transparent corner exactly: \(count(clear))")
        var addMode = settings; addMode.mode = .add
        let island = try StudioWandRegion.select(rgba: rgba, width: width, height: height, x: 24, y: 24, settings: addMode, previous: outer)
        try require(island[24 * width + 24] == 255 && island[30 * width + 2] == 255, "Add mode lost a region")
        var subtractMode = settings; subtractMode.mode = .subtract
        let back = try StudioWandRegion.select(rgba: rgba, width: width, height: height, x: 24, y: 24, settings: subtractMode, previous: island)
        try require(back == outer, "Subtracting the island did not restore the earlier selection")
        var soft = settings; soft.feather = 3
        let feathered = try StudioWandRegion.select(rgba: rgba, width: width, height: height, x: 24, y: 24, settings: soft, previous: nil)
        try require(feathered.contains { $0 > 0 && $0 < 255 }, "Feathered wand has no soft edge")
        try expectFailure(StudioSelectionMask.Failure.invalidMask, "previous mask size") {
            _ = try StudioWandRegion.select(rgba: rgba, width: width, height: height, x: 2, y: 30, settings: settings, previous: [255])
        }
        var checks = 0
        do {
            _ = try StudioWandRegion.select(rgba: rgba, width: width, height: height, x: 2, y: 30, settings: settings, previous: nil) {
                checks += 1; if checks == 3 { throw CancellationError() }
            }
            throw Failure(description: "Wand cancellation ignored")
        } catch is CancellationError {}
        pass("wand rejects transparent active-layer seeds, samples the composite, adds/subtracts/feathers and honours cancellation")
    }

    static func hitTests() throws {
        let width = 64, height = 64
        var selection = [UInt8](repeating: 0, count: width * height)
        for y in 20..<40 { for x in 20..<40 { selection[y * width + x] = 255 } }
        typealias C = StudioSelectionElementHitTest.Candidate
        let inside = C(id: "inside", points: [(x: 25, y: 25), (x: 35, y: 35)], radius: 1)
        let outside = C(id: "outside", points: [(x: 2, y: 2), (x: 10, y: 60)], radius: 2)
        // Sparse samples whose straight segment crosses the selection.
        let crossing = C(id: "crossing", points: [(x: 0, y: 30.5), (x: 63, y: 30.5)], radius: 0.5)
        // Thick stroke whose edge, not centreline, touches the selection.
        let edge = C(id: "edge", points: [(x: 15, y: 0), (x: 15, y: 63)], radius: 6)
        let ids = try StudioSelectionElementHitTest.elements(intersecting: selection, width: width, height: height,
                                                             candidates: [inside, outside, crossing, edge])
        try require(ids == ["inside", "crossing", "edge"], "Element hit test wrong: \(ids)")
        var faint = selection; for i in faint.indices where faint[i] > 0 { faint[i] = 60 }
        try require(try StudioSelectionElementHitTest.elements(intersecting: faint, width: width, height: height, candidates: [inside]).isEmpty,
                    "Feathered pixels below the threshold selected an element")
        let strict = try StudioSelectionElementHitTest.elements(intersecting: selection, width: width, height: height,
                                                                candidates: [edge], minimumCoveredProbes: 200)
        try require(strict.isEmpty, "Minimum coverage requirement ignored")
        try expectFailure(StudioSelectionMask.Failure.invalidSettings, "NaN element point") {
            _ = try StudioSelectionElementHitTest.elements(intersecting: selection, width: width, height: height,
                                                           candidates: [C(id: "bad", points: [(x: .nan, y: 0)], radius: 1)])
        }
        try expectFailure(StudioSelectionMask.Failure.workLimit, "probe budget") {
            let huge = C(id: "huge", points: (0..<2_000).map { i -> (x: Double, y: Double) in (x: Double(i % 2) * 63, y: 32) }, radius: 512)
            _ = try StudioSelectionElementHitTest.elements(intersecting: [UInt8](repeating: 0, count: width * height), width: width, height: height,
                                                           candidates: [huge])
        }
        pass("wand selection maps to the editable drawn elements it touches, honouring stroke width, threshold and work limits")
    }
}
