// StudioLayerManager.swift
// Bottom sheet layer manager — compact/expanded rows, opacity slider
// Visible/Unlocked/Duplicate per layer. Red badge on action bar.
// Matches StickDeath Infinity reference design

import SwiftUI

struct LayerItem: Identifiable {
    let id = UUID()
    var name: String
    var visible: Bool = true
    var locked: Bool = false
    var opacity: Double = 100
    var expanded: Bool = false
}

struct StudioLayerManager: View {
    @ObservedObject var vm: EditorViewModel
    @State private var layers: [LayerItem] = [
        LayerItem(name: "Layer 1", visible: true, locked: false, opacity: 100, expanded: true)
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 0) {
                // Grab handle
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.2))
                        .frame(width: 40, height: 4)
                    Spacer()
                }
                .padding(.top, 10)
                .padding(.bottom, 8)

                // Header
                HStack {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Layers")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                    Text("(\(layers.count))")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.3))
                    Spacer()
                    Button { addLayer() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color(hex: "E03030")))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                // Layer list
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($layers) { $layer in
                            layerRow(layer: $layer)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .frame(maxHeight: 260)
            }
            .background(Color(hex: "1a1a1a"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.bottom, 112)
    }

    // MARK: - Layer Row
    func layerRow(layer: Binding<LayerItem>) -> some View {
        VStack(spacing: 0) {
            // Compact row
            HStack(spacing: 10) {
                // Thumbnail
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white)
                    .frame(width: 36, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.1)))

                // Name
                Text(layer.wrappedValue.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)

                Spacer()

                // Controls
                Button { layer.wrappedValue.visible.toggle() } label: {
                    Image(systemName: layer.wrappedValue.visible ? "eye" : "eye.slash")
                        .font(.system(size: 14))
                        .foregroundStyle(layer.wrappedValue.visible ? .white.opacity(0.6) : .white.opacity(0.2))
                }

                Button { layer.wrappedValue.locked.toggle() } label: {
                    Image(systemName: layer.wrappedValue.locked ? "lock.fill" : "lock.open")
                        .font(.system(size: 14))
                        .foregroundStyle(layer.wrappedValue.locked ? Color(hex: "F2A033") : .white.opacity(0.2))
                }

                Button { layer.wrappedValue.expanded.toggle() } label: {
                    Image(systemName: layer.wrappedValue.expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Expanded panel
            if layer.wrappedValue.expanded {
                VStack(spacing: 8) {
                    // Opacity slider
                    HStack(spacing: 10) {
                        Text("Opacity")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                        RedSlider(
                            label: "",
                            value: Binding(
                                get: { CGFloat(layer.wrappedValue.opacity) },
                                set: { layer.wrappedValue.opacity = Double($0) }
                            ),
                            range: 0...100,
                            unit: "%"
                        )
                    }

                    // Action buttons
                    HStack(spacing: 8) {
                        layerAction("Visible", icon: "eye.fill") {}
                        layerAction("Unlocked", icon: "lock.open") {}
                        layerAction("Duplicate", icon: "doc.on.doc") { duplicateLayer(layer.wrappedValue) }
                        layerAction("Delete", icon: "trash", isDestructive: true) {
                            layers.removeAll { $0.id == layer.wrappedValue.id }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.06)))
    }

    func layerAction(_ label: String, icon: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(label)
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundStyle(isDestructive ? Color(hex: "E03030") : .white.opacity(0.5))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.04)))
        }
    }

    func addLayer() {
        layers.append(LayerItem(name: "Layer \(layers.count + 1)"))
    }

    func duplicateLayer(_ layer: LayerItem) {
        let dup = LayerItem(name: "\(layer.name) copy", visible: layer.visible, locked: layer.locked, opacity: layer.opacity)
        layers.append(dup)
    }
}
