import SwiftUI

struct WatchTogetherView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var progress: Double = 12
    @State private var isPlaying = true
    @State private var reactions: [FloatingReaction] = []
    @State private var chatMessages: [WatchChat] = [
        WatchChat(user: "StickNinja99", message: "this part is insane 🔥", color: .green),
        WatchChat(user: "AnimKing", message: "watch the dodge at 0:15", color: .yellow),
        WatchChat(user: "xDeathArtist", message: "took me 6 hours 💀", color: .red),
    ]
    
    let totalDuration: Double = 45
    let reactionEmojis = ["🔥", "💀", "😂", "👏", "❤️"]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.gray)
                        .font(.system(size: 18))
                }
                Text("Watch Together")
                    .font(.custom("VT323", size: 17))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Spacer()
                Text("4 watching")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.green)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(hex: "0A0A14"))
            
            Divider().background(Color.white.opacity(0.06))
            
            // Video area
            ZStack {
                Color(hex: "0A0A12")
                Text("🏃")
                    .font(.system(size: 64))
                
                // Floating reactions
                ForEach(reactions) { reaction in
                    Text(reaction.emoji)
                        .font(.system(size: 28))
                        .offset(x: reaction.x, y: reaction.y)
                        .opacity(reaction.opacity)
                        .animation(.easeOut(duration: 1.5), value: reaction.opacity)
                }
            }
            .frame(maxHeight: .infinity)
            
            // Progress bar
            HStack(spacing: 8) {
                Button(action: { isPlaying.toggle() }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 12))
                        .frame(width: 32, height: 32)
                        .background(Color.red.opacity(0.2))
                        .clipShape(Circle())
                }
                
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 4)
                        Capsule()
                            .fill(Color.red)
                            .frame(width: geo.size.width * (progress / totalDuration), height: 4)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        progress = (location.x / geo.size.width) * totalDuration
                    }
                }
                .frame(height: 4)
                
                Text("0:\(String(format: "%02d", Int(progress))) / 0:45")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            
            Divider().background(Color.white.opacity(0.06))
            
            // Reaction emojis
            HStack(spacing: 20) {
                ForEach(reactionEmojis, id: \.self) { emoji in
                    Button(action: { addReaction(emoji) }) {
                        Text(emoji)
                            .font(.system(size: 24))
                    }
                }
            }
            .padding(.vertical, 10)
            
            Divider().background(Color.white.opacity(0.06))
            
            // Live chat
            VStack(alignment: .leading, spacing: 6) {
                ForEach(chatMessages) { msg in
                    HStack(spacing: 4) {
                        Text("\(msg.user):")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(msg.color)
                        Text(msg.message)
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(hex: "0A0A14"))
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if isPlaying {
                progress = progress < totalDuration ? progress + 1 : 0
            }
        }
    }
    
    private func addReaction(_ emoji: String) {
        let reaction = FloatingReaction(
            emoji: emoji,
            x: CGFloat.random(in: -80...80),
            y: CGFloat.random(in: -120...(-30)),
            opacity: 1.0
        )
        reactions.append(reaction)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            reactions.removeAll { $0.id == reaction.id }
        }
    }
}

struct FloatingReaction: Identifiable {
    let id = UUID()
    let emoji: String
    let x: CGFloat
    let y: CGFloat
    var opacity: Double
}

struct WatchChat: Identifiable {
    let id = UUID()
    let user: String
    let message: String
    let color: Color
}
