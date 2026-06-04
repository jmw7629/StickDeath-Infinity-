import SwiftUI

struct LeaderboardView: View {
    @Environment(\.dismiss) private var dismiss
    
    struct Leader: Identifiable {
        let id = UUID()
        let rank: Int
        let name: String
        let avatar: String
        let xp: Int
        let wins: Int
        let streak: Int
    }
    
    let leaders: [Leader] = [
        Leader(rank: 1, name: "PixelFury", avatar: "🔥", xp: 12450, wins: 89, streak: 14),
        Leader(rank: 2, name: "NeonBlade", avatar: "⚡", xp: 11200, wins: 76, streak: 8),
        Leader(rank: 3, name: "AnimKing", avatar: "👑", xp: 10800, wins: 72, streak: 12),
        Leader(rank: 4, name: "StickNinja99", avatar: "🥷", xp: 9600, wins: 65, streak: 5),
        Leader(rank: 5, name: "xDeathArtist", avatar: "💀", xp: 8900, wins: 58, streak: 3),
        Leader(rank: 6, name: "J_Willy_Style", avatar: "👑", xp: 8400, wins: 52, streak: 7),
        Leader(rank: 7, name: "DeathDraw", avatar: "✏️", xp: 7200, wins: 45, streak: 2),
        Leader(rank: 8, name: "StickMaster", avatar: "💀", xp: 6800, wins: 41, streak: 1),
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
                Text("🏆 Leaderboard")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding()
            .background(Color(hex: "0A0A14"))
            
            // Top 3 podium
            HStack(alignment: .bottom, spacing: 12) {
                // 2nd place
                podiumColumn(leader: leaders[1], medal: "🥈", height: 90)
                // 1st place
                podiumColumn(leader: leaders[0], medal: "🥇", height: 110)
                // 3rd place
                podiumColumn(leader: leaders[2], medal: "🥉", height: 70)
            }
            .padding(.vertical, 20)
            .padding(.horizontal)
            
            // Rest of leaderboard
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(leaders.dropFirst(3))) { leader in
                        HStack(spacing: 10) {
                            Text("#\(leader.rank)")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(width: 24)
                            Text(leader.avatar)
                                .font(.system(size: 20))
                            VStack(alignment: .leading) {
                                Text(leader.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                Text("\(leader.xp.formatted()) XP · \(leader.wins) wins · 🔥 \(leader.streak)")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        Divider().background(Color.white.opacity(0.03))
                    }
                }
                .padding(.horizontal)
            }
        }
        .background(Color(hex: "0A0A14"))
        .navigationBarHidden(true)
    }
    
    @ViewBuilder
    func podiumColumn(leader: Leader, medal: String, height: CGFloat) -> some View {
        VStack(spacing: 4) {
            Text(medal).font(.system(size: 24))
            Text(leader.avatar).font(.system(size: 28))
            Text(leader.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [.red, .red.opacity(0.3)], startPoint: .bottom, endPoint: .top))
                    .frame(height: height)
                Text("\(leader.xp.formatted()) XP")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(.white)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
