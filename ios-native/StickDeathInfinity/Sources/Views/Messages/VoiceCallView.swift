// VoiceCallView.swift
// Pay-As-You-Go taxi-meter billing for voice & video calls

import SwiftUI

struct VoiceCallView: View {
    @Environment(\.dismiss) var dismiss
    let channelName: String

    @State private var activeTab: CallTab = .voice
    @State private var muted = false
    @State private var speaker = false
    @State private var screenShare = false
    @State private var elapsed: Int = 0
    @State private var callActive = false
    @State private var showBillingSummary = false
    @State private var showRateCard = true
    @State private var timer: Timer?

    enum CallTab: String, CaseIterable { case voice, video }

    private let voiceRate: Double = 0.02
    private let videoRate: Double = 0.08
    private var currentRate: Double { activeTab == .video ? videoRate : voiceRate }
    private var currentCost: Double { (Double(elapsed) / 60.0) * currentRate }

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            if showBillingSummary {
                billingSummaryView
            } else if showRateCard {
                rateCardView
            } else {
                activeCallView
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: - Rate Card (before call starts)
    var rateCardView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                Text(activeTab == .video ? "📹" : "📞")
                    .font(.system(size: 48))
                Text("Start a Call")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Text(channelName)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "#72728a"))

                // Tab toggle
                HStack(spacing: 4) {
                    ForEach(CallTab.allCases, id: \.self) { tab in
                        Button {
                            activeTab = tab
                        } label: {
                            Text(tab == .voice ? "🎙️ Voice" : "📹 Video")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(activeTab == tab ? .white : Color(hex: "#72728a"))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(activeTab == tab ? ThemeManager.card : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(activeTab == tab ? ThemeManager.border : .clear, lineWidth: 1)
                                )
                        }
                    }
                }
                .padding(4)
                .background(Color(hex: "#1a1a24"))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Rate info
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("🚕")
                            .font(.system(size: 20))
                        Text("Pay-As-You-Go")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.bottom, 12)

                    rateRow(emoji: "🎙️", label: "Voice calls", rate: "$0.02")
                    Divider().overlay(ThemeManager.border)
                    rateRow(emoji: "📹", label: "Video calls", rate: "$0.08")
                }
                .padding(16)
                .background(Color(hex: "#1a1a24"))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Text("You'll only be charged for the time you use. No minimums.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "#72728a"))
                    .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    Button { dismiss() } label: {
                        Text("Cancel")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(hex: "#9090a8"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(hex: "#1a1a24"))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ThemeManager.border, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button { startCall() } label: {
                        Text("Start \(activeTab == .video ? "Video" : "Voice") Call")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(ThemeManager.brand)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(28)
            .background(ThemeManager.card)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(ThemeManager.border, lineWidth: 1))
            .padding(.horizontal, 32)
            Spacer()
        }
    }

    // MARK: - Active Call with Taxi Meter
    var activeCallView: some View {
        VStack(spacing: 0) {
            // Header with live billing badge
            HStack(spacing: 12) {
                Button { endCall() } label: {
                    Text("←")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }
                Text("\(activeTab == .voice ? "Voice" : "Video") Call")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                // Live cost badge
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hex: "#22c55e"))
                        .frame(width: 6, height: 6)
                    Text(String(format: "$%.4f", currentCost))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hex: "#22c55e"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(hex: "#22c55e").opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color(hex: "#22c55e").opacity(0.3), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            .padding(16)

            // Voice/Video toggle
            HStack(spacing: 4) {
                ForEach(CallTab.allCases, id: \.self) { tab in
                    Button { activeTab = tab } label: {
                        Text(tab.rawValue.capitalized)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(activeTab == tab ? .white : Color(hex: "#72728a"))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                            .background(activeTab == tab ? ThemeManager.card : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(4)
            .background(Color(hex: "#1a1a24"))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.top, 16)

            // Waiting for others
            Spacer()
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(ThemeManager.brand, lineWidth: 3)
                        .frame(width: 100, height: 100)
                        .shadow(color: ThemeManager.brand.opacity(0.25), radius: 10)
                    Text(activeTab == .video ? "📹" : "🎙️")
                        .font(.system(size: 36))
                }
                Text("Waiting for others...")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Share the room link to invite")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "#72728a"))
            }
            Spacer()

            // Taxi meter
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DURATION")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(hex: "#72728a"))
                        Text(formatTime(elapsed))
                            .font(.system(size: 28, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("RUNNING COST")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(hex: "#72728a"))
                        Text(String(format: "$%.2f", currentCost))
                            .font(.system(size: 28, weight: .heavy, design: .monospaced))
                            .foregroundStyle(Color(hex: "#22c55e"))
                    }
                }
                Divider().overlay(ThemeManager.border)
                HStack {
                    Text("Rate: $\(String(format: "%.2f", currentRate))/min (\(activeTab.rawValue))")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "#72728a"))
                    Spacer()
                    Text("🚕 Metered")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "#72728a"))
                }
            }
            .padding(16)
            .background(ThemeManager.card)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(ThemeManager.border, lineWidth: 1))
            .padding(.horizontal, 24)

            // Controls
            HStack(spacing: 20) {
                callControl(icon: muted ? "🔇" : "🎙️", label: muted ? "Unmute" : "Mute", active: muted) {
                    muted.toggle()
                }
                callControl(icon: speaker ? "🔈" : "🔊", label: "Speaker", active: speaker) {
                    speaker.toggle()
                }
                callControl(icon: "📱", label: "Screen", active: screenShare) {
                    screenShare.toggle()
                }
            }
            .padding(.vertical, 16)

            // End call
            Button { endCall() } label: {
                Circle()
                    .fill(ThemeManager.brand)
                    .frame(width: 64, height: 64)
                    .overlay(Text("📞").font(.system(size: 24)))
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: - Billing Summary
    var billingSummaryView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                Text("📞").font(.system(size: 48))
                Text("Call Ended")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Text(channelName)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "#72728a"))

                VStack(spacing: 12) {
                    billRow(label: "Duration", value: formatTime(elapsed))
                    billRow(label: "Type", value: activeTab == .video ? "📹 Video" : "🎙️ Voice")
                    billRow(label: "Rate", value: activeTab == .video ? "$0.08/min" : "$0.02/min")
                    Divider().overlay(ThemeManager.border)
                    HStack {
                        Text("Total")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                        Spacer()
                        Text(String(format: "$%.2f", currentCost))
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundStyle(Color(hex: "#22c55e"))
                    }
                }
                .padding(16)
                .background(Color(hex: "#1a1a24"))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Text("Charged to your account balance")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "#72728a"))

                Button { dismiss() } label: {
                    Text("Done")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(ThemeManager.brand)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(28)
            .background(ThemeManager.card)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(ThemeManager.border, lineWidth: 1))
            .padding(.horizontal, 32)
            Spacer()
        }
    }

    // MARK: - Helpers
    func rateRow(emoji: String, label: String, rate: String) -> some View {
        HStack {
            Text("\(emoji) \(label)")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "#9090a8"))
            Spacer()
            HStack(spacing: 0) {
                Text(rate)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(hex: "#22c55e"))
                Text("/min")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "#72728a"))
            }
        }
        .padding(.vertical, 8)
    }

    func billRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "#9090a8"))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    func callControl(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Circle()
                    .fill(active ? ThemeManager.brand : Color(hex: "#1a1a24"))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Circle().stroke(active ? ThemeManager.brand : ThemeManager.border, lineWidth: 1)
                    )
                    .overlay(Text(icon).font(.system(size: 22)))
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(active ? .white : Color(hex: "#72728a"))
        }
    }

    func formatTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    func startCall() {
        showRateCard = false
        callActive = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsed += 1
        }
    }

    func endCall() {
        callActive = false
        timer?.invalidate()
        timer = nil
        showBillingSummary = true
    }
}
