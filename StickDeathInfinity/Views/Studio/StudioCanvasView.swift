import SwiftUI

// ═══════════════════════════════════════════════════════════════════════
// CoreGraphics-based Canvas — Renders drawn elements + live stroke
// Handles touch input for drawing, shapes, fill, eraser, text, etc.
// Layer filtering, selection, onion skin, background rendering
// ═══════════════════════════════════════════════════════════════════════

struct StudioCanvasView: View {
    @ObservedObject var vm: StudioViewModel
    @State private var livePoints: [StrokePoint] = []
    @State private var shapeStart: CGPoint?
    @State private var shapeEnd: CGPoint?
    @State private var moveStartPoint: CGPoint?
    @State private var moveAccumulated: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let canvasSize = canvasRect(in: geo.size)

            ZStack {
                // Canvas background
                canvasBackground(size: canvasSize)

                // Rendered elements (layer-filtered)
                Canvas { context, size in
                    // Onion skin: previous frame
                    if vm.showOnionSkin, let prev = vm.previousFrame {
                        for element in prev.elements {
                            guard vm.isLayerVisible(element.layerID ?? "") else { continue }
                            drawElement(context: &context, element: element, size: size, opacityMultiplier: 0.25)
                        }
                    }

                    // Current frame elements, filtered by layer
                    let elements = vm.currentFrame.elements.filter { vm.isLayerVisible($0.layerID ?? "") }
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
                .gesture(moveGesture(canvasSize: canvasSize, geoSize: geo.size))
                .onTapGesture { location in
                    handleTap(at: location, canvasSize: canvasSize, geoSize: geo.size)
                }

                // Grid overlay
                if vm.gridEnabled {
                    GridOverlay()
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .allowsHitTesting(false)
                }

                // Selection indicators
                selectionIndicators(size: canvasSize)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Canvas Background
    @ViewBuilder
    func canvasBackground(size: CGSize) -> some View {
        if let gradientColors = vm.currentFrame.backgroundGradientColors, gradientColors.count >= 2 {
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    LinearGradient(
                        colors: gradientColors.map { Color(hex: $0) },
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(0.4), radius: 12)
        } else if let bgColor = vm.currentFrame.backgroundColor {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: bgColor))
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(0.4), radius: 12)
        } else {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white)
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(0.4), radius: 12)
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

    // MARK: - Canvas origin in geo coordinates
    func canvasOrigin(in geoSize: CGSize, canvasSize: CGSize) -> CGPoint {
        CGPoint(
            x: (geoSize.width - canvasSize.width) / 2,
            y: (geoSize.height - canvasSize.height) / 2
        )
    }

    // MARK: - Local point from geo touch
    func localPoint(from geoPoint: CGPoint, canvasSize: CGSize, geoSize: CGSize) -> CGPoint {
        let origin = canvasOrigin(in: geoSize, canvasSize: canvasSize)
        let localX = (geoPoint.x - origin.x) / canvasSize.width * CGFloat(vm.canvasWidth)
        let localY = (geoPoint.y - origin.y) / canvasSize.height * CGFloat(vm.canvasHeight)
        return CGPoint(x: localX, y: localY)
    }

    // MARK: - Drawing Gesture
    func drawingGesture(canvasSize: CGSize, geoSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { val in
                guard isDrawingTool else { return }
                let local = localPoint(from: val.location, canvasSize: canvasSize, geoSize: geoSize)
                let point = StrokePoint(x: local.x, y: local.y)

                if isShapeTool {
                    if shapeStart == nil {
                        shapeStart = local
                    }
                    shapeEnd = local
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

    // MARK: - Move Gesture (selection-based drag)
    func moveGesture(canvasSize: CGSize, geoSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { val in
                guard vm.selectedTool == .move, vm.hasSelection else { return }
                if moveStartPoint == nil {
                    moveStartPoint = val.location
                    moveAccumulated = .zero
                }
                let delta = CGSize(
                    width: val.location.x - (moveStartPoint?.x ?? val.location.x),
                    height: val.location.y - (moveStartPoint?.y ?? val.location.y)
                )
                let dxCanvas = (delta.width - moveAccumulated.width) / canvasSize.width * CGFloat(vm.canvasWidth)
                let dyCanvas = (delta.height - moveAccumulated.height) / canvasSize.height * CGFloat(vm.canvasHeight)
                moveAccumulated = delta
                vm.moveSelectedBy(dx: dxCanvas, dy: dyCanvas)
            }
            .onEnded { _ in
                if vm.selectedTool == .move && vm.hasSelection {
                    vm.pushUndoDirect()
                }
                moveStartPoint = nil
                moveAccumulated = .zero
            }
    }

    // MARK: - Tap (hit-test for selection)
    func handleTap(at location: CGPoint, canvasSize: CGSize, geoSize: CGSize) {
        guard vm.selectedTool == .move || vm.selectedTool == .lasso else { return }
        let local = localPoint(from: location, canvasSize: canvasSize, geoSize: geoSize)

        // Find topmost element at this point
        let elements = vm.currentFrame.elements.reversed()
        for element in elements {
            guard vm.isLayerVisible(element.layerID ?? "") else { continue }
            if elementHitsPoint(element: element, point: local) {
                vm.selectElement(id: element.id, addToSelection: false)
                return
            }
        }
        vm.deselectAll()
    }

    func elementHitsPoint(element: DrawnElement, point: CGPoint) -> Bool {
        let threshold: CGFloat = max(element.width * 2, 15)
        for p in element.points {
            let dist = hypot(p.x - point.x, p.y - point.y)
            if dist < threshold { return true }
        }
        return false
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
        guard !livePoints.isEmpty else { return }
        let element = DrawnElement(
            id: UUID().uuidString,
            tool: vm.selectedTool,
            points: livePoints,
            color: vm.selectedTool == .eraser ? "#FFFFFF" : vm.strokeColorHex,
            width: vm.strokeWidth,
            opacity: vm.toolOpacity,
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
                StrokePoint(x: start.x, y: start.y),
                StrokePoint(x: end.x, y: end.y)
            ],
            color: vm.strokeColorHex,
            width: vm.strokeWidth,
            opacity: vm.toolOpacity,
            layerID: vm.activeLayerID,
            cornerRadius: vm.shapeCornerRadius
        )
        vm.commitElement(element)
    }

    // MARK: - Draw Element (CoreGraphics-backed)
    func drawElement(context: inout GraphicsContext, element: DrawnElement, size: CGSize, opacityMultiplier: Double = 1.0) {
        let scaleX = size.width / CGFloat(vm.canvasWidth)
        let scaleY = size.height / CGFloat(vm.canvasHeight)
        let color = Color(hex: element.color)

        context.opacity = element.opacity * opacityMultiplier

        // Apply flip transforms
        var transform = CGAffineTransform.identity
        if element.isFlippedH {
            transform = transform.scaledBy(x: -1, y: 1)
            transform = transform.translatedBy(x: -CGFloat(vm.canvasWidth), y: 0)
        }
        if element.isFlippedV {
            transform = transform.scaledBy(x: 1, y: -1)
            transform = transform.translatedBy(x: 0, y: -CGFloat(vm.canvasHeight))
        }

        switch element.tool {
        case .pencil, .pen, .brush, .marker, .crayon, .eraser, .smudge:
            guard element.points.count >= 2 else { return }
            var path = Path()
            let first = element.points[0]
            path.move(to: CGPoint(x: first.x * scaleX, y: first.y * scaleY))

            if element.points.count == 2 {
                let p = element.points[1]
                path.addLine(to: CGPoint(x: p.x * scaleX, y: p.y * scaleY))
            } else {
                for i in 1..<element.points.count {
                    let prev = element.points[i - 1]
                    let curr = element.points[i]
                    let midX = (prev.x + curr.x) / 2 * scaleX
                    let midY = (prev.y + curr.y) / 2 * scaleY
                    path.addQuadCurve(
                        to: CGPoint(x: midX, y: midY),
                        control: CGPoint(x: prev.x * scaleX, y: prev.y * scaleY)
                    )
                }
                let last = element.points.last!
                path.addLine(to: CGPoint(x: last.x * scaleX, y: last.y * scaleY))
            }

            let lineWidth = element.width * scaleX * brushWidthMultiplier(for: element.tool)

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
            path.move(to: CGPoint(x: element.points[0].x * scaleX, y: element.points[0].y * scaleY))
            path.addLine(to: CGPoint(x: element.points[1].x * scaleX, y: element.points[1].y * scaleY))
            context.stroke(path, with: .color(color), lineWidth: element.width * scaleX)

        case .rectangle:
            guard element.points.count >= 2 else { return }
            let rect = CGRect(
                x: min(element.points[0].x, element.points[1].x) * scaleX,
                y: min(element.points[0].y, element.points[1].y) * scaleY,
                width: abs(element.points[1].x - element.points[0].x) * scaleX,
                height: abs(element.points[1].y - element.points[0].y) * scaleY
            )
            context.stroke(Path(roundedRect: rect, cornerRadius: element.cornerRadius * scaleX), with: .color(color), lineWidth: element.width * scaleX)

        case .circle:
            guard element.points.count >= 2 else { return }
            let center = CGPoint(
                x: (element.points[0].x + element.points[1].x) / 2 * scaleX,
                y: (element.points[0].y + element.points[1].y) / 2 * scaleY
            )
            let radiusX = abs(element.points[1].x - element.points[0].x) / 2 * scaleX
            let radiusY = abs(element.points[1].y - element.points[0].y) / 2 * scaleY
            let path = Path(ellipseIn: CGRect(
                x: center.x - radiusX, y: center.y - radiusY,
                width: radiusX * 2, height: radiusY * 2
            ))
            context.stroke(path, with: .color(color), lineWidth: element.width * scaleX)

        case .text:
            if let text = element.textContent ?? element.fillColor, let first = element.points.first {
                var font = UIFont.systemFont(ofSize: element.fontSize, weight: element.isBold ? .bold : .regular)
                if element.isItalic {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic)
                    if let desc = descriptor { font = UIFont(descriptor: desc, size: element.fontSize) }
                }
                context.draw(
                    Text(text).font(Font(font).design(.monospaced)).foregroundColor(color),
                    at: CGPoint(x: first.x * scaleX, y: first.y * scaleY),
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
        path.move(to: CGPoint(x: points[0].x * scaleX, y: points[0].y * scaleY))
        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]
            let midX = (prev.x + curr.x) / 2 * scaleX
            let midY = (prev.y + curr.y) / 2 * scaleY
            path.addQuadCurve(
                to: CGPoint(x: midX, y: midY),
                control: CGPoint(x: prev.x * scaleX, y: prev.y * scaleY)
            )
        }

        context.stroke(path, with: .color(color.opacity(vm.toolOpacity)), style: StrokeStyle(
            lineWidth: vm.strokeWidth * scaleX * brushWidthMultiplier(for: vm.selectedTool),
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
            context.stroke(path, with: .color(color), lineWidth: vm.strokeWidth * scaleX)

        case .rectangle:
            let rect = CGRect(
                x: min(start.x, end.x) * scaleX,
                y: min(start.y, end.y) * scaleY,
                width: abs(end.x - start.x) * scaleX,
                height: abs(end.y - start.y) * scaleY
            )
            context.stroke(Path(roundedRect: rect, cornerRadius: vm.shapeCornerRadius * scaleX), with: .color(color), lineWidth: vm.strokeWidth * scaleX)

        case .circle:
            let cx = (start.x + end.x) / 2 * scaleX
            let cy = (start.y + end.y) / 2 * scaleY
            let rx = abs(end.x - start.x) / 2 * scaleX
            let ry = abs(end.y - start.y) / 2 * scaleY
            let path = Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
            context.stroke(path, with: .color(color), lineWidth: vm.strokeWidth * scaleX)

        default:
            break
        }
    }

    // MARK: - Selection Indicators
    @ViewBuilder
    func selectionIndicators(size: CGSize) -> some View {
        let scaleX = size.width / CGFloat(vm.canvasWidth)
        let scaleY = size.height / CGFloat(vm.canvasHeight)

        ForEach(Array(vm.selectedElementIDs), id: \.self) { id in
            if let element = vm.currentFrame.elements.first(where: { $0.id == id }) {
                let points = element.points
                guard !points.isEmpty else { return }

                let minX = points.map(\.x).min() ?? 0
                let maxX = points.map(\.x).max() ?? 0
                let minY = points.map(\.y).min() ?? 0
                let maxY = points.map(\.y).max() ?? 0
                let padding: CGFloat = 4

                let rect = CGRect(
                    x: minX * scaleX - padding,
                    y: minY * scaleY - padding,
                    width: (maxX - minX) * scaleX + padding * 2,
                    height: (maxY - minY) * scaleY + padding * 2
                )

                Rectangle()
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
                    .allowsHitTesting(false)
            }
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
