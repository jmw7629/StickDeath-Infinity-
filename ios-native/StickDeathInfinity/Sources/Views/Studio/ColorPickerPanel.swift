// ColorPickerPanel.swift
// 5-mode color picker: Swatches, RGB, HSB, Hex, Eyedropper
// Replaces the simple swatch row in DrawingToolsView

import SwiftUI

enum ColorPickerMode: String, CaseIterable {
    case swatches   = "Swatches"
    case rgb        = "RGB"
    case hsb        = "HSB"
    case hex        = "Hex"
    case eyedropper = "Dropper"

    var icon: String {
        switch self {
        case .swatches:   return "circle.grid.3x3.fill"
        case .rgb:        return "slider.horizontal.3"
        case .hsb:        return "paintpalette.fill"
        case .hex:        return "number"
        case .eyedropper: return "eyedropper.halffull"
        }
    }
}

struct ColorPickerPanel: View {
    @Binding var selectedColor: Color
    @Binding var fillEnabled: Bool
    @Binding var fillColor: Color
    @State private var mode: ColorPickerMode = .swatches
    @State private var hexInput: String = "#FF0000"

    // RGB sliders
    @State private var red: Double = 1.0
    @State private var green: Double = 0.0
    @State private var blue: Double = 0.0
    @State private var alpha: Double = 1.0

    // HSB sliders
    @State private var hue: Double = 0.0
    @State private var saturation: Double = 1.0
    @State private var brightness: Double = 1.0

