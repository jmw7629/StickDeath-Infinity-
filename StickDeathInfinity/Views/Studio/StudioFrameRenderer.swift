import SwiftUI

struct StudioFrameThumbnail: View {
    @ObservedObject var vm: StudioViewModel
    let frame: AnimationFrame
    var body: some View {
        let prepared = Result { try StudioFrameRenderer.prepare(frame: frame) }
        Canvas { context, size in
            let scale = min(size.width / CGFloat(vm.canvasWidth), size.height / CGFloat(vm.canvasHeight))
            let fitted = CGSize(width: CGFloat(vm.canvasWidth) * scale, height: CGFloat(vm.canvasHeight) * scale)
            context.translateBy(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2)
            context.fill(Path(CGRect(origin: .zero, size: fitted)), with: .color(.white))
            switch prepared {
            case .success(let brushes):
                if let error = StudioFrameRenderer.draw(context: &context, frame: frame, layers: vm.layers,
                    canvasSize: CGSize(width: vm.canvasWidth, height: vm.canvasHeight), size: fitted,
                    rasterData: vm.rasterData(frame.rasterAssetID), preparedBrushes: brushes) {
                    StudioFrameRenderer.drawFailure(error, context: &context, size: fitted)
                }
            case .failure(let error): StudioFrameRenderer.drawFailure(error, context: &context, size: fitted)
            }
        }
    }
}

/// One compositing path for the live canvas, timeline and frames viewer.
struct StudioFrameRenderer {
    struct PreparedBrushes {
        fileprivate let elements: [DrawnElement]
        fileprivate let strokes: [String: (geometry: StudioBrushRenderer.Geometry, color: StudioBrushColor)]
    }
    /// Performs all brush validation/allocation before a Canvas or export draws.
    static func prepare(frame: AnimationFrame, liveElement: DrawnElement? = nil) throws -> PreparedBrushes {
        let elements = (frame.elements + (liveElement.map { [$0] } ?? [])).filter { $0.brush != nil }
        var strokes: [String: (geometry: StudioBrushRenderer.Geometry, color: StudioBrushColor)] = [:]
        var marks = 0
        for element in elements {
            guard strokes[element.id] == nil else { throw StudioDocumentError.invalid("A brush identity is duplicated.") }
            let geometry = try StudioBrushGeometryCache.geometry(for: element)
            marks += geometry.marks.count
            guard marks <= StudioBrushGeometryCache.maximumFrameMarks else {
                throw StudioBrushError.workLimit("This frame exceeds the brush rendering budget. The stroke has not been committed.")
            }
            strokes[element.id] = (geometry, try StudioBrushGeometryCache.color(element.color))
        }
        return PreparedBrushes(elements: elements, strokes: strokes)
    }
    @discardableResult
    static func draw(context: inout GraphicsContext, frame: AnimationFrame, layers: [CanvasLayer], canvasSize: CGSize,
                     size: CGSize, rasterData: Data? = nil, liveElement: DrawnElement? = nil,
                     preparedBrushes: PreparedBrushes? = nil) -> Error? {
        let prepared: PreparedBrushes
        do {
            prepared = try preparedBrushes ?? prepare(frame: frame, liveElement: liveElement)
            guard prepared.elements == (frame.elements + (liveElement.map { [$0] } ?? [])).filter({ $0.brush != nil }) else {
                throw StudioDocumentError.invalid("Prepared brushes do not match this frame. No frame was rendered.")
            }
        } catch { return error }
        var failure: Error?
        for layer in layers.reversed() where layer.visible {
            var composite = context
            composite.opacity *= layer.opacity
            composite.blendMode = blend(layer.blendMode)
            if layer.glowEnabled { composite.addFilter(.shadow(color: Color(hex: layer.glowColor ?? "#FF0000"), radius: 5)) }
            composite.drawLayer { local in
                if frame.rasterLayerID == layer.id, let data = rasterData, let image = UIImage(data: data) {
                    local.draw(Image(uiImage: image), in: CGRect(origin: .zero, size: size))
                }
                for element in frame.elements where element.layerID == layer.id {
                    var elementContext = local
                    do { try drawElement(context: &elementContext, element: element, size: size, canvasSize: canvasSize,
                        brush: prepared.strokes[element.id]) } catch { failure = error; return }
                }
                if let element = liveElement, element.layerID == layer.id {
                    var elementContext = local
                    do { try drawElement(context: &elementContext, element: element, size: size, canvasSize: canvasSize,
                        brush: prepared.strokes[element.id]) } catch { failure = error }
                }
            }
            if let failure { return failure }
        }
        return nil
    }
    static func drawFailure(_ error: Error, context: inout GraphicsContext, size: CGSize) {
        context.draw(Text("Render unavailable: \(error.localizedDescription)").font(.system(size: 11)).foregroundColor(.red),
                     in: CGRect(origin: .zero, size: size))
    }
    private static func blend(_ name: String) -> GraphicsContext.BlendMode {
        switch name.lowercased() {
        case "multiply": return .multiply
        case "screen": return .screen
        case "overlay": return .overlay
        case "darken": return .darken
        case "lighten": return .lighten
        default: return .normal
        }
    }
    private static func drawElement(context: inout GraphicsContext, element: DrawnElement, size: CGSize, canvasSize: CGSize,
                                   brush: (geometry: StudioBrushRenderer.Geometry, color: StudioBrushColor)?) throws {
        let scaleX = size.width / canvasSize.width
        let scaleY = size.height / canvasSize.height
        let color = Color(hex: element.color)

        if element.brush != nil {
            guard let brush else { throw StudioDocumentError.invalid("A prepared brush is missing.") }
            context.scaleBy(x: scaleX, y: scaleY)
            // Geometry already contains canonical element opacity. Applying it
            // again to this context would square it and break layer/onion alpha.
            try StudioBrushRenderer.draw(brush.geometry, color: brush.color, context: &context)
            return
        }

        context.opacity = element.opacity

        switch element.tool {
        case .pencil, .pen, .brush, .marker, .crayon, .eraser, .smudge:
            guard !element.points.isEmpty else { return }
            if element.points.count == 1 {
                let point = element.points[0]
                let radius = max(0.5, element.width * scaleX * brushWidthMultiplier(for: element.tool) / 2)
                if element.tool == .eraser { context.blendMode = .clear }
                context.fill(Path(ellipseIn: CGRect(x: point.x * scaleX - radius, y: point.y * scaleY - radius, width: radius * 2, height: radius * 2)), with: .color(color))
                context.blendMode = .normal
                return
            }
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
            context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(color), lineWidth: element.width * scaleX)

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
            if let text = element.fillColor, let first = element.points.first {
                context.draw(
                    Text(text).font(.system(size: element.width * 3 * min(scaleX, scaleY), design: .monospaced)).foregroundColor(color),
                    at: CGPoint(x: first.x * scaleX, y: first.y * scaleY),
                    anchor: .topLeading
                )
            }

        default:
            break
        }

        context.opacity = 1.0
    }

    private static func brushWidthMultiplier(for tool: DrawingTool) -> CGFloat {
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

}
