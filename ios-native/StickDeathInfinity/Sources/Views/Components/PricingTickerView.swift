// ═══════════════════════════════════════════════════════════════════
// PricingTickerView — Discrete corner overlay with Spatter's wit
// Matches: MainApp.tsx PricingTicker exactly
// Bottom-right toast, rotates quotes, dismissable
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct PricingTickerView: View {
    @State private var tickerIdx = 0
    @State private var opacity: Double = 1
    @State private var dismissed = false

    private let timer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        if !dismissed {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    tickerContent
                        .padding(.trailing, 12)
                        .padding(.bottom, 68)
                }
            }
        }
    }

    private var tickerContent: some View {
        HStack(spacing: 6) {
            Text("💀")
                .font(.system(size: 14))

            Text(tickerQuotes[tickerIdx].text)
                .font(.specialElite(10))
                .foregroundColor(Color(hex: tickerQuotes[tickerIdx].color))
                .lineSpacing(2)
                .lineLimit(3)

            Button {
                dismissed = true
            } label: {
                Text("✕")
                    .font(.system(size: 10))
                    .foregroundColor(.sdTextMuted)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 260)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.sdBorder.opacity(0.8), lineWidth: 1)
                )
        )
        .opacity(opacity)
        .onTapGesture { dismissed = true }
        .onReceive(timer) { _ in
            withAnimation(.easeOut(duration: 0.4)) { opacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                tickerIdx = (tickerIdx + 1) % tickerQuotes.count
                withAnimation(.easeIn(duration: 0.4)) { opacity = 1 }
            }
        }
    }
}

// Matches MainApp.tsx TICKER_QUOTES exactly
private let tickerQuotes: [(text: String, color: String)] = [
    ("Free plan: $0. Your wallet lives another day 💀", "#9CA3AF"),
    ("Creator $4.99/mo — no watermark, no shame", "#DC2626"),
    ("Pro $9.99/mo — unlimited projects, unlimited chaos 🔥", "#DC2626"),
    ("Studio $19.99/mo — you're basically a whole studio now", "#A855F7"),
    ("Why watermark when you can WRECK mark? Creator: $4.99", "#DC2626"),
    ("50 AI queries/day on Pro — Spatter never sleeps 🧠", "#DC2626"),
    ("4K export on Pro... your stick figures in IMAX resolution", "#DC2626"),
    ("Collab rooms on Pro — animate together, die together ⚔️", "#DC2626"),
    ("Studio plan: commercial license. Sell your stick death art. Get rich. 💀💰", "#A855F7"),
    ("Free tier = 5 projects. That's 5 more than zero tbh", "#9CA3AF"),
    ("Unlimited AI on Studio — Spatter becomes your full-time employee", "#A855F7"),
    ("Creator plan removes the watermark. Your art. No branding. $4.99.", "#DC2626"),
    ("Team workspace on Studio — because chaos scales better together", "#A855F7"),
    ("Cloud sync on Pro — never lose a frame again. Unless you meant to 💀", "#DC2626"),
    ("API access on Studio — connect your stick deaths to literally anything", "#A855F7"),
    ("25 projects on Creator — that's like... 25 entire cinematic universes", "#DC2626"),
]
