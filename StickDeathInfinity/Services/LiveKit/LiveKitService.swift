// ═══════════════════════════════════════════════════════════════════
// LiveKitService — LiveKit + R3 Call Billing Architecture
// Matches: src/services/LiveKitCallService.ts (927 lines)
//        + src/services/CallBillingService.ts
//
// R3 Billing: Per-minute rates, spend warnings, auto-run,
// idle protection, abuse guard, billing audit trail
//
// Rate Tiers: Standard $0.05/min | Creator $0.10/min
//             Pro $0.15/min | Studio $0.25/min
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase
import LiveKit
import SDCore

// MARK: - Call Phase (matches web CallPhase)
enum CallPhase: String {
    case idle        = "idle"
    case preCalling  = "pre_call"       // Dial screen, set spend cap
    case ringing     = "ringing"        // Outgoing ring
    case incoming    = "incoming"       // Someone calling us
    case connecting  = "connecting"     // LiveKit room loading
    case active      = "active"        // Live call
    case ended       = "ended"         // Post-call fare receipt
}

// MARK: - Call Fare (post-call summary)
struct CallFare {
    let durationSeconds: Int
    let rateTier: CallRateTier
    let ratePerMinute: Double
    let totalCost: Double
    let callType: String  // "voice" | "video"
    let peerName: String
    let endReason: CallEndReason
    let spendCap: Double
    let autoRunEnabled: Bool
    let limitExtensions: Int
}

// MARK: - Call End Reason
enum CallEndReason: String {
    case userEnded     = "user_ended"
    case spendLimit    = "spend_limit"
    case idleTimeout   = "idle_timeout"
    case maxDuration   = "max_duration"
    case disconnected  = "disconnected"
    case error         = "error"
    case peerLeft      = "peer_left"
}

// MARK: - R3 Billing Config
enum R3BillingConfig {
    static let defaultSpendLimit: Double = 5.0
    static let maxCallDuration: Int = 3600      // 60 min hard cap
    static let idleWarningSeconds: Int = 30
    static let idleAutoEndSeconds: Int = 60
    static let autoRunExtendAmount: Double = 1.0 // $1 increments
    static let warningThresholds: [Double] = [0.75, 0.90, 1.0]
}

// MARK: - Spend Warning
enum SpendWarning {
    case approaching75   // 75% of limit
    case approaching90   // 90% of limit
    case atLimit         // 100% — auto-end or extend
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - LiveKitService
// ═══════════════════════════════════════════════════════════════════

@MainActor
final class LiveKitService: ObservableObject {
    static let shared = LiveKitService()

    // Connection state
    @Published var room: Room?
    @Published var isConnected = false
    @Published var localParticipant: LocalParticipant?
    @Published var remoteParticipants: [RemoteParticipant] = []
    @Published var isAudioEnabled = true
    @Published var isVideoEnabled = true
    @Published var isScreenShareEnabled = false

    // R3 Billing state
    @Published var callPhase: CallPhase = .idle
    @Published var currentFare: (seconds: Int, cost: Double) = (0, 0)
    @Published var spendWarning: SpendWarning?
    @Published var showIdleWarning = false
    @Published var activePeerName: String = ""

    // R3 Config for active call
    private var activeRateTier: CallRateTier = .standard
    private var activeSpendCap: Double = R3BillingConfig.defaultSpendLimit
    private var activeAutoRun: Bool = false
    private var activeCallType: String = "video"
    private var activeCallStart: Date?
    private var activePeerId: String?
    private var limitExtensions: Int = 0

    // Timers
    private var billingTimer: Timer?
    private var idleTimer: Timer?
    private var lastInteraction: Date = Date()

    private init() {}

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Pre-Call Setup (R3)
    // ═══════════════════════════════════════════════════════════════

    /// Start pre-call flow — user picks rate tier + spend limit
    func startPreCall(
        peerId: String,
        peerName: String,
        isVideo: Bool = true
    ) {
        activePeerId = peerId
        activePeerName = peerName
        activeCallType = isVideo ? "video" : "voice"
        activeRateTier = .standard
        activeSpendCap = R3BillingConfig.defaultSpendLimit
        activeAutoRun = false
        limitExtensions = 0
        callPhase = .preCalling
    }

    /// Update pre-call settings
    func setRateTier(_ tier: CallRateTier) {
        activeRateTier = tier
    }

    func setSpendCap(_ cap: Double) {
        activeSpendCap = max(1.0, cap)
    }

