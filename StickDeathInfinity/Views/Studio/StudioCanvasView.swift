import SwiftUI

// ═══════════════════════════════════════════════════════════════════════
// CoreGraphics-based Canvas — Renders drawn elements + live stroke
// Handles touch input for drawing, shapes, fill, eraser, text, etc.
// ═══════════════════════════════════════════════════════════════════════

struct StudioCanvasView: View {
    @ObservedObject var vm: StudioViewModel
    @State private var livePoints: [StrokePoint] = []
    @State private var shapeStart: CGPoint?
    @State private var shapeEnd: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let canvasSize = canvasRect(in: geo.size)

            ZStack {
                // Canvas background (white)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .shadow(color: .black.opacity(0.4), radius: 12)

                // Rendered elements
                Canvas { context, size in
                    let elements = vm.currentFrame.elements
                    for element in elements {
                        drawElement(context: &context, element: element, size: size)
                    }
                    // Live stroke
                    if !livePoints.isEmpty {
                        drawLiveStroke(context: &context, points: livePoints, size: size)
                    }
                    // Shape preview
                    if let start = shapeStart, let end = shapeEnd {
                        drawShapePreview(context: &context, start: start, end: end, size: size)
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .clipped()
                .gesture(drawingGesture(canvasSize: canvasSize, geoSize: geo.size))

                // Grid overlay
                if vm.gridEnabled {
                    GridOverlay()
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Canvas Size Calculation
    func canvasRect(in size: CGSize) -> CGSize {
        let aspectRatio = CGFloat(vm.canvasWidth) / CGFloat(vm.canvasHeight)
        let maxW = size.width * 0.9
        let maxH = size.height * 0.9

        if maxW / maxH > aspectRatio {
            return CGSize(width: maxH * aspectRatio, height: maxH)
        } else {
            return CGSize(width: maxW, height: maxW / aspectRatio)
        }
    }

    // MARK: - Drawing Gesture
    func drawingGesture(canvasSize: CGSize, geoSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { val in
                guard isDrawingTool else { return }
                let canvasOrigin = CGPoint(
                    x: (geoSize.width - canvasSize.width) / 2,
                    y: (geoSize.height - canvasSize.height) / 2
                )
                let localX = Double((val.location.x - canvasOrigin.x) / canvasSize.width * CGFloat(vm.canvasWidth))
                let localY = Double((val.location.y - canvasOrigin.y) / canvasSize.height * CGFloat(vm.canvasHeight))
                let point = StrokePoint(x: localX, y: localY)

                if isShapeTool {
                    if shapeStart == nil {
                        shapeStart = CGPoint(x: CGFloat(localX), y: CGFloat(localY))
                    }
                    shapeEnd = CGPoint(x: CGFloat(localX), y: CGFloat(localY))
                } else {
                    livePoints.append(point)
                }
            }
            .onEnded { _ in
                guard isDrawingTool else { return }
                if isShapeTool, let start = shapeStart, let end = shapeEnd {
                    commitShape(start: start, end: end)
                    shapeStart = nil
                    shapeEnd = nil
                } else if !livePoints.isEmpty {
                    commitStroke()
                }
            }
    }

    var isDrawingTool: Bool {
        switch vm.selectedTool {
        case .pencil, .pen, .brush, .marker, .crayon, .eraser, .smudge,
             .line, .rectangle, .circle: return true
        default: return false
        }
    }

    var isShapeTool: Bool {
        switch vm.selectedTool {
        case .line, .rectangle, .circle: return true
        default: return false
        }
    }

    // MARK: - Commit Stroke
    func commitStroke() {
        let element = DrawnElement(
            id: UUID().uuidString,
            tool: vm.selectedTool,
            points: livePoints,
            color: vm.selectedTool == .eraser ? "#FFFFFF" : vm.strokeColorHex,
            width: vm.strokeWidth,
            opacity: vm.strokeOpacity,
            layerID: vm.activeLayerID
        )
        vm.commitElement(element)
        livePoints.removeAll()
    }

    func commitShape(start: CGPoint, end: CGPoint) {
        let element = DrawnElement(
            id: UUID().uuidString,
            tool: vm.selectedTool,
            points: [
                StrokePoint(x: Double(start.x), y: Double(start.y)),
                StrokePoint(x: Double(end.x), y: Double(end.y))
            ],
            color: vm.strokeColorHex,
            width: vm.strokeWidth,
            opacity: vm.strokeOpacity,
            layerID: vm.activeLayerID
        )
        vm.commitElement(element)
    }

    // MARK: - Draw Element (CoreGraphics-backed)
    func drawElement(context: inout GraphicsContext, element: DrawnElement, size: CGSize) {
        let scaleX = size.width / CGFloat(vm.canvasWidth)
        let scaleY = size.height / CGFloat(vm.canvasHeight)
        let color = Color(hex: element.color)

        context.opacity = element.opacity

        switch element.tool {
        case .pencil, .pen, .brush, .marker, .crayon, .eraser, .smudge:
            guard element.points.count >= 2 else { return }
            var path = Path()
            let first = element.points[0]
            path.move(to: CGPoint(x: CGFloat(first.x) * scaleX, y: CGFloat(first.y) * scaleY))

            if element.points.count == 2 {
                let p = element.points[1]
                path.addLine(to: CGPoint(x: CGFloat(p.x) * scaleX, y: CGFloat(p.y) * scaleY))
            } else {
                for i in 1..<element.points.count {
                    let prev = element.points[i - 1]
                    let curr = element.points[i]
                    let midX = CGFloat((prev.x + curr.x) / 2.0) * scaleX
                    let midY = CGFloat((prev.y + curr.y) / 2.0) * scaleY
                    path.addQuadCurve(
                        to: CGPoint(x: midX, y: midY),
                        control: CGPoint(x: CGFloat(prev.x) * scaleX, y: CGFloat(prev.y) * scaleY)
                    )
                }
                let last = element.points.last!
                path.addLine(to: CGPoint(x: CGFloat(last.x) * scaleX, y: CGFloat(last.y) * scaleY))
            }

            let lineWidth = CGFloat(element.width) * scaleX * brushWidthMultiplier(for: element.tool)

            if element.tool == .eraser {
                context.blendMode = .clear
            }

            context.stroke(path, with: .color(color), style: StrokeStyle(
                lineWidth: lineWidth,
                lineCap: element.tool == .pencil ? .butt : .round,
                lineJoin: .round
            ))

            if element.tool == .eraser {
                context.blendMode = .normal
            }

        case .line:
            guard element.points.count >= 2 else { return }
            var path = Path()
            path.move(to: CGPoint(x: CGFloat(element.points[0].x) * scaleX, y: CGFloat(element.points[0].y) * scaleY))
            path.addLine(to: CGPoint(x: CGFloat(element.points[1].x) * scaleX, y: CGFloat(element.points[1].y) * scaleY))
            context.stroke(path, with: .color(color), lineWidth: CGFloat(element.width) * scaleX)

        case .rectangle:
            guard element.points.count >= 2 else { return }
            let rect = CGRect(
                x: CGFloat(min(element.points[0].x, element.points[1].x)) * scaleX,
                y: CGFloat(min(element.points[0].y, element.points[1].y)) * scaleY,
                width: CGFloat(abs(element.points[1].x - element.points[0].x)) * scaleX,
                height: CGFloat(abs(element.points[1].y - element.points[0].y)) * scaleY
            )
            context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(color), lineWidth: CGFloat(element.width) * scaleX)

        case .circle:
            guard element.points.count >= 2 else { return }
            let center = CGPoint(
                x: CGFloat((element.points[0].x + element.points[1].x) / 2.0) * scaleX,
                y: CGFloat((element.points[0].y + element.points[1].y) / 2.0) * scaleY
            )
            let radiusX = CGFloat(abs(element.points[1].x - element.points[0].x) / 2.0) * scaleX
            let radiusY = CGFloat(abs(element.points[1].y - element.points[0].y) / 2.0) * scaleY
            let path = Path(ellipseIn: CGRect(
                x: center.x - radiusX, y: center.y - radiusY,
                width: radiusX * 2, height: radiusY * 2
            ))
            context.stroke(path, with: .color(color), lineWidth: CGFloat(element.width) * scaleX)

        case .text:
            if let text = element.fillColor, let first = element.points.first {
                context.draw(
                    Text(text).font(.system(size: CGFloat(element.width) * 3, design: .monospaced)).foregroundColor(color),
                    at: CGPoint(x: CGFloat(first.x) * scaleX, y: CGFloat(first.y) * scaleY),
                    anchor: .topLeading
                )
            }

        default:
            break
        }

        context.opacity = 1.0
    }

    func brushWidthMultiplier(for tool: DrawingTool) -> CGFloat {
        switch tool {
        case .pencil: return 0.8
        case .pen: return 1.0
        case .brush: return 1.5
        case .marker: return 2.5
        case .crayon: return 2.0
        case .eraser: return 3.0
        case .smudge: return 2.0
        default: return 1.0
        }
    }

    // MARK: - Draw Live Stroke
    func drawLiveStroke(context: inout GraphicsContext, points: [StrokePoint], size: CGSize) {
        guard points.count >= 2 else { return }
        let scaleX = size.width / CGFloat(vm.canvasWidth)
        let scaleY = size.height / CGFloat(vm.canvasHeight)
        let color = vm.selectedTool == .eraser ? Color.white : vm.strokeColor

        var path = Path()
        path.move(to: CGPoint(x: CGFloat(points[0].x) * scaleX, y: CGFloat(points[0].y) * scaleY))
        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]
            let midX = CGFloat((prev.x + curr.x) / 2.0) * scaleX
            let midY = CGFloat((prev.y + curr.y) / 2.0) * scaleY
            path.addQuadCurve(
                to: CGPoint(x: midX, y: midY),
                control: CGPoint(x: CGFloat(prev.x) * scaleX, y: CGFloat(prev.y) * scaleY)
            )
        }

        context.stroke(path, with: .color(color.opacity(vm.strokeOpacity)), style: StrokeStyle(
            lineWidth: CGFloat(vm.strokeWidth) * scaleX * brushWidthMultiplier(for: vm.selectedTool),
            lineCap: .round,
            lineJoin: .round
        ))
    }

    // MARK: - Shape Preview
    func drawShapePreview(context: inout GraphicsContext, start: CGPoint, end: CGPoint, size: CGSize) {
        let scaleX = size.width / CGFloat(vm.canvasWidth)
        let scaleY = size.height / CGFloat(vm.canvasHeight)
        let color = vm.strokeColor

        switch vm.selectedTool {
        case .line:
            var path = Path()
            path.move(to: CGPoint(x: start.x * scaleX, y: start.y * scaleY))
            path.addLine(to: CGPoint(x: end.x * scaleX, y: end.y * scaleY))
            context.stroke(path, with: .color(color), lineWidth: CGFloat(vm.strokeWidth) * scaleX)

        case .rectangle:
            let rect = CGRect(
                x: min(start.x, end.x) * scaleX,
                y: min(start.y, end.y) * scaleY,
                width: abs(end.x - start.x) * scaleX,
                height: abs(end.y - start.y) * scaleY
            )
            context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(color), lineWidth: CGFloat(vm.strokeWidth) * scaleX)

        case .circle:
            let cx = (start.x + end.x) / 2 * scaleX
            let cy = (start.y + end.y) / 2 * scaleY
            let rx = abs(end.x - start.x) / 2 * scaleX
            let ry = abs(end.y - start.y) / 2 * scaleY
            let path = Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
            context.stroke(path, with: .color(color), lineWidth: CGFloat(vm.strokeWidth) * scaleX)

        default:
            break
        }
    }
}

// MARK: - Grid Overlay
struct GridOverlay: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 40
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(path, with: .color(.blue.opacity(0.1)), lineWidth: 0.5)
        }
    }
}
