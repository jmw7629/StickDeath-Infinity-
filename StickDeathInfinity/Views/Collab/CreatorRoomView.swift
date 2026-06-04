import SwiftUI

struct CreatorRoomView: View {
    @Environment(\.dismiss) private var dismiss
    
    struct LiveSession: Identifiable {
        let id = UUID()
        let host: String
        let topic: String
        let viewers: Int
        let isLive: Bool
        let scheduledTime: String?
    }
    
    let sessions: [LiveSession] = [
        LiveSession(host: "PixelFury", topic: "Advanced Sword Combos", viewers: 42, isLive: true, scheduledTime: nil),
        LiveSession(host: "AnimKing", topic: "Smooth Walk Cycles", viewers: 28, isLive: true, scheduledTime: nil),
        LiveSession(host: "NeonBlade", topic: "Particle Effects 101", viewers: 0, isLive: false, scheduledTime: "Today 5 PM"),
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
                Text("🎙️ Creator Room")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Text("● LIVE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.red)
                    .cornerRadius(8)
            }
            .padding()
            .background(Color(hex: "0A0A14"))
            
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(sessions) { session in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(session.topic)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text("Hosted by \(session.host)")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if session.isLive {
                                    Text("🟢 \(session.viewers) watching")
                                        .font(.system(size: 10))
                                        .foregroundColor(.green)
                                } else {
                                    Text(session.scheduledTime ?? "")
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange)
                                }
                            }
                            Button(action: {}) {
                                Text(session.isLive ? "Join Session →" : "Set Reminder 🔔")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(session.isLive ? Color.red : Color.white.opacity(0.06))
                                    .cornerRadius(8)
                            }
                        }
                        .padding()
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06)))
                    }
                    
                    Button(action: {}) {
                        Text("+ Start Your Own Session")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red, style: StrokeStyle(dash: [6])))
                            .cornerRadius(12)
                    }
                }
                .padding()
            }
        }
        .background(Color(hex: "0A0A14"))
        .navigationBarHidden(true)
    }
}
