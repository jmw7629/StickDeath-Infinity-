import SwiftUI

struct LayerPanel: View {
    @ObservedObject var vm: StudioViewModel

    let glowColors: [String] = ["#FF0000","#FF5500","#FFAA00","#22C55E","#06B6D4","#3B82F6","#8B5CF6","#EC4899","#FFFFFF"]

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            PanelHeader(title: "Layers", icon: "📄", onClose: { vm.activePanel = .none })

            ScrollView {
                VStack(spacing: 0) {
                    // Layer rows
                    ForEach(Array(vm.layers.enumerated()), id: \.element.id) { index, layer in
                        LayerRow(
                            layer: layer,
                            isSelected: index == vm.currentLayerIndex,
                            onTap: { vm.currentLayerIndex = index; vm.activeLayerID = layer.id },
                            onToggleVisibility: { vm.toggleLayerVisibility(layer.id) }
                        )
                    }

                    // Selected layer settings
                    if vm.layers.indices.contains(vm.currentLayerIndex) {
                        let layerIdx = vm.currentLayerIndex

                        // Opacity slider
                        VStack(spacing: 4) {
                            HStack {
                                Text("Opacity")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.5))
                                Spacer()
                                Text("\(Int(vm.layers[layerIdx].opacity * 100))%")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            Slider(
                                value: $vm.layers[layerIdx].opacity,
                                in: 0...1
                            )
                            .accentColor(Color(hex: "DC2626"))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)

                        // Lock Mode
                        VStack(alignment: .leading, spacing: 6) {
                            Text("LOCK MODE")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                                .tracking(1)

                            HStack(spacing: 8) {
                                ForEach(LockMode.allCases, id: \.rawValue) { mode in
                                    Button(action: {
                                        vm.layers[layerIdx].lockMode = mode.rawValue
                                    }) {
                                        VStack(spacing: 3) {
                                            Text(mode.icon)
                                                .font(.system(size: 16))
                                            Text(mode.rawValue)
                                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                        }
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color(hex: "12121a"))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(
                                                            vm.layers[layerIdx].lockMode == mode.rawValue ? Color.white.opacity(0.3) : Color.white.opacity(0.08),
                                                            lineWidth: 1
                                                        )
                                                )
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)

                        // Blend Mode
                        HStack {
                            Text("BLEND MODE")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                                .tracking(1)
                            Spacer()

                            Menu {
                                ForEach(SDBlendMode.allCases, id: \.rawValue) { mode in
                                    Button(mode.rawValue) {
                                        vm.layers[layerIdx].blendMode = mode.rawValue
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(vm.layers[layerIdx].blendMode)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 8))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(hex: "12121a"))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                        )
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)

                        // Glow
                        HStack {
                            Text("GLOW")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                                .tracking(1)

                            Toggle("", isOn: $vm.layers[layerIdx].glowEnabled)
                                .toggleStyle(SwitchToggleStyle(tint: Color(hex: "DC2626")))
                                .labelsHidden()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)

                        // Glow color row
                        HStack(spacing: 4) {
                            Text("Color:")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                            ForEach(glowColors, id: \.self) { hex in
                                Button(action: {
                                    vm.layers[layerIdx].colorLabel = hex
                                }) {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 22, height: 22)
                                        .overlay(
                                            Circle().stroke(
                                                vm.layers[layerIdx].colorLabel == hex ? Color.white : Color.clear,
                                                lineWidth: 2
                                            )
                                        )
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)

                        // Action buttons
                        HStack(spacing: 8) {
                            Button(action: { vm.addLayer() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 10))
                                    Text("Add Layer")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                }
                                .foregroundColor(.white.opacity(0.6))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(hex: "12121a"))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08)))
                                )
                            }

                            Button(action: { vm.toggleLayerLock(vm.layers[layerIdx].id) }) {
                                HStack(spacing: 4) {
                                    Image(systemName: vm.layers[layerIdx].locked ? "lock.fill" : "lock.open.fill")
                                        .font(.system(size: 10))
                                    Text(vm.layers[layerIdx].locked ? "Locked" : "Unlocked")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                }
                                .foregroundColor(.white.opacity(0.6))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(hex: "12121a"))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08)))
                                )
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .padding(.bottom, 16)
                    }
                }
            }
            .frame(maxHeight: UIScreen.main.bounds.height * 0.55)
        }
        .background(Color(hex: "1a1a24"))
        .cornerRadius(16, corners: [.topLeft, .topRight])
    }
}

// MARK: - Layer Row
struct LayerRow: View {
    let layer: CanvasLayer
    let isSelected: Bool
    let onTap: () -> Void
    let onToggleVisibility: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.2))

                Button(action: onToggleVisibility) {
                    Image(systemName: layer.visible ? "eye" : "eye.slash")
                        .font(.system(size: 12))
                        .foregroundColor(layer.visible ? .white.opacity(0.6) : .red.opacity(0.5))
                }
                .frame(width: 24, height: 24)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 36, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )

                Text(layer.name)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(isSelected ? Color(hex: "DC2626") : .white.opacity(0.7))

                Spacer()

                Image(systemName: layer.locked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "B8860B").opacity(0.7))

                Text("\(Int(layer.opacity * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "DC2626"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}
