import SwiftUI

// Tool settings for each drawing tool — opens as floating panel
struct ToolSettingsPanel: View {
    @ObservedObject var vm: StudioViewModel
    
    var body: some View {
        VStack(spacing: 12) {
            // Size
            ToolSlider(label: "Size", value: $vm.strokeWidth, range: 1...80, displayUnit: "px", accentColor: toolAccent)
            
            // Opacity
            ToolSlider(label: "Opacity", value: opacityPercent, range: 0...100, displayUnit: "%", accentColor: toolAccent)
            
            // Tool-specific settings
            switch vm.selectedTool {
            case .pencil:
                ToolSlider(label: "Smoothing", value: $vm.smoothing, range: 0...10, displayUnit: "", accentColor: toolAccent)
                Toggle("Pressure Sensitivity", isOn: $vm.pressureSensitivity)
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.5)).tint(toolAccent)
                
            case .pen:
                ToolSlider(label: "Smoothing", value: $vm.smoothing, range: 0...10, displayUnit: "", accentColor: toolAccent)
                Toggle("Pressure Sensitivity", isOn: $vm.pressureSensitivity)
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.5)).tint(toolAccent)
                
            case .brush:
                ToolSlider(label: "Smoothing", value: $vm.smoothing, range: 0...10, displayUnit: "", accentColor: toolAccent)
                Toggle("Pressure Sensitivity", isOn: $vm.pressureSensitivity)
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.5)).tint(toolAccent)
                HStack {
                    Text("Tip Shape")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(["circle.fill", "capsule.fill", "rectangle.fill"], id: \.self) { shape in
                            Image(systemName: shape)
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(6)
                                .background(Color(hex: "1E1E2A"))
                                .cornerRadius(6)
                        }
                    }
                }
                
            case .marker:
                ToolSlider(label: "Smoothing", value: $vm.smoothing, range: 0...10, displayUnit: "", accentColor: toolAccent)
                HStack {
                    Text("Tip Angle")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                    Spacer()
                    Text("45°")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.4))
                }
                
            case .crayon:
                ToolSlider(label: "Texture", value: .constant(5), range: 0...10, displayUnit: "", accentColor: toolAccent)
                ToolSlider(label: "Grain", value: .constant(3), range: 0...10, displayUnit: "", accentColor: toolAccent)
                
            case .eraser:
                HStack {
                    Text("Mode")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                    Spacer()
                    Picker("", selection: .constant("soft")) {
                        Text("Soft").tag("soft")
                        Text("Hard").tag("hard")
                        Text("Pixel").tag("pixel")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                
            case .smudge:
                ToolSlider(label: "Strength", value: .constant(50), range: 0...100, displayUnit: "%", accentColor: toolAccent)
                
            case .text:
                HStack {
                    Text("Font")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                    Spacer()
                    Text("Monospaced")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.4))
                }
                Toggle("Bold", isOn: .constant(false))
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                Toggle("Italic", isOn: .constant(false))
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                
            case .fill:
                ToolSlider(label: "Tolerance", value: .constant(32), range: 0...255, displayUnit: "", accentColor: toolAccent)
                Toggle("Contiguous", isOn: .constant(true))
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.5)).tint(toolAccent)
                
            default:
                EmptyView()
            }
        }
    }
    
    var opacityPercent: Binding<CGFloat> {
        Binding(
            get: { CGFloat(vm.strokeOpacity * 100) },
            set: { vm.strokeOpacity = Double($0 / 100) }
        )
    }
    
    var toolAccent: Color {
        switch vm.selectedTool {
        case .crayon: return Color(hex: "F59E0B")
        case .smudge: return Color(hex: "A78BFA")
        default: return Color(hex: "DC2626")
        }
    }
}

struct ToolSlider: View {
    let label: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let displayUnit: String
    let accentColor: Color
    
    init(label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, displayUnit: String, accentColor: Color) {
        self.label = label
        self._value = value
        self.range = range
        self.displayUnit = displayUnit
        self.accentColor = accentColor
    }
    
    init(label: String, value: Binding<Double>, range: ClosedRange<CGFloat>, displayUnit: String, accentColor: Color) {
        self.label = label
        self._value = Binding(get: { CGFloat(value.wrappedValue) }, set: { value.wrappedValue = Double($0) })
        self.range = range
        self.displayUnit = displayUnit
        self.accentColor = accentColor
    }
    
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Text("\(Int(value))\(displayUnit)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }
            Slider(value: $value, in: range)
                .tint(accentColor)
        }
    }
}
