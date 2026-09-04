import Foundation
import LiveKit

/// LiveKit integration for StickDeath ∞
/// Handles: video/audio calls, screen sharing, collab rooms, war rooms, watch together
/// Screen sharing reference: https://github.com/livekit/client-sdk-swift/blob/main/Docs/ios-screen-sharing.md
///
/// Rooms:
///   - DM calls (1:1 video/audio)
///   - War Room (2-player battle with spectators)
///   - Creator Room (1 host, many viewers + chat)
///   - Watch Together (synced video playback)
///   - Collab Room (multi-user canvas sharing)

class LiveKitService: ObservableObject {
    static let shared = LiveKitService()
    
    @Published var isConnected = false
    @Published var localParticipant: LocalParticipant?
    @Published var remoteParticipants: [RemoteParticipant] = []
    @Published var isMuted = false
    @Published var isVideoEnabled = true
    @Published var isScreenSharing = false
    
    private var room: Room?
    
    // LiveKit server config — resolved at runtime from AppConfig
    private var serverURL: String { AppConfig.liveKitWSURL }
    
    // MARK: - Connection
    
    func connect(roomName: String, token: String) async throws {
        let room = Room()
        self.room = room
        
        let connectOptions = ConnectOptions(
            autoSubscribe: true
        )
        
        let roomOptions = RoomOptions(
            defaultCameraCaptureOptions: CameraCaptureOptions(
                position: .front
            ),
            defaultAudioCaptureOptions: AudioCaptureOptions()
        )
        
        try await room.connect(url: serverURL, token: token, connectOptions: connectOptions, roomOptions: roomOptions)
        
        await MainActor.run {
            self.isConnected = true
            self.localParticipant = room.localParticipant
        }
    }
    
    func disconnect() async {
        await room?.disconnect()
        await MainActor.run {
            self.isConnected = false
            self.localParticipant = nil
            self.remoteParticipants = []
        }
    }
    
    // MARK: - Audio/Video Controls
    
    func toggleMute() async {
        guard let local = room?.localParticipant else { return }
        let newMuted = !isMuted
        try? await local.setMicrophone(enabled: !newMuted)
        await MainActor.run { isMuted = newMuted }
    }
    
    func toggleVideo() async {
        guard let local = room?.localParticipant else { return }
        let newEnabled = !isVideoEnabled
        try? await local.setCamera(enabled: newEnabled)
        await MainActor.run { isVideoEnabled = newEnabled }
    }
    
    // MARK: - Screen Sharing (iOS)
    // Uses Broadcast Upload Extension for system-level screen capture
    // See: ios-screen-sharing.md reference
    
    func startScreenShare() async throws {
        guard let local = room?.localParticipant else { return }
        
        // For iOS screen sharing, we use the Broadcast Upload Extension
        // The extension is configured in the app's Info.plist
        // RPSystemBroadcastPickerView is used to trigger the system picker
        try await local.setScreenShare(enabled: true)
        
        await MainActor.run { isScreenSharing = true }
    }
    
    func stopScreenShare() async {
        guard let local = room?.localParticipant else { return }
        try? await local.setScreenShare(enabled: false)
        await MainActor.run { isScreenSharing = false }
    }
    
    // MARK: - Data Channels (for peer-to-peer messaging)
    
    func sendData(_ data: Data, reliable: Bool = true) async throws {
        guard let local = room?.localParticipant else { return }
        try await local.publish(data: data, options: DataPublishOptions(
            reliable: reliable
        ))
    }
    
    // MARK: - Room Token Generation
    // In production, tokens are generated server-side
    // For development, use Supabase Edge Function
    
    func getToken(roomName: String, participantName: String) async throws -> String {
        guard let supabaseURL = URL(string: AppConfig.supabaseURL),
              !AppConfig.supabaseAnonKey.isEmpty else {
            throw NSError(domain: "LiveKitService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Supabase not configured"])
        }
        let tokenURL = supabaseURL.appendingPathComponent("functions/v1/livekit-token")
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(AppConfig.supabaseAnonKey)",
                    forHTTPHeaderField: "Authorization")
        
        let body: [String: String] = [
            "room": roomName,
            "participant": participantName
        ]
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        return response.token
    }
}

struct TokenResponse: Codable {
    let token: String
}
