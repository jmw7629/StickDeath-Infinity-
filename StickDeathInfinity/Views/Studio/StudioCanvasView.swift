import SwiftUI

struct StudioCanvasView: View {
    @ObservedObject var vm: StudioViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @GestureState private var gestureActive = false
    @State private var input: StudioStrokeInput?
    @State private var moveCapture: StudioViewModel.MoveCapture?
    @State private var moveLayout: StudioColorSampleGesture.Layout?
    @State private var moveFrame: AnimationFrame?
    @State private var startedAsMove = false
    @State private var moveCancelled = false
    @State private var handleCapture: StudioViewModel.SelectionHandleCapture?
    @State private var handleGeometry: StudioSelectionHandleGeometry?
    @State private var handleKind: StudioSelectionHandleGeometry.Kind?
    @State private var handleValues = StudioSelectionHandleGeometry.Values()
    @State private var handleFrame: AnimationFrame?
    @State private var startedAsHandle = false
    @State private var handleCancelled = false
    @State private var areaCapture: StudioViewModel.AreaSelectionCapture?
    @State private var areaLayout: StudioColorSampleGesture.Layout?
    @State private var areaTrace = StudioSelectionTrace()
    @State private var areaPreview: [CGPoint] = []
    @State private var startedAsArea = false
    @State private var areaCancelled = false
    @State private var panOrigin: CGSize?
    // A completed gesture still needs its captured context in onEnded.
    // GestureState resets at touch end, so it cannot own this transaction.
    @State private var colorInput = StudioColorSampleGesture()
    @State private var touchID: UUID?
    @State private var fillInput = StudioFillGesture()
    @StateObject private var fillSession = StudioFillSession()
    @State private var liveElement: DrawnElement?
    @State private var livePrepared: StudioFrameRenderer.PreparedBrushes?
    @State private var inputFailure: String?
    @State private var previewFailure: String?
    @State private var lastPreviewTime: TimeInterval = 0
    var body: some View {
        GeometryReader { geo in
            let size = canvasRect(in: geo.size)
            let documentSize = CGSize(width: vm.canvasWidth, height: vm.canvasHeight)
            let displayedFrame = handleFrame ?? moveFrame ?? vm.currentFrame
            let handles = selectionHandles(frame: displayedFrame, size: size)
            let currentPrepared = Result { try livePrepared ?? StudioFrameRenderer.prepare(frame: displayedFrame) }
            let rasterSize = min(4096, max(1, Int(ceil(max(size.width, size.height) * displayScale * max(1, vm.canvasScale)))))
            let currentRaster = Result { try StudioFrameRenderer.prepareRaster(frame: vm.currentFrame, layers: vm.layers,
                data: vm.rasterData(vm.currentFrame.rasterAssetID), maximumDimension: rasterSize) }
            let onionRaster = vm.showOnionSkin ? vm.previousFrame.map { frame in Result {
                try StudioFrameRenderer.prepareRaster(frame: frame, layers: vm.layers,
                    data: vm.rasterData(frame.rasterAssetID), maximumDimension: rasterSize)
            } } : nil
            let onionPrepared = vm.showOnionSkin ? vm.previousFrame.map { frame in Result { try StudioFrameRenderer.prepare(frame: frame) } } : nil
            ZStack {
                Color.clear
                ZStack {
                    Color.white
                    Canvas { context, actual in
                        if vm.showOnionSkin, let previous = vm.previousFrame {
                            var onion = context
                            onion.opacity = 0.2
                            if case .success(let brushes)? = onionPrepared, case .success(let image)? = onionRaster {
                                if let error = StudioFrameRenderer.draw(context: &onion, frame: previous, layers: vm.layers,
                                    canvasSize: CGSize(width: vm.canvasWidth, height: vm.canvasHeight), size: actual,
                                    rasterData: vm.rasterData(previous.rasterAssetID), preparedBrushes: brushes, preparedRaster: image) {
                                    StudioFrameRenderer.drawFailure(error, context: &context, size: actual)
                                }
                            } else if case .failure(let error)? = onionPrepared {
                                StudioFrameRenderer.drawFailure(error, context: &context, size: actual)
                            } else if case .failure(let error)? = onionRaster {
                                StudioFrameRenderer.drawFailure(error, context: &context, size: actual)
                            }
                        }
                        switch (currentPrepared, currentRaster) {
                        case (.success(let brushes), .success(let image)):
                            if let error = StudioFrameRenderer.draw(context: &context, frame: displayedFrame, layers: vm.layers,
                                canvasSize: CGSize(width: vm.canvasWidth, height: vm.canvasHeight), size: actual,
                                rasterData: vm.rasterData(vm.currentFrame.rasterAssetID), liveElement: liveElement,
                                preparedBrushes: brushes, preparedRaster: image) {
                                StudioFrameRenderer.drawFailure(error, context: &context, size: actual)
                            }
                        case (.failure(let error), _), (_, .failure(let error)):
                            StudioFrameRenderer.drawFailure(error, context: &context, size: actual)
                        }
                        for element in displayedFrame.elements where vm.selectedElementIDs.contains(element.id) {
                            guard let bounds = try? StudioSelectionRegion.drawingBounds(element) else { continue }
                            let rect = CGRect(x: bounds.minX / CGFloat(vm.canvasWidth) * actual.width - 3,
                                y: bounds.minY / CGFloat(vm.canvasHeight) * actual.height - 3,
                                width: bounds.width / CGFloat(vm.canvasWidth) * actual.width + 6,
                                height: bounds.height / CGFloat(vm.canvasHeight) * actual.height + 6)
                            context.stroke(Path(rect), with: .color(.red), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                        if let handles {
                            for handle in handles.handles {
                                let r = handles.visualRadius
                                let circle = Path(ellipseIn: CGRect(x: handle.point.x-r, y: handle.point.y-r, width: 2*r, height: 2*r))
                                context.fill(circle, with: .color(handle.kind == .rotate ? .red : .white))
                                context.stroke(circle, with: .color(.red), lineWidth: 2 / handles.zoom)
                                if handle.kind == .rotate {
                                    context.draw(Text("↻").font(.system(size: 10 / handles.zoom, weight: .bold)).foregroundColor(.white), at: handle.point)
                                }
                            }
                        }
                        if let first = areaPreview.first {
                            func scaled(_ point: CGPoint) -> CGPoint {
                                CGPoint(x: point.x / documentSize.width * actual.width,
                                        y: point.y / documentSize.height * actual.height)
                            }
                            var outline = Path(); outline.move(to: scaled(first))
                            areaPreview.dropFirst().forEach { outline.addLine(to: scaled($0)) }
                            if areaPreview.count >= 3 {
                                outline.closeSubpath()
                                context.fill(outline, with: .color(.red.opacity(0.08)), style: FillStyle(eoFill: true))
                            }
                            context.stroke(outline, with: .color(.red), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Animation canvas")
                    .accessibilityIdentifier("studio.canvas")
                    .accessibilityValue(handles == nil ? "" : "Selected artwork: drag white corner handles to resize or the red handle to rotate. The Move popup also provides Scale and Angle controls.")
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
            .onChange(of: StudioColorSampleGesture.Layout(viewport: size,
                scale: vm.canvasScale, offset: vm.canvasOffset)) { _, _ in
                colorInput.invalidate(); fillInput.invalidate(); cancelMovePreview(); cancelAreaPreview(); cancelHandlePreview()
            }
            .overlay(alignment: .bottom) {
                if fillSession.isFilling {
                    HStack(spacing: 12) {
                        ProgressView().tint(.red)
                        Text("Filling artwork…").font(.specialElite(12))
                        Button("Cancel") { fillSession.cancel() }
                            .accessibilityIdentifier("studio.fill.cancel")
                    }.padding(12).background(Color.black.opacity(0.95)).cornerRadius(10).padding(8)
                        .accessibilityIdentifier("studio.fill.progress")
                } else if let pending = vm.pendingBrushStroke {
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
            fillSession.cancel()
            interruptInput("The frame changed before touch input finished. The incomplete draft is retained for explicit discard.")
        }
        .onChange(of: StudioFillContext.current(vm, ownedStroke: vm.activeStrokeID)) { _, _ in
            fillInput.invalidate()
            if fillSession.isFilling { fillSession.cancel() }
        }
        .onChange(of: gestureActive) { _, active in
            guard !active, let endedTouch = touchID else { return }
            // Let onEnded consume its capture first. A cancelled gesture has
            // no onEnded callback; clear only that touch on the next turn.
            Task { @MainActor in
                await Task.yield()
                guard !gestureActive, touchID == endedTouch else { return }
                interruptInput("Touch input was interrupted. The incomplete draft is retained for explicit discard.")
            }
        }
        .onChange(of: vm.document.revision) { _, _ in cancelMovePreview() }
        .onChange(of: vm.selectedTool) { _, _ in cancelMovePreview() }
        .onChange(of: vm.selectionMode) { _, _ in cancelMovePreview() }
        .onChange(of: vm.isPlaying) { _, _ in cancelMovePreview() }
        .onChange(of: vm.beginSelectionHandle()) { _, _ in cancelHandlePreview() }
        .onChange(of: vm.beginAreaSelection()) { _, _ in cancelAreaPreview() }
        .onChange(of: vm.beginColorSample()) { _, _ in colorInput.invalidate() }
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
                if touchID == nil {
                    touchID = UUID(); colorInput = StudioColorSampleGesture(); fillInput = StudioFillGesture()
                    startedAsMove = vm.selectedTool == .move; moveCancelled = false
                    startedAsArea = vm.selectedTool == .lasso; areaCancelled = false
                    if let geometry = selectionHandles(frame: vm.currentFrame, size: size),
                       let kind = geometry.hit(value.startLocation), let capture = vm.beginSelectionHandle() {
                        startedAsHandle = true; handleCancelled = false; startedAsMove = false
                        handleCapture = capture; handleGeometry = geometry; handleKind = kind
                        moveLayout = .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset)
                    }
                    if startedAsMove {
                        moveLayout = .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset)
                        moveCapture = vm.beginMove(at: documentPoint(value.startLocation, size: size))
                    }
                    if startedAsArea {
                        areaCapture = vm.beginAreaSelection()
                        areaLayout = .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset)
                        _ = updateArea(location: value.startLocation, size: size)
                    }
                }
                if startedAsHandle { _ = updateHandle(start: value.startLocation, location: value.location, size: size); return }
                if startedAsArea { _ = updateArea(location: value.location, size: size); return }
                if startedAsMove {
                    updateMove(delta: value.translation, size: size)
                    return
                }
                colorInput.update(context: input == nil ? vm.beginColorSample() : nil,
                    layout: .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset),
                    foreground: scenePhase == .active)
                fillInput.update(context: input == nil ? StudioFillContext.current(vm) : nil,
                    layout: .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset),
                    foreground: scenePhase == .active)
                guard vm.pendingBrushStroke == nil else { return }
                if fillInput.startedAsFill || (input == nil && vm.selectedTool == .fill) { return }
                if colorInput.startedAsPicker || (input == nil && vm.selectedTool == .eyedropper) { return }
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
                        let shape = try vm.shapeDescriptor()
                        let eraser = try vm.eraserDescriptor()
                        guard vm.beginStrokeInput(id: id) else { return }
                        input = StudioStrokeInput(id: id, frameID: vm.currentFrame.id, layerID: vm.activeLayerID,
                            tool: vm.selectedTool, color: vm.strokeColorHex, width: vm.strokeWidth,
                            opacity: styled || shape != nil ? vm.capturedStrokeOpacity : vm.strokeOpacity,
                            brush: brush,
                            documentSize: CGSize(width: vm.canvasWidth, height: vm.canvasHeight), viewportSize: size,
                            startedAt: value.time, shape: shape, eraser: eraser)
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
                if startedAsHandle {
                    guard updateHandle(start: value.startLocation, location: value.location, size: size, final: true),
                          let capture = handleCapture else { return }
                    _ = vm.finishSelectionHandle(capture, values: handleValues)
                    return
                }
                if startedAsArea {
                    guard updateArea(location: value.location, size: size), let capture = areaCapture else { return }
                    _ = vm.finishAreaSelection(capture, points: areaTrace.points)
                    return
                }
                if startedAsMove {
                    guard updateMove(delta: value.translation, size: size), let capture = moveCapture else { return }
                    _ = vm.finishMove(capture, delta: documentDelta(value.translation, size: size))
                    return
                }
                if fillInput.startedAsFill || (input == nil && vm.selectedTool == .fill) {
                    guard let fill = fillInput.resolve(location: value.location,
                        context: StudioFillContext.current(vm),
                        layout: .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset),
                        foreground: scenePhase == .active) else {
                        vm.message = "Studio changed during fill input. Choose a visible unlocked layer and start a new tap."
                        return
                    }
                    Task { await fillSession.fill(vm, context: fill.context, point: fill.point) }
                    return
                }
                if colorInput.startedAsPicker || (input == nil && vm.selectedTool == .eyedropper) {
                    guard let sample = colorInput.resolve(location: value.location,
                        context: vm.beginColorSample(),
                        layout: .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset),
                        foreground: scenePhase == .active) else {
                        vm.message = "Studio or the canvas changed during color sampling. Start a new tap."
                        return
                    }
                    _ = vm.sampleArtworkColor(at: sample.point, captured: sample.context)
                    return
                }
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
                vm.message = "This tool or layer cannot edit here yet. Choose an unlocked Brush, Pen, Pencil, Eraser or shape tool."
            }
    }
    private func documentPoint(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: point.x / size.width * CGFloat(vm.canvasWidth), y: point.y / size.height * CGFloat(vm.canvasHeight))
    }
    private func documentDelta(_ delta: CGSize, size: CGSize) -> CGSize {
        CGSize(width: delta.width / size.width * CGFloat(vm.canvasWidth), height: delta.height / size.height * CGFloat(vm.canvasHeight))
    }
    private func selectionHandles(frame: AnimationFrame, size: CGSize) -> StudioSelectionHandleGeometry? {
        guard vm.beginSelectionHandle() != nil else { return nil }
        var bounds = CGRect.null
        for element in frame.elements where vm.selectedElementIDs.contains(element.id) {
            guard let rect = try? StudioSelectionRegion.drawingBounds(element) else { return nil }
            bounds = bounds.union(rect)
        }
        return StudioSelectionHandleGeometry(bounds: bounds,
            documentSize: CGSize(width: vm.canvasWidth,height: vm.canvasHeight),viewport: size,zoom: vm.canvasScale)
    }
    private func cancelHandlePreview() {
        if startedAsHandle { handleCancelled = true; handleFrame = nil }
    }
    @discardableResult
    private func updateHandle(start: CGPoint, location: CGPoint, size: CGSize, final: Bool = false) -> Bool {
        guard !handleCancelled, let capture = handleCapture, let geometry = handleGeometry, let kind = handleKind else { return false }
        guard scenePhase == .active, vm.beginSelectionHandle() == capture,
              moveLayout == .init(viewport: size,scale: vm.canvasScale,offset: vm.canvasOffset) else {
            cancelHandlePreview(); return false
        }
        do {
            let values = try geometry.values(kind: kind,start: start,current: location)
            let now = ProcessInfo.processInfo.systemUptime
            if final || now-lastPreviewTime >= 1/30 {
                handleFrame = try vm.selectionHandlePreview(capture, values: values)
                handleValues = values; lastPreviewTime = now
            }
            return true
        } catch { cancelHandlePreview(); vm.message = error.localizedDescription; return false }
    }
    private func cancelMovePreview() {
        if startedAsMove { moveCancelled = true; moveFrame = nil }
    }
    private func cancelAreaPreview() {
        if startedAsArea { areaCancelled = true; areaPreview = [] }
    }
    @discardableResult
    private func updateArea(location: CGPoint, size: CGSize) -> Bool {
        guard !areaCancelled, let capture = areaCapture else { return false }
        guard scenePhase == .active, vm.beginAreaSelection() == capture,
              areaLayout == .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset) else {
            cancelAreaPreview(); return false
        }
        do {
            try areaTrace.append(documentPoint(location, size: size), kind: capture.kind)
            areaPreview = (try? StudioSelectionRegion(points: areaTrace.points, kind: capture.kind,
                smoothing: capture.smoothing).points) ?? areaTrace.points
            return true
        } catch { cancelAreaPreview(); vm.message = error.localizedDescription; return false }
    }
    @discardableResult
    private func updateMove(delta: CGSize, size: CGSize) -> Bool {
        guard !moveCancelled, let capture = moveCapture else { return false }
        guard scenePhase == .active, moveLayout == .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset),
              vm.moveIsCurrent(capture) else {
            cancelMovePreview(); vm.message = "Studio changed during the move. The artwork has not moved."; return false
        }
        do { moveFrame = try vm.movePreview(capture, delta: documentDelta(delta, size: size)); return true }
        catch { cancelMovePreview(); vm.message = error.localizedDescription; return false }
    }
    private func clearInput(endingTouch: Bool = true) {
        if let input { vm.finishStrokeInput(id: input.id) }
        input = nil; panOrigin = nil; liveElement = nil; livePrepared = nil
        inputFailure = nil; previewFailure = nil; lastPreviewTime = 0
        if endingTouch {
            colorInput = StudioColorSampleGesture(); fillInput = StudioFillGesture(); touchID = nil
            moveCapture = nil; moveLayout = nil; moveFrame = nil; startedAsMove = false; moveCancelled = false
            handleCapture = nil; handleGeometry = nil; handleKind = nil; handleFrame = nil
            handleValues = .init(); startedAsHandle = false; handleCancelled = false
            areaCapture = nil; areaLayout = nil; areaTrace = StudioSelectionTrace()
            areaPreview = []; startedAsArea = false; areaCancelled = false
        }
    }
    private func interruptInput(_ reason: String) {
        fillSession.cancel()
        if let input { vm.interruptStrokeInput(input, reason: reason) }
        colorInput.invalidate()
        fillInput.invalidate()
        cancelMovePreview()
        cancelAreaPreview()
        cancelHandlePreview()
        // A frame/scene change while the finger is down cancels that whole
        // touch. Keep its identity until physical end; a later move must not
        // capture the new frame as though it were a fresh gesture.
        clearInput(endingTouch: !gestureActive)
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
