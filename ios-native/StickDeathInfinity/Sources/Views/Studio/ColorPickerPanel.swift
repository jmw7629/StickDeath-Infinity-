// ColorPickerPanel.swift
// 5-tab color picker: WHEEL, CLASSIC, HARMONY, VALUE, SWATCH
// Matches StickDeath Infinity reference design exactly
// Dark red active tab, red opacity slider, all modes functional

import SwiftUI

enum StudioColorTab: String, CaseIterable {
    case wheel = "WHEEL"
    case classic = "CLASSIC"
    case harmony = "HARMONY"
    case value = "VALUE"
    case swatch = "SWATCH"
}

struct StudioColorPicker: View {
    @ObservedObject var vm: EditorViewModel
    @State private var tab: StudioColorTab = .wheel
    @State private var hue: Double = 0
    @State private var saturation: Double = 0
    @State private var lightness: Double = 100
    @State private var red: Double = 255
    @State private var green: Double = 255
    @State private var blue: Double = 255
    @State private var opacity: Double = 100
    @State private var hexText: String = "#ffffff"

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 0) {
                // Tab bar
                HStack(spacing: 4) {
                    ForEach(StudioColorTab.allCases, id: \.self) { t in
                        Button {
                            tab = t
                        } label: {
                            Text(t.rawValue)
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(tab == t ? .white : .white.opacity(0.4))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(tab == t ? Color(hex: "8B2020") : .clear)
                                )
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

                // Content
                ScrollView {
                    VStack(spacing: 0) {
                        switch tab {
                        case .wheel:
                            wheelView
                        case .classic:
                            classicView
                        case .harmony:
                            harmonyView
                        case .value:
                            valueView
                        case .swatch:
                            swatchView
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
                .frame(maxHeight: UIScreen.main.bounds.height * 0.4)
            }
            .background(Color(hex: "1a1a1a"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08), lineWidth: 1)
            }
        }
        .padding(.bottom, 112) // Above frame strip + action bar
    }

    // MARK: - Wheel
    var wheelView: some View {
        VStack(spacing: 12) {
            // Color wheel
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red]),
                            center: .center
                        )
                    )
                    .frame(width: 200, height: 200)
                    .overlay(
                        Circle()
                            .fill(Color(hex: "1a1a1a"))
                            .frame(width: 120, height: 120)
                    )

                // Inner square picker
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(colors: [.white, Color(hue: hue / 360, saturation: 1, brightness: 1)], startPoint: .leading, endPoint: .trailing)
                    )
                    .overlay(
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 80, height: 80)
            }

            // Color swatches + hex
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(vm.drawState.strokeColor)
                    .frame(width: 36, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.2), lineWidth: 1))

                RoundedRectangle(cornerRadius: 8)
                    .fill(.black)
                    .frame(width: 36, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.2), lineWidth: 1))

                TextField("#ffffff", text: $hexText)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)).stroke(.white.opacity(0.1), lineWidth: 1))
            }

            opacitySlider
        }
    }

    // MARK: - Classic (HSL sliders)
    var classicView: some View {
        VStack(spacing: 4) {
            hueSlider
            satSlider
            lightnessSlider

            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hue: hue / 360, saturation: saturation / 100, brightness: lightness / 100))
                    .frame(width: 36, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.2)))

                RoundedRectangle(cornerRadius: 8)
                    .fill(.black)
                    .frame(width: 36, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.2)))

                TextField("#ffffff", text: $hexText)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)).stroke(.white.opacity(0.1)))
            }
            .padding(.top, 8)

            opacitySlider
        }
    }

    var hueSlider: some View {
        VStack(spacing: 2) {
            HStack {
                Text("Hue").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("\(Int(hue))°").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 10)
                    Circle()
                        .fill(.white)
                        .frame(width: 20, height: 20)
                        .shadow(radius: 3)
                        .offset(x: geo.size.width * (hue / 360) - 10)
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    hue = max(0, min(360, g.location.x / geo.size.width * 360))
                })
            }
            .frame(height: 20)
        }
        .padding(.bottom, 8)
    }

    var satSlider: some View {
        VStack(spacing: 2) {
            HStack {
                Text("Saturation").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("\(Int(saturation))%").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [
                            Color(hue: hue / 360, saturation: 0, brightness: lightness / 100),
                            Color(hue: hue / 360, saturation: 1, brightness: lightness / 100)
                        ], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 10)
                    Circle()
                        .fill(.white)
                        .frame(width: 20, height: 20)
                        .shadow(radius: 3)
                        .offset(x: geo.size.width * (saturation / 100) - 10)
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    saturation = max(0, min(100, g.location.x / geo.size.width * 100))
                })
            }
            .frame(height: 20)
        }
        .padding(.bottom, 8)
    }

    var lightnessSlider: some View {
        VStack(spacing: 2) {
            HStack {
                Text("Lightness").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("\(Int(lightness))%").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            RedSlider(label: "", value: Binding(get: { CGFloat(lightness) }, set: { lightness = Double($0) }), range: 0...100, unit: "%")
        }
    }

    // MARK: - Harmony
    var harmonyView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(vm.drawState.strokeColor)
                    .frame(width: 48, height: 48)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.2)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text(hexText).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                }
            }

            harmonyRow("COMPLEMENTARY", colors: [Color(hue: (hue + 180).truncatingRemainder(dividingBy: 360) / 360, saturation: 0.5, brightness: 0.7)])
            harmonyRow("ANALOGOUS", colors: [
                Color(hue: (hue + 30).truncatingRemainder(dividingBy: 360) / 360, saturation: 0.5, brightness: 0.7),
                Color(hue: max(0, hue - 30) / 360, saturation: 0.5, brightness: 0.7)
            ])
            harmonyRow("TRIADIC", colors: [
                Color(hue: (hue + 120).truncatingRemainder(dividingBy: 360) / 360, saturation: 0.5, brightness: 0.7),
                Color(hue: (hue + 240).truncatingRemainder(dividingBy: 360) / 360, saturation: 0.5, brightness: 0.7)
            ])
            harmonyRow("SPLIT COMPLEMENT", colors: [
                Color(hue: (hue + 150).truncatingRemainder(dividingBy: 360) / 360, saturation: 0.5, brightness: 0.7),
                Color(hue: (hue + 210).truncatingRemainder(dividingBy: 360) / 360, saturation: 0.5, brightness: 0.7)
            ])

            opacitySlider
        }
    }

    func harmonyRow(_ label: String, colors: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.3))
            HStack(spacing: 8) {
                ForEach(colors.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 10)
                        .fill(colors[i])
                        .frame(height: 40)
                }
            }
        }
    }

    // MARK: - Value (Hex + RGB + HSL)
    var valueView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(vm.drawState.strokeColor)
                    .frame(width: 48, height: 48)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.2)))
                TextField("#ffffff", text: $hexText)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)).stroke(.white.opacity(0.1)))
            }

            // RGB
            HStack(spacing: 12) {
                colorInput("R", color: .red, value: $red)
                colorInput("G", color: .green, value: $green)
                colorInput("B", color: .blue, value: $blue)
            }

            // HSL
            HStack(spacing: 12) {
                colorInput("H", color: .white.opacity(0.4), value: Binding(get: { hue }, set: { hue = $0 }))
                colorInput("S", color: .white.opacity(0.4), value: Binding(get: { saturation }, set: { saturation = $0 }))
                colorInput("L", color: .white.opacity(0.4), value: Binding(get: { lightness }, set: { lightness = $0 }))
            }

            opacitySlider
        }
    }

    func colorInput(_ label: String, color: Color, value: Binding<Double>) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
            TextField("0", value: value, format: .number)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)).stroke(.white.opacity(0.1)))
                .keyboardType(.numberPad)
        }
    }

    // MARK: - Swatch
    var swatchView: some View {
        let basics: [String] = ["000000","333333","666666","999999","cccccc","ff4444","ff0000","ff6600","ffcc00","00cc44","00ccaa","0088ff","6644ff","aa00ff","ff00aa"]
        let skin: [String] = ["ffe0bd","e8b88a","c68c53","8d5524","6b3a1f","c49a6c","f5d0a9"]
        let stick: [String] = ["cc3333","e04040","aa2222","881111","555555","446688","5588aa","eeeedd","999988","777766","556644"]

        return VStack(alignment: .leading, spacing: 12) {
            // Rainbow row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(["000","ff0000","ff4400","ff8800","ffcc00","ffff00","88ff00","00ff00","00ff88","00ffff","0088ff","0044ff","4400ff","8800ff","ff00ff"], id: \.self) { c in
                        swatchButton(hex: c)
                    }
                }
            }

            paletteSection("BASICS", colors: basics)
            paletteSection("SKIN", colors: skin)
            paletteSection("STICKDEATH", colors: stick)

            opacitySlider
        }
    }

    func paletteSection(_ title: String, colors: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.3))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(colors, id: \.self) { c in
                    swatchButton(hex: c)
                }
            }
        }
    }

    func swatchButton(hex: String) -> some View {
        Button {
            vm.drawState.strokeColor = Color(hex: hex)
            hexText = "#\(hex)"
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: hex))
                .aspectRatio(1, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.1)))
        }
    }

    // MARK: - Opacity Slider
    var opacitySlider: some View {
        VStack(spacing: 4) {
            HStack {
                Text("OPACITY")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Text("\(Int(opacity))%")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            RedSlider(label: "", value: Binding(get: { CGFloat(opacity) }, set: { opacity = Double($0) }), range: 0...100, unit: "%")
        }
        .padding(.top, 4)
    }
}
