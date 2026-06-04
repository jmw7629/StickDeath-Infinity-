import SwiftUI

struct WarRoomView: View {
    @State private var activeMatches: [WarMatch] = WarMatch.samples
    @State private var selectedMatch: WarMatch?
    @State private var isMatchmaking = false
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("⚔️")
                        .font(.system(size: 24))
                    Text("War Room")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { isMatchmaking = true }) {
                        Text("Find Match")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.red)
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                // Stats banner
                HStack(spacing: 16) {
                    StatPill(label: "W", value: "12", color: .green)
                    StatPill(label: "L", value: "3", color: .red)
                    StatPill(label: "Streak", value: "4🔥", color: .orange)
                    StatPill(label: "Rank", value: "#42", color: .purple)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                
                Divider().background(Color.white.opacity(0.06))
                
                // Active matches
                ScrollView {
                    VStack(spacing: 12) {
                        Text("ACTIVE BATTLES")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .tracking(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                        
                        ForEach(activeMatches) { match in
                            WarMatchCard(match: match) {
                                selectedMatch = match
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
        }
        .sheet(isPresented: $isMatchmaking) {
            MatchmakingView()
        }
    }
}

struct StatPill: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(hex: "12121A"))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
    }
}

struct WarMatchCard: View {
    let match: WarMatch
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                // VS header
                HStack {
                    // Player 1
                    VStack(spacing: 4) {
                        Text(match.player1Avatar)
                            .font(.system(size: 28))
                        Text(match.player1)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text("\(match.votes1) votes")
                            .font(.system(size: 9))
                            .foregroundColor(.red)
                    }
                    .frame(maxWidth: .infinity)
                    
                    // VS
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.2))
                            .frame(width: 36, height: 36)
                        Text("VS")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundColor(.red)
                    }
                    
                    // Player 2
                    VStack(spacing: 4) {
                        Text(match.player2Avatar)
                            .font(.system(size: 28))
                        Text(match.player2)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text("\(match.votes2) votes")
                            .font(.system(size: 9))
                            .foregroundColor(.blue)
                    }
                    .frame(maxWidth: .infinity)
                }
                
                // Vote bar
                GeometryReader { geo in
                    let total = max(match.votes1 + match.votes2, 1)
                    let leftWidth = CGFloat(match.votes1) / CGFloat(total) * geo.size.width
                    
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: leftWidth)
                        Rectangle()
                            .fill(Color.blue)
                    }
                    .frame(height: 4)
                    .cornerRadius(2)
                }
                .frame(height: 4)
                
                // Timer + spectators
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 9))
                        Text(match.timeLeft)
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundColor(.white.opacity(0.4))
                    
                    Spacer()
                    
                    HStack(spacing: 4) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 9))
                        Text("\(match.spectators) watching")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.white.opacity(0.4))
                }
            }
            .padding(16)
            .background(Color(hex: "12121A"))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct MatchmakingView: View {
    @State private var searchingTime = 0
    @Environment(\.dismiss) var dismiss
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            
            VStack(spacing: 24) {
                Spacer()
                
                // Pulsing circles
                ZStack {
                    ForEach(0..<3) { i in
                        Circle()
                            .stroke(Color.red.opacity(0.3 - Double(i) * 0.1), lineWidth: 2)
                            .frame(width: CGFloat(60 + i * 40), height: CGFloat(60 + i * 40))
                    }
                    Text("⚔️")
                        .font(.system(size: 36))
                }
                
                Text("Finding Opponent...")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                
                Text("Searching for \(searchingTime)s")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Text("Cancel")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.red, lineWidth: 1)
                        )
                }
                .padding(.bottom, 40)
            }
        }
        .onReceive(timer) { _ in
            searchingTime += 1
        }
    }
}

struct WarMatch: Identifiable {
    let id: String
    let player1: String
    let player1Avatar: String
    let player2: String
    let player2Avatar: String
    var votes1: Int
    var votes2: Int
    let timeLeft: String
    let spectators: Int
    
    static let samples: [WarMatch] = [
        WarMatch(id: "wm1", player1: "StickNinja99", player1Avatar: "🥷", player2: "xDeathArtist", player2Avatar: "💀", votes1: 45, votes2: 38, timeLeft: "2:45", spectators: 83),
        WarMatch(id: "wm2", player1: "AnimKing", player1Avatar: "👑", player2: "FightClubArt", player2Avatar: "🥊", votes1: 22, votes2: 31, timeLeft: "4:12", spectators: 47),
        WarMatch(id: "wm3", player1: "PixelWarrior", player1Avatar: "🛡️", player2: "StickLord", player2Avatar: "⚡", votes1: 67, votes2: 54, timeLeft: "0:38", spectators: 156),
    ]
}

struct WarRoomView_Previews: PreviewProvider {
    static var previews: some View {
        WarRoomView()
    }
}
