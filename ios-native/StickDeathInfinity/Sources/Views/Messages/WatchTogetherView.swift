// WatchTogetherView.swift
// Watch Together LIVE — synced playback, emoji reactions, transport controls
// Matches reference exactly

import SwiftUI

struct WatchTogetherView: View {
    let channelName: String
    @Environment(\.dismiss) var dismiss
    @State private var isPlaying = false
    @State private var currentFrame = 33
    @State private var totalFrames = 48
    @State private var showChat = false

    let watchers: [(String, Color)] = [
        ("YO", .red), ("XB", .blue), ("SN", .green)
    ]

    let reactionEmojis = ["🔥", "💀", "😂", "🎯", "❤️", "👋", "💯"]

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ──
                HStack {
                    Button { dismiss() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.left")
                            Text("Back")
                        }
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Text("🎬")
                        Text("Watch Together")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }

                    Spacer()

                    // LIVE badge
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // ── Watching bar ──
                HStack(spacing: 8) {
                    Text("WATCHING:")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hex: "#9090a8"))

                    HStack(spacing: -6) {
                        ForEach(watchers, id: \.0) { w in
                            ZStack {
                                Circle()
                                    .fill(w.1)
                                    .frame(width: 24, height: 24)
                                Text(w.0)
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }

                    Text("#\(channelName)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "#9090a8"))

                    Spacer()

                    Button { showChat.toggle() } label: {
                        HStack(spacing: 4) {
                            Text("💬")
                            Text("Chat")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(showChat ? .white : .green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(showChat ? ThemeManager.surface : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.green, lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                // ── Video Player Area ──
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: "#111118"))

                    // Synced badge
                    VStack {
                        HStack {
                            HStack(spacing: 4) {
                                Circle().fill(.green).frame(width: 6, height: 6)
                                Text("SYNCED")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.green)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                            Spacer()

                            Text("\(currentFrame)/\(totalFrames) · 12fps")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color(hex: "#9090a8"))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .padding(12)
                        Spacer()
                    }

                    // Placeholder content (sword animation)
                    VStack(spacing: 8) {
                        Text("⚔️")
                            .font(.system(size: 64))
                        Text("Epic Sword Fight")
                            .font(.system(size: 16))
                            .foregroundStyle(Color(hex: "#9090a8"))
                        Text("by xBoneBreaker")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "#5a5a6e"))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxHeight: .infinity)

                // ── Timeline scrubber ──
                VStack(spacing: 0) {
                    // Reaction markers
                    GeometryReader { geo in
                        let w = geo.size.width
                        // Some reaction markers along the timeline
                        ForEach([0.2, 0.35, 0.5, 0.65, 0.85], id: \.self) { pos in
                            Text(["😆", "🔥", "💀", "⚡", "🎯"][Int(pos * 5) % 5])
                                .font(.system(size: 12))
                                .position(x: w * pos, y: 8)
                        }
                    }
                    .frame(height: 20)

                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(ThemeManager.surface)
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(ThemeManager.brand)
                                .frame(width: geo.size.width * CGFloat(currentFrame) / CGFloat(totalFrames), height: 6)
                            Circle()
                                .fill(.white)
                                .frame(width: 14, height: 14)
                                .offset(x: geo.size.width * CGFloat(currentFrame) / CGFloat(totalFrames) - 7)
                        }
                    }
                    .frame(height: 14)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                // ── Transport Controls ──
                HStack(spacing: 20) {
                    Button {} label: {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                    }
                    Button {} label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                    }
                    Button { isPlaying.toggle() } label: {
                        ZStack {
                            Circle()
                                .fill(ThemeManager.brand)
                                .frame(width: 52, height: 52)
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.white)
                        }
                    }
                    Button {} label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                    }
                    Button {} label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.bottom, 12)

                // ── Emoji Reactions ──
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(reactionEmojis, id: \.self) { emoji in
                            Button {
                                // Send reaction
                            } label: {
                                Text(emoji)
                                    .font(.system(size: 26))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 20)
            }
        }
        .navigationBarHidden(true)
    }
}
