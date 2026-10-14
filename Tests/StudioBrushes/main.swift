import Foundation
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Compiles the whole production brush model/renderer and canonical StrokePoint.
// No copied renderer, mock brush geometry, asset textures or network requests.
private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(description: message) }
}

@main @MainActor struct StudioBrushTests {
    static let red = StudioBrushColor(red: 1, green: 0, blue: 0)
    static let blue = StudioBrushColor(red: 0, green: 0, blue: 1)
    static var groups = 0
    struct Raster {
        let image: CGImage
        let bytes: [UInt8]
        var inkCount: Int { stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0 + 3] > 16 }.count }
        var alphaSum: Int { stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) } }
        var peakAlpha: UInt8 { stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }.max() ?? 0 }
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * image.width + x) * 4..<(y * image.width + x) * 4 + 4]) }
    }
    static func raster(_ image: CGImage) throws -> Raster {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        try require(rendered, "Cannot decode native pixels")
        return Raster(image: image, bytes: bytes)
    }
    static func context(_ edge: Int = 256) throws -> CGContext {
        guard let context = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8,
            bytesPerRow: edge * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw Failure(description: "Cannot allocate test context")
        }
        return context
    }
    static func bitmap(_ geometry: StudioBrushRenderer.Geometry, edge: Int = 256, color: StudioBrushColor = StudioBrushColor(red:1,green:0,blue:0),
                       outerOpacity: Double = 1) throws -> Raster {
        let context = try context(edge); context.setAlpha(outerOpacity)
        // Raw CGContext bitmaps start with bottom-left user coordinates.
        context.translateBy(x: 0, y: CGFloat(edge)); context.scaleBy(x: 1, y: -1)
        try StudioBrushRenderer.draw(geometry, color: color, in: context)
        guard let image = context.makeImage() else { throw Failure(description: "No CoreGraphics image") }
        return try raster(image)
    }
    static func swiftUI(_ geometry: StudioBrushRenderer.Geometry, color: StudioBrushColor = StudioBrushColor(red:1,green:0,blue:0),
                        outerOpacity: Double = 1) throws -> Raster {
        var failure: Error?
        let canvas = Canvas { context, _ in
            context.opacity = outerOpacity
            do { try StudioBrushRenderer.draw(geometry, color: color, context: &context) }
            catch { failure = error }
        }.frame(width: 256, height: 256)
        let renderer = ImageRenderer(content: canvas); renderer.scale = 1
        guard let image = renderer.cgImage else { throw Failure(description: "No native SwiftUI image") }
        if let failure { throw failure }
        return try raster(image)
    }
    static func geometry(_ settings: StudioBrushSettings, points: [StrokePoint]? = nil, seed: UInt64 = 42) throws -> StudioBrushRenderer.Geometry {
        try StudioBrushRenderer.geometry(points: points ?? wave(), settings: settings, seed: seed)
    }
    static func wave() -> [StrokePoint] {
        (0...32).map { index in
            let x = Double(index) * 6 + 32
            return StrokePoint(x: x, y: 128 + sin(Double(index) / 5) * 32,
                               pressure: 0.5 + Double(index) / 64, timestamp: Double(index) / 60)
        }
    }
    static func line(pressure: Double? = 1, duration: Double? = 1) -> [StrokePoint] {
        let force: CGFloat? = pressure.map { CGFloat($0) }
        let startTime: TimeInterval? = duration == nil ? nil : 0
        return [StrokePoint(x: 32, y: 128, pressure: force, timestamp: startTime),
                StrokePoint(x: 224, y: 128, pressure: force, timestamp: duration)]
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch is StudioBrushError { return } catch is CancellationError { return }
        throw Failure(description: "Accepted invalid input: " + message)
    }
    static func pass(_ message: String) { groups += 1; print("PASS \(message)") }
    static func write(_ image: CGImage, _ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SDI_BRUSH_TEST_OUTPUT"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(description: "Cannot write brush evidence")
        }
        CGImageDestinationAddImage(destination, image, nil)
        try require(CGImageDestinationFinalize(destination), "Cannot encode brush evidence")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure(description: "Brush evidence PNG does not reopen")
        }
        try require(decoded.width == image.width && decoded.height == image.height, "Brush evidence dimensions changed")
    }
    static func main() {
        do {
            let families = StudioBrushFamily.allCases
            try require(families.count == 13, "Reference library entry missing")
            var rasters: [[UInt8]] = []
            for family in families {
                let settings = StudioBrushSettings(family: family, size: 16, gradientEndColor: family == .gradient ? blue : nil)
                let g = try geometry(settings), same = try geometry(settings)
                try require(g == same, "Geometry changes between replays: \(family)")
                let image = try bitmap(g)
                try require(image.inkCount > 20, "Family produces no visible ink: \(family)")
                try require(!rasters.contains(image.bytes), "Family matches an earlier renderer: \(family)")
                rasters.append(image.bytes)
                try require(image.bytes == bitmap(same).bytes, "Fixed seed pixels changed")
                try require(settings == JSONDecoder().decode(StudioBrushSettings.self, from: JSONEncoder().encode(settings)), "Settings roundtrip failed")
                try write(image.image, family.rawValue)
            }
            pass("all thirteen brush families have distinct visible native pixels, deterministic geometry/replay and Codable roundtrip")
            for family in [StudioBrushFamily.airbrush, .watercolor, .neon] {
                var low = StudioBrushSettings(family: family, size: 30, smoothing: 0, texture: 0)
                var high = low; high.texture = 1
                try require(bitmap(geometry(low)).bytes != bitmap(geometry(high)).bytes, "Family-specific Flow/Pigment/Glow does not affect pixels: \(family)")
                low.opacity = 0
                try require(bitmap(geometry(low)).alphaSum == 0, "New family ignores zero opacity")
            }
            var water = StudioBrushSettings(family: .watercolor, size: 30, smoothing: 0, grain: 0)
            let fineWater = try bitmap(geometry(water)); water.grain = 1
            try require(fineWater.bytes != bitmap(geometry(water)).bytes, "Watercolor grain does not change pigment pixels")
            let neon = try bitmap(geometry(StudioBrushSettings(family: .neon, size: 30, smoothing: 0), points: line()))
            let neonCore = neon.pixel(128,128)
            try require(neonCore[1] > 0 && neonCore[2] > 0 && neonCore[3] > 0, "Neon lacks its bright tinted core")
            pass("Airbrush Flow, Watercolor Pigment/Grain and Neon Glow/core alter real pixels with bounded shared geometry")

            // Airbrush Build-up (#142): measured dwell time adds real paint.
            let held = [StrokePoint(x:128,y:128,pressure:1,timestamp:0), StrokePoint(x:128,y:128,pressure:1,timestamp:0.5),
                        StrokePoint(x:128,y:128,pressure:1,timestamp:1)]
            var spray = StudioBrushSettings(family: .airbrush, size: 30, smoothing: 0, pressureEnabled: false)
            let dry = try geometry(spray, points: held)
            spray.buildup = 1
            let wet = try geometry(spray, points: held)
            try require(dry.sampledPointCount == 1, "Build-up 0 should keep a single held dab: \(dry.sampledPointCount)")
            try require(wet.sampledPointCount == 61, "One second at 60 dabs/s should add 60 dabs: \(wet.sampledPointCount)")
            try require(wet == (try geometry(spray, points: held)), "Build-up is not deterministic")
            let dryCentre = try bitmap(dry).pixel(128,128)[3], wetCentre = try bitmap(wet).pixel(128,128)[3]
            try require(Int(wetCentre) > Int(dryCentre) + 40, "Build-up does not accumulate paint: \(dryCentre) -> \(wetCentre)")
            spray.buildup = 0.25
            let quarter = try geometry(spray, points: held)
            try require(quarter.sampledPointCount == 16 && bitmap(quarter).pixel(128,128)[3] < wetCentre,
                        "Build-up amount does not scale accumulation: \(quarter.sampledPointCount)")
            spray.buildup = 1
            let longHold = [StrokePoint(x:128,y:128,pressure:1,timestamp:0), StrokePoint(x:128,y:128,pressure:1,timestamp:100)]
            try require(geometry(spray, points: longHold).sampledPointCount == 1 + StudioBrushRenderer.maximumBuildupDabsPerPosition,
                        "A long hold must saturate at the per-position cap instead of failing")
            var quickSpray = spray; quickSpray.buildup = 0
            try require(geometry(spray, points: line(duration: 0.02)) == geometry(quickSpray, points: line(duration: 0.02)),
                        "A quick stroke already pays its build-up debt and must be unchanged")
            try require(geometry(spray, points: line(duration: nil)) == geometry(quickSpray, points: line(duration: nil)),
                        "Untimed samples cannot invent dwell time")
            var roundBuild = solid0(); roundBuild.buildup = 1
            try require(geometry(roundBuild, points: held) == geometry(solid0(), points: held), "Build-up leaked into Round")
            pass("Airbrush Build-up accumulates measured dwell time, scales with the control, saturates boundedly and leaves quick/untimed strokes unchanged")

            // Watercolor Bleed (#142): pigment spreads past the brush edge.
            func outside(_ raster: Raster, radius: Double) -> Int {
                var count = 0
                for y in 0..<256 { for x in 0..<256 where raster.bytes[(y*256+x)*4+3] > 2 {
                    if hypot(Double(x) + 0.5 - 128, Double(y) + 0.5 - 128) > radius { count += 1 }
                } }
                return count
            }
            var wash = StudioBrushSettings(family: .watercolor, size: 30, smoothing: 0, pressureEnabled: false)
            let tap = [StrokePoint(x:128,y:128)]
            let contained = try bitmap(geometry(wash, points: tap))
            wash.bleed = 1
            let bled = try bitmap(geometry(wash, points: tap))
            try require(outside(bled, radius: 20) > outside(contained, radius: 20) + 40,
                        "Bleed does not spread pigment past the brush edge: \(outside(contained, radius: 20)) -> \(outside(bled, radius: 20))")
            try require(bled.bytes == (try bitmap(geometry(wash, points: tap))).bytes, "Bleed is not seeded deterministically")
            wash.bleed = 0.3
            let partial = try bitmap(geometry(wash, points: tap))
            try require(partial.bytes != bled.bytes && partial.bytes != contained.bytes, "Bleed amount has no distinct effect")
            var plainWash = wash; plainWash.bleed = 0
            try require(geometry(plainWash) == geometry(StudioBrushSettings(family: .watercolor, size: 30, smoothing: 0, pressureEnabled: false)),
                        "Bleed 0 changed historical watercolor geometry")
            pass("Watercolor Bleed spreads seeded pigment past the brush edge, scales with the control and keeps Bleed 0 historical pixels")

            // Neon Additive glow (#142): plus-lighter never darkens the backdrop.
            func overGray(_ geometry: StudioBrushRenderer.Geometry) throws -> (cg: [UInt8], ui: [UInt8]) {
                let backdrop = try Self.context()
                backdrop.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
                backdrop.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
                backdrop.translateBy(x: 0, y: 256); backdrop.scaleBy(x: 1, y: -1)
                try StudioBrushRenderer.draw(geometry, color: red, in: backdrop)
                guard let image = backdrop.makeImage() else { throw Failure(description: "No additive image") }
                var failure: Error?
                let canvas = Canvas { context, _ in
                    context.fill(Path(CGRect(x: 0, y: 0, width: 256, height: 256)), with: .color(Color(.sRGB, red: 0.5, green: 0.5, blue: 0.5, opacity: 1)))
                    do { try StudioBrushRenderer.draw(geometry, color: red, context: &context) } catch { failure = error }
                }.frame(width: 256, height: 256)
                let renderer = ImageRenderer(content: canvas); renderer.scale = 1
                guard let native = renderer.cgImage else { throw Failure(description: "No additive SwiftUI image") }
                if let failure { throw failure }
                let cgPixel = try raster(image).pixel(128, 136)
                let uiPixel = try raster(native).pixel(128, 136)
                return (cgPixel, uiPixel)
            }
            var tube = StudioBrushSettings(family: .neon, size: 30, smoothing: 0, pressureEnabled: false)
            let normalTube = try geometry(tube, points: line())
            tube.additiveGlow = true
            let additiveTube = try geometry(tube, points: line())
            try require(additiveTube.additiveGlow && !normalTube.additiveGlow && additiveTube.marks == normalTube.marks,
                        "Additive glow must change compositing only, not geometry")
            let normalHalo = try overGray(normalTube), additiveHalo = try overGray(additiveTube)
            for (name, plain, added) in [("CoreGraphics", normalHalo.cg, additiveHalo.cg), ("SwiftUI", normalHalo.ui, additiveHalo.ui)] {
                try require(plain[1] <= 120, "\(name) normal halo should cover the gray backdrop: \(plain)")
                try require(added[1] >= 125 && added[2] >= 125, "\(name) additive halo darkened the backdrop: \(added)")
                try require(Int(added[0]) > Int(plain[0]) + 5, "\(name) additive halo is not brighter: \(plain) -> \(added)")
            }
            var additiveRound = solid0(); additiveRound.additiveGlow = true
            try require(geometry(additiveRound, points: line()) == geometry(solid0(), points: line()), "Additive glow leaked into Round")
            pass("Neon Additive glow composites plus-lighter in both native renderers, brightening without darkening the backdrop")

            var encodedDefaults = String(decoding: try JSONEncoder().encode(StudioBrushSettings()), as: UTF8.self)
            try require(!encodedDefaults.contains("buildup") && !encodedDefaults.contains("bleed") && !encodedDefaults.contains("additiveGlow"),
                        "Historical settings JSON gained new keys: \(encodedDefaults)")
            let tuned = StudioBrushSettings(family: .airbrush, size: 12, buildup: 0.4, bleed: 0.2, additiveGlow: true)
            try require(tuned == (try JSONDecoder().decode(StudioBrushSettings.self, from: JSONEncoder().encode(tuned))), "New brush settings do not roundtrip")
            encodedDefaults = String(decoding: try JSONEncoder().encode(tuned), as: UTF8.self)
            try require(encodedDefaults.contains("buildup") && encodedDefaults.contains("additiveGlow"), "Changed settings were not persisted")
            for json in ["{\"buildup\":1.5}", "{\"bleed\":-0.1}", "{\"additiveGlow\":\"yes\"}"] {
                do { _ = try JSONDecoder().decode(StudioBrushSettings.self, from: Data(json.utf8)); throw Failure(description: "Invalid new setting accepted: \(json)") }
                catch is DecodingError {} catch is StudioBrushError {}
            }
            pass("Build-up, Bleed and Additive glow persist only when changed, roundtrip and reject out-of-range values")
            let defaults = try JSONDecoder().decode(StudioBrushSettings.self, from: Data("{}".utf8))
            try require(defaults == StudioBrushSettings(), "Explicit historical setting defaults changed")
            for json in ["{\"version\":2}", "{\"family\":\"missing\"}", "{\"size\":0}", "{\"family\":\"gradient\"}"] {
                do { _ = try JSONDecoder().decode(StudioBrushSettings.self, from: Data(json.utf8)); throw Failure(description: "Invalid JSON settings accepted") }
                catch is DecodingError {} catch is StudioBrushError {}
            }
            var invalid = defaults; invalid.opacity = .nan
            try rejects("NaN settings") { _ = try geometry(invalid) }
            invalid = defaults; invalid.gradientEndColor = StudioBrushColor(red: 2, green: 0, blue: 0)
            try rejects("color outside range") { _ = try geometry(invalid) }
            pass("versioned decode defaults and invalid settings reject without clamping")

            let solid = StudioBrushSettings(size: 24, smoothing: 0, pressureEnabled: false)
            var half = solid; half.opacity = 0.5
            let opaque = try geometry(solid, points: line()), translucent = try geometry(half, points: line())
            let fullPixel = try bitmap(opaque).pixel(128,128), halfPixel = try bitmap(translucent).pixel(128,128)
            try require(fullPixel == [255,0,0,255], "Opaque round center is wrong: \(fullPixel)")
            try require(abs(Int(halfPixel[3]) - 128) <= 1, "Overlapping dabs compound group opacity: \(halfPixel)")
            let nested = try bitmap(translucent, outerOpacity: 0.5).pixel(128,128)
            try require(abs(Int(nested[3]) - 64) <= 1, "Caller alpha was overwritten: \(nested)")
            var clear = solid; clear.opacity = 0
            try require(bitmap(geometry(clear, points: line())).alphaSum == 0, "Zero opacity rendered ink")
            pass("CoreGraphics group opacity applies once and multiplies caller opacity")
            let ui = try swiftUI(translucent).pixel(128,128)
            let uiNested = try swiftUI(translucent, outerOpacity: 0.5).pixel(128,128)
            try require(abs(Int(ui[3]) - 128) <= 1 && abs(Int(uiNested[3]) - 64) <= 1, "SwiftUI group alpha differs: \(ui), \(uiNested)")
            pass("actual SwiftUI GraphicsContext uses the same geometry with matching group opacity")
            for family in families {
                let settings = StudioBrushSettings(family:family,size:16,opacity:0.5,gradientEndColor:family == .gradient ? blue:nil)
                let g = try geometry(settings)
                let cg = try bitmap(g), native = try swiftUI(g)
                try require(cg.peakAlpha <= 129 && native.peakAlpha <= 129,"Family compounds brush opacity: \(family)")
                try require(cg.inkCount > 20 && native.inkCount > 20,"Family missing from a native rendering path: \(family)")
            }
            pass("every family uses the shared geometry in both native renderers and respects opacity cap")
            let translucentRed = StudioBrushColor(red:1,green:0,blue:0,alpha:0.5)
            for family in families {
                let endpoint = family == .gradient ? StudioBrushColor(red:0,green:0,blue:1,alpha:0.5):nil
                let settings = StudioBrushSettings(family:family,size:16,opacity:0.6,gradientEndColor:endpoint)
                let g = try geometry(settings)
                let cg = try bitmap(g,color:translucentRed), native = try swiftUI(g,color:translucentRed)
                try require(cg.peakAlpha <= 77 && native.peakAlpha <= 77,"RGBA alpha compounds with overlapping dabs: \(family)")
                try require(cg.inkCount > 10 && native.inkCount > 10,"Translucent color removed visible brush output: \(family)")
            }
            for (brushOpacity, outer, expected) in [(1.0,1.0,128),(0.5,1.0,64),(0.5,0.5,32)] {
                var settings = solid; settings.opacity = brushOpacity
                let g = try geometry(settings,points:line())
                let cg = try bitmap(g,color:translucentRed,outerOpacity:outer).pixel(128,128)
                let native = try swiftUI(g,color:translucentRed,outerOpacity:outer).pixel(128,128)
                try require(abs(Int(cg[3])-expected) <= 1 && abs(Int(native[3])-expected) <= 1,"Paint/brush/caller alpha did not multiply once")
            }
            pass("RGBA paint alpha, brush opacity and caller opacity each apply once in both native engines")
            var mismatched = solid; mismatched.family = .gradient
            mismatched.gradientEndColor = StudioBrushColor(red:0,green:0,blue:1,alpha:0.25)
            let invalidGradient = try geometry(mismatched,points:line())
            let noPaint = try context()
            try rejects("unequal gradient alpha") { try StudioBrushRenderer.draw(invalidGradient,color:translucentRed,in:noPaint) }
            guard let unpainted = noPaint.makeImage() else { throw Failure(description:"Missing gradient-failure image") }
            try require(raster(unpainted).alphaSum == 0,"Invalid gradient partially changed the bitmap")
            try rejects("unequal SwiftUI gradient alpha") { _ = try swiftUI(invalidGradient,color:translucentRed) }
            var retainedEndpoint = solid
            retainedEndpoint.gradientEndColor = StudioBrushColor(red:0,green:0,blue:1,alpha:0.25)
            let stillRound = try geometry(retainedEndpoint,points:line())
            try require(stillRound == opaque,"Unused retained gradient settings changed Round geometry")
            try require(bitmap(stillRound,color:translucentRed).bytes == bitmap(opaque,color:translucentRed).bytes,
                        "Round applied retained gradient RGB/alpha")
            pass("variable-alpha gradient explicitly fails before drawing; equal endpoint alpha remains supported")
            let asymmetric = try geometry(solid,points:[StrokePoint(x:30,y:40)])
            let cgLocation = try bitmap(asymmetric), uiLocation = try swiftUI(asymmetric)
            for image in [cgLocation,uiLocation] {
                try require(image.pixel(30,40)[3] == 255,"Top-left sample rendered at the wrong native position")
                try require(image.pixel(30,216)[3] == 0 && image.pixel(226,40)[3] == 0,"Asymmetric sample was reflected")
            }
            try write(cgLocation.image,"asymmetric-cg-top-left"); try write(uiLocation.image,"asymmetric-swiftui")
            pass("asymmetric actual bitmap/SwiftUI coordinates agree with explicit top-left CGContext transform")

            var pressure = solid; pressure.pressureEnabled = true
            let low = try geometry(pressure, points: line(pressure:0.1)), high = try geometry(pressure, points:line(pressure:1))
            try require(bitmap(high).alphaSum > bitmap(low).alphaSum * 2, "Pressure does not change footprint")
            try require(geometry(solid, points:line(pressure:0.1)) == geometry(solid, points:line(pressure:1)), "Disabled pressure changes output")
            try require(geometry(pressure, points:line(pressure:nil)) == high, "Missing pressure does not use neutral full pressure")
            pass("pressure changes real geometry, disabled pressure ignores force, and missing force has explicit neutral behavior")
            let pressureTap = [StrokePoint(x:128,y:128,pressure:0.1),StrokePoint(x:128,y:128,pressure:1),StrokePoint(x:128,y:128,pressure:0.1)]
            try require(bitmap(geometry(pressure,points:pressureTap)).alphaSum > bitmap(geometry(pressure,points:[pressureTap[0]])).alphaSum * 2,
                        "Stationary force changes were discarded")
            try require(geometry(solid,points:pressureTap) == geometry(solid,points:[pressureTap[0]]),"Disabled stationary force changes the stroke")
            pass("stationary stylus pressure changes render and stay ignored when pressure is disabled")
            var small = solid; small.size = 6
            try require(bitmap(opaque).alphaSum > bitmap(geometry(small,points:line())).alphaSum * 2, "Size only changes label")
            pass("size changes actual stroke coverage")
            var jitter: [StrokePoint] = []
            for index in 0..<24 {
                let x = CGFloat(32 + index * 8)
                let y: CGFloat = index % 2 == 0 ? 100 : 150
                jitter.append(StrokePoint(x:x,y:y))
            }
            var smooth = solid; smooth.smoothing = 10
            let raw = try geometry(solid,points:jitter), smoothed = try geometry(smooth,points:jitter)
            try require(raw.marks != smoothed.marks && bitmap(raw).bytes != bitmap(smoothed).bytes, "Smoothing has no pixel effect")
            let end = try requireLast(smoothed.marks)
            try require(end.x == Double(jitter.last!.x) && end.y == Double(jitter.last!.y), "Smoothing drops final endpoint")
            pass("smoothing changes the actual jittered path while preserving its final endpoint")

            var nib = solid; nib.family = .calligraphy; nib.tipAngleDegrees = 0
            let flat = try geometry(nib,points:[StrokePoint(x:128,y:128)])
            nib.tipAngleDegrees = 90
            let upright = try geometry(nib,points:[StrokePoint(x:128,y:128)])
            try require(bitmap(flat).bytes != bitmap(upright).bytes, "Tip angle has no native pixel effect")
            var dip = solid; dip.family = .dipPen
            let slow = try geometry(dip,points:line(duration:2)), fast = try geometry(dip,points:line(duration:0.02))
            try require(Double(bitmap(slow).alphaSum) > Double(bitmap(fast).alphaSum) * 1.5, "Measured velocity does not change dip nib")
            try require(geometry(dip,points:line(duration:nil)) == geometry(dip,points:line(duration:nil)), "Missing velocity nondeterministic")
            pass("calligraphy angle and dip-pen measured speed affect native rendering")
            for family in [StudioBrushFamily.stipple,.grain,.roughPen] {
                var textured = solid; textured.family = family; textured.texture = 0; textured.grain = 0
                let plain = try geometry(textured)
                textured.texture = 1; textured.grain = 1
                let rich = try geometry(textured)
                try require(bitmap(plain).bytes != bitmap(rich).bytes, "Texture/grain has no effect: \(family)")
                try require(bitmap(rich).bytes != bitmap(geometry(textured,seed:43)).bytes, "Seed cannot vary texture: \(family)")
            }
            for family in [StudioBrushFamily.stipple,.grain] {
                var particle = solid; particle.family = family; particle.grain = 0
                let fine = try bitmap(geometry(particle)).bytes
                particle.grain = 1
                try require(fine != bitmap(geometry(particle)).bytes,"Grain setting alone has no effect: \(family)")
            }
            var rough = solid; rough.family = .roughPen; rough.texture = 0
            let smoothEdge = try bitmap(geometry(rough)).bytes
            rough.texture = 1
            try require(smoothEdge != bitmap(geometry(rough)).bytes,"Rough-pen texture alone has no effect")
            try require(StudioBrushRenderer.seed(for:"stroke-A") != StudioBrushRenderer.seed(for:"stroke-B"), "Stable IDs share a seed")
            pass("stochastic families honor explicit texture, grain and stable seed")
            var gradient = solid; gradient.family = .gradient; gradient.gradientEndColor = blue
            let grad = try geometry(gradient,points:line())
            try require(grad.marks.first?.colorMix == 0 && grad.marks.last?.colorMix == 1, "Gradient misses endpoint colors")
            let gradientRaster = try bitmap(grad)
            try require(gradientRaster.pixel(32,128)[0] > gradientRaster.pixel(32,128)[2], "Gradient start is not primary color")
            try require(gradientRaster.pixel(224,128)[2] > gradientRaster.pixel(224,128)[0], "Gradient end is not explicit color")
            pass("gradient traverses actual path length between explicit colors")

            let dense: [StrokePoint] = (0...192).map { index in StrokePoint(x:CGFloat(32+index),y:128,pressure:1,timestamp:Double(index)/192) }
            try require(bitmap(geometry(solid,points:dense)).bytes == bitmap(geometry(solid,points:line())).bytes,
                        "Straight stroke changes with sample-event density")
            try require(geometry(solid,points:[]).marks.isEmpty, "Empty stroke has marks")
            try require(bitmap(geometry(solid,points:[StrokePoint(x:128,y:128)])).inkCount > 20, "A tap cannot draw")
            pass("arc-length sampling is independent of straight-line event density; empty strokes and taps work")
            for bad in [StrokePoint(x:.nan,y:0),StrokePoint(x:0,y:.infinity),StrokePoint(x:1_000_001,y:0),
                        StrokePoint(x:0,y:0,pressure:1.1),StrokePoint(x:0,y:0,timestamp:-1)] {
                try rejects("invalid canonical sample") { _ = try geometry(solid,points:[bad]) }
            }
            try rejects("reversed timestamps") { _ = try geometry(solid,points:[StrokePoint(x:0,y:0,timestamp:2),StrokePoint(x:1,y:1,timestamp:1)]) }
            try rejects("too many input samples") { _ = try geometry(solid,points:Array(repeating:StrokePoint(x:0,y:0),count:100_001)) }
            try rejects("overlong geometry") { _ = try geometry(solid,points:[StrokePoint(x:0,y:0),StrokePoint(x:1_000_000,y:0)]) }
            let unchangedContext = try context()
            try rejects("invalid rendering color") {
                try StudioBrushRenderer.draw(opaque,color:StudioBrushColor(red:1,green:.infinity,blue:0),in:unchangedContext)
            }
            guard let untouched = unchangedContext.makeImage() else { throw Failure(description:"Missing failure-test image") }
            try require(raster(untouched).alphaSum == 0,"Invalid color partially drew into caller context")
            var repeatedPressure: [StrokePoint] = []
            for index in 0...StudioBrushRenderer.maximumDabs {
                repeatedPressure.append(StrokePoint(x:128,y:128,pressure:index % 2 == 0 ? 0.1:1))
            }
            try rejects("stationary pressure work limit") { _ = try geometry(pressure,points:repeatedPressure) }
            pass("invalid pressure/timing/coordinates and excessive work fail before rendering")
            var cancellationChecks = 0
            try rejects("cancellation") {
                _ = try StudioBrushRenderer.geometry(points:Array(repeating:StrokePoint(x:0,y:0),count:100_000),settings:solid,seed:1) {
                    cancellationChecks += 1; if cancellationChecks == 3 { throw CancellationError() }
                }
            }
            try require(cancellationChecks == 3, "Cancellation was ignored")
            pass("bounded generation checks cancellation without returning partial output")
            let started = Date()
            let maximumInput = try geometry(solid,points:Array(repeating:StrokePoint(x:128,y:128),count:100_000))
            var density = solid; density.family = .grain; density.size = 1
            let length = Double(StudioBrushRenderer.maximumDabs - 2) * 0.25
            let maximumGeometry = try geometry(density,points:[StrokePoint(x:0,y:128),StrokePoint(x:length,y:128)])
            try require(maximumInput.sampledPointCount == 1, "Duplicate samples generate unbounded dabs")
            try require(maximumGeometry.sampledPointCount <= StudioBrushRenderer.maximumDabs && maximumGeometry.marks.count <= StudioBrushRenderer.maximumMarks, "Geometry budget exceeded")
            _ = try bitmap(maximumGeometry)
            print("BRUSH_BOUND_METRICS marks=\(maximumGeometry.marks.count) markBytes=\(maximumGeometry.marks.count * MemoryLayout<StudioBrushRenderer.Mark>.stride) elapsed=\(Date().timeIntervalSince(started))s")
            pass("100k input samples and near-limit dense rendering remain within explicit work/memory bounds")
            print("STUDIO_BRUSH_TESTS=PASS \(groups) production geometry/pixel groups")
        } catch { print("STUDIO_BRUSH_TESTS=FAIL \(error)"); exit(1) }
    }
    static func solid0() -> StudioBrushSettings { StudioBrushSettings(size: 24, smoothing: 0, pressureEnabled: false) }
    static func requireLast(_ marks: [StudioBrushRenderer.Mark]) throws -> StudioBrushRenderer.Mark {
        guard let last = marks.last else { throw Failure(description:"Missing last mark") }; return last
    }
}
