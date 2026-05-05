// SpatterOverlay.swift
// AI Video Engine copilot — Copilot/Generate/Batch tabs
// Matches reference: floating panel, chat input, quick actions

import SwiftUI

struct SpatterOverlay: View {
    @EnvironmentObject var router: NavigationRouter
    @State private var selectedTab = 0 // 0=Copilot, 1=Generate, 2=Batch
    @State private var inputText = ""
    @State private var messages: [(String, Bool)] = [
        ("I'm *Spatter* — your AI copilot & video engine. Ask me anything or tap suggestions below.", false)
    ]

    var body: some View {
        ZStack {
            // Dim background
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { router.closeSpatter() }

            VStack {
                Spacer()

                // ── Panel ──
                VStack(spacing: 0) {
                    // ── Header ──
                    HStack(spacing: 10) {
                        // Spatter icon
                        ZStack {
                            Circle()
                                .fill(ThemeManager.brand)
                                .frame(width: 36, height: 36)
                            Text("🩸")
                                .font(.system(size: 16))
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Spatter")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                            Text("AI Video Engine")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(hex: "#9090a8"))
                        }

                        Spacer()

                        Button { router.closeSpatter() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color(hex: "#9090a8"))
                                .frame(width: 30, height: 30)
                                .background(ThemeManager.surface)
                                .clipShape(Circle())
                        }
                    }
                    .padding(16)

                    // ── Tabs ──
                    HStack(spacing: 0) {
                        tabButton("💬 Copilot", isActive: selectedTab == 0) { selectedTab = 0 }
                        tabButton("⚡ Generate", isActive: selectedTab == 1) { selectedTab = 1 }
                        tabButton("📦 Batch", isActive: selectedTab == 2) { selectedTab = 2 }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                    // ── Content ──
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(messages.indices, id: \.self) { i in
                                let (text, isUser) = messages[i]
                                HStack {
                                    if isUser { Spacer() }
                                    Text(text)
                                        .font(.system(size: 15))
                                        .foregroundStyle(.white)
                                        .padding(12)
                                        .background(isUser ? ThemeManager.brand.opacity(0.3) : ThemeManager.surface)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                    if !isUser { Spacer() }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(maxHeight: 300)

                    // ── Quick Actions + Input ──
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Text("💡")
                                Text("Quick Actions")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            // Input field
                            HStack {
                                TextField("", text: $inputText, prompt: Text("Ask Spatter...").foregroundStyle(Color(hex: "#5a5a6e")))
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white)

                                Button {
                                    guard !inputText.isEmpty else { return }
                                    messages.append((inputText, true))
                                    let q = inputText
                                    inputText = ""
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                        messages.append(("Working on it... I'll analyze \"\(q)\" and help you create something epic. 🔥", false))
                                    }
                                } label: {
                                    Image(systemName: "arrow.right.circle.fill")
                                        .font(.system(size: 24))
                                        .foregroundStyle(inputText.isEmpty ? Color(hex: "#5a5a6e") : ThemeManager.brand)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                        }

                        // Status
                        Text("● Mock provider · Connect Ollama to go live")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: "#5a5a6e"))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(ThemeManager.card)
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    func tabButton(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: isActive ? .bold : .medium))
                .foregroundStyle(isActive ? .white : Color(hex: "#9090a8"))
                .frame(maxWidth: .infinity, minHeight: 34)
        }
    }
}
