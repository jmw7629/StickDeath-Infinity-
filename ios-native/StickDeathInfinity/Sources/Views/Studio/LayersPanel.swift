// LayersPanel.swift
// Left slide-out — manage figures (layers)

import SwiftUI

struct LayersPanel: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Button { vm.addFigure() } label: {
                    Image(systemName: "plus.circle.fill").foregroundStyle(.orange)
                }
                Button { vm.showLayers = false } label: {
                    Image(systemName: "xmark").font(.caption).foregroundStyle(.gray)
                }
            }
            .padding()

            Divider().background(ThemeManager.border)

            // Figure list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(vm.figures) { figure in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(figure.color.color)
                                .frame(width: 12, height: 12)

                            Text(figure.name)
                                .font(.subheadline)
                                .lineLimit(1)

                            Spacer()

                            // Visibility toggle
                            Button {
                                toggleVisibility(figure.id)
                            } label: {
                                Image(systemName: isVisible(figure.id) ? "eye" : "eye.slash")
                                    .font(.caption)
                                    .foregroundStyle(.gray)
                            }

                            // Delete
                            if vm.figures.count > 1 {
                                Button { vm.deleteFigure(figure.id) } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.red.opacity(0.6))
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(figure.id == vm.selectedFigureId ? Color.orange.opacity(0.1) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { vm.selectedFigureId = figure.id }
                    }
                }
                .padding(8)
            }
        }
        .background(.ultraThinMaterial)
    }

    func isVisible(_ figureId: UUID) -> Bool {
        vm.frames[safe: vm.currentFrameIndex]?.figureStates.first { $0.figureId == figureId }?.visible ?? true
    }

    func toggleVisibility(_ figureId: UUID) {
        guard let stateIdx = vm.frames[safe: vm.currentFrameIndex]?.figureStates.firstIndex(where: { $0.figureId == figureId }) else { return }
        vm.frames[vm.currentFrameIndex].figureStates[stateIdx].visible.toggle()
    }
}
