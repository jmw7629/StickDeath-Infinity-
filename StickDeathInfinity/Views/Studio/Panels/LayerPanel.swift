import SwiftUI

// ═══════════════════════════════════════════════════════════════════
// Layer Panel — Bottom sheet with drag handle
// Matches video frame-by-frame:
// ┌─────────────────────────────────────────────────┐
// │                  ─── drag handle ───             │
// │ ⋮⋮ 🚫 [thumb] Layer 1 (red)  🔒 100% ▼        │
// │ Opacity ████████████████████████████ 100%        │
// │ LOCK MODE                                        │
// │ [🔓 Free] [🔒 Full] [📌 Pos] [🎨 Alpha]        │
// │ BLEND MODE                                       │
// │ [ Normal                              ▼ ]        │
// │ GLOW  ○                                          │
// │ Color: ● ● ● ● ● ● ● ●                         │
// │ [📝 Editable] [📋 Duplicate] [⬆] [⬇]           │
// │                   + (red)                        │
// └─────────────────────────────────────────────────┘
// ═══════════════════════════════════════════════════════════════════

struct LayerPanel: View {
    @ObservedObject var vm: StudioViewModel
    @State private var expandedLayer: UUID? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // Tap to dismiss area
            Color.black.opacity(0.3)
                .onTapGesture { vm.activePanel = .none }
            
            // Panel
            VStack(spacing: 0) {
                // Drag handle
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 40, height: 4)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(vm.studioLayers) { layer in
                            LayerRow(vm: vm, layer: layer, isExpanded: expandedLayer == layer.id)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        expandedLayer = expandedLayer == layer.id ? nil : layer.id
                                    }
                                }
                            
                            if expandedLayer == layer.id {
                                LayerDetailView(vm: vm, layer: layer)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            
                            Divider().background(Color.white.opacity(0.06))
                        }
                        
                        // Add layer button
                        Button(action: { vm.addLayer() }) {
                            Text("+")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }
                }
                .frame(maxHeight: 400)
            }
            .background(Color(hex: "1A1A24").opacity(0.98))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )
            .clipShape(RoundedCorner(radius: 16, corners: [.topLeft, .topRight]))
        }
        .ignoresSafeArea()
    }
}

// MARK: - Layer Row (collapsed)
struct LayerRow: View {
    @ObservedObject var vm: StudioViewModel
    let layer: StudioLayer
    let isExpanded: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            // Drag dots (2×3 grid)
            VStack(spacing: 2) {
                ForEach(0..<3) { _ in
                    HStack(spacing: 2) {
                        Circle().fill(Color.white.opacity(0.2)).frame(width: 2.5, height: 2.5)
                        Circle().fill(Color.white.opacity(0.2)).frame(width: 2.5, height: 2.5)
                    }
                }
            }
            .frame(width: 12)
            
            // Visibility toggle (🚫 when hidden)
            Button(action: { vm.toggleLayerVisibility(layer.id) }) {
                Image(systemName: layer.visible ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 14))
                    .foregroundColor(layer.visible ? .white.opacity(0.5) : .red.opacity(0.6))
            }
            .frame(width: 24)
            
            // Thumbnail
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.08))
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
            
            // Layer name (red text)
            Text(layer.name)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: "DC2626"))
            
            Spacer()
            
            // Lock icon
            Image(systemName: lockIcon(for: layer.lockMode))
                .font(.system(size: 12))
                .foregroundColor(layer.lockMode == .full ? Color.yellow : .white.opacity(0.4))
            
            // Opacity percentage
            Text("\(Int(layer.opacity * 100))%")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
            
            // Chevron
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
    
    func lockIcon(for mode: LayerLockMode) -> String {
        switch mode {
        case .free: return "lock.open"
        case .full: return "lock.fill"
        case .position: return "pin.fill"
        case .alpha: return "paintpalette.fill"
        }
    }
}

