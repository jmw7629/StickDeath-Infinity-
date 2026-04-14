// PropertiesPanel.swift
// Right slide-out — figure properties, onion skin toggle

import SwiftUI

struct PropertiesPanel: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Properties").font(.headline)
                Spacer()
                Button { vm.showProperties = false } label: {
                    Image(systemName: "xmark").font(.caption).foregroundStyle(.gray)
                }
            }
            .padding()

            Divider().background(ThemeManager.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Figure settings
                    if let idx = vm.figures.firstIndex(where: { $0.id == vm.selectedFigureId }) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("FIGURE").font(.caption.bold()).foregroundStyle(.gray)

                            TextField("Name", text: $vm.figures[idx].name)
                                .textFieldStyle(.plain)
                                .padding(8)
                                .background(ThemeManager.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            HStack {
                                Text("Line Width").font(.caption)
                                Slider(value: $vm.figures[idx].lineWidth, in: 1...10, step: 0.5)
                                    .tint(.red)
                            }

                            HStack {
                                Text("Head Size").font(.caption)
                                Slider(value: $vm.figures[idx].headRadius, in: 5...30, step: 1)
                                    .tint(.red)
                            }

                            // Color picker
                            HStack {
                                Text("Color").font(.caption)
                                Spacer()
                                ColorPicker("", selection: Binding(
                                    get: { vm.figures[idx].color.color },
                                    set: { vm.figures[idx].color = CodableColor($0) }
                                ))
                                .labelsHidden()
                            }
                        }
                    }

                    Divider().background(ThemeManager.border)

                    // Canvas settings
                    VStack(alignment: .leading, spacing: 12) {
                        Text("CANVAS").font(.caption.bold()).foregroundStyle(.gray)

                        Toggle("Onion Skin", isOn: $vm.showOnionSkin)
                            .tint(.red)
                            .font(.subheadline)

                        HStack {
                            Text("Zoom").font(.caption)
                            Slider(value: $vm.canvasScale, in: 0.3...3.0)
                                .tint(.red)
                            Text("\(Int(vm.canvasScale * 100))%")
                                .font(.caption.monospacedDigit())
                                .frame(width: 40)
                        }

                        Button {
                            vm.canvasScale = 1.0
                            vm.canvasOffset = .zero
                        } label: {
                            Label("Reset View", systemImage: "arrow.counterclockwise")
                                .font(.caption)
                        }
                    }
                }
                .padding()
            }
        }
        .background(.ultraThinMaterial)
    }
}
