// CanvasView.swift
// GPU-accelerated animation canvas — zero-lag rendering
// v9: White canvas background, drawn elements, imported images, cursor selection

import SwiftUI

struct CanvasView: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(
                x: geo.size.width / 2 + vm.canvasOffset.width,
                y: geo.size.height / 2 + vm.canvasOffset.height
            )

            ZStack {
                // ── White canvas area (so drawing is visible) ──
                canvasBackground(geo: geo, center: center)

                // Grid (subtle, on top of white area)
                if vm.showGrid {
                    GridBackground()
                        .drawingGroup()
                }

                // All figures composited in one GPU pass
                figureLayer(center: center)
                    .drawingGroup(opaque: false)

                // Drawn elements layer (freehand, shapes, text)
                drawnElementsLayer(center: center)
                    .drawingGroup(opaque: false)

                // Imported images layer
                importedImagesLayer(center: center)

                // Joint handles (only in pose mode, only for selected figure)
                if vm.mode == .pose {
                    jointHandles(center: center, geoSize: geo.size)
                }

                // Placed objects layer
                objectsLayer(center: center)
                    .drawingGroup(opaque: false)

                // Selection highlight (cursor mode)
                if vm.mode == .cursor, let sel = vm.selectedObjectBounds {
                    selectionOverlay(bounds: sel, center: center)
                }

                // Current drawing path (live feedback)
                if vm.mode == .draw && !vm.drawState.currentPath.isEmpty {
                    currentDrawingPath(center: center)
                }
            }
            .onAppear {
                vm.canvasSize = geo.size
            }
        }
    }

    // MARK: - White Canvas Background
    @ViewBuilder
    func canvasBackground(geo: GeometryReader<some View>.Content, center: CGPoint) -> some View {
        let cw = CGFloat(vm.project.canvas_width ?? 1080) * vm.canvasScale
        let ch = CGFloat(vm.project.canvas_height ?? 1920) * vm.canvasScale
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.white)
            .frame(width: cw, height: ch)
            .position(x: center.x, y: center.y)
            .shadow(color: .black.opacity(0.3), radius: 12)
    }

    // MARK: - Figure Layer (single Canvas draw call = fast)
    @ViewBuilder
    func figureLayer(center: CGPoint) -> some View {
        Canvas { context, _ in
            // Onion skin (previous frame — faded)
            if vm.showOnionSkin, vm.currentFrameIndex > 0,
               let prevFrame = vm.frames[safe: vm.currentFrameIndex - 1] {
                for state in prevFrame.figureStates where state.visible {
                    if let figure = vm.figures.first(where: { $0.id == state.figureId }) {
                        drawFigure(context: &context, figure: figure, joints: state.joints,
                                   center: center, scale: vm.canvasScale, opacity: 0.15, selected: false)
                    }
                }
            }

            // Current frame
            if let currentFrame = vm.frames[safe: vm.currentFrameIndex] {
                for state in currentFrame.figureStates where state.visible {
                    if let figure = vm.figures.first(where: { $0.id == state.figureId }) {
                        let selected = state.figureId == vm.selectedFigureId
                        drawFigure(context: &context, figure: figure, joints: state.joints,
                                   center: center, scale: vm.canvasScale, opacity: 1.0, selected: selected)
                    }
                }
            }
        }
    }

    // MARK: - Draw Figure (pure Core Graphics — no SwiftUI overhead)
    func drawFigure(context: inout GraphicsContext, figure: StickFigure, joints: [String: CGPoint],
                    center: CGPoint, scale: CGFloat, opacity: Double, selected: Bool) {
        let color = figure.color.color.opacity(opacity)

        // Draw bones
        for (from, to) in StickFigure.bones {
            guard let p1 = joints[from], let p2 = joints[to] else { continue }
            let start = CGPoint(x: center.x + p1.x * scale, y: center.y + p1.y * scale)
            let end = CGPoint(x: center.x + p2.x * scale, y: center.y + p2.y * scale)
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(path, with: .color(color), lineWidth: figure.lineWidth * scale)
        }

        // Draw head
        if let headPos = joints["head"] {
            let hc = CGPoint(x: center.x + headPos.x * scale, y: center.y + headPos.y * scale)
            let r = figure.headRadius * scale
            let headPath = Path(ellipseIn: CGRect(x: hc.x - r, y: hc.y - r, width: r * 2, height: r * 2))
            context.stroke(headPath, with: .color(color), lineWidth: figure.lineWidth * scale)
        }

        // Selection outline
        if selected {
            let allPoints = joints.values.map { CGPoint(x: center.x + $0.x * scale, y: center.y + $0.y * scale) }
            guard let minX = allPoints.map(\.x).min(), let maxX = allPoints.map(\.x).max(),
                  let minY = allPoints.map(\.y).min(), let maxY = allPoints.map(\.y).max() else { return }
            var selPath = Path()
            selPath.addRoundedRect(in: CGRect(x: minX - 10, y: minY - 10, width: maxX - minX + 20, height: maxY - minY + 20),
                                    cornerSize: CGSize(width: 8, height: 8))
            context.stroke(selPath, with: .color(.red.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }

    // MARK: - Drawn Elements Layer
    @ViewBuilder
    func drawnElementsLayer(center: CGPoint) -> some View {
        if let frame = vm.frames[safe: vm.currentFrameIndex] {
            ForEach(frame.drawnElements) { element in
                DrawnElementView(element: element, center: center, scale: vm.canvasScale)
            }
        }
    }

    // MARK: - Imported Images Layer
    @ViewBuilder
    func importedImagesLayer(center: CGPoint) -> some View {
        if let frame = vm.frames[safe: vm.currentFrameIndex] {
            ForEach(frame.importedImages) { img in
                let pos = CGPoint(
                    x: center.x + img.position.x * vm.canvasScale,
                    y: center.y + img.position.y * vm.canvasScale
                )
                let w = img.size.width * vm.canvasScale
                let h = img.size.height * vm.canvasScale

                Image(uiImage: img.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: w, height: h)
                    .rotationEffect(.degrees(img.rotation))
                    .opacity(img.opacity)
                    .position(pos)
                    .overlay(
                        vm.mode == .cursor && vm.selectedImageId == img.id
                            ? RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                                .frame(width: w + 4, height: h + 4)
                                .position(pos)
                            : nil
                    )
            }
        }
    }

    // MARK: - Current Drawing Path (live)
    @ViewBuilder
    func currentDrawingPath(center: CGPoint) -> some View {
        let color = vm.drawState.strokeColor
        let width = vm.drawState.strokeWidth * vm.canvasScale
        let points = vm.drawState.currentPath

        switch vm.drawState.tool {
        case .pencil:
            Path { path in
                guard let first = points.first else { return }
                path.move(to: sp(first, center))
                for pt in points.dropFirst() {
                    path.addLine(to: sp(pt, center))
                }
            }
            .stroke(color, lineWidth: width)

        case .line, .arrow:
            if let first = points.first, let last = points.last {
                Path { path in
                    path.move(to: sp(first, center))
                    path.addLine(to: sp(last, center))
                }
                .stroke(color, lineWidth: width)
            }

        case .rectangle:
            if let first = points.first, let last = points.last {
                let p1 = sp(first, center)
                let p2 = sp(last, center)
                let rect = CGRect(
                    x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                    width: abs(p2.x - p1.x), height: abs(p2.y - p1.y)
                )
                Rectangle()
                    .stroke(color, lineWidth: width)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }

        case .circle:
            if let first = points.first, let last = points.last {
                let p1 = sp(first, center)
                let p2 = sp(last, center)
                let rect = CGRect(
                    x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                    width: abs(p2.x - p1.x), height: abs(p2.y - p1.y)
                )
                Ellipse()
                    .stroke(color, lineWidth: width)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }

        default: EmptyView()
        }
    }

    // MARK: - Selection overlay (cursor mode)
    @ViewBuilder
    func selectionOverlay(bounds: CGRect, center: CGPoint) -> some View {
        let screenRect = CGRect(
            x: center.x + bounds.origin.x * vm.canvasScale,
            y: center.y + bounds.origin.y * vm.canvasScale,
            width: bounds.width * vm.canvasScale,
            height: bounds.height * vm.canvasScale
        )
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.blue, style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
            .frame(width: screenRect.width, height: screenRect.height)
            .position(x: screenRect.midX, y: screenRect.midY)

        // Resize handles at corners
        ForEach(0..<4, id: \.self) { corner in
            let x = corner % 2 == 0 ? screenRect.minX : screenRect.maxX
            let y = corner < 2 ? screenRect.minY : screenRect.maxY
            Circle()
                .fill(Color.blue)
                .frame(width: 10, height: 10)
                .position(x: x, y: y)
        }
    }

    // MARK: - Joint Handles (lightweight overlays)
    @ViewBuilder
    func jointHandles(center: CGPoint, geoSize: CGSize) -> some View {
        if let frame = vm.frames[safe: vm.currentFrameIndex],
           let state = frame.figureStates.first(where: { $0.figureId == vm.selectedFigureId }) {
            ForEach(Array(state.joints.keys.sorted()), id: \.self) { jointName in
                if let pos = state.joints[jointName] {
                    let screenPos = CGPoint(
                        x: center.x + pos.x * vm.canvasScale,
                        y: center.y + pos.y * vm.canvasScale
                    )
                    JointHandle(
                        position: screenPos,
                        isHead: jointName == "head",
                        isSelected: vm.selectedJoint == jointName
                    )
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { drag in
                                vm.selectedJoint = jointName
                                let newPos = CGPoint(
                                    x: (drag.location.x - center.x) / vm.canvasScale,
                                    y: (drag.location.y - center.y) / vm.canvasScale
                                )
                                vm.moveJoint(jointName, to: newPos, figureId: state.figureId)
                            }
                            .onEnded { _ in vm.pushUndo() }
                    )
                }
            }
        }
    }

    // MARK: - Objects Layer (placed props from asset library)
    @ViewBuilder
    func objectsLayer(center: CGPoint) -> some View {
        if let frame = vm.frames[safe: vm.currentFrameIndex] {
            ForEach(frame.placedObjects) { obj in
                Image(systemName: obj.sfSymbol)
                    .font(.system(size: obj.size * vm.canvasScale))
                    .foregroundStyle(Color(hex: obj.tint))
                    .rotationEffect(.degrees(obj.rotation))
                    .position(
                        x: center.x + obj.position.x * vm.canvasScale,
                        y: center.y + obj.position.y * vm.canvasScale
                    )
                    .opacity(obj.opacity)
            }
        }
    }

    // Helper: canvas point → screen point
    func sp(_ pt: CGPoint, _ center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + pt.x * vm.canvasScale, y: center.y + pt.y * vm.canvasScale)
    }
}

