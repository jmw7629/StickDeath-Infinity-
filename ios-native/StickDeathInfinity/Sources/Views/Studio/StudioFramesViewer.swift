// StudioFramesViewer.swift
// Full-screen grid of frame thumbnails + "Add Frame" card
// Matches StickDeath Infinity reference design

import SwiftUI

struct StudioFramesViewer: View {
    @ObservedObject var vm: EditorViewModel
    @Binding var activePanel: StudioPanel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("🎞️")
                    .font(.system(size: 14))
                Text("Frames")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Text("(\(vm.frames.count))")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()

                Button { vm.addFrame() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                        Text("Add")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: "E03030")))
                }

                Button { activePanel = .none } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            // Frame grid
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ], spacing: 10) {
                    ForEach(Array(vm.frames.enumerated()), id: \.offset) { index, _ in
                        frameCard(index: index)
                    }

                    // Add frame card
                    addFrameCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .background(Color(hex: "111111"))
        .ignoresSafeArea()
    }

    // MARK: - Frame Card
    func frameCard(index: Int) -> some View {
        Button {
            vm.currentFrameIndex = index
            activePanel = .none
        } label: {
            VStack(spacing: 0) {
                // Thumbnail
                ZStack {
                    Rectangle()
                        .fill(.white)
                    // Frame number overlay
                    VStack {
                        HStack {
                            Text("\(index + 1)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color(hex: "E03030"))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            Spacer()
                        }
                        .padding(4)
                        Spacer()
                    }
                }
                .aspectRatio(16/9, contentMode: .fit)

                // Bottom bar
                Rectangle()
                    .fill(index == vm.currentFrameIndex ? Color(hex: "E03030") : .white.opacity(0.08))
                    .frame(height: 8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(index == vm.currentFrameIndex ? Color(hex: "E03030") : .white.opacity(0.06), lineWidth: 2)
            )
        }
        .contextMenu {
            Button("Duplicate") {
                vm.currentFrameIndex = index
                vm.duplicateFrame()
            }
            Button("Delete", role: .destructive) {
                vm.currentFrameIndex = index
                vm.deleteFrame()
            }
        }
    }

    // MARK: - Add Frame Card
    var addFrameCard: some View {
        Button { vm.addFrame() } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.25))
                Text("Add Frame")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.2))
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16/9, contentMode: .fit)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .foregroundStyle(.white.opacity(0.1))
            )
        }
    }
}
