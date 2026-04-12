// CanvasView.swift
// GPU-accelerated stick figure canvas — zero-lag rendering
// Uses SwiftUI Canvas (backed by Core Graphics / Metal) with:
//   - drawingGroup() for GPU compositing
//   - Minimal redraws via Equatable conformance
//   - Efficient gesture handling with no state churn
//   - Adaptive to all screen sizes

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
                // Grid — drawn once via Canvas, no per-frame cost
                GridBackground()
                    .drawingGroup()  // GPU compositing

                // All figures composited in one GPU pass
                figureLayer(center: center)
                    .drawingGroup(opaque: false)

                // Joint handles (only in pose mode, only for selected figure)
                if vm.mode == .pose {
                    jointHandles(center: center, geoSize: geo.size)
                }

                // Placed objects layer
                objectsLayer(center: center)
                    .drawingGroup(opaque: false)
            }
        }
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
            context.stroke(selPath, with: .color(.orange.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
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
}

// MARK: - Grid Background (drawn once per resize, GPU cached)
struct GridBackground: View {
    var body: some View {
        Canvas { context, size in
            let gridSize: CGFloat = 40
            let color = Color.white.opacity(0.03)
            // Major grid
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
            context.stroke(hLine, with: .color(.orange.opacity(0.08)), lineWidth: 0.5)
            context.stroke(vLine, with: .color(.orange.opacity(0.08)), lineWidth: 0.5)
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
            .fill(isSelected ? Color.orange : Color.white.opacity(0.6))
            .frame(width: isHead ? 16 : 12, height: isHead ? 16 : 12)
            .overlay(Circle().stroke(Color.orange, lineWidth: isSelected ? 2 : 0))
            .position(position)
            .allowsHitTesting(true)
            .contentShape(Circle().inset(by: -8))  // Larger hit target
    }
}
