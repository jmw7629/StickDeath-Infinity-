// CanvasView.swift
// The main drawing canvas — renders stick figures with joint dragging

import SwiftUI

struct CanvasView: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2 + vm.canvasOffset.width,
                                 y: geo.size.height / 2 + vm.canvasOffset.height)

            ZStack {
                // Grid
                GridBackground()

                // Onion skin (previous frame)
                if vm.showOnionSkin, vm.currentFrameIndex > 0,
                   let prevFrame = vm.frames[safe: vm.currentFrameIndex - 1] {
                    ForEach(prevFrame.figureStates) { state in
                        if state.visible, let figure = vm.figures.first(where: { $0.id == state.figureId }) {
                            StickFigureRenderer(
                                figure: figure,
                                joints: state.joints,
                                center: center,
                                scale: vm.canvasScale,
                                opacity: 0.2,
                                isSelected: false
                            )
                        }
                    }
                }

                // Current frame figures
                if let currentFrame = vm.frames[safe: vm.currentFrameIndex] {
                    ForEach(currentFrame.figureStates) { state in
                        if state.visible, let figure = vm.figures.first(where: { $0.id == state.figureId }) {
                            StickFigureRenderer(
                                figure: figure,
                                joints: state.joints,
                                center: center,
                                scale: vm.canvasScale,
                                opacity: 1.0,
                                isSelected: state.figureId == vm.selectedFigureId
                            )

                            // Joint handles (pose mode)
                            if vm.mode == .pose && state.figureId == vm.selectedFigureId {
                                ForEach(Array(state.joints.keys.sorted()), id: \.self) { jointName in
                                    if let pos = state.joints[jointName] {
                                        JointHandle(
                                            position: CGPoint(
                                                x: center.x + pos.x * vm.canvasScale,
                                                y: center.y + pos.y * vm.canvasScale
                                            ),
                                            isHead: jointName == "head",
                                            isSelected: vm.selectedJoint == jointName
                                        )
                                        .gesture(
                                            DragGesture()
                                                .onChanged { drag in
                                                    vm.selectedJoint = jointName
                                                    let newPos = CGPoint(
                                                        x: (drag.location.x - center.x) / vm.canvasScale,
                                                        y: (drag.location.y - center.y) / vm.canvasScale
                                                    )
                                                    vm.moveJoint(jointName, to: newPos, figureId: figure.id)
                                                }
                                                .onEnded { _ in
                                                    vm.pushUndo()
                                                }
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Grid Background
struct GridBackground: View {
    var body: some View {
        Canvas { context, size in
            let gridSize: CGFloat = 40
            let color = Color.white.opacity(0.04)
            for x in stride(from: 0, to: size.width, by: gridSize) {
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                    with: .color(color), lineWidth: 0.5
                )
            }
            for y in stride(from: 0, to: size.height, by: gridSize) {
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) },
                    with: .color(color), lineWidth: 0.5
                )
            }
        }
    }
}

// MARK: - Stick Figure Renderer
struct StickFigureRenderer: View {
    let figure: StickFigure
    let joints: [String: CGPoint]
    let center: CGPoint
    let scale: CGFloat
    let opacity: Double
    let isSelected: Bool

    var body: some View {
        Canvas { context, _ in
            let color = figure.color.color.opacity(opacity)

            // Draw bones
            for (from, to) in StickFigure.bones {
                guard let p1 = joints[from], let p2 = joints[to] else { continue }
                let start = CGPoint(x: center.x + p1.x * scale, y: center.y + p1.y * scale)
                let end = CGPoint(x: center.x + p2.x * scale, y: center.y + p2.y * scale)

                context.stroke(
                    Path { p in p.move(to: start); p.addLine(to: end) },
                    with: .color(color),
                    lineWidth: figure.lineWidth * scale
                )
            }

            // Draw head
            if let headPos = joints["head"] {
                let headCenter = CGPoint(x: center.x + headPos.x * scale, y: center.y + headPos.y * scale)
                let r = figure.headRadius * scale
                context.stroke(
                    Path { p in p.addEllipse(in: CGRect(x: headCenter.x - r, y: headCenter.y - r, width: r * 2, height: r * 2)) },
                    with: .color(color),
                    lineWidth: figure.lineWidth * scale
                )
            }

            // Selection outline
            if isSelected {
                context.stroke(
                    Path { p in
                        // Bounding box around figure
                        let allPoints = joints.values.map { CGPoint(x: center.x + $0.x * scale, y: center.y + $0.y * scale) }
                        guard let minX = allPoints.map(\.x).min(),
                              let maxX = allPoints.map(\.x).max(),
                              let minY = allPoints.map(\.y).min(),
                              let maxY = allPoints.map(\.y).max() else { return }
                        p.addRoundedRect(in: CGRect(x: minX - 10, y: minY - 10, width: maxX - minX + 20, height: maxY - minY + 20), cornerSize: CGSize(width: 8, height: 8))
                    },
                    with: .color(.orange.opacity(0.4)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
            }
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
    }
}
