import SwiftUI

struct StudioHeaderBar: View {
    @ObservedObject var vm: StudioViewModel
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Back button
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 30, height: 30)
            }

            // Project name
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.projectName)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text("\(vm.fps) FPS · \(vm.frames.count) frames · \(vm.layers.count) layers")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
            }

            Spacer()

            // HIDE toolbar toggle
            Button(action: { withAnimation { vm.showToolbar.toggle() } }) {
                Text(vm.showToolbar ? "HIDE" : "SHOW")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.05))
                    )
            }

            // Save indicator
            HStack(spacing: 3) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                Text("💾")
                    .font(.system(size: 10))
                Text(vm.saveTimeAgo)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
            }

            // Upload
            Button(action: { Task { await vm.save() } }) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 28, height: 28)
            }

            // More menu
            Button(action: {
                withAnimation {
                    vm.activePanel = vm.activePanel == .projectSettings ? .none : .projectSettings
                }
            }) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 28, height: 28)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(Color(hex: "#14141e"))
        .overlay(
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5),
            alignment: .bottom
        )
    }
}
