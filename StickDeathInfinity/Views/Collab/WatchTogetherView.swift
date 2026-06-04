import SwiftUI

struct WatchTogetherView: View {
    @State private var sessions: [WatchSession] = WatchSession.samples
    @State private var isCreating = false
    @State private var newTitle = ""
    @State private var selectedSession: WatchSession?
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Watch Together")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { isCreating = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("New Room")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red)
                        .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
                
                // Active sessions
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(sessions) { session in
                            WatchSessionCard(session: session) {
                                selectedSession = session
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            CreateWatchRoomSheet(title: $newTitle) {
                let session = WatchSession(
                    id: UUID().uuidString,
                    title: newTitle.isEmpty ? "Watch Room" : newTitle,
                    host: "J_Willy_Style",
                    viewers: 0,
                    thumbnail: "🎬",
                    isLive: true,
                    animationTitle: "My Animation"
                )
                sessions.insert(session, at: 0)
                newTitle = ""
                isCreating = false
            }
        }
    }
}

struct WatchSessionCard: View {
    let session: WatchSession
    let onJoin: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Preview area
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: "1A1A24"))
                    .frame(height: 140)
                
                VStack(spacing: 8) {
                    Text(session.thumbnail)
                        .font(.system(size: 48))
                    Text(session.animationTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                
                // Live indicator
                if session.isLive {
                    VStack {
                        HStack {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 6, height: 6)
                                Text("LIVE")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(4)
                            
                            Spacer()
                            
                            HStack(spacing: 2) {
                                Image(systemName: "eye.fill")
                                    .font(.system(size: 8))
                                Text("\(session.viewers)")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)
                        }
                        .padding(8)
                        
                        Spacer()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            
            // Info
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("Hosted by \(session.host)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
                
                Spacer()
                
                Button(action: onJoin) {
                    Text("Join")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.red)
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .padding(12)
        .background(Color(hex: "12121A"))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

struct CreateWatchRoomSheet: View {
    @Binding var title: String
    let onCreate: () -> Void
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "0A0A0F").ignoresSafeArea()
                VStack(spacing: 16) {
                    TextField("Room Name", text: $title)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .padding()
                        .background(Color(hex: "1A1A24"))
                        .cornerRadius(12)
                    
                    Button(action: onCreate) {
                        Text("Create Room")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .cornerRadius(12)
                    }
                    
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("New Watch Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct WatchSession: Identifiable {
    let id: String
    let title: String
    let host: String
    let viewers: Int
    let thumbnail: String
    let isLive: Bool
    let animationTitle: String
    
    static let samples: [WatchSession] = [
        WatchSession(id: "ws1", title: "Epic Battle Marathon", host: "StickNinja99", viewers: 42, thumbnail: "⚔️", isLive: true, animationTitle: "Last Stand"),
        WatchSession(id: "ws2", title: "Speed Run Showcase", host: "AnimKing", viewers: 18, thumbnail: "🏃", isLive: true, animationTitle: "Speed Run"),
        WatchSession(id: "ws3", title: "Art Review Session", host: "xDeathArtist", viewers: 7, thumbnail: "🎨", isLive: false, animationTitle: "Combo Attack"),
    ]
}

struct WatchTogetherView_Previews: PreviewProvider {
    static var previews: some View {
        WatchTogetherView()
    }
}
