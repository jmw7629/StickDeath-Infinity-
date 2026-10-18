import SwiftUI

// ═══════════════════════════════════════════════════════════════════
// Studio Header — "< Untitled Animation" | "12 FPS · 1 frames · 1 layers"
//   HIDE | 💾 save indicator | ↑ export | ⋯ menu
// ═══════════════════════════════════════════════════════════════════

struct StudioHeaderBar: View {
    @ObservedObject var vm: StudioViewModel
    var onDismiss: () -> Void = {}
    @ObservedObject private var room = StudioRoomBridge.shared

    private func roomStatus(_ status: RoomSessionCoordinator.StudioSyncStatus) -> some View {
        let dot: Color
        switch status.level {
        case .synced: dot = .green
        case .syncing: dot = .white.opacity(0.6)
        case .waiting, .paused: dot = .orange
        case .conflict: dot = .red
        }
        return Menu {
            Text(status.detail)
            if status.level == .conflict {
                Button("Keep mine on top") { room.resolveConflict(keepMine: true) }
                    .accessibilityIdentifier("studio.room-sync.keep")
                Button("Discard mine", role: .destructive) { room.resolveConflict(keepMine: false) }
                    .accessibilityIdentifier("studio.room-sync.discard")
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(status.label)
                    .font(.specialElite(9))
                    .lineLimit(1)
            }
            .foregroundColor(.white.opacity(0.7))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(hex: "1A1A24"))
            .cornerRadius(6)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(status.label)
        .accessibilityHint(status.detail)
        .accessibilityIdentifier("studio.room-sync")
    }

    var body: some View {
        HStack(spacing: 8) {
            // Back
            Button(action: onDismiss) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                    Text(vm.projectName)
                        .font(.specialElite(14))
                        .lineLimit(1)
                }
                .foregroundColor(.white.opacity(0.8))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("studio.back")
            
            // Info pill
            Text("\(vm.fps) FPS · \(vm.frames.count) frames · \(vm.studioLayers.count) layers")
                .font(.specialElite(9))
                .foregroundColor(.white.opacity(0.35))

            // Shared-room status (#232): shown only while a room's project is
            // open. Tapping shows the counts and any held-conflict decision;
            // it never blocks the canvas.
            if let status = room.status {
                roomStatus(status)
            }

            Spacer()
            
            // HIDE
            Button(action: { vm.showToolbar.toggle() }) {
                VStack(spacing: 1) {
                    Image(systemName: vm.showToolbar ? "keyboard.chevron.compact.down" : "keyboard.chevron.compact.up")
                        .font(.system(size: 12))
                    Text(vm.showToolbar ? "HIDE" : "SHOW")
                        .font(.specialElite(7))
                }
                .foregroundColor(.white.opacity(0.5))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(vm.showToolbar ? "Hide toolbar" : "Show toolbar")
            .accessibilityIdentifier("studio.toolbar.toggle")
            
            // Save indicator
            Button(action: { Task { await vm.save() } }) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 10))
                    Text(vm.saveTimeAgo)
                        .font(.specialElite(9))
                }
                .foregroundColor(.white.opacity(0.4))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(hex: "1A1A24"))
                .cornerRadius(6)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .disabled(vm.isSaving)
            .accessibilityIdentifier("studio.save")
            .accessibilityLabel(vm.saveTimeAgo)
            
            // Export
            Button(action: {
                vm.activePanel = vm.activePanel == .export ? .none : .export
            }) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.red)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Export")
            .accessibilityIdentifier("studio.export.open")
            
            // Menu (⋯)
            Button(action: {
                vm.activePanel = .menu
            }) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Studio menu")
            .accessibilityIdentifier("studio.menu.open")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
