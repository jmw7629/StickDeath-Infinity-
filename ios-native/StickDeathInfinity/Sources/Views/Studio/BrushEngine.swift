// BrushEngine.swift
// 12 brush types — each with unique rendering characteristics
// Used by DrawingState for stroke rendering on the canvas

import SwiftUI

// MARK: - Brush Type
enum BrushType: String, CaseIterable, Codable {
    case pen            // Clean uniform stroke
    case pencil         // Textured, slightly rough
    case marker         // Wide flat-tip, semi-transparent
    case calligraphy    // Angle-sensitive varying width
    case spray          // Airbrush scatter
    case watercolor     // Soft edges, blends
    case crayon         // Rough texture, wide
    case neon           // Glowing outline
    case dotted         // Dotted line pattern
    case pixel          // Blocky pixel art
    case charcoal       // Dark, smudgy, thick
    case highlighter    // Wide, very transparent yellow-ish

    var displayName: String {
        switch self {
        case .pen:          return "Pen"
        case .pencil:       return "Pencil"
        case .marker:       return "Marker"
        case .calligraphy:  return "Calligraphy"
        case .spray:        return "Spray"
        case .watercolor:   return "Watercolor"
        case .crayon:       return "Crayon"
        case .neon:         return "Neon"
        case .dotted:       return "Dotted"
        case .pixel:        return "Pixel"
        case .charcoal:     return "Charcoal"
        case .highlighter:  return "Highlighter"
        }
    }

    var icon: String {
        switch self {
        case .pen:          return "pencil.tip"
        case .pencil:       return "pencil"
        case .marker:       return "paintbrush.pointed"
        case .calligraphy:  return "paintbrush"
        case .spray:        return "aqi.medium"
        case .watercolor:   return "drop.fill"
        case .crayon:       return "pencil.tip.crop.circle"
        case .neon:         return "lightbulb.fill"
        case .dotted:       return "ellipsis"
        case .pixel:        return "square.grid.3x3.fill"
        case .charcoal:     return "scribble.variable"
        case .highlighter:  return "highlighter"
        }
    }

    /// Base opacity for the brush
    var baseOpacity: Double {
        switch self {
        case .highlighter:  return 0.3
        case .watercolor:   return 0.5
        case .marker:       return 0.7
        case .spray:        return 0.6
        default:            return 1.0
        }
    }

    /// Width multiplier relative to user-set strokeWidth
    var widthMultiplier: CGFloat {
        switch self {
        case .marker:       return 2.5
        case .calligraphy:  return 2.0
        case .crayon:       return 1.8
        case .highlighter:  return 3.0
        case .charcoal:     return 1.5
        case .spray:        return 4.0
        case .pixel:        return 1.0  // Exact pixel sizing
        default:            return 1.0
        }
    }

    /// Line cap style
    var lineCap: CGLineCap {
        switch self {
        case .pixel:        return .butt
        case .calligraphy:  return .butt
        default:            return .round
        }
    }

    /// Line join style
    var lineJoin: CGLineJoin {
        switch self {
        case .pixel:    return .miter
        default:        return .round
    }
    }
}

// MARK: - Brush Renderer
struct BrushRenderer {
    /// Render a path with the given brush type into a SwiftUI Shape
    static func render(
        points: [CGPoint],
        brush: BrushType,
        color: Color,
        width: CGFloat,
        scale: CGFloat,
        toScreen: (CGPoint) -> CGPoint
    ) -> some View {
        let effectiveWidth = width * brush.widthMultiplier * scale
        let screenPoints = points.map { toScreen($0) }

        return ZStack {
            switch brush {
            case .pen, .pencil:
                smoothPath(screenPoints)
                    .stroke(color, style: StrokeStyle(
                        lineWidth: effectiveWidth,
                        lineCap: brush.lineCap,
                        lineJoin: brush.lineJoin
                    ))
                    .opacity(brush.baseOpacity)

            case .marker:
                smoothPath(screenPoints)
                    .stroke(color, style: StrokeStyle(
                        lineWidth: effectiveWidth,
                        lineCap: .round,
                        lineJoin: .round
                    ))
                    .opacity(brush.baseOpacity)

            case .calligraphy:
                calligraphyPath(screenPoints, width: effectiveWidth)
                    .fill(color)
                    .opacity(brush.baseOpacity)

            case .spray:
                sprayPath(screenPoints, radius: effectiveWidth, color: color)

            case .watercolor:
                smoothPath(screenPoints)
                    .stroke(color, style: StrokeStyle(
                        lineWidth: effectiveWidth,
                        lineCap: .round,
                        lineJoin: .round
                    ))
                    .opacity(brush.baseOpacity)
                    .blur(radius: effectiveWidth * 0.3)

            case .crayon:
                // Multiple offset strokes for texture
                ForEach(0..<3, id: \.self) { i in
                    let offset = CGFloat(i - 1) * effectiveWidth * 0.15
                    smoothPath(screenPoints.map { CGPoint(x: $0.x + offset, y: $0.y + offset) })
                        .stroke(color, style: StrokeStyle(
                            lineWidth: effectiveWidth * 0.5,
                            lineCap: .round,
                            lineJoin: .round
                        ))
                        .opacity(0.4)
                }

            case .neon:
                // Glow effect: blurred background + sharp foreground
                smoothPath(screenPoints)
                    .stroke(color, style: StrokeStyle(lineWidth: effectiveWidth * 2, lineCap: .round))
                    .blur(radius: effectiveWidth)
                    .opacity(0.5)
                smoothPath(screenPoints)
                    .stroke(.white, style: StrokeStyle(lineWidth: effectiveWidth * 0.5, lineCap: .round))
                    .opacity(0.9)

            case .dotted:
                smoothPath(screenPoints)
                    .stroke(color, style: StrokeStyle(
                        lineWidth: effectiveWidth,
                        lineCap: .round,
                        dash: [effectiveWidth * 0.5, effectiveWidth * 1.5]
                    ))

            case .pixel:
                pixelPath(screenPoints, pixelSize: max(2, effectiveWidth), color: color)

            case .charcoal:
                smoothPath(screenPoints)
                    .stroke(color, style: StrokeStyle(
                        lineWidth: effectiveWidth,
                        lineCap: .round,
                        lineJoin: .round
                    ))
                    .opacity(0.85)
                // Rough edges
                smoothPath(screenPoints)
                    .stroke(color.opacity(0.3), style: StrokeStyle(
                        lineWidth: effectiveWidth * 1.5,
                        lineCap: .round
                    ))
                    .blur(radius: 1)

            case .highlighter:
                smoothPath(screenPoints)
                    .stroke(color, style: StrokeStyle(
                        lineWidth: effectiveWidth,
                        lineCap: .butt,
                        lineJoin: .miter
                    ))
                    .opacity(brush.baseOpacity)
            }
        }
    }

