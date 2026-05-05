// WarRoomView.swift
// War Room — VS battle with timer, vote bars, spectators
// Matches reference exactly

import SwiftUI

struct WarRoomView: View {
    let channelName: String
    @Environment(\.dismiss) var dismiss
    @State private var selectedTab = 0 // 0=Battle, 1=Board, 2=Chat
    @State private var timeRemaining: TimeInterval = 845 // 14:05
    @State private var votesRed = 0
    @State private var votesBlue = 0

    struct Spectator: Identifiable {
        let id = UUID()
        let initials: String
        let name: String
        let color: Color
    }

    let spectators: [Spectator] = [
        Spectator(initials: "DF", name: "DeathFrame", color: .purple),
        Spectator(initials: "FM", name: "FlipMaster", color: .orange),
        Spectator(initials: "BR", name: "BoneRush", color: .teal),
        Spectator(initials: "IB", name: "InkBleed", color: .pink),
        Spectator(initials: "FK", name: "FrameKill", color: .cyan),
        Spectator(initials: "SL", name: "StickLord", color: .yellow),
    ]

    var totalVotes: Int { votesRed + votesBlue }
    var redPercent: CGFloat { totalVotes > 0 ? CGFloat(votesRed) / CGFloat(totalVotes) : 0.5 }
    var bluePercent: CGFloat { 1.0 - redPercent }

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
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
                            Text("⚔️")
                            Text("War Room")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                        }

                        Spacer()

                        HStack(spacing: 4) {
                            Image(systemName: "eye.fill")
                                .font(.system(size: 12))
                            Text("8")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(Color(hex: "#9090a8"))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    // ── VS Header ──
                    HStack {
                        HStack(spacing: 4) {
                            Circle().fill(.red).frame(width: 8, height: 8)
                            Text("xBoneBreaker")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.red)
                        }

                        Text("VS")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Color(hex: "#5a5a6e"))
                            .padding(.horizontal, 8)

                        HStack(spacing: 4) {
                            Text("StickNinja42")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.green)
                            Circle().fill(.green).frame(width: 8, height: 8)
                        }
                    }
                    .padding(.vertical, 8)

                    // Challenge name
                    HStack(spacing: 4) {
                        Text("🏆")
                        Text("\"Ultimate Sword Fight\" Challenge")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.yellow)
                    }
                    .padding(.bottom, 12)

                    // ── Timer + Vote Counts ──
                    HStack {
                        Text("\(votesRed) votes")
                            .font(.system(size: 13))
                            .foregroundStyle(.red)

                        Spacer()

                        HStack(spacing: 6) {
                            Text("⏱")
                            Text(formatTime(timeRemaining))
                                .font(.system(size: 24, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                        }

                        Spacer()

                        Text("\(votesBlue) votes")
                            .font(.system(size: 13))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                    // ── Vote Bar ──
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.red)
                                .frame(width: geo.size.width * redPercent)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.green)
                                .frame(width: geo.size.width * bluePercent)
                        }
                    }
                    .frame(height: 8)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.horizontal, 20)

                    HStack {
                        Text("\(Int(redPercent * 100))%")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.red)
                        Spacer()
                        Text("\(totalVotes) total votes")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: "#9090a8"))
                        Spacer()
                        Text("\(Int(bluePercent * 100))%")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 16)

                    // ── Battle / Board / Chat Tabs ──
                    HStack(spacing: 0) {
                        tabPill("⚔️ Battle", isActive: selectedTab == 0) { selectedTab = 0 }
                        tabPill("🏆 Board", isActive: selectedTab == 1) { selectedTab = 1 }
                        tabPill("💬 Chat", isActive: selectedTab == 2) { selectedTab = 2 }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                    if selectedTab == 0 {
                        // ── Battle View ──
                        HStack(alignment: .top, spacing: 12) {
                            // Red contestant
                            contestantCard("XB", "xBoneBreaker", frames: 24, status: "Drawing", statusColor: .blue, votes: votesRed, voteColor: .red)

                            // Blue contestant
                            contestantCard("SN", "StickNinja42", frames: 18, status: "Animating", statusColor: .green, votes: votesBlue, voteColor: .green)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }

                    // ── Spectators ──
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SPECTATORS (\(spectators.count))")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(hex: "#9090a8"))
                            .padding(.horizontal, 16)

                        // Spectator chips
                        let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(spectators) { s in
                                HStack(spacing: 6) {
                                    ZStack {
                                        Circle().fill(s.color).frame(width: 24, height: 24)
                                        Text(s.initials)
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                    Text(s.name)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(ThemeManager.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    Spacer().frame(height: 40)
                }
            }
        }
        .navigationBarHidden(true)
    }

    func tabPill(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: isActive ? .bold : .medium))
                .foregroundStyle(isActive ? .white : Color(hex: "#9090a8"))
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(isActive ? ThemeManager.surface : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    func contestantCard(_ initials: String, _ name: String, frames: Int, status: String, statusColor: Color, votes: Int, voteColor: Color) -> some View {
        VStack(spacing: 10) {
            // Name
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(voteColor).frame(width: 24, height: 24)
                    Text(initials)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text(name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(voteColor)
                    .lineLimit(1)
            }

            // Preview card
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(ThemeManager.surface)
                    .aspectRatio(1, contentMode: .fill)

                VStack {
                    HStack {
                        Spacer()
                        Text("\(frames) frames")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(hex: "#9090a8"))
                            .padding(4)
                    }
                    Spacer()
                    HStack {
                        HStack(spacing: 4) {
                            Circle().fill(statusColor).frame(width: 6, height: 6)
                            Text(status)
                                .font(.system(size: 10))
                                .foregroundStyle(Color(hex: "#9090a8"))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        Spacer()
                    }
                    .padding(6)
                }

                // Sword emoji
                Text("⚔️")
                    .font(.system(size: 40))
            }

            // Vote button
            Button {} label: {
                HStack(spacing: 6) {
                    Text("VOTE")
                        .font(.system(size: 14, weight: .bold))
                    Circle()
                        .fill(voteColor)
                        .frame(width: 10, height: 10)
                    Text("(\(votes))")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(voteColor.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    func formatTime(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d : %02d", m, s)
    }
}
