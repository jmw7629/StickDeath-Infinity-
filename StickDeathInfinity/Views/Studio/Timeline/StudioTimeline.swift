import SwiftUI

// ═══════════════════════════════════════════════════════════════════
// Frame Timeline — < ▶ > | frame thumbnails (red border=selected) | +
//   onion skin icon | frame counter
// ═══════════════════════════════════════════════════════════════════

struct StudioTimeline: View {
    @ObservedObject var vm: StudioViewModel

    var body: some View {
        HStack(spacing: 6) {
            // Prev
            Button(action: { vm.prevFrame() }) {
                Text("‹")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(vm.currentFrameIndex > 0 ? .white.opacity(0.6) : .white.opacity(0.2))
            }
            .disabled(vm.currentFrameIndex == 0)

            // Play/Pause
            Button(action: { vm.togglePlayback() }) {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Color(hex: "1E1E2A"))
                    .clipShape(Circle())
            }

            // Next
            Button(action: { vm.nextFrame() }) {
                Text("›")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(vm.currentFrameIndex < vm.frames.count - 1 ? .white.opacity(0.6) : .white.opacity(0.2))
            }
            .disabled(vm.currentFrameIndex >= vm.frames.count - 1)

            // Frame thumbnails
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(vm.frames.indices, id: \.self) { i in
                            Button(action: { vm.currentFrameIndex = i }) {
                                ZStack {
                                    // Mini canvas render
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white)
                                        .frame(width: 36, height: 36)

                                    StudioFrameThumbnail(vm: vm, frame: vm.frames[i])
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))

                                    // Frame number
                                    Text("\(i + 1)")
                                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                                        .foregroundColor(vm.currentFrameIndex == i ? .red : .white.opacity(0.4))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                        .padding(2)
                                }
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(vm.currentFrameIndex == i ? Color.red : Color.white.opacity(0.1),
                                                lineWidth: vm.currentFrameIndex == i ? 2 : 1)
                                )
                            }
                            .id(i)
                            .contextMenu {
                                Button("Duplicate frame") { vm.currentFrameIndex = i; vm.duplicateFrame() }
                                Button("Move earlier") { vm.moveFrame(vm.frames[i].id, offset: -1) }
                                Button("Move later") { vm.moveFrame(vm.frames[i].id, offset: 1) }
                                Button("Delete this frame", role: .destructive) { vm.deleteFrame(vm.frames[i].id) }
                                    .disabled(vm.frames.count <= 1)
                            }
                        }
                    }
                }
                .onChange(of: vm.currentFrameIndex) { newIndex in
                    withAnimation { proxy.scrollTo(newIndex, anchor: .center) }
                }
            }

            // Add frame
            Button(action: { vm.addFrame() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 32, height: 32)
                    .background(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
            }

            .accessibilityIdentifier("studio.add-frame")

            // Onion skin toggle
            Button(action: { vm.showOnionSkin.toggle() }) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 14))
                    .foregroundColor(vm.showOnionSkin ? .red : .white.opacity(0.3))
            }

            Spacer()

            // Frame counter
            Text("\(vm.currentFrameIndex + 1)/\(vm.frames.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(hex: "0A0A10"))
    }
}
