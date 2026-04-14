// PropertiesPanel.swift
// Right slide-out — figure properties, onion skin toggle
// v2: Higher contrast, better labeled sections, visible borders, close button

import SwiftUI

struct PropertiesPanel: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Properties")
                    .font(ThemeManager.headline(size: 22))
                Spacer()
                Button { vm.showProperties = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.gray)
                }
            }
            .padding()

            Divider().background(ThemeManager.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Figure settings
                    if let idx = vm.figures.firstIndex(where: { $0.id == vm.selectedFigureId }) {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionHeader("FIGURE", icon: "figure.stand")

                            TextField("Name", text: $vm.figures[idx].name)
                                .stickDeathTextField()

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Line Width").font(.caption.bold())
                                    Spacer()
                                    Text("\(String(format: "%.1f", vm.figures[idx].lineWidth))pt")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.orange)
                                }
                                Slider(value: $vm.figures[idx].lineWidth, in: 1...10, step: 0.5)
                                    .tint(.orange)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Head Size").font(.caption.bold())
                                    Spacer()
                                    Text("\(String(format: "%.0f", vm.figures[idx].headRadius))")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.orange)
                                }
                                Slider(value: $vm.figures[idx].headRadius, in: 5...30, step: 1)
                                    .tint(.orange)
                            }

                            // Color picker
                            HStack {
                                Text("Color").font(.caption.bold())
                                Spacer()
                                ColorPicker("", selection: Binding(
                                    get: { vm.figures[idx].color.color },
                                    set: { vm.figures[idx].color = CodableColor($0) }
                                ))
                                .labelsHidden()
                            }
                            .padding(10)
                            .background(ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    } else {
                        // No figure selected
                        VStack(spacing: 8) {
                            Image(systemName: "hand.tap")
                                .font(.title2)
                                .foregroundStyle(.orange.opacity(0.5))
                            Text("Select a figure to edit")
                                .font(.caption)
                                .foregroundStyle(ThemeManager.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }

                    Divider().background(ThemeManager.border)

                    // Canvas settings
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("CANVAS", icon: "rectangle.on.rectangle")

                        HStack {
                            Image(systemName: vm.showOnionSkin ? "square.stack.3d.up.fill" : "square.stack.3d.up.slash")
                                .foregroundStyle(vm.showOnionSkin ? .orange : .gray)
                                .frame(width: 20)
                            Toggle("Onion Skin", isOn: $vm.showOnionSkin)
                                .tint(.orange)
                                .font(.subheadline)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Zoom").font(.caption.bold())
                                Spacer()
                                Text("\(Int(vm.canvasScale * 100))%")
                                    .font(.caption.bold().monospacedDigit())
                                    .foregroundStyle(.orange)
                            }
                            Slider(value: $vm.canvasScale, in: 0.3...3.0)
                                .tint(.orange)
                        }

                        Button {
                            vm.canvasScale = 1.0
                            vm.canvasOffset = .zero
                        } label: {
                            Label("Reset View", systemImage: "arrow.counterclockwise")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.orange.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding()
            }
        }
        .background(ThemeManager.background.opacity(0.95))
        .overlay(
            Rectangle()
                .fill(ThemeManager.border)
                .frame(width: 1),
            alignment: .leading
        )
    }

    func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.orange)
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(ThemeManager.textSecondary)
        }
    }
}
