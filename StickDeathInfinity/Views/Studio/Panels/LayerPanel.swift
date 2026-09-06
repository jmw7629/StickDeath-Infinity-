import SwiftUI
import SDCore

// ═══════════════════════════════════════════════════════════════════
// Layer Panel — Canonical CanvasLayer drives all visible controls
// ═══════════════════════════════════════════════════════════════════

struct LayerPanel: View {
    @ObservedObject var vm: StudioViewModel
    @State private var expandedLayer: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            Color.black.opacity(0.3)
                .onTapGesture { vm.activePanel = .none }

            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 40, height: 4)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(vm.layers) { layer in
                            LayerRow(vm: vm, layer: layer, isExpanded: expandedLayer == layer.id, isSelected: vm.activeLayerID == layer.id)
                                .onTapGesture {
                                    vm.selectLayer(layer.id)
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
    let layer: CanvasLayer
    let isExpanded: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Drag dots
            VStack(spacing: 2) {
                ForEach(0..<3) { _ in
                    HStack(spacing: 2) {
                        Circle().fill(Color.white.opacity(0.2)).frame(width: 2.5, height: 2.5)
                        Circle().fill(Color.white.opacity(0.2)).frame(width: 2.5, height: 2.5)
                    }
                }
            }
            .frame(width: 12)

            // Visibility toggle
            Button(action: { vm.toggleLayerVisibility(layer.id) }) {
                Image(systemName: layer.visible ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 14))
                    .foregroundColor(layer.visible ? .white.opacity(0.5) : .red.opacity(0.6))
            }
            .frame(width: 24)

            // Thumbnail
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.red.opacity(0.2) : Color.white.opacity(0.08))
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.red.opacity(0.5) : Color.white.opacity(0.15), lineWidth: isSelected ? 1.5 : 0.5)
                )

            // Layer name
            Text(layer.name)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(isSelected ? Color(hex: "DC2626") : .white.opacity(0.7))

            Spacer()

            // Lock icon
            Image(systemName: lockIcon(for: layer.lockMode))
                .font(.system(size: 12))
                .foregroundColor(layer.lockMode == "full" ? Color.yellow : .white.opacity(0.4))

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

    func lockIcon(for mode: String) -> String {
        switch mode {
        case "full": return "lock.fill"
        case "position": return "pin.fill"
        case "alpha": return "paintpalette.fill"
        default: return "lock.open"
        }
    }
}

// MARK: - Layer Detail View (expanded)
struct LayerDetailView: View {
    @ObservedObject var vm: StudioViewModel
    let layer: CanvasLayer

    @State private var opacityDraft: Double = 1.0
    @State private var blendModeDraft: String = "Normal"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Opacity slider (functional)
            HStack {
                Text("Opacity")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))

                Slider(value: $opacityDraft, in: 0...1, step: 0.01)
                    .tint(.red)
                    .onChange(of: opacityDraft) { newVal in
                        vm.setLayerOpacity(layer.id, opacity: newVal)
                    }

                Text("\(Int(opacityDraft * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 40, alignment: .trailing)
            }

            // LOCK MODE
            VStack(alignment: .leading, spacing: 6) {
                Text("LOCK MODE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)

                HStack(spacing: 6) {
                    LockModeButton(emoji: "🔓", label: "Free", isSelected: layer.lockMode == "free", selectedColor: .clear) {
                        vm.setLayerLockMode(layer.id, mode: "free")
                    }
                    LockModeButton(emoji: "🔒", label: "Full", isSelected: layer.lockMode == "full", selectedColor: .yellow) {
                        vm.setLayerLockMode(layer.id, mode: "full")
                    }
                    LockModeButton(emoji: "📌", label: "Pos", isSelected: layer.lockMode == "position", selectedColor: .red) {
                        vm.setLayerLockMode(layer.id, mode: "position")
                    }
                    LockModeButton(emoji: "🎨", label: "Alpha", isSelected: layer.lockMode == "alpha", selectedColor: .orange) {
                        vm.setLayerLockMode(layer.id, mode: "alpha")
                    }
                }
            }

            // BLEND MODE (functional dropdown)
            VStack(alignment: .leading, spacing: 6) {
                Text("BLEND MODE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)

                Picker("Blend Mode", selection: $blendModeDraft) {
                    ForEach(["Normal", "Multiply", "Screen", "Overlay", "Darken", "Lighten", "Color Dodge", "Color Burn"], id: \.self) { mode in
                        Text(mode).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: blendModeDraft) { newVal in
                    vm.setLayerBlendMode(layer.id, blendMode: newVal)
                }
            }

            // GLOW toggle (functional)
            HStack {
                Text("GLOW")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)

                Toggle("", isOn: Binding(
                    get: { layer.glowEnabled },
                    set: { vm.setLayerGlow(layer.id, enabled: $0) }
                ))
                .labelsHidden()
                .scaleEffect(0.8)

                if layer.glowEnabled {
                    ColorPicker("", selection: Binding(
                        get: { Color(hex: layer.glowColor ?? "#FFFFFF") },
                        set: { newColor in
                            let hex = UIColor(newColor).hexString
                            vm.setLayerGlow(layer.id, enabled: true, color: hex)
                        }
                    ))
                    .labelsHidden()
                    .frame(width: 28, height: 28)
                }

                Spacer()
            }

            // Color dots (functional)
            HStack(spacing: 6) {
                Text("Color:")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))

                ForEach(["#FF0000", "#FF8C00", "#FFD600", "#00C853", "#38BDF8", "#A855F7", "#EC4899", "#9CA3AF"], id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .stroke(layer.colorLabel == hex ? Color.white : Color.white.opacity(0.1), lineWidth: layer.colorLabel == hex ? 2 : 0.5)
                        )
                        .onTapGesture {
                            vm.setLayerColor(layer.id, color: hex)
                        }
                }
            }

            // Action buttons (functional)
            HStack(spacing: 6) {
                // Duplicate
                Button(action: { vm.duplicateLayer(layer.id) }) {
                    HStack(spacing: 4) {
                        Text("📋").font(.system(size: 12))
                        Text("Duplicate")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                }

                // Delete (only if more than one layer)
                if vm.layers.count > 1 {
                    Button(action: { vm.deleteLayer(layer.id) }) {
                        HStack(spacing: 4) {
                            Text("🗑").font(.system(size: 12))
                            Text("Delete")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.red.opacity(0.8))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.05))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.1), lineWidth: 0.5))
                    }
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
        .onAppear {
            opacityDraft = layer.opacity
            blendModeDraft = layer.blendMode
        }
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