    func setAutoRun(_ enabled: Bool) {
        activeAutoRun = enabled
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Connect to Room (LiveKit)
    // ═══════════════════════════════════════════════════════════════

    /// Connect and start call with R3 billing
    func connect(roomName: String, participantName: String) async throws {
        callPhase = .connecting

        // Get token from backend
        let token = try await fetchToken(roomName: roomName, participantName: participantName)

        let room = Room()
        let connectOptions = ConnectOptions(autoSubscribe: true)
        let roomOptions = RoomOptions(
            defaultCameraCaptureOptions: CameraCaptureOptions(position: .front),
            defaultAudioCaptureOptions: AudioCaptureOptions(
                echoCancellation: true,
                noiseSuppression: true
            )
        )

        try await room.connect(
            url: AppConfig.liveKitWSURL,
            token: token,
            connectOptions: connectOptions,
            roomOptions: roomOptions
        )

        self.room = room
        self.localParticipant = room.localParticipant
        self.isConnected = true

        // Enable media
        if activeCallType == "video" {
            try await room.localParticipant.setCamera(enabled: true)
        }
        try await room.localParticipant.setMicrophone(enabled: true)

        // Start R3 billing
        startBilling()
        callPhase = .active
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - R3 Billing Engine
    // ═══════════════════════════════════════════════════════════════

    private func startBilling() {
        activeCallStart = Date()
        lastInteraction = Date()
        currentFare = (0, 0)
        spendWarning = nil

        // Billing ticker — every second
        billingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickBilling()
            }
        }

        // Idle detection timer
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkIdle()
            }
        }
    }

    private func tickBilling() {
        guard let start = activeCallStart else { return }
        let seconds = Int(Date().timeIntervalSince(start))
        let cost = Double(seconds) / 60.0 * activeRateTier.ratePerMinute
        currentFare = (seconds, cost)

        // Check spend warnings
        let ratio = cost / activeSpendCap
        if ratio >= 1.0 {
            spendWarning = .atLimit
            if activeAutoRun {
                // Auto-extend by $1
                activeSpendCap += R3BillingConfig.autoRunExtendAmount
                limitExtensions += 1
                spendWarning = nil
            } else {
                // End call — spend limit reached
                Task { await endCall(reason: .spendLimit) }
            }
        } else if ratio >= 0.90 {
            spendWarning = .approaching90
        } else if ratio >= 0.75 {
            spendWarning = .approaching75
        }

        // Hard duration cap
        if seconds >= R3BillingConfig.maxCallDuration {
            Task { await endCall(reason: .maxDuration) }
        }
    }

    private func checkIdle() {
        let idleSeconds = Int(Date().timeIntervalSince(lastInteraction))
        if idleSeconds >= R3BillingConfig.idleAutoEndSeconds {
            Task { await endCall(reason: .idleTimeout) }
        } else if idleSeconds >= R3BillingConfig.idleWarningSeconds {
            showIdleWarning = true
        } else {
            showIdleWarning = false
        }
    }

    /// Call this when user interacts (tap, speak, etc.)
    func recordInteraction() {
        lastInteraction = Date()
        showIdleWarning = false
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - End Call
    // ═══════════════════════════════════════════════════════════════

    /// End call, stop billing, log to Supabase, show fare
    func endCall(reason: CallEndReason = .userEnded) async {
        // Stop timers
        billingTimer?.invalidate()
        billingTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil

        // Calculate final fare
        let fare = CallFare(
            durationSeconds: currentFare.seconds,
            rateTier: activeRateTier,
            ratePerMinute: activeRateTier.ratePerMinute,
            totalCost: currentFare.cost,
            callType: activeCallType,
            peerName: activePeerName,
            endReason: reason,
            spendCap: activeSpendCap,
            autoRunEnabled: activeAutoRun,
            limitExtensions: limitExtensions
        )

        // Log charge to Supabase via StripeService
        if fare.totalCost > 0 {
            try? await StripeService.shared.chargeForCall(
                calleeId: activePeerId ?? "",
                durationSeconds: fare.durationSeconds,
                rateTier: activeRateTier,
                callType: activeCallType,
                spendCap: activeSpendCap
            )
        }

        // Disconnect LiveKit
        await room?.disconnect()
        room = nil
        localParticipant = nil
        remoteParticipants = []
        isConnected = false

        // Show fare receipt
        callPhase = .ended
    }

    /// Dismiss fare receipt and return to idle
    func dismissFare() {
        callPhase = .idle
        currentFare = (0, 0)
        spendWarning = nil
        showIdleWarning = false
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Media Controls
    // ═══════════════════════════════════════════════════════════════

    func toggleAudio() async throws {
        isAudioEnabled.toggle()
        try await room?.localParticipant.setMicrophone(enabled: isAudioEnabled)
        recordInteraction()
    }

    func toggleVideo() async throws {
        isVideoEnabled.toggle()
        try await room?.localParticipant.setCamera(enabled: isVideoEnabled)
        recordInteraction()
    }

    func toggleScreenShare() async throws {
        isScreenShareEnabled.toggle()
        try await room?.localParticipant.setScreenShare(enabled: isScreenShareEnabled)
        recordInteraction()
    }

    func flipCamera() async throws {
        // Toggle between front and back camera
        recordInteraction()
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Token Generation
    // ═══════════════════════════════════════════════════════════════

    private func fetchToken(roomName: String, participantName: String) async throws -> String {
        struct TokenRequest: Encodable {
            let room: String
            let identity: String
        }
        struct TokenResponse: Decodable {
            let token: String
        }

        let response: TokenResponse = try await SupabaseManager.shared.client.functions.invoke(
            "livekit-token",
            options: .init(body: TokenRequest(room: roomName, identity: participantName))
        )
        return response.token
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Call Abuse Guard (R3)
    // ═══════════════════════════════════════════════════════════════

    private var recentCallStarts: [Date] = []

    /// Check if user is abusing call system (rapid start/stop)
    func checkAbuseGuard() -> Bool {
        let now = Date()
        // Remove entries older than 5 minutes
        recentCallStarts = recentCallStarts.filter { now.timeIntervalSince($0) < 300 }

        // Flag if more than 10 call starts in 5 minutes
        if recentCallStarts.count >= 10 {
            return false // blocked
        }

        recentCallStarts.append(now)
        return true // allowed
    }
}