// MARK: - Layer Detail View (expanded)
struct LayerDetailView: View {
    @ObservedObject var vm: StudioViewModel
    let layer: StudioLayer
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Opacity slider (RED bar)
            HStack {
                Text("Opacity")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.red)
                            .frame(width: geo.size.width * CGFloat(layer.opacity), height: 6)
                    }
                }
                .frame(height: 6)
                
                Text("\(Int(layer.opacity * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
            
            // LOCK MODE
            VStack(alignment: .leading, spacing: 6) {
                Text("LOCK MODE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)
                
                HStack(spacing: 6) {
                    LockModeButton(emoji: "🔓", label: "Free", isSelected: layer.lockMode == .free, selectedColor: .clear) {
                        vm.setLayerLockMode(layer.id, mode: .free)
                    }
                    LockModeButton(emoji: "🔒", label: "Full", isSelected: layer.lockMode == .full, selectedColor: .yellow) {
                        vm.setLayerLockMode(layer.id, mode: .full)
                    }
                    LockModeButton(emoji: "📌", label: "Pos", isSelected: layer.lockMode == .position, selectedColor: .red) {
                        vm.setLayerLockMode(layer.id, mode: .position)
                    }
                    LockModeButton(emoji: "🎨", label: "Alpha", isSelected: layer.lockMode == .alpha, selectedColor: .orange) {
                        vm.setLayerLockMode(layer.id, mode: .alpha)
                    }
                }
            }
            
            // BLEND MODE
            VStack(alignment: .leading, spacing: 6) {
                Text("BLEND MODE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)
                
                HStack {
                    Text(layer.blendMode)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )
            }
            
            // GLOW toggle
            HStack {
                Text("GLOW")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)
                
                Toggle("", isOn: .constant(false))
                    .labelsHidden()
                    .scaleEffect(0.8)
                
                Spacer()
            }
            
            // Color dots
            HStack(spacing: 6) {
                Text("Color:")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                
                ForEach([
                    Color.red, Color.orange, Color.yellow, Color.green,
                    Color(hex: "38BDF8"), Color.purple, Color.pink, Color.gray
                ], id: \.self) { color in
                    Circle()
                        .fill(color)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .stroke(layer.labelColor == color ? Color.white : Color.white.opacity(0.1), lineWidth: layer.labelColor == color ? 2 : 0.5)
                        )
                        .onTapGesture {
                            vm.setLayerColor(layer.id, color: color)
                        }
                }
            }
            
            // Action buttons
            HStack(spacing: 6) {
                LayerActionButton(emoji: "📝", label: "Editable") {}
                LayerActionButton(emoji: "📋", label: "Duplicate") {
                    vm.duplicateLayer(layer.id)
                }
                
                // Move up
                Button(action: { vm.moveLayerUp(layer.id) }) {
                    Image(systemName: "arrow.up.square.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 44, height: 36)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                }
                
                // Move down
                Button(action: { vm.moveLayerDown(layer.id) }) {
                    Image(systemName: "arrow.down.square.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 44, height: 36)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(hex: "14141E"))
    }
}

// MARK: - Lock Mode Button
struct LockModeButton: View {
    let emoji: String
    let label: String
    let isSelected: Bool
    let selectedColor: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(emoji)
                    .font(.system(size: 16))
                Text(label)
                    .font(.system(size: 9, weight: isSelected ? .bold : .regular, design: .monospaced))
                    .foregroundColor(isSelected ? selectedColor == .clear ? .white : selectedColor : .white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? (selectedColor == .clear ? Color.white.opacity(0.1) : selectedColor.opacity(0.15)) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? (selectedColor == .clear ? Color.white.opacity(0.2) : selectedColor.opacity(0.4)) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

// MARK: - Layer Action Button
struct LayerActionButton: View {
    let emoji: String
    let label: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(emoji).font(.system(size: 12))
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        }
    }
}

// Rounded corner helper
