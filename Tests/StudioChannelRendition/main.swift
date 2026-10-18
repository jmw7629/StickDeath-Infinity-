import Foundation

// Foundation-only verification of the official-channel mark placement and
// contrast rules (#241). Compositing pixels and the installed owner asset are
// verified natively; this suite proves the geometry for portrait, landscape and
// square outputs, the refusal paths and that personal exports carry no mark.

private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }

@main struct StudioChannelRenditionTests {
    static func main() {
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") } catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        typealias R = StudioChannelRendition

        test("only the channel copy carries the mark") {
            try require(R.Purpose.channelCopy.carriesChannelMark && !R.Purpose.personalExport.carriesChannelMark, "purpose rule")
            try require(R.markAssetName == "SDIChannelWatercolorMark", "asset name")
        }

        test("orientation classification") {
            try require(R.Orientation(width: 1080, height: 1920) == .portrait && R.Orientation(width: 1920, height: 1080) == .landscape
                && R.Orientation(width: 1080, height: 1080) == .square && R.Orientation(width: 1000, height: 1040) == .square, "orientations")
        }

        test("landscape 1920x1080: small, lower-right, inside the safe margin") {
            let rect = try R.placement(outputWidth: 1920, outputHeight: 1080, markWidth: 400, markHeight: 200)
            // 12% of 1080 = 129.6 → 130 wide, 65 high; margin 4% of 1080 = 43.
            try require(rect == .init(x: 1920 - 43 - 130, y: 1080 - 43 - 65, width: 130, height: 65), "rect \(rect)")
            try require(rect.maxX == 1877 && rect.maxY == 1037, "edges \(rect)")
        }

        test("portrait 1080x1920 sits above the vertical-video control band") {
            let rect = try R.placement(outputWidth: 1080, outputHeight: 1920, markWidth: 400, markHeight: 200)
            // 130 wide; right margin 5% of 1080 = 54; bottom margin 12% of 1920 = 230.
            try require(rect == .init(x: 1080 - 54 - 130, y: 1920 - 230 - 65, width: 130, height: 65), "rect \(rect)")
            try require(Double(1920 - rect.maxY) / 1920 >= 0.119, "bottom band kept clear")
        }

        test("square 1080x1080 and the logo aspect is preserved") {
            let rect = try R.placement(outputWidth: 1080, outputHeight: 1080, markWidth: 300, markHeight: 300)
            try require(rect == .init(x: 1080 - 43 - 130, y: 1080 - 43 - 130, width: 130, height: 130), "rect \(rect)")
            let tall = try R.placement(outputWidth: 1080, outputHeight: 1080, markWidth: 100, markHeight: 150)
            try require(tall.width == 130 && tall.height == 195, "aspect \(tall)")
        }

        test("size is clamped for very large outputs and the mark stays a small fraction") {
            let rect = try R.placement(outputWidth: 7680, outputHeight: 4320, markWidth: 400, markHeight: 200)
            try require(rect.width == R.maximumMarkWidth && rect.height == 120, "clamped \(rect)")
            for (w, h) in [(1280, 720), (720, 1280), (720, 720), (3840, 2160), (2160, 3840)] {
                let r = try R.placement(outputWidth: w, outputHeight: h, markWidth: 512, markHeight: 256)
                let area = Double(r.width * r.height) / Double(w * h)
                try require(area < 0.02 && r.x > w / 2 && r.y > h / 2 && r.maxX < w && r.maxY < h, "\(w)x\(h) placement \(r) area \(area)")
            }
        }

        test("outputs too small for a legible mark are refused, never marked off-screen") {
            for (w, h) in [(200, 200), (120, 640), (64, 64)] {
                do { _ = try R.placement(outputWidth: w, outputHeight: h, markWidth: 400, markHeight: 200); throw Failure(description: "\(w)x\(h) accepted") }
                catch R.Failure.outputTooSmall {}
            }
            do { _ = try R.placement(outputWidth: 1920, outputHeight: 1080, markWidth: 0, markHeight: 10); throw Failure(description: "empty mark accepted") }
            catch R.Failure.markInvalid {}
            // A pathologically tall logo cannot cover a third of the frame.
            do { _ = try R.placement(outputWidth: 1920, outputHeight: 1080, markWidth: 10, markHeight: 400); throw Failure(description: "tall mark accepted") }
            catch R.Failure.outputTooSmall {}
        }

        test("contrast rule adds a plate only when the picture under the mark is too close") {
            let white = R.relativeLuminance(red: 1, green: 1, blue: 1), black = R.relativeLuminance(red: 0, green: 0, blue: 0)
            try require(abs(white - 1) < 1e-9 && black == 0 && abs(R.contrastRatio(white, black) - 21) < 1e-9, "WCAG endpoints")
            let watercolorRed = R.relativeLuminance(red: 0.86, green: 0.15, blue: 0.15)
            try require(!R.needsBackingPlate(markLuminance: watercolorRed, backgroundLuminance: white), "red mark on white needs no plate")
            try require(R.needsBackingPlate(markLuminance: watercolorRed, backgroundLuminance: watercolorRed), "same tone needs a plate")
            try require(R.plateIsDark(markLuminance: white) && !R.plateIsDark(markLuminance: black), "plate tone opposes the mark")
        }

        test("mean luminance weights by alpha and ignores transparent pixels") {
            // Opaque white + fully transparent black → white.
            try require(R.meanLuminance(rgba: [255, 255, 255, 255, 0, 0, 0, 0], premultiplied: true).map { abs($0 - 1) < 1e-9 } == true, "transparent ignored")
            try require(R.meanLuminance(rgba: [0, 0, 0, 0], premultiplied: true) == nil, "fully transparent is nil")
            // Premultiplied half-alpha white (128,128,128,128) is white.
            try require(R.meanLuminance(rgba: [128, 128, 128, 128], premultiplied: true).map { abs($0 - 1) < 0.01 } == true, "premultiplied undone")
            try require(R.meanLuminance(rgba: [1, 2, 3], premultiplied: false) == nil, "malformed bytes")
        }

        test("a usable mark has transparent and visible pixels") {
            try require(R.hasTransparency(alpha: [0, 255, 128]) && !R.hasTransparency(alpha: [255, 255]) && !R.hasTransparency(alpha: [0, 0]), "alpha rule")
        }

        test("refusal messages are truthful and keep originals") {
            let text = R.Failure.markUnavailable.errorDescription ?? ""
            try require(text.contains("not installed") && text.contains("not prepared") && text.contains("unchanged"), text)
        }

        print("STUDIO_CHANNEL_RENDITION_TESTS=\(failed == 0 ? "PASS" : "FAIL") \(passed) passed \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
