// FillLassoTools.swift
// Fill tool (flood fill via CGImage pixel scan) and Lasso tool (freehand selection)

import SwiftUI
import UIKit

// MARK: - Fill Tool (Flood Fill)
/// Renders the current canvas to a CGImage, performs scanline flood fill,
/// then converts the result back to a DrawnElement bitmap overlay.
class FillTool {
    struct FillResult {
        let image: UIImage
        let origin: CGPoint  // Canvas-space origin
        let size: CGSize     // Canvas-space size
    }

    /// Perform flood fill at the given point on a rendered canvas image
    /// - Parameters:
    ///   - point: Tap point in canvas coordinates
    ///   - canvasImage: Current rendered canvas as CGImage
    ///   - fillColor: Color to fill with
    ///   - tolerance: Color matching tolerance (0-255 per channel)
    /// - Returns: A FillResult with the filled area as a transparent UIImage
    static func floodFill(
        at point: CGPoint,
        in canvasImage: CGImage,
        fillColor: UIColor,
        tolerance: Int = 32
    ) -> UIImage? {
        let width = canvasImage.width
        let height = canvasImage.height
        let px = Int(point.x)
        let py = Int(point.y)

        guard px >= 0, px < width, py >= 0, py < height else { return nil }

        // Get pixel data
        guard let data = canvasImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }

        let bytesPerPixel = canvasImage.bitsPerPixel / 8
        let bytesPerRow = canvasImage.bytesPerRow

        func pixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let offset = y * bytesPerRow + x * bytesPerPixel
            return (ptr[offset], ptr[offset+1], ptr[offset+2], ptr[offset+3])
        }

        let target = pixel(x: px, y: py)

        // Get fill color components
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        fillColor.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)

        // If target is already the fill color, skip
        let fillR = UInt8(fr * 255), fillG = UInt8(fg * 255), fillB = UInt8(fb * 255), fillA = UInt8(fa * 255)
        if abs(Int(target.0) - Int(fillR)) < tolerance &&
           abs(Int(target.1) - Int(fillG)) < tolerance &&
           abs(Int(target.2) - Int(fillB)) < tolerance { return nil }

        // Scanline flood fill
        var visited = Set<Int>()  // y * width + x
        var stack: [(Int, Int)] = [(px, py)]
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        func matches(_ x: Int, _ y: Int) -> Bool {
            let p = pixel(x: x, y: y)
            return abs(Int(p.0) - Int(target.0)) <= tolerance &&
                   abs(Int(p.1) - Int(target.1)) <= tolerance &&
                   abs(Int(p.2) - Int(target.2)) <= tolerance &&
                   abs(Int(p.3) - Int(target.3)) <= tolerance
        }

        while let (cx, cy) = stack.popLast() {
            let key = cy * width + cx
            guard !visited.contains(key) else { continue }
            guard cx >= 0, cx < width, cy >= 0, cy < height else { continue }
            guard matches(cx, cy) else { continue }

            visited.insert(key)
            let offset = key * 4
            pixels[offset] = fillR
            pixels[offset+1] = fillG
            pixels[offset+2] = fillB
            pixels[offset+3] = fillA

            stack.append((cx+1, cy))
            stack.append((cx-1, cy))
            stack.append((cx, cy+1))
            stack.append((cx, cy-1))
        }

        // Create image from filled pixels
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else { return nil }

        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Lasso Tool (Freehand Selection)
/// Allows freehand lasso selection of drawn elements
class LassoTool {
    /// Check if a point is inside a lasso polygon using ray casting
    static func pointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1

        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]

            if (pi.y > point.y) != (pj.y > point.y) &&
               point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Find all DrawnElements whose centroid falls within the lasso
    static func selectElements(
        in elements: [DrawnElement],
        lasso: [CGPoint]
    ) -> [UUID] {
        guard lasso.count >= 3 else { return [] }

        return elements.compactMap { element in
            let centroid: CGPoint
            if let origin = element.origin, let size = element.size {
                centroid = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            } else if !element.points.isEmpty {
                let avgX = element.points.map(\.x).reduce(0, +) / CGFloat(element.points.count)
                let avgY = element.points.map(\.y).reduce(0, +) / CGFloat(element.points.count)
                centroid = CGPoint(x: avgX, y: avgY)
            } else {
                return nil
            }

            return pointInPolygon(centroid, polygon: lasso) ? element.id : nil
        }
    }

    /// Compute bounding box of lasso polygon
    static func boundingBox(of polygon: [CGPoint]) -> CGRect {
        guard !polygon.isEmpty else { return .zero }
        let xs = polygon.map(\.x)
        let ys = polygon.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!
        let minY = ys.min()!, maxY = ys.max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Lasso Overlay (renders the lasso path while dragging)
struct LassoOverlayView: View {
    let points: [CGPoint]
    let canvasCenter: CGPoint
    let canvasScale: CGFloat

    var body: some View {
        if points.count >= 2 {
            Path { path in
                let screenPoints = points.map { screenPt($0) }
                guard let first = screenPoints.first else { return }
                path.move(to: first)
                for pt in screenPoints.dropFirst() {
                    path.addLine(to: pt)
                }
                path.closeSubpath()
            }
            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(.white)

            Path { path in
                let screenPoints = points.map { screenPt($0) }
                guard let first = screenPoints.first else { return }
                path.move(to: first)
                for pt in screenPoints.dropFirst() {
                    path.addLine(to: pt)
                }
                path.closeSubpath()
            }
            .fill(.white.opacity(0.08))
        }
    }

    func screenPt(_ pt: CGPoint) -> CGPoint {
        CGPoint(
            x: canvasCenter.x + pt.x * canvasScale,
            y: canvasCenter.y + pt.y * canvasScale
        )
    }
}
