import SwiftUI
import UIKit

struct StudioCanvasView: View {
    @ObservedObject var vm: StudioViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @State private var gestureActive = false
    @State private var input: StudioStrokeInput?
    @State private var eraserCapture: StudioViewModel.EraserInputCapture?
    @State private var strokeInputCancelled = false
    @State private var imageMoveCapture: StudioViewModel.ImageMoveCapture?
    @State private var imageMoveFrame: AnimationFrame?
    @State private var startedAsImageMove = false
    @State private var imageMoveCancelled = false
    @State private var imageResizeCorner: StudioSelectionHandleGeometry.Kind?
    @State private var imageRotationStart: CGPoint?
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
    // A completed touch still needs its captured context in inputEnded.
    // UIKit cancellation and backgrounding share the interruption path.
    @State private var colorInput = StudioColorSampleGesture()
    @State private var touchID: UUID?
    @State private var fillInput = StudioFillGesture()
    @StateObject private var fillSession = StudioFillSession()
    @StateObject private var smudgeSession = StudioSmudgeSession()
    @State private var smudgeInput: StudioSmudgeInput?
    @State private var startedAsSmudge = false
    @State private var smudgeSubmission: UUID?
    @State private var smudgeTask: Task<Void, Never>?
    @StateObject private var blurSession = StudioBlurSession()
    @State private var blurInput: StudioBlurInput?
    @State private var startedAsBlur = false
    @State private var blurSubmission: UUID?
    @State private var blurTask: Task<Void, Never>?
    @StateObject private var sharpenSession = StudioSharpenSession()
    @State private var sharpenInput: StudioSharpenInput?
    @State private var startedAsSharpen = false
    @State private var sharpenSubmission: UUID?
    @State private var sharpenTask: Task<Void, Never>?
    @StateObject private var dodgeBurnSession = StudioDodgeBurnSession()
    @State private var dodgeBurnInput: StudioDodgeBurnInput?
    @State private var startedAsDodgeBurn = false
    @State private var dodgeBurnSubmission: UUID?
    @State private var dodgeBurnTask: Task<Void, Never>?
    @State private var strokePreviewFrame: AnimationFrame?
    @State private var liveElement: DrawnElement?
    @State private var livePrepared: StudioFrameRenderer.PreparedBrushes?
    @State private var inputFailure: String?
    @State private var previewFailure: String?
    @State private var lastPreviewTime: TimeInterval = 0
    var body: some View {
        contextualCanvas
        .onChange(of: gestureActive) { _, active in
            guard !active, let endedTouch = touchID else { return }
            // Let inputEnded consume its capture first; clear only the same
            // interrupted touch on the next turn.
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
        .onChange(of: vm.currentImageMoveCapture()) { _, _ in cancelImageMovePreview() }
        .onChange(of: vm.beginSelectionHandle()) { _, _ in cancelHandlePreview() }
        .onChange(of: vm.beginAreaSelection()) { _, _ in cancelAreaPreview(); vm.cancelPolygonSelection() }
        .onChange(of: vm.captureEraserInput(ownedStroke: input?.id)) { _, current in
            if let captured = eraserCapture, input?.tool == .eraser, current != captured {
                interruptInput("Erasing cancelled because Studio changed. The artwork is unchanged.")
            }
        }
        .onChange(of: vm.beginColorSample()) { _, _ in colorInput.invalidate() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { StudioSmudgeReplay.viewCache.clear(); interruptInput("Studio left the foreground before the stroke finished. The incomplete draft remains unsaved.") }
        }
        .onDisappear { StudioSmudgeReplay.viewCache.clear(); interruptInput("Studio closed before the stroke finished. The incomplete draft remains unsaved.") }
    }

    private var contextualCanvas: some View {
        canvasContent
        .onChange(of: vm.currentFrame.id) { _, _ in
            fillSession.cancel()
            interruptInput("The frame changed before touch input finished. The incomplete draft is retained for explicit discard.")
        }
        .onChange(of: StudioFillContext.current(vm, ownedStroke: vm.activeStrokeID)) { _, _ in
            fillInput.invalidate()
            if fillSession.isFilling { fillSession.cancel() }
        }
        .onChange(of: StudioSmudgeContext.current(vm, ownedStroke: vm.activeStrokeID)) { _, _ in
            cancelSmudge()
        }
        .onChange(of: StudioBlurContext.current(vm, ownedStroke: vm.activeStrokeID)) { _, _ in
            cancelBlur()
        }
        .onChange(of: StudioSharpenContext.current(vm, ownedStroke: vm.activeStrokeID)) { _, _ in
            cancelSharpen()
        }
        .onChange(of: StudioDodgeBurnContext.current(vm, ownedStroke: vm.activeStrokeID)) { _, _ in
            cancelDodgeBurn()
        }
        .onChange(of: vm.activePanel) { _, _ in cancelBlur(); cancelSharpen(); cancelDodgeBurn() }
    }

    private var canvasContent: some View {
        GeometryReader { geo in
            let size = canvasRect(in: geo.size)
            let documentSize = CGSize(width: vm.canvasWidth, height: vm.canvasHeight)
            let displayedFrame = imageMoveFrame ?? handleFrame ?? moveFrame ?? strokePreviewFrame ?? vm.currentFrame
            let handles = selectionHandles(frame: displayedFrame, size: size)
            let currentPrepared = Result { try livePrepared ?? StudioFrameRenderer.prepare(frame: displayedFrame) }
            let rasterSize = min(4096, max(1, Int(ceil(max(size.width, size.height) * displayScale * max(1, vm.canvasScale)))))
            let currentRaster = Result { try StudioFrameRenderer.prepareRaster(frame: vm.currentFrame, layers: vm.layers,
                data: vm.rasterData(vm.currentFrame.rasterAssetID), maximumDimension: rasterSize) }
            let currentSmudges = Result { try StudioSmudgeReplay.viewCache.prepare(frame: displayedFrame, layers: vm.layers,
                canvasSize: documentSize, rasterData: vm.rasterData(vm.currentFrame.rasterAssetID), liveElement: liveElement) }
            ZStack {
                Color.clear
                ZStack {
                    Color.white
                    Canvas { context, actual in
                        // Prepare one ghost at a time: range is bounded to four,
                        // and full-resolution effect buffers are not retained as an array.
                        for ghost in vm.visibleOnionGhosts {
                            do {
                                let frame = ghost.frame
                                let brushes = try StudioFrameRenderer.prepare(frame: frame)
                                let image = try StudioFrameRenderer.prepareRaster(frame: frame, layers: vm.layers,
                                    data: vm.rasterData(frame.rasterAssetID), maximumDimension: rasterSize)
                                let effects = try StudioSmudgeReplay.viewCache.prepare(frame: frame, layers: vm.layers,
                                    canvasSize: documentSize, rasterData: vm.rasterData(frame.rasterAssetID))
                                var onion = StudioFrameRenderer.onionContext(context, opacity: ghost.opacity,
                                    previous: ghost.previous, tinted: ghost.tinted)
                                if let error = StudioFrameRenderer.draw(context: &onion, frame: frame, layers: vm.layers,
                                    canvasSize: documentSize, size: actual, rasterData: vm.rasterData(frame.rasterAssetID),
                                    preparedBrushes: brushes, preparedRaster: image, preparedSmudges: effects) { throw error }
                            } catch { StudioFrameRenderer.drawFailure(error, context: &context, size: actual) }
                        }
                        switch (currentPrepared, currentRaster, currentSmudges) {
                        case (.success(let brushes), .success(let image), .success(let effects)):
                            if let error = StudioFrameRenderer.draw(context: &context, frame: displayedFrame, layers: vm.layers,
                                canvasSize: CGSize(width: vm.canvasWidth, height: vm.canvasHeight), size: actual,
                                rasterData: vm.rasterData(vm.currentFrame.rasterAssetID), liveElement: liveElement,
                                preparedBrushes: brushes, preparedRaster: image, preparedSmudges: effects) {
                                StudioFrameRenderer.drawFailure(error, context: &context, size: actual)
                            }
                        case (.failure(let error), _, _), (_, .failure(let error), _), (_, _, .failure(let error)):
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
                        if let corners = vm.selectedAreaImageCorners {
                            let points = corners.map { CGPoint(x: $0.x / Double(vm.canvasWidth) * actual.width,
                                y: $0.y / Double(vm.canvasHeight) * actual.height) }
                            var outline = Path(); outline.move(to: points[0])
                            points.dropFirst().forEach { outline.addLine(to: $0) }; outline.closeSubpath()
                            context.stroke(outline, with: .color(.red),
                                style: StrokeStyle(lineWidth: 1 / max(0.01, vm.canvasScale), dash: [4, 3]))
                        }
                        if let capture = vm.currentImageMoveCapture(), let placement = displayedFrame.rasterInstance(on: capture.placement.layerID)?.placement {
                            let rect = CGRect(x: placement.x / Double(vm.canvasWidth) * actual.width,
                                y: placement.y / Double(vm.canvasHeight) * actual.height,
                                width: placement.width / Double(vm.canvasWidth) * actual.width,
                                height: placement.height / Double(vm.canvasHeight) * actual.height)
                            let angle = displayedFrame.rasterInstance(on: capture.placement.layerID)?.rotationDegrees ?? 0
                            var outline = Path()
                            if angle == 0 { outline = Path(rect.insetBy(dx: 1, dy: 1)) }
                            else {
                                let points = StudioImageRotationGeometry(placement: placement, degrees: angle).corners.map {
                                    CGPoint(x: $0.x / Double(vm.canvasWidth) * actual.width,
                                            y: $0.y / Double(vm.canvasHeight) * actual.height)
                                }
                                outline.move(to: points[0]); points.dropFirst().forEach { outline.addLine(to: $0) }; outline.closeSubpath()
                            }
                            context.stroke(outline, with: .color(.red),
                                style: StrokeStyle(lineWidth: 1 / max(0.01, vm.canvasScale), dash: [4, 3]))
                            if let geometry = imageHandles(frame: displayedFrame, size: actual) {
                                for handle in geometry.handles {
                                    let radius = geometry.visualRadius
                                    let circle = Path(ellipseIn: CGRect(x: handle.point.x-radius, y: handle.point.y-radius,
                                        width: 2*radius, height: 2*radius))
                                    context.fill(circle, with: .color(handle.kind == .rotate ? .red : .white))
                                    context.stroke(circle, with: .color(.red), lineWidth: 2 / geometry.zoom)
                                }
                            }
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
                        if let smudgeInput, !smudgeInput.isCancelled, let point = smudgeInput.points.last {
                            // This ring shows the real brush footprint, not fabricated preview pixels.
                            let diameter = smudgeInput.context.settings.diameter
                            let rect = CGRect(x: (point.x-diameter/2) / documentSize.width * actual.width,
                                y: (point.y-diameter/2) / documentSize.height * actual.height,
                                width: diameter / documentSize.width * actual.width,
                                height: diameter / documentSize.height * actual.height)
                            context.stroke(Path(ellipseIn: rect), with: .color(.red),
                                style: StrokeStyle(lineWidth: 1 / max(0.01, vm.canvasScale), dash: [3, 2]))
                        }
                        if let blurInput, !blurInput.isCancelled, let point = blurInput.points.last {
                            // This ring shows the real brush footprint, not fabricated preview pixels.
                            let diameter = blurInput.context.settings.diameter
                            let rect = CGRect(x: (point.x-diameter/2) / documentSize.width * actual.width,
                                y: (point.y-diameter/2) / documentSize.height * actual.height,
                                width: diameter / documentSize.width * actual.width,
                                height: diameter / documentSize.height * actual.height)
                            context.stroke(Path(ellipseIn: rect), with: .color(.red),
                                style: StrokeStyle(lineWidth: 1 / max(0.01, vm.canvasScale), dash: [3, 2]))
                        }
                        if let sharpenInput, !sharpenInput.isCancelled, let point = sharpenInput.points.last {
                            // This ring shows the real brush footprint, not fabricated preview pixels.
                            let diameter = sharpenInput.context.settings.diameter
                            let rect = CGRect(x: (point.x-diameter/2) / documentSize.width * actual.width,
                                y: (point.y-diameter/2) / documentSize.height * actual.height,
                                width: diameter / documentSize.width * actual.width,
                                height: diameter / documentSize.height * actual.height)
                            context.stroke(Path(ellipseIn: rect), with: .color(.red),
                                style: StrokeStyle(lineWidth: 1 / max(0.01, vm.canvasScale), dash: [3, 2]))
                        }
                        if let dodgeBurnInput, !dodgeBurnInput.isCancelled, let point = dodgeBurnInput.points.last {
                            // This ring shows the real brush footprint, not fabricated preview pixels.
                            let diameter = dodgeBurnInput.context.settings.diameter
                            let rect = CGRect(x: (point.x-diameter/2) / documentSize.width * actual.width,
                                y: (point.y-diameter/2) / documentSize.height * actual.height,
                                width: diameter / documentSize.width * actual.width,
                                height: diameter / documentSize.height * actual.height)
                            context.stroke(Path(ellipseIn: rect), with: .color(.red),
                                style: StrokeStyle(lineWidth: 1 / max(0.01, vm.canvasScale), dash: [3, 2]))
                        }
                        if let mirror = input?.mirror {
                            var guide = Path()
                            if mirror.mode == .vertical || mirror.mode == .both {
                                guide.move(to: CGPoint(x: actual.width/2, y: 0)); guide.addLine(to: CGPoint(x: actual.width/2, y: actual.height))
                            }
                            if mirror.mode == .horizontal || mirror.mode == .both {
                                guide.move(to: CGPoint(x: 0, y: actual.height/2)); guide.addLine(to: CGPoint(x: actual.width, y: actual.height/2))
                            }
                            context.stroke(guide, with: .color(.blue.opacity(0.6)),
                                style: StrokeStyle(lineWidth: 1/max(0.01,vm.canvasScale), dash: [5,3]))
                        }
                        if let guide = input?.rulerGuide, guide.count == 2 {
                            var ruler = Path()
                            ruler.move(to: CGPoint(x: guide[0].x/documentSize.width*actual.width, y: guide[0].y/documentSize.height*actual.height))
                            ruler.addLine(to: CGPoint(x: guide[1].x/documentSize.width*actual.width, y: guide[1].y/documentSize.height*actual.height))
                            context.stroke(ruler, with: .color(.blue.opacity(0.6)),
                                style: StrokeStyle(lineWidth: 1/max(0.01,vm.canvasScale), dash: [5,3]))
                        }
                        let selectionPreview = vm.areaSelectionKind == .polygon ? vm.currentPolygonSelectionVertices : areaPreview
                        if let first = selectionPreview.first {
                            func scaled(_ point: CGPoint) -> CGPoint {
                                CGPoint(x: point.x / documentSize.width * actual.width,
                                        y: point.y / documentSize.height * actual.height)
                            }
                            var outline = Path(); outline.move(to: scaled(first))
                            selectionPreview.dropFirst().forEach { outline.addLine(to: scaled($0)) }
                            if selectionPreview.count >= 3 {
                                outline.closeSubpath()
                                context.fill(outline, with: .color(.red.opacity(0.08)), style: FillStyle(eoFill: true))
                            }
                            context.stroke(outline, with: .color(.red), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            if vm.areaSelectionKind == .polygon {
                                for vertex in selectionPreview {
                                    let point = scaled(vertex)
                                    let marker = Path(ellipseIn: CGRect(x: point.x-3, y: point.y-3, width: 6, height: 6))
                                    context.fill(marker, with: .color(.white))
                                    context.stroke(marker, with: .color(.red), lineWidth: 1)
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Animation canvas")
                    .accessibilityIdentifier("studio.canvas")
                    .accessibilityValue(vm.isMovingImageOnCanvas ? "Selected image: drag inside the red outline to move it. Drag white corner handles to resize or the red handle to rotate. Position image offers numeric dimensions and angle." : handles == nil ? "" : "Selected artwork: drag white corner handles to resize or the red handle to rotate. The Move popup also provides Scale and Angle controls.")
                    if vm.gridEnabled { GridOverlay(settings: vm.document.gridSettings ?? .init()).allowsHitTesting(false) }
                }
                .frame(width: size.width, height: size.height)
                .clipped()
                .contentShape(Rectangle())
                .overlay {
                    StudioTouchSurface(onChanged: { value in
                        gestureActive = true
                        inputChanged(value, size: size)
                    }, onEstimated: { value in
                        inputEstimated(value)
                    }, onEnded: { value in
                        inputEnded(value, size: size)
                        gestureActive = false
                    }, onCancelled: {
                        gestureActive = false
                        interruptInput("Touch input was cancelled. The incomplete draft remains unsaved.")
                    }).accessibilityHidden(true)
                }
                .scaleEffect(vm.canvasScale)
                .offset(vm.canvasOffset)
                .shadow(color: .black.opacity(0.4), radius: 12)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onChange(of: StudioColorSampleGesture.Layout(viewport: size,
                scale: vm.canvasScale, offset: vm.canvasOffset)) { _, _ in
                colorInput.invalidate(); fillInput.invalidate(); cancelSmudge(); cancelBlur(); cancelSharpen(); cancelDodgeBurn(); cancelMovePreview(); cancelImageMovePreview(); cancelAreaPreview(); cancelHandlePreview()
                if input?.tool == .eraser { interruptInput("Erasing cancelled because the canvas moved.") }
            }
            .overlay(alignment: .bottom) { inputStatusOverlay }
        }
    }

    private func canvasRect(in size: CGSize) -> CGSize {
        let ratio = CGFloat(vm.canvasWidth) / CGFloat(vm.canvasHeight)
        let width = max(1, size.width * 0.9), height = max(1, size.height * 0.9)
        return width / height > ratio ? CGSize(width: height * ratio, height: height) : CGSize(width: width, height: width / ratio)
    }
    private func inputChanged(_ value: StudioTouchValue, size: CGSize) {
                guard !strokeInputCancelled else { return }
                if touchID == nil {
                    touchID = UUID(); colorInput = StudioColorSampleGesture(); fillInput = StudioFillGesture()
                    startedAsImageMove = vm.selectedTool == .move && vm.isMovingImageOnCanvas
                    imageMoveCancelled = false
                    startedAsSmudge = vm.selectedTool == .smudge
                    if startedAsSmudge, smudgeSubmission == nil, let context = StudioSmudgeContext.current(vm) {
                        smudgeInput = StudioSmudgeInput(context: context,
                            layout: .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset))
                        _ = updateSmudge(location: value.startLocation, size: size)
                    }
                    startedAsBlur = vm.selectedTool == .blur
                    if startedAsBlur, blurSubmission == nil, let context = StudioBlurContext.current(vm) {
                        blurInput = StudioBlurInput(context: context,
                            layout: .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset))
                        _ = updateBlur(location: value.startLocation, size: size)
                    }
                    startedAsSharpen = vm.selectedTool == .sharpen
                    if startedAsSharpen, sharpenSubmission == nil, let context = StudioSharpenContext.current(vm) {
                        sharpenInput = StudioSharpenInput(context: context,
                            layout: .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset))
                        _ = updateSharpen(location: value.startLocation, size: size)
                    }
                    startedAsDodgeBurn = vm.selectedTool == .dodge || vm.selectedTool == .burn
                    if startedAsDodgeBurn, dodgeBurnSubmission == nil, let context = StudioDodgeBurnContext.current(vm) {
                        dodgeBurnInput = StudioDodgeBurnInput(context: context,
                            layout: .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset))
                        _ = updateDodgeBurn(location: value.startLocation, size: size)
                    }
                    startedAsMove = vm.selectedTool == .move && !startedAsImageMove; moveCancelled = false
                    if startedAsImageMove {
                        moveLayout = .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset)
                        imageResizeCorner = nil
                        if let geometry = imageHandles(frame: vm.currentFrame, size: size) {
                            imageResizeCorner = geometry.handles.filter {
                                hypot($0.point.x-value.startLocation.x, $0.point.y-value.startLocation.y) <= geometry.hitRadius }
                                .min { hypot($0.point.x-value.startLocation.x, $0.point.y-value.startLocation.y) <
                                    hypot($1.point.x-value.startLocation.x, $1.point.y-value.startLocation.y) }?.kind
                        }
                        imageMoveCapture = imageResizeCorner == nil
                            ? vm.beginImageMove(at: documentPoint(value.startLocation, size: size)) : vm.currentImageMoveCapture()
                        imageRotationStart = imageResizeCorner == .rotate ? documentPoint(value.startLocation, size: size) : nil
                    }
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
                if startedAsSmudge { _ = updateSmudge(location: value.location, size: size); return }
                if startedAsBlur { _ = updateBlur(location: value.location, size: size); return }
                if startedAsSharpen { _ = updateSharpen(location: value.location, size: size); return }
                if startedAsDodgeBurn { _ = updateDodgeBurn(location: value.location, size: size); return }
                if startedAsImageMove { _ = updateImageMove(delta: value.translation, size: size); return }
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
                        let id = value.strokeID
                        let styled = [.pencil, .pen, .brush, .marker, .crayon].contains(vm.selectedTool)
                        let brush = styled ? try vm.brushDescriptor(elementID: id) : nil
                        let shape = try vm.shapeDescriptor()
                        let eraser = try vm.eraserDescriptor()
                        if eraser != nil {
                            guard let capture = vm.captureEraserInput() else { throw StudioCommandError.staleRevision }
                            eraserCapture = capture
                        }
                        guard vm.beginStrokeInput(id: id) else { return }
                        input = StudioStrokeInput(id: id, frameID: vm.currentFrame.id, layerID: vm.activeLayerID,
                            tool: vm.selectedTool, color: vm.strokeColorHex, width: vm.strokeWidth,
                            opacity: styled || shape != nil ? vm.capturedStrokeOpacity : vm.strokeOpacity,
                            brush: brush,
                            documentSize: CGSize(width: vm.canvasWidth, height: vm.canvasHeight), viewportSize: size,
                            startedAt: value.time, shape: shape, eraser: eraser,
                            angleSnapDegrees: vm.selectedTool == .line && !vm.lineRulerEnabled ? vm.lineAngleSnap : 0,
                            equalShapeSides: [.rectangle, .circle].contains(vm.selectedTool) && vm.equalShapeSides,
                            rulerAngleDegrees: vm.selectedTool == .line && vm.lineRulerEnabled ? vm.lineRulerAngle : nil,
                            rulerLength: vm.selectedTool == .line && vm.lineRulerEnabled && vm.lineRulerFixedLength ? vm.lineRulerLength : nil,
                            mirror: vm.selectedTool != .eraser && vm.mirrorMode != .off ?
                                .init(mode: vm.mirrorMode, width: Double(vm.canvasWidth), height: Double(vm.canvasHeight)) : nil,
                            preservesLayerAlpha: styled && layer.lockMode == "alpha")
                    } catch { vm.message = error.localizedDescription; return }
                }
                do { try input?.append(location: value.location, time: value.time, pressure: value.pressure, tilt: value.tilt,
                    estimationIndex: value.expectsUpdates ? value.estimationIndex : nil) }
                catch { inputFailure = error.localizedDescription; return }
                refreshInputPreview()
    }
    private func inputEstimated(_ value: StudioTouchValue) {
        guard gestureActive, scenePhase == .active, inputFailure == nil,
              var captured = input, captured.id == value.strokeID,
              vm.activeStrokeID == captured.id, captured.frameID == vm.currentFrame.id,
              captured.layerID == vm.activeLayerID, captured.tool == vm.selectedTool,
              let estimationIndex = value.estimationIndex else { return }
        do {
            guard try captured.updateEstimatedSample(strokeID: value.strokeID, estimationIndex: estimationIndex,
                location: value.location, pressure: value.pressure, tilt: value.tilt,
                expectsMoreUpdates: value.expectsUpdates) else { return }
            input = captured; refreshInputPreview()
        } catch { inputFailure = error.localizedDescription }
    }
    private func refreshInputPreview() {
                let now = ProcessInfo.processInfo.systemUptime
                // Capture every supported sample; only preview regeneration is
                // coalesced to 30Hz. Commit always prepares the complete input.
                if now - lastPreviewTime >= 1 / 30, previewFailure == nil, let input {
                    do {
                        var preview = vm.currentFrame
                        let previewElement: DrawnElement?
                        if let capture = eraserCapture {
                            preview = try vm.eraserInputPreview(capture, element: input.element)
                            previewElement = nil
                        } else if let mirror = input.mirror {
                            // Match commit ordering even where translucent gradient copies overlap.
                            preview.elements.append(contentsOf: try mirror.elements(from: input.element))
                            previewElement = nil
                        } else { previewElement = input.element }
                        let next = try StudioFrameRenderer.prepare(frame: preview, liveElement: previewElement)
                        strokePreviewFrame = preview
                        liveElement = previewElement; livePrepared = next; lastPreviewTime = now
                    } catch { previewFailure = error.localizedDescription }
                }
    }
    private func inputEnded(_ value: StudioTouchValue, size: CGSize) {
                defer { clearInput() }
                guard !strokeInputCancelled, vm.pendingBrushStroke == nil else { return }
                if startedAsSmudge {
                    guard updateSmudge(location: value.location, size: size), let captured = smudgeInput,
                          smudgeSubmission == nil else { return }
                    let submission = UUID(); smudgeSubmission = submission
                    smudgeTask = Task { @MainActor in
                        defer {
                            if smudgeSubmission == submission { smudgeSubmission = nil; smudgeTask = nil }
                        }
                        guard !Task.isCancelled, smudgeSubmission == submission, scenePhase == .active else { return }
                        await smudgeSession.apply(vm, input: captured)
                    }
                    return
                }
                if startedAsBlur {
                    guard updateBlur(location: value.location, size: size), let captured = blurInput,
                          blurSubmission == nil else { return }
                    let submission = UUID(); blurSubmission = submission
                    blurTask = Task { @MainActor in
                        defer {
                            if blurSubmission == submission { blurSubmission = nil; blurTask = nil }
                        }
                        guard !Task.isCancelled, blurSubmission == submission, scenePhase == .active else { return }
                        await blurSession.apply(vm, input: captured)
                    }
                    return
                }
                if startedAsSharpen {
                    guard updateSharpen(location: value.location, size: size), let captured = sharpenInput,
                          sharpenSubmission == nil else { return }
                    let submission = UUID(); sharpenSubmission = submission
                    sharpenTask = Task { @MainActor in
                        defer {
                            if sharpenSubmission == submission { sharpenSubmission = nil; sharpenTask = nil }
                        }
                        guard !Task.isCancelled, sharpenSubmission == submission, scenePhase == .active else { return }
                        await sharpenSession.apply(vm, input: captured)
                    }
                    return
                }
                if startedAsDodgeBurn {
                    guard updateDodgeBurn(location: value.location, size: size), let captured = dodgeBurnInput,
                          dodgeBurnSubmission == nil else { return }
                    let submission = UUID(); dodgeBurnSubmission = submission
                    dodgeBurnTask = Task { @MainActor in
                        defer {
                            if dodgeBurnSubmission == submission { dodgeBurnSubmission = nil; dodgeBurnTask = nil }
                        }
                        guard !Task.isCancelled, dodgeBurnSubmission == submission, scenePhase == .active else { return }
                        await dodgeBurnSession.apply(vm, input: captured)
                    }
                    return
                }
                if startedAsImageMove {
                    guard updateImageMove(delta: value.translation, size: size), let capture = imageMoveCapture else { return }
                    if imageResizeCorner == .rotate, let start = imageRotationStart {
                        let delta = documentDelta(value.translation, size: size)
                        _ = vm.finishImageRotation(capture, start: start,
                            current: CGPoint(x: start.x + delta.width, y: start.y + delta.height))
                    } else if let corner = imageResizeCorner {
                        _ = vm.finishImageResize(capture, corner: corner, delta: documentDelta(value.translation, size: size))
                    } else { _ = vm.finishImageMove(capture, delta: documentDelta(value.translation, size: size)) }
                    return
                }
                if startedAsHandle {
                    guard updateHandle(start: value.startLocation, location: value.location, size: size, final: true),
                          let capture = handleCapture else { return }
                    _ = vm.finishSelectionHandle(capture, values: handleValues)
                    return
                }
                if startedAsArea {
                    guard updateArea(location: value.location, size: size), let capture = areaCapture else { return }
                    if capture.kind == .polygon {
                        _ = vm.appendPolygonSelectionVertex(documentPoint(value.location, size: size))
                    } else {
                        _ = vm.finishAreaSelection(capture, points: areaTrace.points)
                    }
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
                        if captured.tool == .eraser { vm.message = inputFailure; return }
                        vm.retainRejectedBrush(captured.element, frameID: captured.frameID,
                            reason: inputFailure, inputComplete: false, mirror: captured.mirror)
                    } else {
                        do {
                            try captured.append(location: value.location, time: value.time, pressure: value.pressure, tilt: value.tilt)
                            captured.finishEstimatedUpdates()
                            if captured.tool == .eraser {
                                guard scenePhase == .active, let capture = eraserCapture else { throw StudioCommandError.staleRevision }
                                _ = vm.commitEraserInput(capture, element: captured.element)
                            } else {
                                _ = vm.commitElement(captured.element, frameID: captured.frameID, mirror: captured.mirror)
                            }
                        } catch {
                            if captured.tool == .eraser { vm.message = error.localizedDescription; return }
                            vm.retainRejectedBrush(captured.element, frameID: captured.frameID,
                                reason: error.localizedDescription, inputComplete: false, mirror: captured.mirror)
                        }
                    }
                    return
                }
                if vm.selectedTool == .zoom { vm.zoomIn(); return }
                vm.message = "This tool or layer cannot edit here yet. Choose an unlocked Brush, Pen, Pencil, Eraser or shape tool."
    }
    @ViewBuilder private var inputStatusOverlay: some View {
                if dodgeBurnSession.isApplying {
                    HStack(spacing: 12) {
                        ProgressView().tint(.red)
                        Text("Adjusting exposure…").font(.specialElite(12))
                        Button("Cancel") { cancelDodgeBurn() }
                            .accessibilityIdentifier("studio.dodge-burn.cancel")
                    }.padding(12).background(Color.black.opacity(0.95)).cornerRadius(10).padding(8)
                        .accessibilityIdentifier("studio.dodge-burn.progress")
                } else if let dodgeBurnInput, !dodgeBurnInput.isCancelled, startedAsDodgeBurn {
                    Text("Release to adjust exposure on the active layer")
                        .font(.specialElite(12)).padding(10).background(Color.black.opacity(0.95)).cornerRadius(10)
                        .accessibilityIdentifier("studio.dodge-burn.release-hint")
                } else if sharpenSession.isApplying {
                    HStack(spacing: 12) {
                        ProgressView().tint(.red)
                        Text("Sharpening artwork…").font(.specialElite(12))
                        Button("Cancel") { cancelSharpen() }
                            .accessibilityIdentifier("studio.sharpen.cancel")
                    }.padding(12).background(Color.black.opacity(0.95)).cornerRadius(10).padding(8)
                        .accessibilityIdentifier("studio.sharpen.progress")
                } else if let sharpenInput, !sharpenInput.isCancelled, startedAsSharpen {
                    Text("Release to sharpen the active layer")
                        .font(.specialElite(12)).padding(10).background(Color.black.opacity(0.95)).cornerRadius(10)
                        .accessibilityIdentifier("studio.sharpen.release-hint")
                } else if blurSession.isApplying {
                    HStack(spacing: 12) {
                        ProgressView().tint(.red)
                        Text("Blurring artwork…").font(.specialElite(12))
                        Button("Cancel") { cancelBlur() }
                            .accessibilityIdentifier("studio.blur.cancel")
                    }.padding(12).background(Color.black.opacity(0.95)).cornerRadius(10).padding(8)
                        .accessibilityIdentifier("studio.blur.progress")
                } else if let blurInput, !blurInput.isCancelled, startedAsBlur {
                    Text("Release to blur the active layer")
                        .font(.specialElite(12)).padding(10).background(Color.black.opacity(0.95)).cornerRadius(10)
                        .accessibilityIdentifier("studio.blur.release-hint")
                } else if smudgeSession.isApplying {
                    HStack(spacing: 12) {
                        ProgressView().tint(.red)
                        Text("Smudging artwork…").font(.specialElite(12))
                        Button("Cancel") { cancelSmudge() }
                            .accessibilityIdentifier("studio.smudge.cancel")
                    }.padding(12).background(Color.black.opacity(0.95)).cornerRadius(10).padding(8)
                        .accessibilityIdentifier("studio.smudge.progress")
                } else if let smudgeInput, !smudgeInput.isCancelled, startedAsSmudge {
                    Text("Release to smudge the active layer")
                        .font(.specialElite(12)).padding(10).background(Color.black.opacity(0.95)).cornerRadius(10)
                        .accessibilityIdentifier("studio.smudge.release-hint")
                } else if fillSession.isFilling {
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

    private func updateSmudge(location: CGPoint, size: CGSize) -> Bool {
        guard var captured = smudgeInput else {
            vm.message = "Choose a visible unlocked layer and deselect artwork before smudging."
            return false
        }
        do {
            try captured.append(location, current: StudioSmudgeContext.current(vm),
                layout: .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset),
                foreground: scenePhase == .active)
            smudgeInput = captured
            return true
        } catch {
            smudgeInput = captured
            vm.message = "Smudge cancelled. Start a new drag on the current artwork."
            return false
        }
    }
    private func cancelSmudge() {
        smudgeInput?.cancel(); smudgeTask?.cancel(); smudgeSession.cancel()
        smudgeSubmission = nil; smudgeTask = nil
    }
    private func updateBlur(location: CGPoint, size: CGSize) -> Bool {
        guard var captured = blurInput else {
            vm.message = "Choose a visible unlocked layer and deselect artwork before blurring."
            return false
        }
        do {
            try captured.append(location, current: StudioBlurContext.current(vm),
                layout: .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset),
                foreground: scenePhase == .active)
            blurInput = captured
            return true
        } catch {
            blurInput = captured
            vm.message = "Blur cancelled. Start a new drag on the current artwork."
            return false
        }
    }
    private func cancelBlur() {
        blurInput?.cancel(); blurTask?.cancel(); blurSession.cancel()
        blurSubmission = nil; blurTask = nil
    }
    private func updateSharpen(location: CGPoint, size: CGSize) -> Bool {
        guard var captured = sharpenInput else {
            vm.message = "Choose a visible unlocked layer and deselect artwork before sharpening."
            return false
        }
        do {
            try captured.append(location, current: StudioSharpenContext.current(vm),
                layout: .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset),
                foreground: scenePhase == .active)
            sharpenInput = captured
            return true
        } catch {
            sharpenInput = captured
            vm.message = "Sharpen cancelled. Start a new drag on the current artwork."
            return false
        }
    }
    private func cancelSharpen() {
        sharpenInput?.cancel(); sharpenTask?.cancel(); sharpenSession.cancel()
        sharpenSubmission = nil; sharpenTask = nil
    }
    private func updateDodgeBurn(location: CGPoint, size: CGSize) -> Bool {
        guard var captured = dodgeBurnInput else {
            vm.message = "Choose a visible unlocked layer and deselect artwork before adjusting exposure."
            return false
        }
        do {
            try captured.append(location, current: StudioDodgeBurnContext.current(vm),
                layout: .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset),
                foreground: scenePhase == .active)
            dodgeBurnInput = captured
            return true
        } catch {
            dodgeBurnInput = captured
            vm.message = "Dodge/Burn cancelled. Start a new drag on the current artwork."
            return false
        }
    }
    private func cancelDodgeBurn() {
        dodgeBurnInput?.cancel(); dodgeBurnTask?.cancel(); dodgeBurnSession.cancel()
        dodgeBurnSubmission = nil; dodgeBurnTask = nil
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
    private func imageHandles(frame: AnimationFrame, size: CGSize) -> StudioSelectionHandleGeometry? {
        guard let capture = vm.currentImageMoveCapture(), let p = frame.rasterInstance(on: capture.placement.layerID)?.placement else { return nil }
        return .init(bounds: StudioImageRotationGeometry(placement: p, degrees: frame.rasterInstance(on: capture.placement.layerID)?.rotationDegrees ?? 0).bounds,
            documentSize: CGSize(width: vm.canvasWidth, height: vm.canvasHeight), viewport: size, zoom: vm.canvasScale)
    }
    private func cancelImageMovePreview() {
        if startedAsImageMove { imageMoveCancelled = true; imageMoveFrame = nil }
    }
    @discardableResult
    private func updateImageMove(delta: CGSize, size: CGSize) -> Bool {
        guard !imageMoveCancelled, let capture = imageMoveCapture else { return false }
        guard scenePhase == .active, vm.currentImageMoveCapture() == capture,
              moveLayout == .init(viewport: size, scale: vm.canvasScale, offset: vm.canvasOffset) else {
            cancelImageMovePreview(); return false
        }
        do {
            if imageResizeCorner == .rotate, let start = imageRotationStart {
                let movement = documentDelta(delta, size: size)
                imageMoveFrame = try vm.imageRotationPreview(capture, start: start,
                    current: CGPoint(x: start.x + movement.width, y: start.y + movement.height))
            } else if let corner = imageResizeCorner {
                imageMoveFrame = try vm.imageResizePreview(capture, corner: corner, delta: documentDelta(delta, size: size))
            } else { imageMoveFrame = try vm.imageMovePreview(capture, delta: documentDelta(delta, size: size)) }
            return true
        }
        catch { cancelImageMovePreview(); vm.message = error.localizedDescription; return false }
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
        if capture.kind == .polygon { return true }
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
        input = nil; eraserCapture = nil; panOrigin = nil; strokePreviewFrame = nil; liveElement = nil; livePrepared = nil
        inputFailure = nil; previewFailure = nil; lastPreviewTime = 0
        if endingTouch {
            strokeInputCancelled = false
            colorInput = StudioColorSampleGesture(); fillInput = StudioFillGesture(); touchID = nil
            smudgeInput = nil; startedAsSmudge = false
            blurInput = nil; startedAsBlur = false
            sharpenInput = nil; startedAsSharpen = false
            dodgeBurnInput = nil; startedAsDodgeBurn = false
            imageResizeCorner = nil; imageRotationStart = nil; imageMoveCapture = nil; imageMoveFrame = nil; startedAsImageMove = false; imageMoveCancelled = false
            moveCapture = nil; moveLayout = nil; moveFrame = nil; startedAsMove = false; moveCancelled = false
            handleCapture = nil; handleGeometry = nil; handleKind = nil; handleFrame = nil
            handleValues = .init(); startedAsHandle = false; handleCancelled = false
            areaCapture = nil; areaLayout = nil; areaTrace = StudioSelectionTrace()
            areaPreview = []; startedAsArea = false; areaCancelled = false
        }
    }
    private func interruptInput(_ reason: String) {
        // Keep the cancellation latched until the physical touch ends. Clearing
        // the captured input alone would let its next move recapture new targets.
        if gestureActive { strokeInputCancelled = true }
        vm.cancelPolygonSelection()
        fillSession.cancel(); cancelSmudge(); cancelBlur(); cancelSharpen(); cancelDodgeBurn()
        if let input { vm.interruptStrokeInput(input, reason: reason) }
        colorInput.invalidate()
        fillInput.invalidate()
        cancelMovePreview()
        cancelImageMovePreview()
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
    var settings = StudioGridSettings()
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for x in settings.positions(length: size.width) {
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in settings.positions(length: size.height) {
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            let color: Color = settings.tint == .blue ? .blue : settings.tint == .red ? .red : .gray
            context.stroke(path, with: .color(color.opacity(settings.opacity)), lineWidth: 0.5)
        }
    }
}

// UIKit provides real coalesced Pencil samples; SwiftUI's DragGesture does not
// expose pressure. Both Pencil and finger now use the same Studio transaction.
private struct StudioTouchValue {
    let strokeID: String
    let estimationIndex: Int64?
    let expectsUpdates: Bool
    let location: CGPoint
    let startLocation: CGPoint
    let time: Date
    let pressure: CGFloat?
    let tilt: StudioPencilTilt?
    var translation: CGSize { CGSize(width: location.x-startLocation.x, height: location.y-startLocation.y) }
}

private struct StudioTouchSurface: UIViewRepresentable {
    var onChanged: (StudioTouchValue) -> Void
    var onEstimated: (StudioTouchValue) -> Void
    var onEnded: (StudioTouchValue) -> Void
    var onCancelled: () -> Void
    func makeUIView(context: Context) -> StudioTouchView {
        let view = StudioTouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = false
        updateUIView(view, context: context)
        return view
    }
    func updateUIView(_ view: StudioTouchView, context: Context) {
        view.changed = onChanged; view.estimated = onEstimated; view.ended = onEnded; view.cancelled = onCancelled
    }
    static func dismantleUIView(_ view: StudioTouchView, coordinator: ()) { view.cancelStroke() }
}

private final class StudioTouchView: UIView {
    var changed: ((StudioTouchValue) -> Void)?
    var estimated: ((StudioTouchValue) -> Void)?
    var ended: ((StudioTouchValue) -> Void)?
    var cancelled: (() -> Void)?
    private var active: UITouch?
    private var strokeID = UUID().uuidString
    private var held = Set<UITouch>()
    private var start = CGPoint.zero
    private var startTime: TimeInterval = 0
    private var startDate = Date()
    private var lastTime: TimeInterval = -.infinity

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        held.formUnion(touches)
        if let active {
            // Ignore palm contacts while Pencil owns the stroke. Additional
            // fingers cancel finger drawing rather than connecting segments.
            if active.type != .pencil { cancelStroke() }
            return
        }
        guard let touch = touches.first(where: { $0.type == .pencil }) ?? (held.count == 1 ? touches.first : nil),
              touch.type == .pencil || touch.type == .direct else { return }
        // Do not restart a cancelled multi-touch gesture until all contacts lift.
        guard held.count == 1 || touch.type == .pencil else { return }
        strokeID = UUID().uuidString
        active = touch; start = touch.preciseLocation(in: self)
        startTime = touch.timestamp; startDate = Date(); lastTime = -.infinity
        emit(touch, event: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active, touches.contains(active) else { return }
        emit(active, event: event)
    }
    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        guard active?.type == .pencil else { return }
        for touch in touches where touch.type == .pencil && touch.estimationUpdateIndex != nil {
            guard touch.timestamp >= startTime, touch.timestamp <= lastTime else { continue }
            estimated?(value(touch))
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { held.subtract(touches) }
        guard let active, touches.contains(active) else { return }
        emit(active, event: event)
        let final = value(active)
        self.active = nil
        ended?(final)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let active, touches.contains(active) { cancelStroke() }
        held.subtract(touches)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelStroke(); held.removeAll() }
    }
    func cancelStroke() {
        guard active != nil else { return }
        active = nil; cancelled?()
    }
    private func emit(_ touch: UITouch, event: UIEvent?) {
        // Predicted samples are deliberately excluded from persisted artwork.
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            guard sample.timestamp >= startTime, sample.timestamp > lastTime else { continue }
            lastTime = sample.timestamp
            changed?(value(sample))
        }
    }
    private func value(_ touch: UITouch) -> StudioTouchValue {
        let pressure: CGFloat? = touch.type == .pencil && touch.maximumPossibleForce > 0
            ? min(1, max(0, touch.force / touch.maximumPossibleForce)) : nil
        var tilt: StudioPencilTilt?
        if touch.type == .pencil {
            let rawAzimuth = Double(touch.azimuthAngle(in: self))
            let azimuth = rawAzimuth.truncatingRemainder(dividingBy: .pi * 2)
            let measuredTilt = StudioPencilTilt(altitude: Double(touch.altitudeAngle),
                azimuth: azimuth < 0 ? azimuth + .pi * 2 : azimuth)
            tilt = measuredTilt.isValid ? measuredTilt : nil
        }
        return StudioTouchValue(strokeID: strokeID, estimationIndex: touch.estimationUpdateIndex?.int64Value,
            expectsUpdates: !touch.estimatedPropertiesExpectingUpdates.isEmpty,
            location: touch.preciseLocation(in: self), startLocation: start,
            time: startDate.addingTimeInterval(max(0, touch.timestamp-startTime)), pressure: pressure, tilt: tilt)
    }
}
