import Foundation
import AVFoundation
import Combine

/// A bounded, real offline mix followed by one actual player clock. No network,
/// microphone or rendered-video export. Immutable owned bytes outlive the player.
@MainActor
final class StudioAudioTimelineSession: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPreparing = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var progress = 0.0
    @Published private(set) var notice: String?
    @Published private(set) var previewGain = 1.0
    private let mixer = StudioAudioMixService()
    private let scratchParent: URL
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var output: StudioAudioMixService.Output?
    // One process-wide session owns preparation/playback. Failed outputs retain
    // their captured recovery handles across panel dismissal, never guessed paths.
    private static var activeOwner: UUID?
    private static var retainedOutput: StudioAudioMixService.Output?
    private static var retainedRecovery: StudioAudioMixService.Recovery?
    private let ownerID = UUID()
    private var playbackBegan = false
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var stillCurrent: (() -> Bool)?
    private var onTime: ((Double, Bool) -> Void)?
    var actualPlayerIsPlaying: Bool { player?.isPlaying == true }
    var actualPlayerVolume: Float? { player?.volume }

    init(scratchParent: URL = FileManager.default.temporaryDirectory) {
        self.scratchParent = scratchParent
        super.init()
    }

    @discardableResult
    func play(document: StudioDocument, tracks: [AudioTrack], duration: Double,
              from start: Double, auditionVolume: Float = 1,
              stillCurrent: @escaping () -> Bool,
              onTime: @escaping (Double, Bool) -> Void) -> Bool {
        guard !isPreparing, work == nil else { return false }
        stop()
        guard output == nil, Self.retainedOutput == nil, Self.retainedRecovery == nil else {
            notice = "The previous audio output needs safe recovery. Close or retry after restoring its ownership."; return false
        }
        guard Self.activeOwner == nil else { notice = "Another audio timeline is preparing or playing."; return false }
        guard stillCurrent(), duration.isFinite, duration > 0, duration <= 120,
              start.isFinite, start >= 0, start < duration,
              auditionVolume.isFinite, (0...1).contains(auditionVolume), !document.audioClips.isEmpty else {
            notice = "Add saved audio and select a playhead within the 120-second preview limit."; return false
        }
        Self.activeOwner = ownerID
        let token = UUID(); generation = token
        self.stillCurrent = stillCurrent; self.onTime = onTime
        self.duration = duration; currentTime = start; progress = 0; notice = nil
        isPreparing = true
        // Retain the owner until this bounded task executes its deferred release,
        // even if the panel closes in the same actor turn before work starts.
        work = Task { [self] in
            defer {
                self.isPreparing = false; self.work = nil
                if !self.isPlaying && Self.activeOwner == self.ownerID { Self.activeOwner = nil }
            }
            do {
                let length = ceil(duration * StudioAudioMixService.sampleRate) / StudioAudioMixService.sampleRate
                let result = try await self.mixer.mix(document: document, retainedAudioTracks: tracks,
                    durationSeconds: length, outputParent: self.scratchParent) { [weak self] value in
                        try Task.checkCancellation()
                        await self?.setProgress(Double(value.completed) / Double(max(1, value.total)), token: token)
                    }
                // Own the result before any throwing cancellation/lease check.
                self.output = result
                try Task.checkCancellation()
                guard self.generation == token, stillCurrent() else { throw TimelineError.stale }
                let next = try AVAudioPlayer(contentsOf: result.checkedURL())
                guard next.duration.isFinite, abs(next.duration - length) <= 0.01 else { throw TimelineError.playback }
                next.delegate = self; next.numberOfLoops = 0
                // The mixed file preserves exact gains/over-range samples. Only
                // audition gain is reduced, visibly, to avoid clipping playback.
                self.previewGain = 1 / max(1, Double(result.receipt.peakAbsoluteSample))
                next.volume = auditionVolume * Float(self.previewGain)
                next.currentTime = start
                guard next.prepareToPlay() else { throw TimelineError.playback }
                self.player = next
                guard next.play(), next.isPlaying else { throw TimelineError.playback }
                self.isPlaying = true; self.playbackBegan = true; self.progress = 1
                if self.previewGain < 1 { self.notice = "Preview level reduced to avoid clipping. Clip volumes are unchanged." }
                onTime(start, true)
                self.timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
            } catch {
                if let failure = error as? StudioAudioMixService.Failure {
                    Self.retainedRecovery = failure.recovery
                }
                self.releasePlayerAndOutput()
                if self.notice == nil {
                    self.notice = error is CancellationError ? "Audio preparation cancelled." : error.localizedDescription
                }
            }
        }
        return true
    }
    private func setProgress(_ value: Double, token: UUID) {
        guard token == generation else { return }
        progress = min(1, max(0, value))
    }
    private func tick() {
        guard let player, stillCurrent?() == true else {
            stop(); return
        }
        currentTime = min(duration, max(0, player.currentTime))
        if !player.isPlaying { stop(); return }
        onTime?(currentTime, true)
    }
    func stop() {
        generation = UUID(); work?.cancel()
        releasePlayerAndOutput()
    }
    private func releasePlayerAndOutput() {
        timer?.invalidate(); timer = nil
        player?.stop(); player?.delegate = nil; player = nil
        isPlaying = false
        let callback = playbackBegan ? onTime : nil
        playbackBegan = false; onTime = nil; stillCurrent = nil
        if let output {
            do { try output.cleanup(); self.output = nil }
            catch {
                Self.retainedOutput = output; self.output = nil
                notice = "Audio stopped. A changed output was preserved for safe recovery."
            }
        }
        // Never remove unfamiliar files; each retained object checks its original
        // descriptors and file identities. Only one active owner can create these.
        if let held = Self.retainedOutput {
            do { try held.cleanup(); Self.retainedOutput = nil }
            catch { notice = "Audio stopped. Output recovery is still required." }
        }
        if let held = Self.retainedRecovery {
            do { try held.cleanup(); Self.retainedRecovery = nil }
            catch { notice = "Audio stopped. Output recovery is still required." }
        }
        if !isPreparing && Self.activeOwner == ownerID { Self.activeOwner = nil }
        callback?(currentTime, false)
    }
    func close() { stop() }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == id else { return }
            if flag { self.currentTime = self.duration }
            self.stop()
            if !flag { self.notice = "Audio playback ended with an error." }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == id else { return }
            self.stop(); self.notice = "The audio device could not decode this prepared mix."
        }
    }
    private enum TimelineError: LocalizedError {
        case stale, playback
        var errorDescription: String? {
            switch self {
            case .stale: return "The project changed while audio was preparing. Play the current version again."
            case .playback: return "Mixed audio playback could not start on this device."
            }
        }
    }
}
