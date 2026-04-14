// LayersPanel.swift
// Left slide-out — manage figures (layers)
// v2: Higher contrast, visible items, close button, colored layer indicators

import SwiftUI

struct LayersPanel: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Layers")
                    .font(ThemeManager.headline(size: 22))
                Spacer()
                Button { vm.addFigure() } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
                Button { vm.showLayers = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.gray)
                }
            }
            .padding()

            Divider().background(ThemeManager.border)

            if vm.figures.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange.opacity(0.4))
                    Text("No layers yet")
                        .font(.subheadline)
                        .foregroundStyle(ThemeManager.textSecondary)
                    Text("Add a figure to get started")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                // Figure list
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(vm.figures.enumerated()), id: \.element.id) { index, figure in
                            let isSelected = figure.id == vm.selectedFigureId
                            HStack(spacing: 10) {
                                // Layer number + color indicator
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(figure.color.color.opacity(0.3))
                                        .frame(width: 32, height: 32)
                                    Text("\(index + 1)")
                                        .font(.caption.bold().monospacedDigit())
                                        .foregroundStyle(figure.color.color)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(figure.name)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text("Line: \(String(format: "%.0f", figure.lineWidth))pt")
                                        .font(.caption2)
                                        .foregroundStyle(ThemeManager.textSecondary)
                                }

                                Spacer()

                                // Visibility toggle
                                Button {
                                    toggleVisibility(figure.id)
                                } label: {
                                    Image(systemName: isVisible(figure.id) ? "eye" : "eye.slash")
                                        .font(.caption)
                                        .foregroundStyle(isVisible(figure.id) ? .orange : .gray)
                                        .frame(width: 28, height: 28)
                                        .background(ThemeManager.surface)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }

                                // Delete
                                if vm.figures.count > 1 {
                                    Button { vm.deleteFigure(figure.id) } label: {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                            .foregroundStyle(.red.opacity(0.7))
                                            .frame(width: 28, height: 28)
                                            .background(Color.red.opacity(0.1))
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isSelected ? Color.orange.opacity(0.15) : ThemeManager.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(isSelected ? Color.orange.opacity(0.4) : .clear, lineWidth: 1)
                            )
                            .onTapGesture { vm.selectedFigureId = figure.id }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(ThemeManager.background.opacity(0.95))
        .overlay(
            Rectangle()
                .fill(ThemeManager.border)
                .frame(width: 1),
            alignment: .trailing
        )
    }

    func isVisible(_ figureId: UUID) -> Bool {
        vm.frames[safe: vm.currentFrameIndex]?.figureStates.first { $0.figureId == figureId }?.visible ?? true
    }

    func toggleVisibility(_ figureId: UUID) {
        guard let stateIdx = vm.frames[safe: vm.currentFrameIndex]?.figureStates.firstIndex(where: { $0.figureId == figureId }) else { return }
        vm.frames[vm.currentFrameIndex].figureStates[stateIdx].visible.toggle()
    }
}
