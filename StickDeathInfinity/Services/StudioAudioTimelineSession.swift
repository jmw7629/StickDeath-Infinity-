import Foundation
import AVFoundation
import Combine

/// Why a project clip would be inaudible in the mixed preview (#180). Mirrors
/// the mixer's gain rules, including SoundCraft solo, so the hint never claims
/// sound that the mix cannot produce.
enum StudioAudioPreviewSilence {
    static func reason(clipMuted: Bool, clipVolume: Double, trackMuted: Bool, trackVolume: Double, trackAudible: Bool) -> String? {
        if clipMuted || trackMuted { return "Preview is silent: clip or track is muted" }
        if !trackAudible { return "Preview is silent: another track is soloed" }
        if clipVolume == 0 || trackVolume == 0 { return "Preview is silent: clip or track volume is zero" }
        return nil
    }
    static func reason(for clip: AudioClip, in document: StudioDocument) -> String? {
        reason(clipMuted: clip.isMuted, clipVolume: clip.volume,
               trackMuted: document.isAudioTrackMuted(clip.track), trackVolume: document.audioTrackVolume(clip.track),
               trackAudible: document.isAudioTrackAudible(clip.track))
    }
}

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
    /// Non-nil while playing a 120-second window of a longer timeline (#180).
    @Published private(set) var window: StudioAudioPreviewWindow.Range?
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
    private var awaitingCompletionSince: TimeInterval?
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
              from start: Double, auditionVolume: Float = 1, loop: Bool = false,
              stillCurrent: @escaping () -> Bool,
              onTime: @escaping (Double, Bool) -> Void) -> Bool {
        guard !isPreparing, work == nil else { return false }
        stop()
        guard output == nil, Self.retainedOutput == nil, Self.retainedRecovery == nil else {
            notice = "The previous audio output needs safe recovery. Close or retry after restoring its ownership."; return false
        }
        guard Self.activeOwner == nil else { notice = "Another audio timeline is preparing or playing."; return false }
        guard stillCurrent(), duration.isFinite, duration > 0, duration <= 1300,
              start.isFinite, start >= 0, start < duration,
              auditionVolume.isFinite, (0...1).contains(auditionVolume), !document.audioClips.isEmpty else {
            notice = "Add saved audio and place the playhead inside the timeline before playing."; return false
        }
        // Timelines longer than one mix (120 s) play the window that starts at
        // the playhead (#180). The mixer still renders real clips; nothing is
        // invented for the parts of the timeline outside the window.
        var mixDocument = document, mixTracks = tracks, mixLength = duration, playerStart = start
        var windowRange: StudioAudioPreviewWindow.Range?
        if StudioAudioPreviewWindow.needsWindow(timelineDuration: duration) {
            guard let range = StudioAudioPreviewWindow.range(playhead: start, timelineDuration: duration),
                  let shifted = Self.windowed(document: document, tracks: tracks, range: range) else {
                notice = "No audio clips lie within the 120 seconds after the playhead. Move the playhead to a clip to preview it."
                return false
            }
            windowRange = range; mixDocument = shifted.document; mixTracks = shifted.tracks
            mixLength = range.length; playerStart = 0
        }
        let playsLoop = loop && windowRange == nil
        Self.activeOwner = ownerID
        let token = UUID(); generation = token
        self.stillCurrent = stillCurrent; self.onTime = onTime
        self.duration = duration; currentTime = start; progress = 0; notice = nil
        self.window = windowRange
        isPreparing = true
        // Retain the owner until this bounded task executes its deferred release,
        // even if the panel closes in the same actor turn before work starts.
        work = Task { [self] in
            defer {
                self.isPreparing = false; self.work = nil
                if !self.isPlaying && Self.activeOwner == self.ownerID { Self.activeOwner = nil }
            }
            do {
                let length = ceil(mixLength * StudioAudioMixService.sampleRate) / StudioAudioMixService.sampleRate
                let result = try await self.mixer.mix(document: mixDocument, retainedAudioTracks: mixTracks,
                    durationSeconds: length, outputParent: self.scratchParent) { [weak self] value in
                        try Task.checkCancellation()
                        await self?.setProgress(Double(value.completed) / Double(max(1, value.total)), token: token)
                    }
                // Own the result before any throwing cancellation/lease check.
                self.output = result
                try Task.checkCancellation()
                guard self.generation == token, stillCurrent() else { throw TimelineError.stale }
                // Activate the playback session before the player exists so the
                // ring switch cannot silence the mix (#180); failure is reported.
                try StudioAudioSessionController.shared.begin(owner: self.ownerID) { [weak self] event in
                    self?.handleSessionEvent(event)
                }
                let next = try AVAudioPlayer(contentsOf: result.checkedURL())
                guard next.duration.isFinite, abs(next.duration - length) <= 0.01 else { throw TimelineError.playback }
                next.delegate = self; next.numberOfLoops = playsLoop ? -1 : 0
                // The mixed file preserves exact gains/over-range samples. Only
                // audition gain is reduced, visibly, to avoid clipping playback.
                self.previewGain = 1 / max(1, Double(result.receipt.peakAbsoluteSample))
                next.volume = auditionVolume * Float(self.previewGain)
                next.currentTime = playerStart
                guard next.prepareToPlay() else { throw TimelineError.playback }
                self.player = next
                guard next.play(), next.isPlaying else { throw TimelineError.playback }
                self.isPlaying = true; self.playbackBegan = true; self.progress = 1
                if self.previewGain < 1 { self.notice = "Preview level reduced to avoid clipping. Clip volumes are unchanged." }
                if let windowRange {
                    self.notice = String(format: "Playing %.0f s from the playhead (%.1f–%.1f s). Timelines longer than 120 s preview one window at a time; looping is off.",
                                         windowRange.length, windowRange.start, windowRange.end)
                }
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
    func tick(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let player, stillCurrent?() == true else {
            stop(); return
        }
        guard player.isPlaying else {
            // The engine can stop before its completion delegate reaches this
            // actor. Keep that delegate and the owned mix alive until it reports
            // success; polling a stopped engine cannot certify the final time.
            if let since = awaitingCompletionSince, now - since >= 2 {
                stop()
                notice = "Audio stopped before playback completion was confirmed. Play again to retry."
            } else if awaitingCompletionSince == nil {
                awaitingCompletionSince = now
            }
            return
        }
        awaitingCompletionSince = nil
        currentTime = timelineTime(player.currentTime)
        onTime?(currentTime, true)
    }
    /// Player positions are window-relative when a window is active.
    private func timelineTime(_ playerTime: Double) -> Double {
        if let window { return StudioAudioPreviewWindow.timelineTime(playerTime: playerTime, range: window) }
        return min(duration, max(0, playerTime))
    }
    /// The clips of `document` that intersect `range`, re-based to the window,
    /// with only the assets they still reference. Nil when nothing is audible.
    static func windowed(document: StudioDocument, tracks: [AudioTrack],
                         range: StudioAudioPreviewWindow.Range) -> (document: StudioDocument, tracks: [AudioTrack])? {
        var clips: [AudioClip] = []
        for clip in document.audioClips {
            guard let span = StudioAudioPreviewWindow.clipped(.init(start: clip.startTime, duration: clip.duration, sourceOffset: clip.sourceOffset), to: range) else { continue }
            var copy = clip
            copy.startTime = span.start; copy.duration = span.duration; copy.sourceOffset = span.sourceOffset
            clips.append(copy)
        }
        guard !clips.isEmpty else { return nil }
        var shifted = document
        shifted.audioClips = clips
        let referenced = Set(clips.compactMap(\.assetID))
        return (shifted, tracks.filter { referenced.contains($0.id) })
    }
    func stop() {
        generation = UUID(); work?.cancel()
        releasePlayerAndOutput()
    }
    /// System interruption or lost output route: stop and say so (#180).
    func handleSessionEvent(_ event: StudioAudioSessionController.Event) {
        guard player != nil || isPreparing else { return }
        stop()
        notice = StudioAudioSessionController.message(for: event)
    }
    private func releasePlayerAndOutput() {
        timer?.invalidate(); timer = nil
        awaitingCompletionSince = nil
        player?.stop(); player?.delegate = nil; player = nil
        StudioAudioSessionController.shared.end(owner: ownerID)
        isPlaying = false
        window = nil
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
            if flag { self.currentTime = self.window?.end ?? self.duration }
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
