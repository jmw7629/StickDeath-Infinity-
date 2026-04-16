// DrawingToolsView.swift
// v2: 12 brush types, fill tool, lasso tool, 5-mode color picker
// Floating toolbar for the Studio's Draw mode

import SwiftUI

// MARK: - Drawing Tool Enum
enum DrawingTool: String, CaseIterable {
    case pencil     // Freehand drawing
    case line       // Straight line
    case rectangle  // Rectangle/square
    case circle     // Circle/ellipse
    case arrow      // Arrow
    case fill       // Flood fill
    case lasso      // Freehand selection
    case eraser     // Erase drawn elements
    case text       // Add text label

    var icon: String {
        switch self {
        case .pencil:    return "pencil.tip"
        case .line:      return "line.diagonal"
        case .rectangle: return "rectangle"
        case .circle:    return "circle"
        case .arrow:     return "arrow.up.right"
        case .fill:      return "paintbrush.pointed.fill"
        case .lasso:     return "lasso"
        case .eraser:    return "eraser.fill"
        case .text:      return "textformat"
        }
    }

    var label: String {
        switch self {
        case .pencil:    return "Draw"
        case .line:      return "Line"
        case .rectangle: return "Rect"
        case .circle:    return "Circle"
        case .arrow:     return "Arrow"
        case .fill:      return "Fill"
        case .lasso:     return "Lasso"
        case .eraser:    return "Erase"
        case .text:      return "Text"
        }
    }
}

// MARK: - Drawing State
@MainActor
class DrawingState: ObservableObject {
    @Published var tool: DrawingTool = .pencil
    @Published var brushType: BrushType = .pen
    @Published var strokeColor: Color = .black
    @Published var strokeWidth: CGFloat = 3
    @Published var fillEnabled: Bool = false
    @Published var fillColor: Color = .clear
    @Published var currentPath: [CGPoint] = []
    @Published var drawnElements: [DrawnElement] = []
    @Published var textInput: String = ""
    @Published var showTextInput: Bool = false
    @Published var textPosition: CGPoint = .zero

    // Lasso
    @Published var lassoPath: [CGPoint] = []
    @Published var lassoSelectedIds: Set<UUID> = []

    func clear() {
        drawnElements.removeAll()
        lassoSelectedIds.removeAll()
    }

    func undoLastElement() {
        _ = drawnElements.popLast()
    }

    func deleteSelected() {
        drawnElements.removeAll { lassoSelectedIds.contains($0.id) }
        lassoSelectedIds.removeAll()
        lassoPath.removeAll()
    }
}

// MARK: - Drawn Element
struct DrawnElement: Identifiable, Codable {
    let id: UUID
    var tool: String
    var brushType: String?       // BrushType.rawValue — nil for legacy
    var points: [CGPoint]
    var origin: CGPoint?
    var size: CGSize?
    var strokeColor: String      // Hex
    var strokeWidth: CGFloat
    var fillColor: String?       // Hex
    var text: String?
    var fontSize: CGFloat?
}

// MARK: - Drawing Tools Floating Bar
struct DrawingToolsView: View {
    @ObservedObject var drawState: DrawingState
    @State private var showColorPicker = false
    @State private var showWidthSlider = false
    @State private var showBrushPicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Tool row — scrollable for 9 tools
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(DrawingTool.allCases, id: \.self) { tool in
                        drawToolButton(tool)
                    }

                    Divider().frame(height: 24).background(ThemeManager.border)

                    // Brush type button
                    Button { showBrushPicker = true } label: {
                        VStack(spacing: 1) {
                            Image(systemName: drawState.brushType.icon)
                                .font(.system(size: 14))
                            Text(drawState.brushType.displayName)
                                .font(.system(size: 7, weight: .medium))
                        }
                        .foregroundStyle(.orange)
                        .frame(width: 36, height: 36)
                    }

                    // Color swatch
                    Button { showColorPicker.toggle(); showWidthSlider = false } label: {
                        Circle()
                            .fill(drawState.strokeColor)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
                    }

