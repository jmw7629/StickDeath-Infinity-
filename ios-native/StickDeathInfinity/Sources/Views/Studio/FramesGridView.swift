// FramesGridView.swift
// Full-screen frames viewer — grid of all frames with thumbnails
// v9: Tap to jump, long-press context menu (duplicate, delete, copy, clear)

import SwiftUI

struct FramesGridView: View {
    @ObservedObject var vm: EditorViewModel
    @Environment(\.dismiss) var dismiss

    private let columns = [
        GridItem(.adaptive(minimum: 90, maximum: 120), spacing: 8)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(Array(vm.frames.enumerated()), id: \.element.id) { idx, frame in
                            FrameCard(
                                index: idx,
                                frame: frame,
                                isCurrent: idx == vm.currentFrameIndex,
                                figures: vm.figures,
                                onTap: {
                                    vm.goToFrame(idx)
                                    dismiss()
                                },
                                onDuplicate: {
                                    vm.currentFrameIndex = idx
                                    vm.duplicateFrame()
                                },
                                onDelete: {
                                    if vm.frames.count > 1 {
                                        vm.currentFrameIndex = idx
                                        vm.deleteFrame()
                                    }
                                },
                                onClearDrawing: {
                                    vm.pushUndo()
                                    vm.frames[idx].drawnElements.removeAll()
                                    vm.frames[idx].importedImages.removeAll()
                                }
                            )
                        }

                        // Add frame button
                        Button {
                            vm.addFrame()
                            HapticManager.shared.buttonTap()
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(ThemeManager.surface)
                                        .frame(height: 110)

                                    VStack(spacing: 4) {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(.red)
                                        Text("Add")
                                            .font(.caption2)
                                            .foregroundStyle(.gray)
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
            .navigationTitle("Frames (\(vm.frames.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.red)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            vm.addFrame()
                        } label: {
                            Label("Add Frame", systemImage: "plus")
                        }
                        Button {
                            vm.duplicateFrame()
                        } label: {
                            Label("Duplicate Current", systemImage: "doc.on.doc")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }
}

// MARK: - Individual Frame Card
struct FrameCard: View {
    let index: Int
    let frame: AnimationFrame
    let isCurrent: Bool
    let figures: [StickFigure]
    let onTap: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onClearDrawing: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            // Frame preview
            ZStack {
                // White canvas background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white)
                    .frame(height: 110)

                // Mini stick figure preview
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let scale: CGFloat = 0.6

                    for state in frame.figureStates where state.visible {
                        if let figure = figures.first(where: { $0.id == state.figureId }) {
                            // Draw bones
                            for (from, to) in StickFigure.bones {
                                guard let p1 = state.joints[from], let p2 = state.joints[to] else { continue }
                                var path = Path()
                                path.move(to: CGPoint(x: center.x + p1.x * scale, y: center.y + p1.y * scale))
                                path.addLine(to: CGPoint(x: center.x + p2.x * scale, y: center.y + p2.y * scale))
                                context.stroke(path, with: .color(figure.color.color.opacity(0.8)),
                                             lineWidth: figure.lineWidth * scale)
                            }
                            // Head
                            if let headPos = state.joints["head"] {
                                let hc = CGPoint(x: center.x + headPos.x * scale, y: center.y + headPos.y * scale)
                                let r = figure.headRadius * scale
                                let headPath = Path(ellipseIn: CGRect(x: hc.x - r, y: hc.y - r, width: r * 2, height: r * 2))
                                context.stroke(headPath, with: .color(figure.color.color.opacity(0.8)),
                                             lineWidth: figure.lineWidth * scale)
                            }
                        }
                    }

                    // Drawn elements indicator
                    if !frame.drawnElements.isEmpty {
                        let iconRect = CGRect(x: size.width - 16, y: 4, width: 12, height: 12)
                        context.fill(Path(ellipseIn: iconRect), with: .color(.red.opacity(0.6)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(height: 110)

                // Image count indicator
                if !frame.importedImages.isEmpty {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            HStack(spacing: 2) {
                                Image(systemName: "photo")
                                    .font(.system(size: 8))
                                Text("\(frame.importedImages.count)")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.6))
                            .clipShape(Capsule())
                            .padding(4)
                        }
                    }
                }

                // Selection border
                if isCurrent {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red, lineWidth: 2.5)
                        .frame(height: 110)
                }
            }

            // Frame number
            Text("\(index + 1)")
                .font(.system(size: 10, weight: isCurrent ? .bold : .regular))
                .foregroundStyle(isCurrent ? .red : .gray)
        }
        .onTapGesture { onTap() }
        .contextMenu {
            Button { onDuplicate() } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            Button { onClearDrawing() } label: {
                Label("Clear Drawing", systemImage: "eraser")
            }
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete Frame", systemImage: "trash")
            }
        }
    }
}
