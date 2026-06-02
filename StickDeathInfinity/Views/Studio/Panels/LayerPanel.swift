import SwiftUI

// ═══════════════════════════════════════════════════════════════════
// Layer Panel — Opacity RED slider, LOCK MODE (Free/Full/Pos/Alpha),
// BLEND MODE dropdown, GLOW toggle, Color dots,
// Editable/Duplicate/↑/↓ buttons, + add layer
// ═══════════════════════════════════════════════════════════════════

struct LayerPanel: View {
    @ObservedObject var vm: StudioViewModel
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            
            VStack(spacing: 0) {
                PanelHeader(title: "Layers (\(vm.layers.count))", icon: "square.3.layers.3d") {
                    vm.activePanel = .none
                }
                
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.layers.indices, id: \.self) { i in
                            LayerRowView(
                                layer: $vm.layers[i],
                                isActive: vm.activeLayerID == vm.layers[i].id,
                                index: i,
                                totalLayers: vm.layers.count,
                                onSelect: { vm.activeLayerID = vm.layers[i].id; vm.currentLayerIndex = i },
                                onToggleVisibility: { vm.toggleLayerVisibility(vm.layers[i].id) },
                                onToggleLock: { vm.toggleLayerLock(vm.layers[i].id) },
                                onMoveUp: { if i > 0 { vm.layers.swapAt(i, i - 1) } },
                                onMoveDown: { if i < vm.layers.count - 1 { vm.layers.swapAt(i, i + 1) } },
                                onDuplicate: {
                                    let dupe = CanvasLayer(
                                        id: UUID().uuidString,
                                        name: vm.layers[i].name + " copy",
                                        visible: true, locked: false, opacity: vm.layers[i].opacity
                                    )
                                    vm.layers.insert(dupe, at: i + 1)
                                }
                            )
                        }
                    }
                }
                
                // Add layer button
                Button(action: { vm.addLayer() }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.red)
                        Text("Add Layer")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(hex: "12121A"))
                }
            }
        }
    }
}

struct LayerRowView: View {
    @Binding var layer: CanvasLayer
    let isActive: Bool
    let index: Int
    let totalLayers: Int
    let onSelect: () -> Void
    let onToggleVisibility: () -> Void
    let onToggleLock: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDuplicate: () -> Void
    @State private var expanded = false
    
    let colorLabels: [(Color, String)] = [
        (.red, "Red"), (.orange, "Orange"), (.yellow, "Yellow"), (.green, "Green"),
        (.blue, "Blue"), (.purple, "Purple"), (.pink, "Pink"), (.gray, "Gray"),
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // Layer row
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    // Drag handle
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                    
                    // Visibility toggle
                    Button(action: onToggleVisibility) {
                        Image(systemName: layer.visible ? "eye" : "eye.slash")
                            .font(.system(size: 12))
                            .foregroundColor(layer.visible ? .white.opacity(0.5) : .red)
                    }
                    
                    // Thumbnail
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hex: "1E1E2A"))
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(isActive ? Color.red : Color.white.opacity(0.1), lineWidth: isActive ? 1.5 : 0.5)
                        )
                    
                    // Name (red when active)
                    Text(layer.name)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(isActive ? .red : .white.opacity(0.6))
                    
                    Spacer()
                    
                    // Lock indicator
                    Image(systemName: layer.locked ? "lock.fill" : "lock.open")
                        .font(.system(size: 10))
                        .foregroundColor(layer.locked ? .red : .white.opacity(0.3))
                    
                    // Opacity
                    Text("\(Int(layer.opacity * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                    
                    // Expand/collapse
                    Button(action: { expanded.toggle() }) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(isActive ? Color(hex: "12121A") : Color.clear)
            }
            .buttonStyle(.plain)
            
            // Expanded settings
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    // Opacity — RED slider
                    HStack {
                        Text("Opacity")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                        Slider(value: $layer.opacity, in: 0...1)
                            .tint(.red)
                        Text("\(Int(layer.opacity * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 36, alignment: .trailing)
                    }
                    
                    // LOCK MODE
                    Text("LOCK MODE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                        .tracking(2)
                    
                    HStack(spacing: 6) {
                        ForEach(LockMode.allCases, id: \.self) { mode in
                            Button(action: {
                                layer.lockMode = mode.rawValue.lowercased()
                                layer.locked = mode != .free
                            }) {
                                VStack(spacing: 2) {
                                    Text(mode.icon)
                                        .font(.system(size: 14))
                                    Text(mode.rawValue)
                                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                                }
                                .foregroundColor(layer.lockMode == mode.rawValue.lowercased() ? .red : .white.opacity(0.4))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(layer.lockMode == mode.rawValue.lowercased() ? Color.red.opacity(0.15) : Color(hex: "1E1E2A"))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(layer.lockMode == mode.rawValue.lowercased() ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1)
                                )
                            }
                        }
                    }
                    
                    // BLEND MODE
                    Text("BLEND MODE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                        .tracking(2)
                    
                    Picker("", selection: $layer.blendMode) {
                        ForEach(SDBlendMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(hex: "1E1E2A"))
                    .cornerRadius(8)
                    
                    // GLOW toggle
                    HStack {
                        Text("GLOW")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                            .tracking(2)
                        Spacer()
                        Toggle("", isOn: $layer.glowEnabled)
                            .labelsHidden()
                            .scaleEffect(0.7)
                            .tint(.red)
                    }
                    
                    // Color labels
                    HStack(spacing: 8) {
                        Text("Color")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.4))
                        ForEach(colorLabels.indices, id: \.self) { ci in
                            Circle()
                                .fill(colorLabels[ci].0)
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: layer.colorLabel == colorLabels[ci].1 ? 2 : 0)
                                )
                                .onTapGesture {
                                    layer.colorLabel = colorLabels[ci].1
                                }
                        }
                    }
                    
                    // Action buttons
                    HStack(spacing: 6) {
                        LayerActionButton(icon: "pencil", label: "Editable") {}
                        LayerActionButton(icon: "doc.on.doc", label: "Duplicate") { onDuplicate() }
                        
                        Button(action: onMoveUp) {
                            Image(systemName: "arrow.up.square")
                                .font(.system(size: 12))
                                .foregroundColor(index > 0 ? .white.opacity(0.5) : .white.opacity(0.15))
                                .padding(6)
                                .background(Color(hex: "1E1E2A"))
                                .cornerRadius(6)
                        }
                        .disabled(index == 0)
                        
                        Button(action: onMoveDown) {
                            Image(systemName: "arrow.down.square")
                                .font(.system(size: 12))
                                .foregroundColor(index < totalLayers - 1 ? .white.opacity(0.5) : .white.opacity(0.15))
                                .padding(6)
                                .background(Color(hex: "1E1E2A"))
                                .cornerRadius(6)
                        }
                        .disabled(index >= totalLayers - 1)
                        
                        Spacer()
                        
                        Button(action: {}) {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundColor(.red.opacity(0.6))
                                .padding(6)
                                .background(Color(hex: "1E1E2A"))
                                .cornerRadius(6)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(hex: "0A0A10").opacity(0.5))
            }
            
            Divider().background(Color.white.opacity(0.04))
        }
    }
}

struct LayerActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .foregroundColor(.white.opacity(0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(hex: "1E1E2A"))
            .cornerRadius(6)
        }
    }
}