                    // Stroke width
                    Button {
                        showWidthSlider.toggle()
                        showColorPicker = false
                    } label: {
                        VStack(spacing: 1) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(.white)
                                .frame(width: 18, height: max(1, drawState.strokeWidth))
                        }
                        .frame(width: 28, height: 28)
                    }

                    // Undo
                    Button { drawState.undoLastElement() } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.red)
                            .frame(width: 28, height: 28)
                    }
                    .disabled(drawState.drawnElements.isEmpty)

                    // Delete selected (lasso)
                    if !drawState.lassoSelectedIds.isEmpty {
                        Button { drawState.deleteSelected() } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .frame(width: 28, height: 28)
                        }
                    }

                    // Clear all
                    Button { drawState.clear() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.5))
                            .frame(width: 28, height: 28)
                    }
                    .disabled(drawState.drawnElements.isEmpty)
                }
                .padding(.horizontal, 6)
            }
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Expanded: 5-mode color picker
            if showColorPicker {
                ColorPickerPanel(
                    selectedColor: $drawState.strokeColor,
                    fillEnabled: $drawState.fillEnabled,
                    fillColor: $drawState.fillColor
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Expanded: width slider
            if showWidthSlider {
                widthSlider
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25), value: showColorPicker)
        .animation(.spring(response: 0.25), value: showWidthSlider)
        .sheet(isPresented: $showBrushPicker) {
            BrushPickerSheet(selectedBrush: $drawState.brushType)
                .presentationDetents([.medium])
        }
    }

    @ViewBuilder
    func drawToolButton(_ tool: DrawingTool) -> some View {
        Button {
            drawState.tool = tool
            showColorPicker = false
            showWidthSlider = false
        } label: {
            VStack(spacing: 1) {
                Image(systemName: tool.icon)
                    .font(.system(size: 14, weight: drawState.tool == tool ? .bold : .regular))
                Text(tool.label)
                    .font(.system(size: 7, weight: .medium))
            }
            .foregroundStyle(drawState.tool == tool ? .red : .white.opacity(0.6))
            .frame(width: 36, height: 36)
            .background(drawState.tool == tool ? Color.red.opacity(0.15) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Width Slider
    var widthSlider: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: drawState.strokeWidth / 2)
                .fill(drawState.strokeColor)
                .frame(width: 40, height: max(1, drawState.strokeWidth))

            Slider(value: $drawState.strokeWidth, in: 1...20, step: 0.5)
                .tint(.red)

            Text("\(drawState.strokeWidth, specifier: "%.1f")pt")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.gray)
                .frame(width: 36)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(width: 280)
    }
}

// MARK: - Drawing Canvas Overlay
struct DrawingOverlay: View {
    @ObservedObject var drawState: DrawingState
    let canvasCenter: CGPoint
    let canvasScale: CGFloat

    var body: some View {
        ZStack {
            // Completed elements
            ForEach(drawState.drawnElements) { element in
                DrawnElementView(element: element, center: canvasCenter, scale: canvasScale)
            }

            // Lasso selection highlight
            ForEach(drawState.drawnElements.filter { drawState.lassoSelectedIds.contains($0.id) }) { element in
                DrawnElementView(element: element, center: canvasCenter, scale: canvasScale)
                    .opacity(0.3)
                    .blendMode(.difference)
            }

            // Current drawing path
            if !drawState.currentPath.isEmpty {
                currentPathView
            }

            // Lasso path overlay
            if !drawState.lassoPath.isEmpty {
                LassoOverlayView(
                    points: drawState.lassoPath,
                    canvasCenter: canvasCenter,
                    canvasScale: canvasScale
                )
            }
        }
        .drawingGroup(opaque: false)
    }