// MARK: - Grid Background (drawn once per resize, GPU cached)
struct GridBackground: View {
    var body: some View {
        Canvas { context, size in
            let gridSize: CGFloat = 40
            let color = Color.gray.opacity(0.08)
            for x in stride(from: 0, to: size.width, by: gridSize) {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(color), lineWidth: 0.5)
            }
            for y in stride(from: 0, to: size.height, by: gridSize) {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(color), lineWidth: 0.5)
            }
            // Center crosshair
            let cx = size.width / 2, cy = size.height / 2
            var hLine = Path(); hLine.move(to: CGPoint(x: 0, y: cy)); hLine.addLine(to: CGPoint(x: size.width, y: cy))
            var vLine = Path(); vLine.move(to: CGPoint(x: cx, y: 0)); vLine.addLine(to: CGPoint(x: cx, y: size.height))
            context.stroke(hLine, with: .color(.red.opacity(0.12)), lineWidth: 0.5)
            context.stroke(vLine, with: .color(.red.opacity(0.12)), lineWidth: 0.5)
        }
    }
}

// MARK: - Joint Handle
struct JointHandle: View {
    let position: CGPoint
    let isHead: Bool
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(isSelected ? Color.red : Color.white.opacity(0.6))
            .frame(width: isHead ? 16 : 12, height: isHead ? 16 : 12)
            .overlay(Circle().stroke(Color.red, lineWidth: isSelected ? 2 : 0))
            .position(position)
            .allowsHitTesting(true)
            .contentShape(Circle().inset(by: -8))
    }
}
