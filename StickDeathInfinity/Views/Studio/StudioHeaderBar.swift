import SwiftUI

// ═══════════════════════════════════════════════════════════════════
// Studio Header — "< Untitled Animation" | "12 FPS · 1 frames · 1 layers"
//   HIDE | 💾 save indicator | ↑ export | ⋯ menu
// ═══════════════════════════════════════════════════════════════════

struct StudioHeaderBar: View {
    @ObservedObject var vm: StudioViewModel
    var onDismiss: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            // Back
            Button(action: onDismiss) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                    Text(vm.projectName)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundColor(.white.opacity(0.8))
            }

            // Info pill
            Text("\(vm.fps) FPS · \(vm.frames.count) frames · \(vm.studioLayers.count) layers")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.35))

            Spacer()

            // HIDE
            Button(action: { vm.showToolbar.toggle() }) {
                VStack(spacing: 1) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 12))
                    Text("HIDE")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                }
                .foregroundColor(.white.opacity(0.5))
            }

            // Save indicator
            Button(action: { Task { await vm.save() } }) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 10))
                    Text(vm.saveTimeAgo)
                        .font(.system(size: 9))
                }
                .foregroundColor(.white.opacity(0.4))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(hex: "1A1A24"))
                .cornerRadius(6)
            }

            // Export
            Button(action: {
                vm.activePanel = vm.activePanel == .export ? .none : .export
            }) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.red)
            }

            // Menu (⋯)
            Button(action: {
                vm.activePanel = .menu
            }) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
