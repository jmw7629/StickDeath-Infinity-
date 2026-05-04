// StudioAudioTimeline.swift
// Full-screen audio timeline — transport controls, 4 tracks, red playhead
// Matches StickDeath Infinity reference design

import SwiftUI

struct StudioAudioTimeline: View {
    @ObservedObject var vm: EditorViewModel
    @Binding var activePanel: StudioPanel
    @State private var playheadTime: Double = 0
    @State private var snapEnabled = true
    let totalDuration: Double = 5.0

    var body: some View {
        VStack(spacing: 0) {
            header
            transport
            timelineGrid
            footer
        }
        .background(Color(hex: "111111"))
        .ignoresSafeArea()
    }

    // MARK: - Header
    var header: some View {
        HStack(spacing: 6) {
            Text("🎵")
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 0) {
                Text("Audio")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Text("Timeline")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }

            Spacer()

            // Toolbar buttons
            HStack(spacing: 4) {
                headerButton(icon: "0", isText: true)
                headerButton(icon: "arrow.uturn.backward")
                headerButton(icon: "arrow.uturn.forward")
                headerButton(icon: "plus.viewfinder")
                headerButton(icon: "minus")
                headerButton(icon: "plus")

                Button {
                    activePanel = .soundLibrary
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("Add")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: "E03030")))
                }

                Button { activePanel = .none } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    func headerButton(icon: String, isText: Bool = false) -> some View {
        Button {} label: {
            Group {
                if isText {
                    Text(icon)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: "222222")))
        }
    }

    // MARK: - Transport
    var transport: some View {
        HStack(spacing: 10) {
            Button {} label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "222222")))
            }

            Button { vm.isPlaying.toggle() } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "E03030")))
            }

            Button {} label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "222222")))
            }

            // Time display
            HStack(spacing: 2) {
                Text(formatTime(playheadTime))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Color(hex: "E03030"))
                Text(" / \(formatTime(totalDuration))")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.leading, 8)

            Spacer()

            // SNAP badge
            Button { snapEnabled.toggle() } label: {
                Text("SNAP")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Color(hex: "E03030"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(hex: "E03030"), lineWidth: 1.5)
                    )
                    .background(snapEnabled ? Color(hex: "E03030").opacity(0.1) : .clear)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Timeline Grid
    var timelineGrid: some View {
        GeometryReader { geo in
            ZStack {
                Color(hex: "0d0d0d")

                VStack(spacing: 0) {
                    // Time markers
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 48)
                        ForEach(0..<5) { i in
                            Text(formatTime(Double(i)))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.25))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 4)
                        }
                    }
                    .frame(height: 22)
                    .background(Color(hex: "181818"))
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
                    }

                    // Tracks
                    ForEach(1...4, id: \.self) { trackNum in
                        HStack(spacing: 0) {
                            // Track controls
                            VStack(spacing: 4) {
                                Text("\(trackNum)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.2))
                                Button {} label: {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.4))
                                        .frame(width: 26, height: 26)
                                        .background(Circle().fill(.white.opacity(0.06)))
                                }
                                Button {} label: {
                                    Image(systemName: "lock")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.4))
                                        .frame(width: 26, height: 26)
                                        .background(Circle().fill(.white.opacity(0.06)))
                                }
                            }
                            .frame(width: 48)
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
                            }

                            // Track lane (empty for now)
                            Color.clear
                        }
                        .frame(height: 60)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(.white.opacity(0.04)).frame(height: 1)
                        }
                    }
                }

                // Playhead
                Rectangle()
                    .fill(Color(hex: "E03030"))
                    .frame(width: 2)
                    .offset(x: -geo.size.width / 2 + 48 + (geo.size.width - 48) * playheadTime / totalDuration)
            }
        }
    }

    // MARK: - Footer
    var footer: some View {
        HStack {
            Text("Tap to place playhead · Drag clips to reposition")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
            Spacer()
            Button {} label: {
                Text("+ Quick Add at Playhead")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "E03030"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(hex: "111111"))
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
        }
    }

    func formatTime(_ t: Double) -> String {
        let m = Int(t) / 60
        let s = t.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%05.2f", m, s)
    }
}
