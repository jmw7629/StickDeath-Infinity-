import SwiftUI

struct WarRoomView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var timer: Int = 165  // 2:45
    @State private var votesLeft: Int = 45
    @State private var votesRight: Int = 38
    @State private var hasVoted = false
    
    var totalVotes: Int { votesLeft + votesRight }
    var leftPct: Int { totalVotes > 0 ? Int(round(Double(votesLeft) / Double(totalVotes) * 100)) : 50 }
    var rightPct: Int { 100 - leftPct }
    var timerString: String {
        "\(timer / 60):\(String(format: "%02d", timer % 60))"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.gray)
                        .font(.system(size: 18))
                }
                Spacer()
                HStack(spacing: 6) {
                    Text("⚔️")
                        .font(.system(size: 20))
                    Text("WAR ROOM")
                        .font(.custom("VT323", size: 18))
                        .fontWeight(.heavy)
                        .foregroundColor(.red)
                        .tracking(2)
                }
                Spacer()
                Text("\(totalVotes) votes")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            // Timer
            Text(timerString)
                .font(.system(size: 40, weight: .heavy, design: .monospaced))
                .foregroundColor(.white)
                .tracking(4)
                .padding(.bottom, 16)
            
            // VS Header
            HStack {
                Text("xDeathArtist")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.red)
                Spacer()
                Text("VS")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(.gray)
                Spacer()
                Text("StickNinja99")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.blue)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            
            // Side-by-side canvases
            HStack(spacing: 8) {
                // Left contestant
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: "141423").opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(
                        VStack(spacing: 8) {
                            Text("⚔️").font(.system(size: 48))
                            Text("Contestant A")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                    )
                
                // Right contestant
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: "141423").opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(
                        VStack(spacing: 8) {
                            Text("🥷").font(.system(size: 48))
                            Text("Contestant B")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                    )
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            
            // Vote bar
            VStack(spacing: 6) {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: geo.size.width * CGFloat(leftPct) / 100)
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: geo.size.width * CGFloat(rightPct) / 100)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)
                
                HStack {
                    Text("\(votesLeft) (\(leftPct)%)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red)
                    Spacer()
                    Text("\(votesRight) (\(rightPct)%)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            
            // Vote buttons
            HStack(spacing: 12) {
                Button(action: {
                    if !hasVoted { votesLeft += 1; hasVoted = true }
                }) {
                    Text("Vote Left 💖")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.red)
                        .cornerRadius(12)
                }
                
                Button(action: {
                    if !hasVoted { votesRight += 1; hasVoted = true }
                }) {
                    Text("Vote Right 💙")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue)
                        .cornerRadius(12)
                }
            }
            .padding(16)
        }
        .background(Color(hex: "0A0A14"))
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if timer > 0 { timer -= 1 }
        }
    }
}
