import SwiftUI

struct ColorPickerPanel: View {
    @ObservedObject var vm: StudioViewModel
    enum Target: Equatable { case drawing, gradientEnd }
    var target: Target = .drawing
    @State private var selectedPaletteIndex: Int = 0
    @State private var customHex = ""
    @FocusState private var customHexFocused: Bool
    private var selectedColor: Color { target == .drawing ? vm.strokeColor : vm.brushGradientEndColor }
    private var selectedHex: String { target == .drawing ? vm.strokeColorHex : vm.brushGradientEndColorHex }
    private func setColor(_ color: Color) {
        if target == .drawing { vm.strokeColor = color }
        else { vm.brushGradientEndColor = color; vm.rememberRecentColor(vm.brushGradientEndColorHex) }
    }
    private var validCustomHex: String? { StudioViewModel.normalizedColorHex(customHex) }

    static let palettes: [(name: String, colors: [String])] = [
        ("Basic", ["#5AC8FA","#7EC8D9","#C4C9A8","#F39C12","#E67E22","#FFFFFF","#000000"]),
        ("Sketch", ["#F5DEB3","#D2C6A5","#E8E4A0","#2D2D2D","#D5F0E8","#8B8B8B","#555555"]),
        ("Retro Animation", ["#EF4444","#E8F5A3","#4A9C6D","#6B7B8D","#2D3B4E","#FF6B6B","#FFD93D"]),
        ("Neon", ["#FF1493","#FF8C00","#ADFF2F","#1E90FF","#9400D3","#00FF7F","#FF4500"]),
        ("Pop", ["#7FFF00","#FF7F00","#FF00FF","#7B2D8E","#00BFFF","#9B59B6","#F1C40F"]),
        ("Sketches", ["#B0A890","#A0A0A0","#D0D0D0","#3D3D2D","#4D5D4D","#8B7355","#6B6B6B"]),
        ("Old Japan", ["#6B3A5A","#5A6A5A","#C0453A","#D4885A","#C9A06A","#8B6F47","#2D2D2D"]),
        ("Fun Sketch", ["#5AC8FA","#555555","#F39C12","#E67E22","#EF4444","#3498DB","#2ECC71"]),
    ]

    static let presetColors: [String] = [
        "#FF0000","#FF5500","#FFAA00","#FFFF00","#AAFF00",
        "#00FF00","#00FFAA","#00FFFF","#00AAFF","#0055FF",
        "#0000FF","#5500FF","#AA00FF","#FF00FF","#FF00AA",
        "#FFFFFF","#CCCCCC","#999999","#666666","#333333","#000000",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            PanelHeader(title: target == .drawing ? "Color" : "Gradient end color", icon: "🎨", onClose: { customHexFocused = false; vm.activePanel = target == .drawing ? .none : .toolSettings })

            ScrollView {
            VStack(spacing: 0) {
            // Current color preview
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(selectedColor)
                    .frame(width: 48, height: 48)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )

                Text(selectedHex.uppercased())
                    .font(.specialElite(13))
                    .foregroundColor(.white.opacity(0.7))
                    .accessibilityIdentifier("studio.color.current")

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Group {
                HStack(spacing: 10) {
                    Text("Custom hex").font(.specialElite(11))
                    TextField("RRGGBB", text: $customHex)
                        .font(.specialElite(13))
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .keyboardType(.asciiCapable).focused($customHexFocused)
                        .accessibilityLabel(target == .drawing ? "Custom drawing color hex" : "Custom gradient end color hex")
                        .accessibilityIdentifier("studio.color.hex")
                    Button("Apply") {
                        guard let hex = validCustomHex else { return }
                        guard vm.applyCustomColorHex(hex, gradientEnd: target == .gradientEnd) else { return }
                        customHex = ""; customHexFocused = false
                    }
                    .disabled(validCustomHex == nil)
                    .accessibilityIdentifier("studio.color.hex.apply")
                }
                .foregroundColor(.white).padding(10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16).padding(.bottom, 12)
            }

            // Preset colors grid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(Self.presetColors, id: \.self) { hex in
                    Button(action: {
                        setColor(Color(hex: hex))
                    }) {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle()
                                    .stroke(selectedHex == hex ? Color.white : Color.white.opacity(0.1), lineWidth: selectedHex == hex ? 2 : 1)
                            )
                    }
                    .accessibilityLabel("Color " + hex)
                    .accessibilityIdentifier("studio.color.preset." + hex)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            // Palette selector
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(Self.palettes.enumerated()), id: \.offset) { index, palette in
                        Button(action: { selectedPaletteIndex = index }) {
                            Text(palette.name)
                                .font(.specialElite(9))
                                .foregroundColor(selectedPaletteIndex == index ? Color(hex: "DC2626") : .white.opacity(0.4))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(selectedPaletteIndex == index ? Color(hex: "DC2626").opacity(0.15) : Color.white.opacity(0.04))
                                )
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 8)

            // Palette colors
            HStack(spacing: 8) {
                ForEach(Self.palettes[selectedPaletteIndex].colors, id: \.self) { hex in
                    Button(action: {
                        setColor(Color(hex: hex))
                    }) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(hex: hex))
                            .frame(height: 32)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            if !vm.recentColorHexes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECENT COLORS").font(.specialElite(10)).foregroundColor(.white.opacity(0.7))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(vm.recentColorHexes, id: \.self) { hex in
                                Button { _ = vm.applyCustomColorHex(hex, gradientEnd: target == .gradientEnd) } label: {
                                    Circle().fill(Color(hex: hex)).frame(width: 30, height: 30)
                                        .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 1))
                                        .frame(width: 44, height: 44)
                                }
                                .accessibilityLabel("Recent color " + hex)
                                .accessibilityIdentifier("studio.color.recent." + hex)
                            }
                        }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }
            }
            }.accessibilityIdentifier("studio.color.scroll")
        }
        .background(Color(hex: "1a1a24"))
        .cornerRadius(16, corners: [.topLeft, .topRight])
    }
}
