// VoiceCallView.swift
// Voice/Video call — matches reference exactly
// Voice/Video tabs, participant circles with initials, mute/speaker/screen controls

import SwiftUI

struct VoiceCallView: View {
    let channelName: String
    @Environment(\.dismiss) var dismiss
    @State private var isVoice = true
    @State private var isMuted = false
    @State private var isSpeaker = false
    @State private var callDuration: TimeInterval = 2

    struct Participant: Identifiable {
        let id = UUID()
        let initials: String
        let name: String
        let ringColor: Color
        let isMuted: Bool
    }

    let participants: [Participant] = [
        Participant(initials: "YO", name: "You", ringColor: .red, isMuted: false),
        Participant(initials: "XB", name: "xBoneBreaker", ringColor: Color(hex: "#2a2a3a"), isMuted: false),
        Participant(initials: "SN", name: "StickNinja42", ringColor: .green, isMuted: false),
        Participant(initials: "DF", name: "DeathFrame", ringColor: Color(hex: "#2a2a3a"), isMuted: true),
    ]

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ──
                HStack {
                    Button { dismiss() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 16))
                            Text("Back")
                                .font(.system(size: 16))
                        }
                        .foregroundStyle(.white)
                    }

                    Spacer()

                    // Timer
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text(formatTime(callDuration))
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(.white)
                    }

                    Spacer()

                    // Participant count
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 14))
                        Text("\(participants.count)")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                // ── Voice / Video Toggle ──
                HStack(spacing: 0) {
                    tabPill("🎙 Voice", isActive: isVoice) { isVoice = true }
                    tabPill("🎥 Video", isActive: !isVoice) { isVoice = false }
                }
                .padding(4)
                .background(ThemeManager.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.bottom, 24)

                // ── Participants ──
                Spacer()

                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 20),
                    GridItem(.flexible(), spacing: 20),
                    GridItem(.flexible(), spacing: 20),
                ], spacing: 24) {
                    ForEach(participants) { p in
                        participantCircle(p)
                    }
                }
                .padding(.horizontal, 40)

                Spacer()

                // Channel name
                Text("#\(channelName) · \(participants.count) participants")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#9090a8"))
                    .padding(.bottom, 24)

                // ── Controls ──
                HStack(spacing: 28) {
                    controlButton(icon: "mic.slash.fill", label: "Mute", isActive: isMuted) {
                        isMuted.toggle()
                    }
                    controlButton(icon: "speaker.wave.2.fill", label: "Speaker", isActive: isSpeaker) {
                        isSpeaker.toggle()
                    }
                    controlButton(icon: "rectangle.on.rectangle", label: "Screen", isActive: false) {}

                    // End call (red)
                    Button { dismiss() } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .fill(ThemeManager.brand)
                                    .frame(width: 56, height: 56)
                                Image(systemName: "phone.down.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white)
                                    .rotationEffect(.degrees(135))
                            }
                            Text("")
                                .font(.system(size: 10))
                        }
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                callDuration += 1
            }
        }
    }

    func tabPill(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isActive ? .white : Color(hex: "#9090a8"))
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(isActive ? ThemeManager.brand : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    func participantCircle(_ p: Participant) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(p.ringColor, lineWidth: 3)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(ThemeManager.surface)
                    .frame(width: 64, height: 64)
                Text(p.initials)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text(p.name)
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "#9090a8"))
                .lineLimit(1)
            if p.isMuted {
                Text("Muted")
                    .font(.system(size: 11))
                    .foregroundStyle(ThemeManager.brand)
            }
        }
    }

    func controlButton(icon: String, label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(isActive ? ThemeManager.surface : ThemeManager.card)
                        .frame(width: 52, height: 52)
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(isActive ? ThemeManager.brand : .white)
                }
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: "#9090a8"))
            }
        }
    }

    func formatTime(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
