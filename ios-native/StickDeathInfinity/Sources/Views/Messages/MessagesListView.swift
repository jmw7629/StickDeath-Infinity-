// MessagesListView.swift
// Channel list → tapping opens ChatView
// Matches reference: channels with member counts, DMs, action buttons for Call/Watch/Creator/WarRoom

import SwiftUI

struct MessagesListView: View {
    @EnvironmentObject var router: NavigationRouter

    struct Channel: Identifiable {
        let id: Int
        let name: String
        let emoji: String
        let memberCount: Int
        let lastMessage: String
        let timeAgo: String
        let unread: Int
    }

    @State private var channels: [Channel] = [
        Channel(id: 1, name: "general", emoji: "#", memberCount: 23, lastMessage: "StickMasterFlex: yo that fight scene was insane", timeAgo: "2m", unread: 3),
        Channel(id: 2, name: "show-off", emoji: "🎬", memberCount: 45, lastMessage: "AnimateOrDie shared a new animation", timeAgo: "5m", unread: 1),
        Channel(id: 3, name: "feedback", emoji: "💬", memberCount: 18, lastMessage: "xBladeRunner: can someone review my walk cycle?", timeAgo: "12m", unread: 0),
        Channel(id: 4, name: "collabs", emoji: "🤝", memberCount: 31, lastMessage: "BoneBreaker: looking for a partner for the challenge", timeAgo: "25m", unread: 0),
        Channel(id: 5, name: "tips-tricks", emoji: "💡", memberCount: 67, lastMessage: "FlipMaster: pro tip — use onion skinning for walk cycles", timeAgo: "1h", unread: 0),
        Channel(id: 6, name: "off-topic", emoji: "🎲", memberCount: 42, lastMessage: "DeathFrame: anyone else hyped for the new update?", timeAgo: "2h", unread: 0),
    ]

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // ── Header ──
                    HStack {
                        Text("Messages")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                        Spacer()

                        // Action buttons row
                        HStack(spacing: 12) {
                            quickAction("📞", "Call") {
                                router.push(MessagesDestination.voiceCall("general"))
                            }
                            quickAction("🎬", "Watch") {
                                router.push(MessagesDestination.watchTogether("general"))
                            }
                            quickAction("🎨", "Create") {
                                router.push(MessagesDestination.creatorRoom("general"))
                            }
                            quickAction("⚔️", "Battle") {
                                router.push(MessagesDestination.warRoom("general"))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                    // ── Search ──
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Color(hex: "#9090a8"))
                        Text("Search messages...")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(hex: "#5a5a6e"))
                        Spacer()
                    }
                    .padding(12)
                    .background(ThemeManager.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                    // ── Channels ──
                    ForEach(channels) { channel in
                        Button {
                            router.push(MessagesDestination.chat(channel.id, channel.name))
                        } label: {
                            channelRow(channel)
                        }
                    }

                    Spacer().frame(height: 80)
                }
            }
        }
        .navigationBarHidden(true)
    }

    func quickAction(_ emoji: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(emoji)
                    .font(.system(size: 16))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(hex: "#9090a8"))
            }
            .frame(width: 42, height: 42)
            .background(ThemeManager.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    func channelRow(_ channel: Channel) -> some View {
        HStack(spacing: 12) {
            // Channel icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(ThemeManager.surface)
                    .frame(width: 44, height: 44)
                Text(channel.emoji)
                    .font(.system(size: channel.emoji == "#" ? 20 : 22))
                    .foregroundStyle(channel.emoji == "#" ? Color(hex: "#9090a8") : .white)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(channel.name)
                        .font(.system(size: 16, weight: channel.unread > 0 ? .bold : .semibold))
                        .foregroundStyle(.white)
                    Text("· \(channel.memberCount)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "#9090a8"))
                    Spacer()
                    Text(channel.timeAgo)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "#9090a8"))
                }
                Text(channel.lastMessage)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#9090a8"))
                    .lineLimit(1)
            }

            if channel.unread > 0 {
                Text("\(channel.unread)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(ThemeManager.brand)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.clear)
    }
}
