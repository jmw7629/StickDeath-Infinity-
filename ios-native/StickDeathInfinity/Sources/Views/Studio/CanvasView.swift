// CanvasView.swift
// GPU-accelerated animation canvas — zero-lag rendering
// v10: Bone rig rendering (styled bones, thickness, IK handles), add-bone preview

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
                // ── White canvas area ──
                canvasBackground(center: center)

                // Grid
                if vm.showGrid {
                    GridBackground()
                        .drawingGroup()
                }

                // All figures (GPU composited)
                figureLayer(center: center)
                    .drawingGroup(opaque: false)

                // Bone overlay (rig mode or when showBoneOverlay is on)
                if vm.showBoneOverlay && (vm.mode == .rig || vm.mode == .pose) {
                    boneOverlay(center: center)
                        .drawingGroup(opaque: false)
                }

                // Drawn elements
                drawnElementsLayer(center: center)
                    .drawingGroup(opaque: false)

                // Imported images
                importedImagesLayer(center: center)

                // Joint handles (pose mode or rig select/IK)
                if vm.mode == .pose || (vm.mode == .rig && [.select, .ikDrag, .addBone, .pinJoint].contains(vm.rigSubTool)) {
                    jointHandles(center: center, geoSize: geo.size)
                }

                // Placed objects
                objectsLayer(center: center)
                    .drawingGroup(opaque: false)

                // Selection highlight (cursor mode)
                if vm.mode == .cursor, let sel = vm.selectedObjectBounds {
                    selectionOverlay(bounds: sel, center: center)
                }

                // Current drawing path (live)
                if vm.mode == .draw && !vm.drawState.currentPath.isEmpty {
                    currentDrawingPath(center: center)
                }

                // Rig: add-bone preview line
                if vm.mode == .rig && vm.rigSubTool == .addBone,
                   let startJoint = vm.rigDragStartJoint,
                   let figId = vm.selectedFigureId,
                   let state = vm.frames[safe: vm.currentFrameIndex]?.figureStates.first(where: { $0.figureId == figId }),
                   let startPos = state.joints[startJoint] {
                    addBonePreview(startPos: startPos, center: center)
                }

                // Selected bone highlight
                if vm.mode == .rig, let bone = vm.selectedBone {
                    selectedBoneHighlight(bone: bone, center: center)
                }
            }
            .onAppear { vm.canvasSize = geo.size }
        }
    }

    // MARK: - Canvas Background
    @ViewBuilder
    func canvasBackground(center: CGPoint) -> some View {
        let cw = CGFloat(vm.project.canvas_width ?? 1080) * vm.canvasScale
        let ch = CGFloat(vm.project.canvas_height ?? 1920) * vm.canvasScale
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.white)
            .frame(width: cw, height: ch)
            .position(x: center.x, y: center.y)
            .shadow(color: .black.opacity(0.3), radius: 12)
    }

    // MARK: - Figure Layer (single Canvas draw call)
    @ViewBuilder
    func figureLayer(center: CGPoint) -> some View {
        Canvas { context, _ in
            // Onion skin
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

    func drawFigure(context: inout GraphicsContext, figure: StickFigure, joints: [String: CGPoint],
                    center: CGPoint, scale: CGFloat, opacity: Double, selected: Bool) {
        let color = figure.color.color.opacity(opacity)

        for (from, to) in StickFigure.bones {
            guard let p1 = joints[from], let p2 = joints[to] else { continue }
            let start = CGPoint(x: center.x + p1.x * scale, y: center.y + p1.y * scale)
            let end = CGPoint(x: center.x + p2.x * scale, y: center.y + p2.y * scale)
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(path, with: .color(color), lineWidth: figure.lineWidth * scale)
        }

        // Custom bones (from rig)
        for bone in vm.rig.bones {
            guard !StickFigure.bones.contains(where: { $0.0 == bone.jointA && $0.1 == bone.jointB }) else { continue }
            guard let p1 = joints[bone.jointA], let p2 = joints[bone.jointB] else { continue }
            let start = CGPoint(x: center.x + p1.x * scale, y: center.y + p1.y * scale)
            let end = CGPoint(x: center.x + p2.x * scale, y: center.y + p2.y * scale)
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(path, with: .color(color), lineWidth: figure.lineWidth * scale)
        }

        // Head
        if let headPos = joints["head"] {
            let hc = CGPoint(x: center.x + headPos.x * scale, y: center.y + headPos.y * scale)
            let r = figure.headRadius * scale
            let headPath = Path(ellipseIn: CGRect(x: hc.x - r, y: hc.y - r, width: r * 2, height: r * 2))
            context.stroke(headPath, with: .color(color), lineWidth: figure.lineWidth * scale)
        }

        // Selection box
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

    // MARK: - Bone Overlay (styled bones — thickness, taper, block, etc.)
    @ViewBuilder
    func boneOverlay(center: CGPoint) -> some View {
        if let figId = vm.selectedFigureId,
           let state = vm.frames[safe: vm.currentFrameIndex]?.figureStates.first(where: { $0.figureId == figId }) {
            Canvas { context, _ in
                for bone in vm.rig.bones {
                    guard bone.style != .hidden else { continue }
                    guard let posA = state.joints[bone.jointA],
                          let posB = state.joints[bone.jointB] else { continue }
                    let pA = CGPoint(x: center.x + posA.x * vm.canvasScale, y: center.y + posA.y * vm.canvasScale)
                    let pB = CGPoint(x: center.x + posB.x * vm.canvasScale, y: center.y + posB.y * vm.canvasScale)
                    let thickness = bone.thickness * vm.canvasScale
                    let boneColor = Color(hex: bone.color)
                    let isSelected = bone.id == vm.selectedBoneId

                    switch bone.style {
                    case .stick:
                        var path = Path()
                        path.move(to: pA)
                        path.addLine(to: pB)
                        context.stroke(path, with: .color(isSelected ? .red : boneColor.opacity(0.5)),
                                      lineWidth: isSelected ? thickness + 2 : thickness)

                    case .tapered:
                        drawTaperedBone(context: &context, from: pA, to: pB,
                                       baseWidth: thickness * 2, tipWidth: thickness * 0.5,
                                       color: isSelected ? .red : boneColor.opacity(0.5))

                    case .block:
                        drawBlockBone(context: &context, from: pA, to: pB,
                                     width: thickness * 1.5,
                                     color: isSelected ? .red : boneColor.opacity(0.5))

                    case .rounded:
                        drawRoundedBone(context: &context, from: pA, to: pB,
                                       width: thickness * 1.5,
                                       color: isSelected ? .red : boneColor.opacity(0.5))

                    case .hidden:
                        break
                    }

                    // Lock icon
                    if bone.locked {
                        let mid = CGPoint(x: (pA.x + pB.x) / 2, y: (pA.y + pB.y) / 2)
                        if let lockSymbol = context.resolveSymbol(id: "lock_\(bone.id.uuidString)") {
                            context.draw(lockSymbol, at: mid)
                        }
                    }
                }
            } symbols: {
                ForEach(vm.rig.bones.filter { $0.locked }) { bone in
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.yellow)
                        .tag("lock_\(bone.id.uuidString)")
                }
            }
        }
    }

    // Tapered bone (thick at base, thin at tip)
    func drawTaperedBone(context: inout GraphicsContext, from: CGPoint, to: CGPoint,
                         baseWidth: CGFloat, tipWidth: CGFloat, color: Color) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let perpAngle = angle + .pi / 2

        let bL = CGPoint(x: from.x + cos(perpAngle) * baseWidth / 2, y: from.y + sin(perpAngle) * baseWidth / 2)
        let bR = CGPoint(x: from.x - cos(perpAngle) * baseWidth / 2, y: from.y - sin(perpAngle) * baseWidth / 2)
        let tL = CGPoint(x: to.x + cos(perpAngle) * tipWidth / 2, y: to.y + sin(perpAngle) * tipWidth / 2)
        let tR = CGPoint(x: to.x - cos(perpAngle) * tipWidth / 2, y: to.y - sin(perpAngle) * tipWidth / 2)

        var path = Path()
        path.move(to: bL)
        path.addLine(to: tL)
        path.addLine(to: tR)
        path.addLine(to: bR)
        path.closeSubpath()
        context.fill(path, with: .color(color))
        context.stroke(path, with: .color(color.opacity(0.8)), lineWidth: 0.5)
    }

    // Block bone (rectangle oriented along bone axis)
    func drawBlockBone(context: inout GraphicsContext, from: CGPoint, to: CGPoint,
                       width: CGFloat, color: Color) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let perpAngle = angle + .pi / 2
        let hw = width / 2

        let corners = [
            CGPoint(x: from.x + cos(perpAngle) * hw, y: from.y + sin(perpAngle) * hw),
            CGPoint(x: to.x + cos(perpAngle) * hw, y: to.y + sin(perpAngle) * hw),
            CGPoint(x: to.x - cos(perpAngle) * hw, y: to.y - sin(perpAngle) * hw),
            CGPoint(x: from.x - cos(perpAngle) * hw, y: from.y - sin(perpAngle) * hw),
        ]

        var path = Path()
        path.move(to: corners[0])
        for c in corners.dropFirst() { path.addLine(to: c) }
        path.closeSubpath()
        context.fill(path, with: .color(color))
        context.stroke(path, with: .color(color.opacity(0.8)), lineWidth: 0.5)
    }

    // Rounded bone (capsule shape)
    func drawRoundedBone(context: inout GraphicsContext, from: CGPoint, to: CGPoint,
                         width: CGFloat, color: Color) {
        // Draw as thick line with round caps
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(path, with: .color(color),
                      style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    // MARK: - Selected Bone Highlight
    @ViewBuilder
    func selectedBoneHighlight(bone: Bone, center: CGPoint) -> some View {
        if let figId = vm.selectedFigureId,
           let state = vm.frames[safe: vm.currentFrameIndex]?.figureStates.first(where: { $0.figureId == figId }),
           let posA = state.joints[bone.jointA],
           let posB = state.joints[bone.jointB] {
            let pA = CGPoint(x: center.x + posA.x * vm.canvasScale, y: center.y + posA.y * vm.canvasScale)
            let pB = CGPoint(x: center.x + posB.x * vm.canvasScale, y: center.y + posB.y * vm.canvasScale)

            // Dashed highlight line
            Path { path in
                path.move(to: pA)
                path.addLine(to: pB)
            }
            .stroke(.red, style: StrokeStyle(lineWidth: (bone.thickness + 4) * vm.canvasScale, lineCap: .round, dash: [6, 4]))
            .opacity(0.4)
            .allowsHitTesting(false)

            // Joint dots
            Circle().fill(.red).frame(width: 10, height: 10).position(pA)
            Circle().fill(.red).frame(width: 10, height: 10).position(pB)
        }
    }

    // MARK: - Add-Bone Preview
    @ViewBuilder
    func addBonePreview(startPos: CGPoint, center: CGPoint) -> some View {
        // This just shows a dashed line from start joint following touch
        // The actual drawing is handled by the rig gesture + vm.rigDragStartJoint
        let pA = CGPoint(x: center.x + startPos.x * vm.canvasScale,
                         y: center.y + startPos.y * vm.canvasScale)
        Circle()
            .fill(.green.opacity(0.6))
            .frame(width: 14, height: 14)
            .position(pA)
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
                for pt in points.dropFirst() { path.addLine(to: sp(pt, center)) }
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
                let p1 = sp(first, center); let p2 = sp(last, center)
                let rect = CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                                  width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
                Rectangle().stroke(color, lineWidth: width)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }

        case .circle:
            if let first = points.first, let last = points.last {
                let p1 = sp(first, center); let p2 = sp(last, center)
                let rect = CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                                  width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
                Ellipse().stroke(color, lineWidth: width)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }

        default: EmptyView()
        }
    }

    // MARK: - Selection Overlay
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
        ForEach(0..<4, id: \.self) { corner in
            let x = corner % 2 == 0 ? screenRect.minX : screenRect.maxX
            let y = corner < 2 ? screenRect.minY : screenRect.maxY
            Circle().fill(Color.blue).frame(width: 10, height: 10).position(x: x, y: y)
        }
    }

    // MARK: - Joint Handles
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

                    // Different handle style in rig mode
                    let isRigMode = vm.mode == .rig
                    let isPinned = vm.rig.ikChains.contains { $0.pinned && $0.jointNames.contains(jointName) }

                    JointHandle(
                        position: screenPos,
                        isHead: jointName == "head",
                        isSelected: vm.selectedJoint == jointName,
                        isRigMode: isRigMode,
                        isPinned: isPinned
                    )
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { drag in
                                vm.selectedJoint = jointName
                                let newPos = CGPoint(
                                    x: (drag.location.x - center.x) / vm.canvasScale,
                                    y: (drag.location.y - center.y) / vm.canvasScale
                                )
                                if vm.mode == .rig {
                                    vm.moveJointWithIK(jointName, to: newPos, figureId: state.figureId)
                                } else {
                                    vm.moveJoint(jointName, to: newPos, figureId: state.figureId)
                                }
                            }
                            .onEnded { _ in vm.pushUndo() }
                    )
                }
            }
        }
    }

    // MARK: - Objects Layer
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

    func sp(_ pt: CGPoint, _ center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + pt.x * vm.canvasScale, y: center.y + pt.y * vm.canvasScale)
    }
}

