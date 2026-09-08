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
                                    outerOpacity: Double = 1) throws -> [UInt8] {
        let frame = AnimationFrame(id: "fixture", elements: elements)
        let canvas = Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            context.opacity = outerOpacity
            StudioFrameRenderer.draw(context: &context, frame: frame, layers: layers,
                                     canvasSize: CGSize(width: 64, height: 64), size: size)
        }.frame(width: 64, height: 64)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1
        guard let image = renderer.cgImage else {
            throw Failure(description: "SwiftUI did not produce an image")
        }
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 64, height: 64,
                bitsPerComponent: 8, bytesPerRow: 64 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            return true
        }
        guard rendered else { throw Failure(description: "Could not decode rendered image pixels") }
        return Array(bytes[(32 * 64 + 32) * 4..<(32 * 64 + 32) * 4 + 4])
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
            print("STUDIO_RENDERER_TESTS=PASS 8 native macOS SwiftUI pixel cases")
        } catch {
            print("STUDIO_RENDERER_TESTS=FAIL \(error)")
            exit(1)
        }
    }
}
