// ToolSettingsSheet.swift
// Bottom sheet with tool-specific settings
// Red slider tracks, white thumbs, ruler modes for Pen

import SwiftUI

struct ToolSettingsSheet: View {
    @ObservedObject var vm: EditorViewModel
    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            if isExpanded {
                VStack(spacing: 0) {
                    // Grab handle
                    grabHandle

                    VStack(spacing: 0) {
                        switch vm.drawState.tool {
                        case .pencil:
                            penSettings
                        case .eraser:
                            eraserSettings
                        case .lasso:
                            lassoSettings
                        case .fill:
                            fillSettings
                        case .text:
                            textSettings
                        default:
                            penSettings
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .padding(.top, 8)
                }
                .background(Color(hex: "1a1a1a"))
                .overlay(alignment: .top) {
                    Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
                }
            }
        }
        .padding(.bottom, 112) // Above frame strip + action bar
    }

    // MARK: - Grab Handle
    var grabHandle: some View {
        HStack {
            Spacer()
            RoundedRectangle(cornerRadius: 2)
                .fill(.white.opacity(0.2))
                .frame(width: 40, height: 4)
            Spacer()
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
    }

    // MARK: - Pen Settings
    var penSettings: some View {
        VStack(spacing: 4) {
            // Header
            HStack {
                Image(systemName: "pencil.tip")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Pen")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button { isExpanded = false } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .padding(.bottom, 12)

            RedSlider(label: "Size", value: $vm.drawState.strokeWidth, range: 1...100, unit: "px")
            RedSlider(label: "Opacity", value: .constant(100), range: 0...100, unit: "%")
            RedSlider(label: "Smooth", value: .constant(30), range: 0...100, unit: "%")

            // Ruler modes
            VStack(alignment: .leading, spacing: 8) {
                Text("RULER")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.3))

                HStack(spacing: 6) {
                    ForEach(RulerModeItem.all) { item in
                        Button {
                            // Set ruler mode
                        } label: {
                            VStack(spacing: 4) {
                                Text(item.icon)
                                    .font(.system(size: 14))
                                Text(item.label)
                                    .font(.system(size: 9))
                            }
                            .foregroundStyle(item.id == "off" ? Color(hex: "E03030") : .white.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(item.id == "off" ? Color(hex: "E03030").opacity(0.15) : .white.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(item.id == "off" ? Color(hex: "E03030").opacity(0.5) : .white.opacity(0.06), lineWidth: 1.5)
                            )
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Eraser Settings
    var eraserSettings: some View {
        VStack(spacing: 4) {
            RedSlider(label: "Size", value: .constant(20), range: 1...100, unit: "px")
            RedSlider(label: "Opacity", value: .constant(100), range: 0...100, unit: "%")
            RedSlider(label: "Feather", value: .constant(0), range: 0...50, unit: "px")
        }
    }

    // MARK: - Lasso Settings
    var lassoSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lasso / Select")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.bottom, 4)

            ForEach([
                "Draw around an area to select it",
                "Double-tap canvas to select all on layer",
                "Drag inside box to move",
                "Drag corner handles to scale",
                "Drag top handle to rotate",
                "Tap outside the box to commit"
            ], id: \.self) { instruction in
                Text("• \(instruction)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    // MARK: - Fill Settings
    var fillSettings: some View {
        VStack(spacing: 8) {
            RedSlider(label: "Tolerance", value: .constant(10), range: 0...100, unit: "")
            Text("Tap an area on the canvas to fill it with the current color.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Text Settings
    var textSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tap canvas to place text. Font: Special Elite.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
            Text("Change color from the color swatch below.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}

// MARK: - Red Slider
struct RedSlider: View {
    let label: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let unit: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 56, alignment: .trailing)

            GeometryReader { geo in
                let pct = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack(alignment: .leading) {
                    // Track background
                    Capsule()
                        .fill(Color(hex: "333333"))
                        .frame(height: 6)

                    // Filled track
                    Capsule()
                        .fill(Color(hex: "E03030"))
                        .frame(width: geo.size.width * pct, height: 6)

                    // Thumb
                    Circle()
                        .fill(.white)
                        .frame(width: 20, height: 20)
                        .shadow(color: .black.opacity(0.3), radius: 3)
                        .offset(x: geo.size.width * pct - 10)
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let pct = max(0, min(1, gesture.location.x / geo.size.width))
                            value = range.lowerBound + pct * (range.upperBound - range.lowerBound)
                        }
                )
            }
            .frame(height: 20)

            Text("\(Int(value))\(unit)")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Ruler Mode Item
struct RulerModeItem: Identifiable {
    let id: String
    let label: String
    let icon: String

    static let all: [RulerModeItem] = [
        .init(id: "off", label: "Off", icon: "✕"),
        .init(id: "line", label: "Line", icon: "╱"),
        .init(id: "rect", label: "Rect", icon: "▢"),
        .init(id: "circle", label: "Circle", icon: "○"),
        .init(id: "mirror", label: "Mirror", icon: "⟲"),
    ]
}
