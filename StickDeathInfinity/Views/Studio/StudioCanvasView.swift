import SwiftUI

struct StudioCanvasView: View {
    @ObservedObject var vm: StudioViewModel
    @State private var input: CanvasInput?
    @State private var panOrigin: CGSize?

    private struct CanvasInput {
        let frameID: String
        let layerID: String
        let tool: DrawingTool
        let color: String
        let width: Double
        let opacity: Double
        var points: [StrokePoint]
        var element: DrawnElement {
            let shape = [.line, .rectangle, .circle].contains(tool)
            let rendered = shape && points.count > 1 ? [points[0], points[points.count - 1]] : points
            return DrawnElement(id: "live", tool: tool, points: rendered, color: color, width: width, opacity: opacity, layerID: layerID)
        }
    }
    var body: some View {
        GeometryReader { geo in
            let size = canvasRect(in: geo.size)
            ZStack {
                Color.clear
                ZStack {
                    Color.white
                    Canvas { context, actual in
                        if vm.showOnionSkin, let previous = vm.previousFrame {
                            var onion = context
                            onion.opacity = 0.2
                            StudioFrameRenderer.draw(context: &onion, frame: previous, layers: vm.layers,
                                canvasSize: CGSize(width: vm.canvasWidth, height: vm.canvasHeight), size: actual,
                                rasterData: vm.rasterData(previous.rasterAssetID))
                        }
                        StudioFrameRenderer.draw(context: &context, frame: vm.currentFrame, layers: vm.layers,
                            canvasSize: CGSize(width: vm.canvasWidth, height: vm.canvasHeight), size: actual,
                            rasterData: vm.rasterData(vm.currentFrame.rasterAssetID),
                            liveElement: input?.frameID == vm.currentFrame.id ? input?.element : nil)
                        for element in vm.currentFrame.elements where vm.selectedElementIDs.contains(element.id) {
                            guard let first = element.points.first else { continue }
                            let xs = element.points.map(\.x), ys = element.points.map(\.y)
                            let x = xs.min() ?? first.x, y = ys.min() ?? first.y
                            let rect = CGRect(x: x / CGFloat(vm.canvasWidth) * actual.width - 3,
                                y: y / CGFloat(vm.canvasHeight) * actual.height - 3,
                                width: ((xs.max() ?? x) - x) / CGFloat(vm.canvasWidth) * actual.width + 6,
                                height: ((ys.max() ?? y) - y) / CGFloat(vm.canvasHeight) * actual.height + 6)
                            context.stroke(Path(rect), with: .color(.red), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Animation canvas")
                    .accessibilityIdentifier("studio.canvas")
                    if vm.gridEnabled { GridOverlay().allowsHitTesting(false) }
                }
                .frame(width: size.width, height: size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(gesture(size: size))
                .scaleEffect(vm.canvasScale)
                .offset(vm.canvasOffset)
                .shadow(color: .black.opacity(0.4), radius: 12)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .onChange(of: vm.currentFrame.id) { _ in input = nil }
    }
    private func canvasRect(in size: CGSize) -> CGSize {
        let ratio = CGFloat(vm.canvasWidth) / CGFloat(vm.canvasHeight)
        let width = max(1, size.width * 0.9), height = max(1, size.height * 0.9)
        return width / height > ratio ? CGSize(width: height * ratio, height: height) : CGSize(width: width, height: width / ratio)
    }
    private func gesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if vm.selectedTool == .hand {
                    if panOrigin == nil { panOrigin = vm.canvasOffset }
                    vm.canvasOffset = CGSize(width: (panOrigin?.width ?? 0) + value.translation.width,
                                             height: (panOrigin?.height ?? 0) + value.translation.height)
                    return
                }
                guard [.pencil, .pen, .brush, .marker, .crayon, .eraser, .line, .rectangle, .circle].contains(vm.selectedTool), !vm.isPlaying else { return }
                guard let layer = vm.layers.first(where: { $0.id == vm.activeLayerID }), layer.visible, !layer.isFullyLocked else { return }
                let point = StrokePoint(x: min(max(value.location.x / size.width, 0), 1) * CGFloat(vm.canvasWidth),
                                        y: min(max(value.location.y / size.height, 0), 1) * CGFloat(vm.canvasHeight))
                if input == nil {
                    input = CanvasInput(frameID: vm.currentFrame.id, layerID: vm.activeLayerID, tool: vm.selectedTool,
                        color: vm.strokeColorHex, width: vm.strokeWidth, opacity: vm.strokeOpacity, points: [])
                }
                input?.points.append(point)
            }
            .onEnded { value in
                defer { input = nil; panOrigin = nil }
                if vm.selectedTool == .hand { return }
                if vm.selectedTool == .zoom { vm.zoomIn(); return }
                if vm.selectedTool == .move {
                    vm.selectElement(at: CGPoint(x: value.location.x / size.width * CGFloat(vm.canvasWidth),
                                                 y: value.location.y / size.height * CGFloat(vm.canvasHeight)))
                    return
                }
                guard let captured = input, !captured.points.isEmpty else {
                    vm.message = "This tool or layer cannot edit here yet. Choose an unlocked Brush, Pen, Pencil, Eraser or shape tool."
                    return
                }
                let source = captured.element
                let element = DrawnElement(id: UUID().uuidString, tool: source.tool, points: source.points, color: source.color,
                    width: source.width, opacity: source.opacity, layerID: source.layerID)
                vm.commitElement(element, frameID: captured.frameID)
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
