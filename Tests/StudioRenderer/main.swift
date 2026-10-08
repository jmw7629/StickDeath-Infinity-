import AppKit
import SwiftUI

// macOS-only test adapter for UIKit's image container. The complete production
// StudioFrameRenderer.swift is compiled unchanged; there is no test renderer.
// These native SwiftUI pixel checks do not establish iOS UI or screenshot parity.
typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

@main @MainActor struct StudioRendererTests {
    private static func stroke(id: String, layer: String, color: String,
                               width: CGFloat = 30, opacity: Double = 1,
                               tool: DrawingTool = .brush) -> DrawnElement {
        DrawnElement(id: id, tool: tool,
                     points: [StrokePoint(x: 8, y: 32), StrokePoint(x: 56, y: 32)],
                     color: color, width: width, opacity: opacity, layerID: layer)
    }

    private static func centerPixel(layers: [CanvasLayer], elements: [DrawnElement],
                                    outerOpacity: Double = 1, onionPrevious: Bool? = nil, edge: Int = 64, sampleY: Int = 32, white: Bool = true) throws -> [UInt8] {
        let frame = AnimationFrame(id: "fixture", elements: elements)
        let canvas = Canvas { context, size in
            if white { context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white)) }
            context.opacity = outerOpacity
            if let onionPrevious { context = StudioFrameRenderer.onionContext(context, opacity: 1, previous: onionPrevious, tinted: true) }
            StudioFrameRenderer.draw(context: &context, frame: frame, layers: layers,
                                     canvasSize: CGSize(width: 64, height: 64), size: size)
        }.frame(width: CGFloat(edge), height: CGFloat(edge))
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1
        guard let image = renderer.cgImage else {
            throw Failure(description: "SwiftUI did not produce an image")
        }
        var bytes = [UInt8](repeating: 0, count: edge * edge * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: edge, height: edge,
                bitsPerComponent: 8, bytesPerRow: edge * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: edge, height: edge))
            return true
        }
        guard rendered else { throw Failure(description: "Could not decode rendered image pixels") }
        let offset = ((sampleY * edge / 64) * edge + edge / 2) * 4
        return Array(bytes[offset..<offset + 4])
    }

    private static func requirePixel(_ name: String, _ actual: [UInt8], _ expected: [UInt8]) throws {
        guard actual.count == expected.count,
              zip(actual, expected).allSatisfy({ abs(Int($0.0) - Int($0.1)) <= 1 }) else {
            throw Failure(description: "\(name): decoded RGBA \(actual), expected \(expected)")
        }
        print("PASS \(name): decoded RGBA \(actual)")
    }

    private static func textInkBounds(edge: Int) throws -> CGSize {
        let layer = CanvasLayer(id: "text", name: "Text")
        let element = DrawnElement(id: "label", tool: .text,
            points: [StrokePoint(x: 64, y: 64)], color: "#000000", width: 8,
            opacity: 1, fillColor: "M", layerID: layer.id)
        let frame = AnimationFrame(id: "frame", elements: [element])
        let renderer = ImageRenderer(content: Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            StudioFrameRenderer.draw(context: &context, frame: frame, layers: [layer],
                canvasSize: CGSize(width: 256, height: 256), size: size)
        }.frame(width: CGFloat(edge), height: CGFloat(edge)))
        renderer.scale = 1
        guard let image = renderer.cgImage else { throw Failure(description: "No rendered text image") }
        var bytes = [UInt8](repeating: 0, count: edge * edge * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: edge, height: edge,
                bitsPerComponent: 8, bytesPerRow: edge * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: edge, height: edge))
            return true
        }
        guard rendered else { throw Failure(description: "Could not decode text image") }
        var minX = edge, minY = edge, maxX = -1, maxY = -1
        for y in 0..<edge { for x in 0..<edge {
            let i = (y * edge + x) * 4
            if bytes[i] < 128 && bytes[i + 1] < 128 && bytes[i + 2] < 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        } }
        guard maxX >= minX, maxY >= minY else { throw Failure(description: "Text did not produce visible ink") }
        return CGSize(width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func mixedStackReplayPixels() throws {
        let layer = CanvasLayer(id: "stack", name: "Stack")
        let asset = "image-" + UUID().uuidString
        var rgba: [UInt8] = []
        for _ in 0..<64 { for x in 0..<64 { rgba += x < 32 ? [0, 0, 0, 128] : [128, 128, 128, 128] } }
        let original = try StudioSmudge.Pixels(width: 64, height: 64, rgba: rgba)
        let sourceImage = try StudioSmudgeReplay.cgImage(original)
        guard let png = NSBitmapImageRep(cgImage: sourceImage).representation(using: .png, properties: [:]) else {
            throw Failure(description: "Stack fixture PNG encoding failed")
        }
        let sources = [asset: png], size = CGSize(width: 64, height: 64)
        var base = AnimationFrame(id: "stack-frame", elements: [], rasterAssetID: asset, rasterLayerID: layer.id,
            rasterPlacement: .init(x: 0, y: 0, width: 64, height: 64))
        func effect(_ id: String) -> DrawnElement {
            .init(id: id, tool: .blur, points: [.init(x: 32, y: 32)], color: "#000000", width: 40,
                opacity: 1, layerID: layer.id, blur: .init(hardness: 1, radius: 4))
        }
        @MainActor func render(_ frame: AnimationFrame, live: DrawnElement? = nil) throws -> StudioSmudge.Pixels {
            let brushes = try StudioFrameRenderer.prepare(frame: frame, liveElement: live)
            let rasters = try StudioFrameRenderer.prepareRasters(frame: frame, layers: [layer], sourceData: sources)
            let replay = try StudioSmudgeReplay.prepare(frame: frame, layers: [layer], canvasSize: size,
                rasterData: nil, rasterDataByID: sources, liveElement: live)
            var failure: Error?
            let renderer = ImageRenderer(content: Canvas { context, actual in
                failure = StudioFrameRenderer.draw(context: &context, frame: frame, layers: [layer], canvasSize: size,
                    size: actual, liveElement: live, preparedBrushes: brushes, preparedSmudges: replay,
                    rasterSources: sources, preparedRasters: rasters)
            }.frame(width: 64, height: 64))
            renderer.scale = 1; renderer.isOpaque = false
            guard let image = renderer.cgImage else { throw Failure(description: "Mixed stack render unavailable") }
            if let failure { throw failure }
            return try StudioSmudgeReplay.pixels(image)
        }
        func blur(_ pixels: StudioSmudge.Pixels) throws -> StudioSmudge.Pixels {
            let input = try StudioBlur.Pixels(width: 64, height: 64, rgba: pixels.rgba)
            let result = try StudioBlur.apply(to: input, path: [.init(x: 32, y: 32)],
                settings: .init(diameter: 40, hardness: 1, radius: 4, strength: 1))
            return try StudioSmudgeReplay.pixels(StudioSmudgeReplay.cgImage(.init(width: 64, height: 64, rgba: result.rgba)))
        }
        let imageOnly = try render(base), once = try blur(imageOnly), twice = try blur(once)
        guard once.rgba != imageOnly.rgba, twice.rgba != once.rgba else {
            throw Failure(description: "Real blur oracle does not distinguish successive effects")
        }
        let blank = [UInt8](repeating: 0, count: 64 * 64 * 4)
        base.elements = [effect("first"), effect("second")]
        for slot in 0...2 {
            var frame = base; frame.rasterStackPosition = slot == 0 ? nil : slot
            let replay = try StudioSmudgeReplay.prepare(frame: frame, layers: [layer], canvasSize: size,
                rasterData: nil, rasterDataByID: sources)
            guard let first = replay.images["first"], let second = replay.images["second"] else {
                throw Failure(description: "Missing real effect prefix")
            }
            let firstPixels = try StudioSmudgeReplay.pixels(first).rgba
            let secondPixels = try StudioSmudgeReplay.pixels(second).rgba
            guard firstPixels == (slot == 0 ? once.rgba : blank),
                  secondPixels == (slot == 0 ? twice.rgba : slot == 1 ? once.rgba : blank) else {
                throw Failure(description: "Image consumed at wrong effect prefix slot \(slot)")
            }
            let final = try render(frame)
            guard final.rgba == (slot == 0 ? twice.rgba : slot == 1 ? once.rgba : imageOnly.rgba) else {
                throw Failure(description: "Final layer repeats, drops or reorders image at slot \(slot)")
            }
            // Cached effects are tied to exact persisted stack metadata.
            var moved = frame; moved.rasterStackPosition = slot == 2 ? nil : slot + 1
            do {
                try replay.validate(frame: moved, layers: [layer], canvasSize: size, rasterData: nil,
                    rasterDataByID: sources, liveElement: nil)
                throw Failure(description: "Old effect cache accepted changed image slot")
            } catch StudioSmudgeReplay.Failure.stale { }
        }
        print("PASS image before between and after successive blur effects matches exact real pixel prefixes without duplicate alpha")
        var liveFrame = base; liveFrame.elements = [effect("first")]; liveFrame.rasterStackPosition = 1
        let livePixels = try render(liveFrame, live: effect("live"))
        guard livePixels.rgba == once.rgba else { throw Failure(description: "End-slot image did not precede live effect") }
        // Identical legacy nil and explicit zero preserve the old compositor.
        var legacy = base; legacy.rasterStackPosition = nil
        var zero = legacy; zero.rasterStackPosition = 0
        guard try render(legacy).rgba == render(zero).rgba else { throw Failure(description: "Nil legacy stack pixels changed") }
        var invalid = base; invalid.rasterStackPosition = 3
        do { _ = try render(invalid); throw Failure(description: "Out-of-range full-frame image slot rendered") }
        catch StudioRasterLayerInstance.Failure.invalid { }
        do {
            _ = try StudioSmudgeReplay.prepare(frame: liveFrame, layers: [layer], canvasSize: size,
                rasterData: nil, rasterDataByID: [:])
            throw Failure(description: "Image above a flattened effect bypassed source validation")
        } catch StudioRasterImage.Failure.missing { }
        print("PASS live effect end-slot legacy equality stale cache invalid slot and missing later source guards")
    }

    static func main() {
        do {
            let red = CanvasLayer(id: "red", name: "Red")
            var blue = CanvasLayer(id: "blue", name: "Blue")
            let lines = [stroke(id: "r", layer: "red", color: "#FF0000"),
                         stroke(id: "b", layer: "blue", color: "#0000FF", width: 10)]
            try requirePixel("front blue layer", centerPixel(layers: [blue, red], elements: lines), [0, 0, 255, 255])
            try requirePixel("reorder puts red in front", centerPixel(layers: [red, blue], elements: lines), [255, 0, 0, 255])
            blue.visible = false
            try requirePixel("hidden layer does not render", centerPixel(layers: [blue, red], elements: lines), [255, 0, 0, 255])
            blue.visible = true; blue.opacity = 0.5
            try requirePixel("layer opacity blends with lower layer", centerPixel(layers: [blue, red], elements: lines), [128, 0, 128, 255])
            blue.opacity = 1
            let erased = lines + [stroke(id: "e", layer: "blue", color: "#FFFFFF", width: 3, tool: .eraser)]
            try requirePixel("eraser clears only its own layer", centerPixel(layers: [blue, red], elements: erased), [255, 0, 0, 255])
            var half = red; half.opacity = 0.5
            let halfStroke = stroke(id: "r", layer: "red", color: "#FF0000", opacity: 0.5)
            try requirePixel("layer and element opacity multiply", centerPixel(layers: [half], elements: [halfStroke]), [255, 191, 191, 255])
            try requirePixel("onion opacity survives layer composition", centerPixel(layers: [red], elements: [lines[0]], outerOpacity: 0.2), [255, 204, 204, 255])
            let black = stroke(id: "black", layer: "red", color: "#000000")
            try requirePixel("previous ghost tints black ink red", centerPixel(layers: [red], elements: [black], outerOpacity: 0.2, onionPrevious: true), [255, 204, 204, 255])
            try requirePixel("next ghost tints black ink blue", centerPixel(layers: [red], elements: [black], outerOpacity: 0.2, onionPrevious: false), [204, 204, 255, 255])
            let fullText = try textInkBounds(edge: 256)
            let thumbnailText = try textInkBounds(edge: 64)
            // Allow font hinting/antialiasing at small sizes, while requiring
            // the same document's glyph to shrink with its thumbnail geometry.
            guard abs(fullText.width - thumbnailText.width * 4) <= 4,
                  abs(fullText.height - thumbnailText.height * 4) <= 4,
                  thumbnailText.width < fullText.width, thumbnailText.height < fullText.height else {
                throw Failure(description: "Text ink does not scale with canvas: full \(fullText), quarter-size \(thumbnailText)")
            }
            print("PASS text scales with thumbnail geometry: full \(fullText), quarter-size \(thumbnailText)")
            let backdrop = CanvasLayer(id: "backdrop", name: "Backdrop")
            var foreground = CanvasLayer(id: "foreground", name: "Foreground")
            let blendStrokes = [stroke(id: "base", layer: backdrop.id, color: "#804020"), stroke(id: "front", layer: foreground.id, color: "#4080C0")]
            let golden: [(String, [UInt8])] = [("normal", [64,128,192,255]), ("multiply", [32,32,24,255]),
                ("screen", [160,160,200,255]), ("overlay", [64,64,48,255]), ("darken", [64,64,32,255]), ("lighten", [128,128,192,255])]
            for edge in [64, 128] {
                for (mode, expected) in golden {
                    foreground.blendMode = mode
                    try requirePixel("analytical \(mode) at \(edge)", centerPixel(layers: [foreground, backdrop], elements: blendStrokes, edge: edge), expected)
                }
                foreground.blendMode = "normal"
                try requirePixel("reversed colored layer golden at \(edge)", centerPixel(layers: [backdrop, foreground], elements: blendStrokes, edge: edge), [128,64,32,255])
                var halo = CanvasLayer(id: "halo", name: "Halo", glowEnabled: true, glowColor: "#00FF00", glowRadius: 12, glowStrength: 1)
                let ink = [stroke(id: "ink", layer: halo.id, color: "#000000", width: 4)]
                try requirePixel("glow preserves opaque source at \(edge)", centerPixel(layers: [halo], elements: ink, edge: edge, white: false), [0,0,0,255])
                let full = try centerPixel(layers: [halo], elements: ink, edge: edge, sampleY: 24, white: false)
                guard full[0] == 0 && full[2] == 0 && full[1] == full[3] && full[3] > 5 else { throw Failure(description: "Green glow missing independent premultiplied alpha halo at \(edge): \(full)") }
                halo.glowStrength = 0.25
                let weak = try centerPixel(layers: [halo], elements: ink, edge: edge, sampleY: 24, white: false)
                guard weak[3] > 0 && weak[3] < full[3] else { throw Failure(description: "Strength does not change actual halo alpha") }
                halo.glowStrength = 0
                try requirePixel("zero strength transparent halo at \(edge)", centerPixel(layers: [halo], elements: ink, edge: edge, sampleY: 24, white: false), [0,0,0,0])
                try requirePixel("zero strength white background at \(edge)", centerPixel(layers: [halo], elements: ink, edge: edge, sampleY: 24), [255,255,255,255])
                halo.glowStrength = 1; halo.glowRadius = 0
                try requirePixel("zero radius cannot extend source at \(edge)", centerPixel(layers: [halo], elements: ink, edge: edge, sampleY: 24, white: false), [0,0,0,0])
            }
            try mixedStackReplayPixels()
            print("STUDIO_RENDERER_TESTS=PASS 10 existing cases plus 2 scales of analytical blend/order and glow color/strength/radius/alpha goldens plus 2 mixed image/effect replay groups")
        } catch {
            print("STUDIO_RENDERER_TESTS=FAIL \(error)")
            exit(1)
        }
    }
}
