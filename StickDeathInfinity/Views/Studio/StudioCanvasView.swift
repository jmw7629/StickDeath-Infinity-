import SwiftUI

struct StudioCanvasView: View {
    @ObservedObject var vm: StudioViewModel
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var gestureActive = false
    @State private var input: StudioStrokeInput?
    @State private var panOrigin: CGSize?
    @State private var liveElement: DrawnElement?
    @State private var livePrepared: StudioFrameRenderer.PreparedBrushes?
    @State private var inputFailure: String?
    @State private var previewFailure: String?
    @State private var lastPreviewTime: TimeInterval = 0
    var body: some View {
        GeometryReader { geo in
            let size = canvasRect(in: geo.size)
            let currentPrepared = Result { try livePrepared ?? StudioFrameRenderer.prepare(frame: vm.currentFrame) }
            let onionPrepared = vm.showOnionSkin ? vm.previousFrame.map { frame in Result { try StudioFrameRenderer.prepare(frame: frame) } } : nil
            ZStack {
                Color.clear
                ZStack {
                    Color.white
                    Canvas { context, actual in
                        if vm.showOnionSkin, let previous = vm.previousFrame {
                            var onion = context
                            onion.opacity = 0.2
                            if case .success(let brushes)? = onionPrepared {
                                if let error = StudioFrameRenderer.draw(context: &onion, frame: previous, layers: vm.layers,
                                    canvasSize: CGSize(width: vm.canvasWidth, height: vm.canvasHeight), size: actual,
                                    rasterData: vm.rasterData(previous.rasterAssetID), preparedBrushes: brushes) {
                                    StudioFrameRenderer.drawFailure(error, context: &context, size: actual)
                                }
                            } else if case .failure(let error)? = onionPrepared {
                                StudioFrameRenderer.drawFailure(error, context: &context, size: actual)
                            }
                        }
                        switch currentPrepared {
                        case .success(let brushes):
                            if let error = StudioFrameRenderer.draw(context: &context, frame: vm.currentFrame, layers: vm.layers,
                                canvasSize: CGSize(width: vm.canvasWidth, height: vm.canvasHeight), size: actual,
                                rasterData: vm.rasterData(vm.currentFrame.rasterAssetID), liveElement: liveElement,
                                preparedBrushes: brushes) {
                                StudioFrameRenderer.drawFailure(error, context: &context, size: actual)
                            }
                        case .failure(let error): StudioFrameRenderer.drawFailure(error, context: &context, size: actual)
                        }
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
            .overlay(alignment: .bottom) {
                if let pending = vm.pendingBrushStroke {
                    VStack(spacing: 6) {
                        Text("Brush draft not saved").font(.specialElite(12)).foregroundColor(.red)
                        Text(pending.reason).font(.system(size: 10)).foregroundColor(.white)
                            .lineLimit(4)
                        HStack(spacing: 12) {
                            Button("Retry with settings") { vm.retryRejectedBrush() }
                                .disabled(!pending.inputComplete)
                                .accessibilityIdentifier("studio.brush-retry")
                            Button("Discard draft") { vm.discardRejectedBrush() }
                                .accessibilityIdentifier("studio.brush-discard")
                        }.font(.system(size: 11, weight: .bold))
                    }.padding(10).background(Color.black.opacity(0.95)).cornerRadius(10)
                        .padding(8)
                }
            }
        }
        .onChange(of: vm.currentFrame.id) { _, _ in
            interruptInput("The frame changed before touch input finished. The incomplete draft is retained for explicit discard.")
        }
        .onChange(of: gestureActive) { _, active in
            if !active { interruptInput("Touch input was interrupted. The incomplete draft is retained for explicit discard.") }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { interruptInput("Studio left the foreground before the stroke finished. The incomplete draft remains unsaved.") }
        }
        .onDisappear { interruptInput("Studio closed before the stroke finished. The incomplete draft remains unsaved.") }
    }
    private func canvasRect(in size: CGSize) -> CGSize {
        let ratio = CGFloat(vm.canvasWidth) / CGFloat(vm.canvasHeight)
        let width = max(1, size.width * 0.9), height = max(1, size.height * 0.9)
        return width / height > ratio ? CGSize(width: height * ratio, height: height) : CGSize(width: width, height: width / ratio)
    }
    private func gesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard vm.pendingBrushStroke == nil else { return }
                if input == nil && vm.selectedTool == .hand {
                    if panOrigin == nil { panOrigin = vm.canvasOffset }
                    vm.canvasOffset = CGSize(width: (panOrigin?.width ?? 0) + value.translation.width,
                                             height: (panOrigin?.height ?? 0) + value.translation.height)
                    return
                }
                guard inputFailure == nil else { return }
                if input == nil {
                    guard [.pencil, .pen, .brush, .marker, .crayon, .eraser, .line, .rectangle, .circle].contains(vm.selectedTool), !vm.isPlaying else { return }
                    guard let layer = vm.layers.first(where: { $0.id == vm.activeLayerID }), layer.visible, !layer.isFullyLocked else { return }
                    do {
                        let id = UUID().uuidString
                        let styled = [.pencil, .pen, .brush, .marker, .crayon].contains(vm.selectedTool)
                        let brush = styled ? try vm.brushDescriptor(elementID: id) : nil
                        guard vm.beginStrokeInput(id: id) else { return }
                        input = StudioStrokeInput(id: id, frameID: vm.currentFrame.id, layerID: vm.activeLayerID,
                            tool: vm.selectedTool, color: vm.strokeColorHex, width: vm.strokeWidth,
                            opacity: styled ? vm.capturedStrokeOpacity : vm.strokeOpacity,
                            brush: brush,
                            documentSize: CGSize(width: vm.canvasWidth, height: vm.canvasHeight), viewportSize: size,
                            startedAt: value.time)
                    } catch { vm.message = error.localizedDescription; return }
                }
                do { try input?.append(location: value.location, time: value.time) }
                catch { inputFailure = error.localizedDescription; return }
                let now = ProcessInfo.processInfo.systemUptime
                // Capture every supported sample; only preview regeneration is
                // coalesced to 30Hz. Commit always prepares the complete input.
                if now - lastPreviewTime >= 1 / 30, previewFailure == nil, let input {
                    do {
                        let next = try StudioFrameRenderer.prepare(frame: vm.currentFrame, liveElement: input.element)
                        liveElement = input.element; livePrepared = next; lastPreviewTime = now
                    } catch { previewFailure = error.localizedDescription }
                }
            }
            .onEnded { value in
                defer { clearInput() }
                guard vm.pendingBrushStroke == nil else { return }
                if panOrigin != nil { return }
                if var captured = input, !captured.points.isEmpty {
                    if let inputFailure {
                        vm.retainRejectedBrush(captured.element, frameID: captured.frameID,
                            reason: inputFailure, inputComplete: false)
                    } else {
                        do {
                            try captured.append(location: value.location, time: value.time)
                            _ = vm.commitElement(captured.element, frameID: captured.frameID)
                        } catch {
                            vm.retainRejectedBrush(captured.element, frameID: captured.frameID,
                                reason: error.localizedDescription, inputComplete: false)
                        }
                    }
                    return
                }
                if vm.selectedTool == .zoom { vm.zoomIn(); return }
                if vm.selectedTool == .move {
                    vm.selectElement(at: CGPoint(x: value.location.x / size.width * CGFloat(vm.canvasWidth),
                                                 y: value.location.y / size.height * CGFloat(vm.canvasHeight)))
                    return
                }
                vm.message = "This tool or layer cannot edit here yet. Choose an unlocked Brush, Pen, Pencil, Eraser or shape tool."
            }
    }
    private func clearInput() {
        if let input { vm.finishStrokeInput(id: input.id) }
        input = nil; panOrigin = nil; liveElement = nil; livePrepared = nil
        inputFailure = nil; previewFailure = nil; lastPreviewTime = 0
    }
    private func interruptInput(_ reason: String) {
        if let input { vm.interruptStrokeInput(input, reason: reason) }
        clearInput()
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
