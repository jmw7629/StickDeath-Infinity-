// ═══════════════════════════════════════════════════════════════════
// PricingTickerView — Existing corner overlay with factual local Studio tips
// Historical type name retained; this toast makes no pricing or entitlement claims.
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

// Manual tips for existing local controls, not subscriptions or completed actions.
private let tickerQuotes: [(text: String, color: String)] = [
    ("Your projects stay on this device. Back up the good chaos to Files 💀", "#9CA3AF"),
    ("Wrong stroke? Undo has your back. Keep the mayhem editable 💀", "#DC2626"),
    ("Onion skin shows neighboring frames. Give that skeleton some timing 💀", "#DC2626"),
    ("Export makes a file, not a public post. You choose what leaves the crypt 💀", "#A855F7"),
]