    // Eyedropper
    @State private var eyedropperActive: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            // Mode tabs
            HStack(spacing: 0) {
                ForEach(ColorPickerMode.allCases, id: \.self) { m in
                    Button {
                        mode = m
                    } label: {
                        Image(systemName: m.icon)
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(mode == m ? Color.red.opacity(0.2) : .clear)
                            .foregroundStyle(mode == m ? .red : .white.opacity(0.5))
                    }
                }
            }
            .background(ThemeManager.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Color preview
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedColor)
                    .frame(width: 36, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.3), lineWidth: 1))

                Text(colorToHex(selectedColor))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.gray)

                Spacer()

                // Fill toggle
                HStack(spacing: 4) {
                    Toggle("Fill", isOn: $fillEnabled)
                        .toggleStyle(.switch)
                        .tint(.red)
                        .scaleEffect(0.7)
                        .fixedSize()

                    if fillEnabled {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(fillColor)
                            .frame(width: 24, height: 24)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.3), lineWidth: 1))
                            .onTapGesture {
                                fillColor = selectedColor
                            }
                    }
                }
            }

            // Mode-specific content
            switch mode {
            case .swatches:
                swatchGrid
            case .rgb:
                rgbSliders
            case .hsb:
                hsbSliders
            case .hex:
                hexInput_view
            case .eyedropper:
                eyedropperView
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(width: 300)
        .onChange(of: selectedColor) { _, newColor in
            syncFromColor(newColor)
        }
    }

    // MARK: - Swatches
    var swatchGrid: some View {
        let colors: [[Color]] = [
            [.white, Color(white: 0.85), Color(white: 0.65), Color(white: 0.45), Color(white: 0.25), .black],
            [Color(red: 1, green: 0, blue: 0), Color(red: 1, green: 0.3, blue: 0), Color(red: 1, green: 0.6, blue: 0), Color(red: 1, green: 0.85, blue: 0), Color(red: 0.9, green: 1, blue: 0), Color(red: 0.5, green: 1, blue: 0)],
            [Color(red: 0, green: 0.8, blue: 0), Color(red: 0, green: 0.8, blue: 0.4), Color(red: 0, green: 0.8, blue: 0.8), Color(red: 0, green: 0.5, blue: 1), Color(red: 0, green: 0.2, blue: 1), Color(red: 0.3, green: 0, blue: 1)],
            [Color(red: 0.6, green: 0, blue: 1), Color(red: 0.8, green: 0, blue: 0.8), Color(red: 1, green: 0, blue: 0.6), Color(red: 1, green: 0.2, blue: 0.4), Color(red: 0.6, green: 0.3, blue: 0.1), Color(red: 0.4, green: 0.2, blue: 0.1)],
        ]

        return VStack(spacing: 3) {
            ForEach(0..<colors.count, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<colors[row].count, id: \.self) { col in
                        let c = colors[row][col]
                        RoundedRectangle(cornerRadius: 3)
                            .fill(c)
                            .frame(height: 28)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(.white, lineWidth: colorsMatch(selectedColor, c) ? 2 : 0)
                            )
                            .onTapGesture { selectedColor = c }
                    }
                }
            }

            // System picker fallback
            ColorPicker("Custom color", selection: $selectedColor, supportsOpacity: true)
                .font(.caption2)
                .padding(.top, 4)
        }
    }

    // MARK: - RGB Sliders
    var rgbSliders: some View {
        VStack(spacing: 6) {
            colorSlider(label: "R", value: $red, color: .red)
            colorSlider(label: "G", value: $green, color: .green)
            colorSlider(label: "B", value: $blue, color: .blue)
            colorSlider(label: "A", value: $alpha, color: .gray)
        }
        .onChange(of: red) { _, _ in updateFromRGB() }
        .onChange(of: green) { _, _ in updateFromRGB() }
        .onChange(of: blue) { _, _ in updateFromRGB() }
        .onChange(of: alpha) { _, _ in updateFromRGB() }
    }

    // MARK: - HSB Sliders
    var hsbSliders: some View {
        VStack(spacing: 6) {
            hsbSlider(label: "H", value: $hue, range: 0...360,
                      gradient: (0...12).map { Color(hue: Double($0)/12, saturation: 1, brightness: 1) })
            hsbSlider(label: "S", value: $saturation, range: 0...1,
                      gradient: [Color(hue: hue/360, saturation: 0, brightness: brightness),
                                 Color(hue: hue/360, saturation: 1, brightness: brightness)])
            hsbSlider(label: "B", value: $brightness, range: 0...1,
                      gradient: [.black, Color(hue: hue/360, saturation: saturation, brightness: 1)])
        }
        .onChange(of: hue) { _, _ in updateFromHSB() }
        .onChange(of: saturation) { _, _ in updateFromHSB() }
        .onChange(of: brightness) { _, _ in updateFromHSB() }
    }

    // MARK: - Hex Input
    var hexInput_view: some View {
        VStack(spacing: 8) {
            HStack {
                Text("#").font(.system(size: 16, design: .monospaced)).foregroundStyle(.gray)
                TextField("FF0000", text: $hexInput)
                    .font(.system(size: 16, design: .monospaced))
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(ThemeManager.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .autocapitalization(.allCharacters)
                    .onSubmit { applyHex() }

                Button("Apply") { applyHex() }
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.red)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Recent hex colors
            HStack(spacing: 4) {
                ForEach(["#DC2626", "#FF2D55", "#FFFFFF", "#0A0A0F", "#00FF00", "#00BFFF"], id: \.self) { hex in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: String(hex.dropFirst())))
                        .frame(width: 28, height: 28)
                        .onTapGesture {
                            hexInput = hex
                            applyHex()
                        }
                }
            }
        }
    }

    // MARK: - Eyedropper
    var eyedropperView: some View {
        VStack(spacing: 12) {
            Image(systemName: "eyedropper.halffull")
                .font(.system(size: 36))
                .foregroundStyle(.red)

            Text("Tap anywhere on the canvas\nto pick a color")
                .font(.caption)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)

            Button {
                eyedropperActive.toggle()
            } label: {
                Label(
                    eyedropperActive ? "Cancel Eyedropper" : "Activate Eyedropper",
                    systemImage: eyedropperActive ? "xmark" : "eyedropper"
                )
                .font(.caption.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(eyedropperActive ? .gray : .red)
                .foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    func colorSlider(label: String, value: Binding<Double>, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11, weight: .bold, design: .monospaced)).frame(width: 14)
            Slider(value: value, in: 0...1).tint(color)
            Text("\(Int(value.wrappedValue * 255))").font(.system(size: 10, design: .monospaced)).frame(width: 28).foregroundStyle(.gray)
        }
    }

    func hsbSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>, gradient: [Color]) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11, weight: .bold, design: .monospaced)).frame(width: 14)
            ZStack {
                LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 8)
                    .clipShape(Capsule())
                Slider(value: value, in: range).tint(.clear)
            }
            Text("\(Int(value.wrappedValue * (range.upperBound > 1 ? 1 : 100)))").font(.system(size: 10, design: .monospaced)).frame(width: 28).foregroundStyle(.gray)
        }
    }

    func updateFromRGB() {
        selectedColor = Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    func updateFromHSB() {
        selectedColor = Color(hue: hue / 360, saturation: saturation, brightness: brightness)
    }

    func syncFromColor(_ color: Color) {
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        red = Double(r); green = Double(g); blue = Double(b); alpha = Double(a)

        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0
        uiColor.getHue(&h, saturation: &s, brightness: &br, alpha: nil)
        hue = Double(h) * 360; saturation = Double(s); brightness = Double(br)

        hexInput = colorToHex(color)
    }

    func applyHex() {
        let clean = hexInput.replacingOccurrences(of: "#", with: "")
        guard clean.count == 6 || clean.count == 8 else { return }
        selectedColor = Color(hex: clean)
    }

    func colorToHex(_ color: Color) -> String {
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    func colorsMatch(_ a: Color, _ b: Color) -> Bool {
        let ua = UIColor(a), ub = UIColor(b)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0
        ua.getRed(&r1, green: &g1, blue: &b1, alpha: nil)
        ub.getRed(&r2, green: &g2, blue: &b2, alpha: nil)
        return abs(r1-r2) < 0.02 && abs(g1-g2) < 0.02 && abs(b1-b2) < 0.02
    }
}

// MARK: - Brush Picker Sheet
struct BrushPickerSheet: View {
    @Binding var selectedBrush: BrushType
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                    ForEach(BrushType.allCases, id: \.self) { brush in
                        VStack(spacing: 6) {
                            Image(systemName: brush.icon)
                                .font(.system(size: 24))
                                .foregroundStyle(selectedBrush == brush ? .red : .white.opacity(0.7))

                            Text(brush.displayName)
                                .font(.caption2.bold())
                                .foregroundStyle(selectedBrush == brush ? .red : .white.opacity(0.7))

                            // Preview stroke
                            brushPreview(brush)
                                .frame(height: 20)
                        }
                        .padding(10)
                        .background(selectedBrush == brush ? Color.red.opacity(0.15) : ThemeManager.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture {
                            selectedBrush = brush
                            dismiss()
                        }
                    }
                }
                .padding()
            }
            .background(ThemeManager.background)
            .navigationTitle("Brush Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    func brushPreview(_ brush: BrushType) -> some View {
        Canvas { context, size in
            let y = size.height / 2
            var path = Path()
            path.move(to: CGPoint(x: 4, y: y))
            path.addCurve(
                to: CGPoint(x: size.width - 4, y: y),
                control1: CGPoint(x: size.width * 0.3, y: y - 8),
                control2: CGPoint(x: size.width * 0.7, y: y + 8)
            )
            context.stroke(
                path,
                with: .color(.red),
                style: StrokeStyle(
                    lineWidth: 3 * brush.widthMultiplier,
                    lineCap: brush.lineCap,
                    lineJoin: brush.lineJoin,
                    dash: brush == .dotted ? [3, 6] : []
                )
            )
        }
        .opacity(brush.baseOpacity)
    }
}
