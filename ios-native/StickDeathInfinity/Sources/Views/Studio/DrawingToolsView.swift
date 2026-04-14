// DrawingToolsView.swift
// Drawing tools overlay for the Studio's Draw mode
// Appears as a floating toolbar when draw mode is active
// Supports: freehand, line, rectangle, circle, eraser, text

import SwiftUI

// MARK: - Drawing Tool Enum
enum DrawingTool: String, CaseIterable {
    case pencil     // Freehand drawing
    case line       // Straight line
    case rectangle  // Rectangle/square
    case circle     // Circle/ellipse
    case arrow      // Arrow
    case eraser     // Erase drawn elements
    case text       // Add text label

    var icon: String {
        switch self {
        case .pencil: return "pencil.tip"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .arrow: return "arrow.up.right"
        case .eraser: return "eraser.fill"
        case .text: return "textformat"
        }
    }

    var label: String {
        switch self {
        case .pencil: return "Pen"
        case .line: return "Line"
        case .rectangle: return "Rect"
        case .circle: return "Circle"
        case .arrow: return "Arrow"
        case .eraser: return "Erase"
        case .text: return "Text"
        }
    }
}

// MARK: - Drawing State (lives on EditorViewModel via extension)
class DrawingState: ObservableObject {
    @Published var tool: DrawingTool = .pencil
    @Published var strokeColor: Color = .white
    @Published var strokeWidth: CGFloat = 3
    @Published var fillEnabled: Bool = false
    @Published var fillColor: Color = .clear
    @Published var currentPath: [CGPoint] = []
    @Published var drawnElements: [DrawnElement] = []
    @Published var textInput: String = ""
    @Published var showTextInput: Bool = false
    @Published var textPosition: CGPoint = .zero

    func clear() {
        drawnElements.removeAll()
    }

    func undoLastElement() {
        _ = drawnElements.popLast()
    }
}

// MARK: - Drawn Element (stored per frame)
struct DrawnElement: Identifiable, Codable {
    let id: UUID
    var tool: String            // DrawingTool.rawValue
    var points: [CGPoint]       // Path points (for pencil/line/arrow)
    var origin: CGPoint?        // For rect/circle: top-left
    var size: CGSize?           // For rect/circle: width/height
    var strokeColor: String     // Hex
    var strokeWidth: CGFloat
    var fillColor: String?      // Hex, nil = no fill
    var text: String?           // For text tool
    var fontSize: CGFloat?
}

// MARK: - Drawing Tools Floating Bar
struct DrawingToolsView: View {
    @ObservedObject var drawState: DrawingState
    @State private var showColorPicker = false
    @State private var showWidthSlider = false

    var body: some View {
        VStack(spacing: 0) {
            // Tool selection row
            HStack(spacing: 2) {
                ForEach(DrawingTool.allCases, id: \.self) { tool in
                    drawToolButton(tool)
                }

                Divider().frame(height: 24).background(ThemeManager.border)

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

                // Undo drawn
                Button { drawState.undoLastElement() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 28, height: 28)
                }
                .disabled(drawState.drawnElements.isEmpty)

                // Clear all
                Button { drawState.clear() } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.7))
                        .frame(width: 28, height: 28)
                }
                .disabled(drawState.drawnElements.isEmpty)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Expanded panels
            if showColorPicker {
                drawColorPicker
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if showWidthSlider {
                widthSlider
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25), value: showColorPicker)
        .animation(.spring(response: 0.25), value: showWidthSlider)
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
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundStyle(drawState.tool == tool ? .red : .white.opacity(0.6))
            .frame(width: 36, height: 36)
            .background(drawState.tool == tool ? Color.red.opacity(0.15) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Color Picker
    var drawColorPicker: some View {
        VStack(spacing: 8) {
            // Preset swatches
            let presets: [Color] = [.white, .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .gray]
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 10), spacing: 4) {
                ForEach(presets, id: \.self) { color in
                    Circle()
                        .fill(color)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle().stroke(.white, lineWidth: drawState.strokeColor == color ? 2 : 0)
                        )
                        .onTapGesture { drawState.strokeColor = color }
                }
            }

            // iOS system color picker
            ColorPicker("Custom", selection: $drawState.strokeColor, supportsOpacity: true)
                .font(.caption)
                .labelsHidden()

            // Fill toggle
            HStack {
                Toggle(isOn: $drawState.fillEnabled) {
                    Text("Fill").font(.caption2)
                }
                .toggleStyle(.switch)
                .tint(.red)
                .scaleEffect(0.8)

                if drawState.fillEnabled {
                    ColorPicker("", selection: $drawState.fillColor)
                        .labelsHidden()
                        .scaleEffect(0.8)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(width: 300)
    }

    // MARK: - Width Slider
    var widthSlider: some View {
        HStack(spacing: 12) {
            // Preview
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
// Place this on top of CanvasView when in draw mode
struct DrawingOverlay: View {
    @ObservedObject var drawState: DrawingState
    let canvasCenter: CGPoint
    let canvasScale: CGFloat

    var body: some View {
        ZStack {
            // Render completed elements
            ForEach(drawState.drawnElements) { element in
                DrawnElementView(element: element, center: canvasCenter, scale: canvasScale)
            }

            // Render current in-progress path
            if !drawState.currentPath.isEmpty {
                currentPathView
            }
        }
        .drawingGroup(opaque: false)  // GPU composite
    }

    @ViewBuilder
    var currentPathView: some View {
        let color = drawState.strokeColor
        let width = drawState.strokeWidth * canvasScale

        switch drawState.tool {
        case .pencil:
            Path { path in
                guard let first = drawState.currentPath.first else { return }
                path.move(to: screenPoint(first))
                for pt in drawState.currentPath.dropFirst() {
                    path.addLine(to: screenPoint(pt))
                }
            }
            .stroke(color, lineWidth: width)

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

    var body: some View {
        switch element.tool {
        case "pencil":
            Path { path in
                guard let first = element.points.first else { return }
                path.move(to: sp(first))
                for pt in element.points.dropFirst() {
                    path.addLine(to: sp(pt))
                }
            }
            .stroke(strokeColor, lineWidth: element.strokeWidth * scale)

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

        // Arrowhead
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
