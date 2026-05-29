import SwiftUI

struct StudioTimelineBar: View {
    @ObservedObject var vm: StudioViewModel
    
    var body: some View {
        HStack(spacing: 0) {
            // Frame nav arrows
            Button(action: { vm.prevFrame() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 28, height: 44)
            }
            
            // Play button
            Button(action: { vm.isPlaying.toggle() }) {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(Color(hex: "#DC2626"))
                    )
            }
            .padding(.horizontal, 4)
            
            Button(action: { vm.nextFrame() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 28, height: 44)
            }
            
            // Frame thumbnails (scrollable)
            ScrollView(.horizontal, showsIndicators: false) {
                ScrollViewReader { proxy in
                    HStack(spacing: 6) {
                        ForEach(Array(vm.frames.enumerated()), id: \.element.id) { index, frame in
                            FrameThumbnail(
                                frameNumber: index + 1,
                                isSelected: index == vm.currentFrameIndex,
                                onTap: { vm.currentFrameIndex = index }
                            )
                            .id(index)
                        }
                        
                        // Add frame button
                        Button(action: { vm.addFrame() }) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                    .foregroundColor(.white.opacity(0.2))
                                Image(systemName: "plus")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.3))
                            }
                            .frame(width: 40, height: 36)
                        }
                    }
                    .padding(.horizontal, 4)
                    .onChange(of: vm.currentFrameIndex) { newIndex in
                        withAnimation { proxy.scrollTo(newIndex, anchor: .center) }
                    }
                }
            }
            
            // Frame counter
            Text("\(vm.currentFrameIndex + 1)/\(vm.frames.count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
                .padding(.trailing, 8)
        }
        .frame(height: 50)
        .background(Color(hex: "#14141e"))
        .overlay(
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5),
            alignment: .top
        )
    }
}

// MARK: - Frame Thumbnail
struct FrameThumbnail: View {
    let frameNumber: Int
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white)
                    .frame(width: 40, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isSelected ? Color(hex: "#DC2626") : Color.white.opacity(0.15), lineWidth: isSelected ? 2 : 1)
                    )
                
                Text("\(frameNumber)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(isSelected ? Color(hex: "#DC2626") : .gray)
            }
        }
    }
}
