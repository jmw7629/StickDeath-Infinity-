import SwiftUI

struct ToolSettingsPanel: View {
    @ObservedObject var vm: StudioViewModel

    private var toolLabel: String {
        vm.selectedTool.rawValue.capitalized
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            // Header
            HStack {
                Text(toolLabel)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { vm.activePanel = .none }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Size
            SettingsSliderView(
                label: "Size",
                value: $vm.strokeWidth,
                range: 1...50,
                unit: "px"
            )

            // Opacity
            SettingsSliderView(
                label: "Opacity",
                value: Binding(
                    get: { CGFloat(vm.strokeOpacity * 100) },
                    set: { vm.strokeOpacity = Double($0) / 100.0 }
                ),
                range: 1...100,
                unit: "%"
            )

            // Smoothing
            SettingsSliderView(
                label: "Smoothing",
                value: Binding(
                    get: { CGFloat(vm.smoothing) },
                    set: { vm.smoothing = Double($0) }
                ),
                range: 0...10,
                unit: ""
            )

            // Pressure Sensitivity
            HStack {
                Text("Pressure Sensitivity")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Toggle("", isOn: $vm.pressureSensitivity)
                    .toggleStyle(SwitchToggleStyle(tint: Color(hex: "DC2626")))
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .padding(.bottom, 16)
        }
        .background(Color(hex: "1a1a24"))
        .cornerRadius(16, corners: [.topLeft, .topRight])
    }
}

// MARK: - Settings Slider View
struct SettingsSliderView: View {
    let label: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Text("\(Int(value))\(unit)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }
            Slider(value: $value, in: range)
                .accentColor(Color(hex: "DC2626"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: - Corner Radius Extension
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCornerShape(radius: radius, corners: corners))
    }
}

struct RoundedCornerShape: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
