import SwiftUI

struct CallsView: View {
    @State private var callActive = false
    @State private var callTimer = 0
    @State private var timer: Timer?
    
    struct RecentCall: Identifiable {
        let id = UUID()
        let name: String
        let type: String // "video" or "audio"
        let direction: String // "incoming", "outgoing", "missed"
        let time: String
        let duration: String
        let avatar: String
    }
    
    let recentCalls: [RecentCall] = [
        RecentCall(name: "PixelFury", type: "video", direction: "incoming", time: "2 min ago", duration: "12:34", avatar: "🔥"),
        RecentCall(name: "AnimKing", type: "audio", direction: "outgoing", time: "1h ago", duration: "5:22", avatar: "👑"),
        RecentCall(name: "NeonBlade", type: "video", direction: "missed", time: "3h ago", duration: "-", avatar: "⚡"),
        RecentCall(name: "StickMaster", type: "audio", direction: "incoming", time: "Yesterday", duration: "8:45", avatar: "💀"),
    ]
    
    var body: some View {
        if callActive {
            // Active call screen
            VStack(spacing: 16) {
                Spacer()
                Text("🔥")
                    .font(.system(size: 64))
                Text("PixelFury")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                Text(String(format: "%02d:%02d", callTimer / 60, callTimer % 60))
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.green)
                Spacer()
                HStack(spacing: 24) {
                    callButton(icon: "mic.fill", label: "Mute")
                    callButton(icon: "video.fill", label: "Video")
                    Button(action: {
                        callActive = false
                        callTimer = 0
                        timer?.invalidate()
                    }) {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .background(Color.red)
                            .clipShape(Circle())
                    }
                }
                .padding(.bottom, 60)
            }
            .background(LinearGradient(colors: [Color(hex: "1a0a0a"), Color(hex: "0A0A14")], startPoint: .top, endPoint: .bottom))
            .onAppear {
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    callTimer += 1
                }
            }
        } else {
            // Call history
            VStack(spacing: 0) {
                HStack {
                    Text("📞 Calls")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { callActive = true }) {
                        Text("+ New Call")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.green)
                            .cornerRadius(20)
                    }
                }
                .padding()
                .background(Color(hex: "0A0A14"))
                
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(recentCalls) { call in
                            HStack(spacing: 12) {
                                Text(call.avatar)
                                    .font(.system(size: 24))
                                VStack(alignment: .leading) {
                                    Text(call.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white)
                                    HStack(spacing: 4) {
                                        Text(call.direction == "incoming" ? "↙" : call.direction == "outgoing" ? "↗" : "✕")
                                        Text(call.type == "video" ? "Video" : "Audio")
                                        Text("·")
                                        Text(call.time)
                                        Text("·")
                                        Text(call.duration)
                                    }
                                    .font(.system(size: 10))
                                    .foregroundColor(call.direction == "missed" ? .red : .secondary)
                                }
                                Spacer()
                                Button(action: { callActive = true }) {
                                    Image(systemName: call.type == "video" ? "video.fill" : "phone.fill")
                                        .foregroundColor(.green)
                                        .padding(6)
                                        .background(Color.green.opacity(0.15))
                                        .clipShape(Circle())
                                }
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal)
                            Divider().background(Color.white.opacity(0.03))
                        }
                    }
                }
            }
            .background(Color(hex: "0A0A14"))
        }
    }
    
    @ViewBuilder
    func callButton(icon: String, label: String) -> some View {
        Button(action: {}) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
        }
    }
}
