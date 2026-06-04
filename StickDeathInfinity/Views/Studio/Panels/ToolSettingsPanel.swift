import SwiftUI

// ═══════════════════════════════════════════════════════════════════
// Floating Tool Settings Panel — positioned over canvas
// Matches video exactly: tool icon + name, X close, per-tool settings,
// Shortcut key at bottom
// Colors: Red for Pencil/Pen/Brush, Green for Fill, Purple for Smudge,
//         Amber for Crayon, Cyan for Picker, Orange for Eraser,
//         Pink for Marker/Text, Gray for shapes/move/lasso
// ═══════════════════════════════════════════════════════════════════

struct FloatingToolSettingsPanel: View {
    @ObservedObject var vm: StudioViewModel
    
    var toolDef: ToolDef? {
        StudioToolStrip.tools.first { $0.tool == vm.selectedTool }
    }
    
    var accentColor: Color {
        guard let def = toolDef else { return .red }
        return Color(hex: def.topColor)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let def = toolDef {
                VStack(alignment: .leading, spacing: 10) {
                    // Header: icon + name + X close
                    HStack {
                        Image(systemName: def.icon)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.8))
                        Text(def.label)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Button(action: { vm.activePanel = .none }) {
                            Text("✕")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                    
                    Divider().background(Color.white.opacity(0.08))
                    
                    // Tool-specific content
                    toolSettingsContent(def)
                    
                    // Shortcut
                    HStack(spacing: 4) {
                        Text("Shortcut:")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                        Text(def.shortcut)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(4)
                    }
                    .padding(.top, 4)
                }
                .padding(12)
            }
        }
        .frame(width: 260)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: "1A1A24").opacity(0.98))
                .shadow(color: .black.opacity(0.5), radius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 8)
    }
    
    @ViewBuilder
    func toolSettingsContent(_ def: ToolDef) -> some View {
        switch def.tool {
        // ── BRUSH / PENCIL / PEN ──
        case .pencil, .pen, .brush:
            VStack(alignment: .leading, spacing: 8) {
                SettingsSlider(label: "Size", value: $vm.strokeWidth, range: 1...50, unit: "px", accent: accentColor)
                SettingsSlider(label: "Opacity", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
                SettingsSlider(label: "Smoothing", value: $vm.smoothing, range: 0...10, unit: "", accent: .green)
                SettingsToggle(label: "Pressure Sensitivity", isOn: $vm.pressureSensitivity, accent: .red)
            }
            
        // ── MARKER ──
        case .marker:
            VStack(alignment: .leading, spacing: 8) {
                SettingsSlider(label: "Size", value: $vm.strokeWidth, range: 1...50, unit: "px", accent: accentColor)
                SettingsSlider(label: "Opacity", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
                SettingsSlider(label: "Smoothing", value: $vm.smoothing, range: 0...10, unit: "", accent: .green)
                HStack {
                    Text("Tip Angle")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.4))
                    Spacer()
                    Text("45°")
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.5))
                }
            }
            
        // ── CRAYON ──
        case .crayon:
            // Video shows minimal panel — just name + shortcut
            VStack(alignment: .leading, spacing: 8) {
                SettingsSlider(label: "Size", value: $vm.strokeWidth, range: 1...50, unit: "px", accent: accentColor)
                SettingsSlider(label: "Opacity", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
                SettingsSlider(label: "Texture", value: .constant(5.0), range: 0...10, unit: "", accent: accentColor)
                SettingsSlider(label: "Grain", value: .constant(3.0), range: 0...10, unit: "", accent: accentColor)
            }
            
        // ── FILL TOOL (GREEN THEME) ──
        case .fill:
            VStack(alignment: .leading, spacing: 8) {
                SettingsSlider(label: "Tolerance", value: $vm.fillTolerance, range: 0...128, unit: "", accent: .green)
                SettingsSlider(label: "Opacity", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
                SettingsSlider(label: "Expand", value: $vm.fillExpand, range: -5...5, unit: "px", accent: .orange)
                SettingsSlider(label: "Gap Close", value: $vm.fillGapClose, range: 0...5, unit: "", accent: .yellow)
                
                // Toggle buttons (green themed)
                VStack(spacing: 4) {
                    FillToggleButton(label: vm.fillContiguous ? "🔗 Contiguous" : "🌐 All Similar",
                                     isOn: $vm.fillContiguous, accent: .green)
                    FillToggleButton(label: vm.fillAntiAlias ? "✓ Anti-Alias" : "✕ No Anti-Alias",
                                     isOn: $vm.fillAntiAlias, accent: .green)
                    FillToggleButton(label: vm.fillSampleAll ? "👁 Sample All Layers" : "📄 Current Layer Only",
                                     isOn: $vm.fillSampleAll, accent: .green)
                }
            }
            
        // ── ERASER (ORANGE THEME) ──
        case .eraser:
            VStack(alignment: .leading, spacing: 8) {
                SettingsSlider(label: "Size", value: $vm.strokeWidth, range: 1...50, unit: "px", accent: accentColor)
                
                Text("ERASER TYPE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)
                
                HStack(spacing: 4) {
                    ForEach(["◼ Hard", "◐ Soft"], id: \.self) { mode in
                        Button(action: {}) {
                            Text(mode)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(mode.contains("Hard") ? accentColor : .white.opacity(0.5))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(mode.contains("Hard") ? accentColor.opacity(0.2) : Color.white.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(mode.contains("Hard") ? accentColor.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                                )
                        }
                    }
                }
                
                SettingsSlider(label: "Opacity", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
            }
            
        // ── SMUDGE (PURPLE THEME) ──
        case .smudge:
            VStack(alignment: .leading, spacing: 8) {
                SettingsSlider(label: "Size", value: $vm.strokeWidth, range: 1...50, unit: "px", accent: accentColor)
                SettingsSlider(label: "Opacity", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
                SettingsSlider(label: "Strength", value: .constant(50.0), range: 0...100, unit: "%", accent: accentColor)
            }
            
        // ── TEXT (MAGENTA THEME) ──
        case .text:
            VStack(alignment: .leading, spacing: 8) {
                SettingsSlider(label: "Font Size", value: .constant(24.0), range: 8...120, unit: "px", accent: accentColor)
                
                Text("ALIGNMENT")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)
                
                HStack(spacing: 4) {
                    ForEach(["◁ Left", "☰ Center", "▷ Right"], id: \.self) { align in
                        Button(action: {}) {
                            Text(align)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(align.contains("Left") ? accentColor : .white.opacity(0.5))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(align.contains("Left") ? accentColor.opacity(0.2) : Color.white.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(align.contains("Left") ? accentColor.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                                )
                        }
                    }
                }
                
                Text("STYLE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)
                
                HStack(spacing: 4) {
                    Button(action: {}) {
                        Text("B Bold")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    }
                    Button(action: {}) {
                        Text("I Italic")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    }
                }
                
                SettingsSlider(label: "Opacity", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
            }
            
        // ── LINE ──
        case .line:
            VStack(alignment: .leading, spacing: 8) {
                SettingsSlider(label: "Stroke Width", value: $vm.strokeWidth, range: 1...20, unit: "px", accent: accentColor)
                SettingsSlider(label: "Opacity", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
                Text("Drag to draw line · Tap endpoint to connect")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.25))
            }
            
        // ── RECTANGLE / CIRCLE ──
        case .rectangle, .circle:
            VStack(alignment: .leading, spacing: 8) {
                SettingsSlider(label: "Stroke Width", value: $vm.strokeWidth, range: 1...20, unit: "px", accent: accentColor)
                SettingsSlider(label: "Opacity", value: opacityBinding, range: 0...100, unit: "%", accent: accentColor)
                
                Text("FILL")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)
                
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(vm.strokeColor)
                        .frame(width: 28, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2), lineWidth: 1))
                    Text("No fill")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                }
                
                if def.tool == .rectangle {
                    SettingsSlider(label: "Corner Radius", value: .constant(0.0), range: 0...50, unit: "px", accent: .orange)
                }
            }
            
        // ── MOVE ──
        case .move:
            VStack(alignment: .leading, spacing: 8) {
                Text("SELECTION MODE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)
                
                HStack(spacing: 4) {
                    ForEach(["⬜ New", "➕ Add", "➖ Sub"], id: \.self) { mode in
                        Button(action: {}) {
                            Text(mode)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(mode.contains("New") ? .red : .white.opacity(0.5))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(mode.contains("New") ? Color.red.opacity(0.2) : Color.white.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(mode.contains("New") ? Color.red.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                                )
                        }
                    }
                }
                
                Text("ACTIONS")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)
                
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(["📋 Copy", "🗑 Delete", "↔️ Flip H", "↕️ Flip V", "⬆ Fwd", "⬇ Back", "🔒 Lock", "✂️ Clear"], id: \.self) { action in
                        Button(action: {}) {
                            VStack(spacing: 2) {
                                Text(String(action.prefix(2)))
                                    .font(.system(size: 12))
                                Text(String(action.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                                    .font(.system(size: 7, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(8)
                        }
                    }
                }
            }
            
        // ── LASSO ──
        case .lasso:
            VStack(alignment: .leading, spacing: 8) {
                Text("LASSO MODE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)
                
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                    ForEach(["✏️ Freehand", "⬡ Polygon", "🧲 Magnetic", "✨ Smart"], id: \.self) { mode in
                        Button(action: {}) {
                            Text(mode)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(mode.contains("Free") ? .cyan : .white.opacity(0.5))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(mode.contains("Free") ? Color.cyan.opacity(0.2) : Color.white.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(mode.contains("Free") ? Color.cyan.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                                )
                        }
                    }
                }
                
                SettingsSlider(label: "Feather", value: .constant(0.0), range: 0...20, unit: "px", accent: .cyan)
                SettingsSlider(label: "Smoothness", value: .constant(3.0), range: 0...10, unit: "", accent: .cyan)
            }
            
        default:
            EmptyView()
        }
    }
    
    var opacityBinding: Binding<Double> {
        Binding(
            get: { vm.toolOpacity * 100 },
            set: { vm.toolOpacity = $0 / 100 }
        )
    }
}

// MARK: - Settings Slider (matches video: label + value, slider underneath)
struct SettingsSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    let accent: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(label): \(Int(value))\(unit)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
            
            Slider(value: $value, in: range)
                .tint(accent)
                .frame(height: 6)
        }
    }
}

// MARK: - Settings Toggle (matches video: label + red toggle)
struct SettingsToggle: View {
    let label: String
    @Binding var isOn: Bool
    let accent: Color
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(accent)
        }
    }
}

// MARK: - Fill Toggle Button (green themed)
struct FillToggleButton: View {
    let label: String
    @Binding var isOn: Bool
    let accent: Color
    
    var body: some View {
        Button(action: { isOn.toggle() }) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(isOn ? accent : .white.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isOn ? accent.opacity(0.15) : Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isOn ? accent.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                )
        }
    }
}

// ToolSettingsPanel wrapper kept for backward compat
struct ToolSettingsPanel: View {
    @ObservedObject var vm: StudioViewModel
    var body: some View { FloatingToolSettingsPanel(vm: vm) }
}
