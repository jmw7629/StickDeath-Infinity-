// CreatorRoomView.swift
// Creator Room LIVE COLLAB — Canvas/Layers/Chat tabs, multi-cursor, frame numbers
// Matches reference exactly

import SwiftUI

struct CreatorRoomView: View {
    let channelName: String
    @Environment(\.dismiss) var dismiss
    @State private var selectedTab = 0 // 0=Canvas, 1=Layers, 2=Chat
    @State private var currentFrame = 6
    @State private var totalFrames = 48
    @State private var isPlaying = false
    @State private var isRecording = false

    let collaborators: [(String, Color)] = [
        ("YO", .red), ("XB", .blue), ("SN", .green)
    ]

    let tools: [(String, String, Color)] = [
        ("pencil.tip", "Draw", .red),
        ("eraser", "Erase", .white),
        ("selection.pin.in.out", "Select", .white),
        ("paintbrush.fill", "Fill", .white),
        ("textformat", "Text", .white),
        ("figure.stand", "Rig", .white),
    ]

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ──
                HStack(spacing: 10) {
                    Button { dismiss() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.left")
                            Text("Back")
                        }
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Text("🎨")
                        Text("Creator Room")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }

                    // LIVE COLLAB badge
                    Text("LIVE COLLAB")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.green)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Spacer()

                    // Collaborator avatars
                    HStack(spacing: -6) {
                        ForEach(collaborators, id: \.0) { c in
                            ZStack {
                                Circle().fill(c.1).frame(width: 28, height: 28)
                                Text(c.0)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // ── Project Info ──
                HStack(spacing: 8) {
                    Text("🎬 Epic Collab Fight Scene")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)

                    Text("·")
                        .foregroundStyle(Color(hex: "#5a5a6e"))

                    Text("24 FPS · 1920×1080")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "#9090a8"))

                    Text("·")
                        .foregroundStyle(Color(hex: "#5a5a6e"))

                    Text("Frame \(currentFrame)/\(totalFrames)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "#9090a8"))

                    Spacer()

                    Text("#\(channelName)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "#9090a8"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(ThemeManager.card)

                // ── Canvas/Layers/Chat Tabs ──
                HStack(spacing: 0) {
                    tabButton("🖼 Canvas", isActive: selectedTab == 0) { selectedTab = 0 }
                    tabButton("📋 Layers", isActive: selectedTab == 1) { selectedTab = 1 }
                    tabButton("💬 Chat", isActive: selectedTab == 2) { selectedTab = 2 }
                }
                .background(ThemeManager.card)
                .overlay(
                    Rectangle().fill(ThemeManager.border).frame(height: 0.5),
                    alignment: .bottom
                )

                if selectedTab == 0 {
                    // ── Tool Bar ──
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(tools, id: \.1) { tool in
                                VStack(spacing: 2) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(tool.2 == .red ? ThemeManager.brand : ThemeManager.surface)
                                            .frame(width: 40, height: 40)
                                        Image(systemName: tool.0)
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                    }
                                    Text(tool.1)
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color(hex: "#9090a8"))
                                }
                            }

                            Spacer()

                            // Record button
                            Button { isRecording.toggle() } label: {
                                Circle()
                                    .fill(isRecording ? .red : Color(hex: "#2a2a3a"))
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Circle()
                                            .fill(.red)
                                            .frame(width: isRecording ? 16 : 24)
                                    )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .background(ThemeManager.card)

                    // ── Canvas with multi-cursor ──
                    ZStack {
                        // White canvas
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.white)
                            .padding(12)

                        // Placeholder content — sword animation
                        VStack(spacing: 12) {
                            Text("⚔️")
                                .font(.system(size: 48))
                            Text("🗡️✨")
                                .font(.system(size: 40))
                        }

                        // Multi-cursor indicators
                        VStack {
                            HStack {
                                Spacer()
                                cursorLabel("" /* clean slate */, color: .green)
                                    .offset(x: -40, y: 80)
                            }
                            Spacer()
                            HStack {
                                cursorLabel("" /* clean slate */, color: .blue)
                                    .offset(x: 30, y: -40)
                                Spacer()
                            }
                        }
                        .padding(24)
                    }
                    .frame(maxHeight: .infinity)
                }

                if selectedTab == 1 {
                    // Layers list
                    ScrollView {
                        VStack(spacing: 2) {
                            layerRow("Layer 3 — Effects", isActive: false)
                            layerRow("Layer 2 — Characters", isActive: true)
                            layerRow("Layer 1 — Background", isActive: false)
                        }
                        .padding(16)
                    }
                    .frame(maxHeight: .infinity)
                }

                if selectedTab == 2 {
                    // Simple chat placeholder
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            chatBubble("SN", "Frame 14 is looking great!", .green)
                            chatBubble("XB", "Working on the impact effects now", .blue)
                            chatBubble("YO", "Nice! Adding the sound FX next", .red)
                        }
                        .padding(16)
                    }
                    .frame(maxHeight: .infinity)
                }

                // ── Frame Strip ──
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        Button { isPlaying.toggle() } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(ThemeManager.brand)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }

                        ForEach(1...12, id: \.self) { frame in
                            Button {
                                currentFrame = frame
                            } label: {
                                Text("\(frame)")
                                    .font(.system(size: 12, weight: frame == currentFrame ? .bold : .regular, design: .monospaced))
                                    .foregroundStyle(frame == currentFrame ? .white : Color(hex: "#9090a8"))
                                    .frame(width: 28, height: 28)
                                    .background(frame == currentFrame ? ThemeManager.brand : ThemeManager.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }

                        Text("...")
                            .foregroundStyle(Color(hex: "#5a5a6e"))

                        Text("\(currentFrame)/\(totalFrames)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color(hex: "#9090a8"))
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: 44)
                .background(ThemeManager.card)
                .overlay(
                    Rectangle().fill(ThemeManager.border).frame(height: 0.5),
                    alignment: .top
                )
            }
        }
        .navigationBarHidden(true)
    }

    func tabButton(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: isActive ? .bold : .medium))
                .foregroundStyle(isActive ? .white : Color(hex: "#9090a8"))
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(isActive ? ThemeManager.surface : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    func cursorLabel(_ name: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrowtriangle.left.fill")
                .font(.system(size: 10))
                .foregroundStyle(color)
            Text(name)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    func layerRow(_ name: String, isActive: Bool) -> some View {
        HStack {
            Image(systemName: "eye.fill")
                .font(.system(size: 14))
                .foregroundStyle(isActive ? ThemeManager.brand : Color(hex: "#5a5a6e"))
            Text(name)
                .font(.system(size: 14))
                .foregroundStyle(isActive ? .white : Color(hex: "#9090a8"))
            Spacer()
            if isActive {
                Text("EDITING")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ThemeManager.brand)
            }
        }
        .padding(12)
        .background(isActive ? ThemeManager.surface : ThemeManager.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func chatBubble(_ initials: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle().fill(color).frame(width: 28, height: 28)
                Text(initials)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.white)
        }
    }
}
