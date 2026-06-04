// ═══════════════════════════════════════════════════════════════════
// WatchPartyView — Synchronized video watching
// Matches: src/messenger/components/WatchParty.tsx (730 lines)
// - Host picks a video/animation to watch
// - Synchronized playback across participants
// - LiveKit for audio/video of participants
// - Chat sidebar
// - Host controls (play/pause/seek)
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct WatchPartyView: View {
    let roomName: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = WatchPartyViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                let isLandscape = geo.size.width > geo.size.height

                if isLandscape {
                    // Landscape: video left, chat right
                    HStack(spacing: 0) {
                        videoContent
                            .frame(maxWidth: .infinity)
                        chatSidebar
                            .frame(width: 280)
                    }
                } else {
                    // Portrait: video top, participants + chat bottom
                    VStack(spacing: 0) {
                        videoContent
                            .frame(height: geo.size.height * 0.45)
                        participantStrip
                            .frame(height: 80)
                        chatSidebar
                            .frame(maxHeight: .infinity)
                    }
                }
            }

            // Top overlay
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }

                    Spacer()

                    Text("Watch Party")
                        .font(.specialElite(16))
                        .foregroundColor(.white)

                    Spacer()

                    Text("\(vm.participantCount) 👤")
                        .font(.system(size: 14))
                        .foregroundColor(.sdTextSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .cornerRadius(16)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()
            }
        }
    }

    // MARK: - Video Content
    private var videoContent: some View {
        ZStack {
            Color.black

            if let videoURL = vm.videoURL {
                // TODO: AVPlayer with synchronized playback
                Text("🎬 Playing: \(videoURL)")
                    .font(.system(size: 14))
                    .foregroundColor(.sdTextMuted)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.sdTextMuted)
                    Text("No video selected")
                        .font(.system(size: 16))
                        .foregroundColor(.sdTextSecondary)

                    if vm.isHost {
                        Button {
                            // Pick video
                        } label: {
                            Text("Choose Video")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Color.sdPrimaryGradient)
                                .cornerRadius(10)
                        }
                    }
                }
            }

            // Host controls overlay (bottom of video)
            if vm.isHost && vm.videoURL != nil {
                VStack {
                    Spacer()
                    HStack(spacing: 24) {
                        Button { vm.seekBackward() } label: {
                            Image(systemName: "gobackward.10")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                        }
                        Button { vm.togglePlay() } label: {
                            Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white)
                        }
                        Button { vm.seekForward() } label: {
                            Image(systemName: "goforward.10")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 32)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    // MARK: - Participant Strip
    private var participantStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(vm.participants, id: \.self) { name in
                    VStack(spacing: 4) {
                        Circle()
                            .fill(Color.sdSurface2)
                            .frame(width: 48, height: 48)
                            .overlay(
                                Text(String(name.prefix(1)))
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.sdTextPrimary)
                            )
                        Text(name)
                            .font(.system(size: 10))
                            .foregroundColor(.sdTextSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color.sdSurface)
    }

    // MARK: - Chat Sidebar
    private var chatSidebar: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.chatMessages) { msg in
                        HStack(alignment: .top, spacing: 8) {
                            Text(msg.senderUsername ?? "?")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.sdRed)
                            Text(msg.content)
                                .font(.system(size: 13))
                                .foregroundColor(.sdTextPrimary)
                        }
                    }
                }
                .padding(12)
            }

            // Input
            HStack(spacing: 8) {
                TextField("Say something...", text: $vm.chatInput)
                    .font(.system(size: 14))
                    .foregroundColor(.sdTextPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(16)

                Button {
                    vm.sendChat()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(vm.chatInput.isEmpty ? .sdTextMuted : .sdRed)
                }
                .disabled(vm.chatInput.isEmpty)
            }
            .padding(8)
            .background(Color.sdSurface)
        }
        .background(Color.sdSurface.opacity(0.95))
    }
}

// MARK: - ViewModel
@MainActor
final class WatchPartyViewModel: ObservableObject {
    @Published var videoURL: String? = nil
    @Published var isPlaying = false
    @Published var isHost = false
    @Published var participantCount = 1
    @Published var participants: [String] = ["You"]
    @Published var chatMessages: [ChatMessage] = []
    @Published var chatInput = ""

    func togglePlay() { isPlaying.toggle() }
    func seekForward() { /* +10s */ }
    func seekBackward() { /* -10s */ }

    func sendChat() {
        guard !chatInput.isEmpty else { return }
        let msg = ChatMessage(
            id: Int.random(in: 1...999999),
            roomID: 0,
            senderID: AuthService.shared.userId ?? "",
            senderUsername: AuthService.shared.displayName,
            content: chatInput,
            createdAt: nil,
            mediaURL: nil,
            messageType: nil
        )
        chatMessages.append(msg)
        chatInput = ""
    }
}