    // MARK: - Path Helpers

    /// Smooth Catmull-Rom spline through points
    static func smoothPath(_ points: [CGPoint]) -> Path {
        Path { path in
            guard points.count >= 2 else { return }
            path.move(to: points[0])
            if points.count == 2 {
                path.addLine(to: points[1])
                return
            }
            for i in 1..<points.count {
                let prev = points[max(0, i - 1)]
                let curr = points[i]
                let mid = CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2)
                path.addQuadCurve(to: mid, control: prev)
            }
            if let last = points.last {
                path.addLine(to: last)
            }
        }
    }

    /// Calligraphy: varying width based on stroke angle
    static func calligraphyPath(_ points: [CGPoint], width: CGFloat) -> Path {
        Path { path in
            guard points.count >= 2 else { return }
            let angle: CGFloat = .pi / 4  // 45° nib angle

            for i in 0..<points.count - 1 {
                let p1 = points[i]
                let p2 = points[i + 1]
                let dx = p2.x - p1.x
                let dy = p2.y - p1.y
                let strokeAngle = atan2(dy, dx)
                let angleDiff = abs(sin(strokeAngle - angle))
                let w = width * (0.3 + 0.7 * angleDiff) / 2

                let perpX = cos(strokeAngle + .pi / 2) * w
                let perpY = sin(strokeAngle + .pi / 2) * w

                let quad = [
                    CGPoint(x: p1.x + perpX, y: p1.y + perpY),
                    CGPoint(x: p2.x + perpX, y: p2.y + perpY),
                    CGPoint(x: p2.x - perpX, y: p2.y - perpY),
                    CGPoint(x: p1.x - perpX, y: p1.y - perpY),
                ]
                path.move(to: quad[0])
                for q in quad.dropFirst() { path.addLine(to: q) }
                path.closeSubpath()
            }
        }
    }

    /// Spray: random dots around the stroke path
    static func sprayPath(_ points: [CGPoint], radius: CGFloat, color: Color) -> some View {
        Canvas { context, size in
            let r = radius / 2
            for pt in points {
                for _ in 0..<8 {
                    let angle = CGFloat.random(in: 0...(.pi * 2))
                    let dist = CGFloat.random(in: 0...r)
                    let dot = CGPoint(
                        x: pt.x + cos(angle) * dist,
                        y: pt.y + sin(angle) * dist
                    )
                    let dotSize = CGFloat.random(in: 1...3)
                    context.fill(
                        Path(ellipseIn: CGRect(x: dot.x - dotSize/2, y: dot.y - dotSize/2, width: dotSize, height: dotSize)),
                        with: .color(color.opacity(Double.random(in: 0.2...0.8)))
                    )
                }
            }
        }
    }

    /// Pixel: snap to grid
    static func pixelPath(_ points: [CGPoint], pixelSize: CGFloat, color: Color) -> some View {
        Canvas { context, size in
            var visited = Set<String>()
            for pt in points {
                let gx = floor(pt.x / pixelSize) * pixelSize
                let gy = floor(pt.y / pixelSize) * pixelSize
                let key = "\(Int(gx)),\(Int(gy))"
                guard !visited.contains(key) else { continue }
                visited.insert(key)
                context.fill(
                    Path(CGRect(x: gx, y: gy, width: pixelSize, height: pixelSize)),
                    with: .color(color)
                )
            }
        }
    }
}