    @ViewBuilder
    var currentPathView: some View {
        let color = drawState.strokeColor
        let width = drawState.strokeWidth * canvasScale

        switch drawState.tool {
        case .pencil:
            BrushRenderer.render(
                points: drawState.currentPath,
                brush: drawState.brushType,
                color: color,
                width: drawState.strokeWidth,
                scale: canvasScale,
                toScreen: { screenPoint($0) }
            )

        case .line, .arrow:
            if let first = drawState.currentPath.first, let last = drawState.currentPath.last {
                Path { path in
                    path.move(to: screenPoint(first))
                    path.addLine(to: screenPoint(last))
                }
                .stroke(color, lineWidth: width)
            }

        case .rectangle:
            if let first = drawState.currentPath.first, let last = drawState.currentPath.last {
                let p1 = screenPoint(first)
                let p2 = screenPoint(last)
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
            if let first = drawState.currentPath.first, let last = drawState.currentPath.last {
                let p1 = screenPoint(first)
                let p2 = screenPoint(last)
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

    func screenPoint(_ pt: CGPoint) -> CGPoint {
        CGPoint(
            x: canvasCenter.x + pt.x * canvasScale,
            y: canvasCenter.y + pt.y * canvasScale
        )
    }
}

// MARK: - Render a completed drawn element
struct DrawnElementView: View {
    let element: DrawnElement
    let center: CGPoint
    let scale: CGFloat

    var strokeColor: Color { Color(hex: element.strokeColor) }
    var fillColor: Color? { element.fillColor.flatMap { Color(hex: $0) } }
    var brush: BrushType { BrushType(rawValue: element.brushType ?? "pen") ?? .pen }

    var body: some View {
        switch element.tool {
        case "pencil":
            BrushRenderer.render(
                points: element.points,
                brush: brush,
                color: strokeColor,
                width: element.strokeWidth,
                scale: scale,
                toScreen: { sp($0) }
            )

        case "line":
            if let first = element.points.first, let last = element.points.last {
                Path { path in
                    path.move(to: sp(first))
                    path.addLine(to: sp(last))
                }
                .stroke(strokeColor, lineWidth: element.strokeWidth * scale)
            }

        case "arrow":
            if let first = element.points.first, let last = element.points.last {
                ArrowShape(from: sp(first), to: sp(last))
                    .stroke(strokeColor, lineWidth: element.strokeWidth * scale)
            }

        case "rectangle":
            if let origin = element.origin, let size = element.size {
                let rect = CGRect(
                    x: center.x + origin.x * scale,
                    y: center.y + origin.y * scale,
                    width: size.width * scale,
                    height: size.height * scale
                )
                ZStack {
                    if let fc = fillColor {
                        Rectangle().fill(fc)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                    Rectangle().stroke(strokeColor, lineWidth: element.strokeWidth * scale)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }

        case "circle":
            if let origin = element.origin, let size = element.size {
                let rect = CGRect(
                    x: center.x + origin.x * scale,
                    y: center.y + origin.y * scale,
                    width: size.width * scale,
                    height: size.height * scale
                )
                ZStack {
                    if let fc = fillColor {
                        Ellipse().fill(fc)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                    Ellipse().stroke(strokeColor, lineWidth: element.strokeWidth * scale)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }

        case "text":
            if let textContent = element.text, let origin = element.origin {
                Text(textContent)
                    .font(.system(size: (element.fontSize ?? 14) * scale))
                    .foregroundStyle(strokeColor)
                    .position(
                        x: center.x + origin.x * scale,
                        y: center.y + origin.y * scale
                    )
            }

        default: EmptyView()
        }
    }

    func sp(_ pt: CGPoint) -> CGPoint {
        CGPoint(x: center.x + pt.x * scale, y: center.y + pt.y * scale)
    }
}

// MARK: - Arrow Shape
struct ArrowShape: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)

        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLength: CGFloat = 12
        let headAngle: CGFloat = .pi / 6

        let left = CGPoint(
            x: to.x - headLength * cos(angle - headAngle),
            y: to.y - headLength * sin(angle - headAngle)
        )
        let right = CGPoint(
            x: to.x - headLength * cos(angle + headAngle),
            y: to.y - headLength * sin(angle + headAngle)
        )
        path.move(to: left)
        path.addLine(to: to)
        path.addLine(to: right)

        return path
    }
}
