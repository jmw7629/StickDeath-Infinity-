// TimelinePanel.swift
// Bottom panel — frame thumbnails, playback controls

import SwiftUI

struct TimelinePanel: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule().fill(.gray.opacity(0.4)).frame(width: 40, height: 4).padding(.top, 8)

            // Playback controls
            HStack(spacing: 16) {
                Button { vm.currentFrameIndex = 0 } label: {
                    Image(systemName: "backward.end.fill").font(.caption)
                }
                Button { vm.currentFrameIndex = max(0, vm.currentFrameIndex - 1) } label: {
                    Image(systemName: "backward.fill").font(.caption)
                }
                Button { vm.togglePlay() } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
                Button { vm.currentFrameIndex = min(vm.frames.count - 1, vm.currentFrameIndex + 1) } label: {
                    Image(systemName: "forward.fill").font(.caption)
                }
                Button { vm.currentFrameIndex = vm.frames.count - 1 } label: {
                    Image(systemName: "forward.end.fill").font(.caption)
                }

                Spacer()

                Text("\(vm.currentFrameIndex + 1) / \(vm.frames.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.gray)

                // Add frame
                Button { vm.addFrame() } label: {
                    Image(systemName: "plus.rectangle").font(.caption)
                }
                Button { vm.duplicateFrame() } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                Button { vm.deleteFrame() } label: {
                    Image(systemName: "trash").font(.caption).foregroundStyle(.red)
                }
                .disabled(vm.frames.count <= 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            // Frame thumbnails
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(vm.frames.enumerated()), id: \.element.id) { index, frame in
                            FrameThumbnail(
                                index: index,
                                isSelected: index == vm.currentFrameIndex,
                                figureCount: frame.figureStates.filter(\.visible).count
                            )
                            .id(index)
                            .onTapGesture { vm.currentFrameIndex = index }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .onChange(of: vm.currentFrameIndex) { _, newIndex in
                    withAnimation { proxy.scrollTo(newIndex, anchor: .center) }
                }
            }
        }
        .background(.ultraThinMaterial)
    }
}

struct FrameThumbnail: View {
    let index: Int
    let isSelected: Bool
    let figureCount: Int

    var body: some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.red.opacity(0.2) : ThemeManager.surface)
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "figure.stand")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? .red : .gray)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.red : Color.clear, lineWidth: 2)
                )
            Text("\(index + 1)")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(isSelected ? .red : .gray)
        }
    }
}