// MARK: - Grid Background
struct GridBackground: View {
    var body: some View {
        Canvas { context, size in
            let gridSize: CGFloat = 40
            let color = Color.gray.opacity(0.08)
            for x in stride(from: 0, to: size.width, by: gridSize) {
                var path = Path(); path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(color), lineWidth: 0.5)
            }
            for y in stride(from: 0, to: size.height, by: gridSize) {
                var path = Path(); path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(color), lineWidth: 0.5)
            }
            let cx = size.width / 2, cy = size.height / 2
            var hLine = Path(); hLine.move(to: CGPoint(x: 0, y: cy)); hLine.addLine(to: CGPoint(x: size.width, y: cy))
            var vLine = Path(); vLine.move(to: CGPoint(x: cx, y: 0)); vLine.addLine(to: CGPoint(x: cx, y: size.height))
            context.stroke(hLine, with: .color(.red.opacity(0.12)), lineWidth: 0.5)
            context.stroke(vLine, with: .color(.red.opacity(0.12)), lineWidth: 0.5)
        }
    }
}

// MARK: - Joint Handle (updated for rig mode)
struct JointHandle: View {
    let position: CGPoint
    let isHead: Bool
    let isSelected: Bool
    var isRigMode: Bool = false
    var isPinned: Bool = false

    var body: some View {
        ZStack {
            // Rig mode: diamond shape, larger hit target
            if isRigMode {
                Diamond()
                    .fill(isPinned ? .yellow : (isSelected ? .red : .cyan.opacity(0.7)))
                    .frame(width: isHead ? 18 : 14, height: isHead ? 18 : 14)
                    .overlay(
                        Diamond()
                            .stroke(isSelected ? .white : .clear, lineWidth: 1.5)
                    )
            } else {
                Circle()
                    .fill(isSelected ? Color.red : Color.white.opacity(0.6))
                    .frame(width: isHead ? 16 : 12, height: isHead ? 16 : 12)
                    .overlay(Circle().stroke(Color.red, lineWidth: isSelected ? 2 : 0))
            }

            // Pin indicator
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.black)
            }
        }
        .position(position)
        .allowsHitTesting(true)
        .contentShape(Circle().inset(by: -10))
    }
}

// Diamond shape for rig joints
struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}
