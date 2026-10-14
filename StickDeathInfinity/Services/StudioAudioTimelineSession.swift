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
    /// Measured audio-clock drift for the current or last playback (#180).
    @Published private(set) var driftReport = StudioAudioDriftMonitor.Report()
    private var drift = StudioAudioDriftMonitor()
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
              frameClock: StudioAudioTransport.FrameClock? = nil,
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
        let fps = frameClock?.fps ?? 24
        drift = StudioAudioDriftMonitor(bound: StudioAudioDriftMonitor.bound(fps: fps), frameClock: frameClock)
        driftReport = drift.report
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
        // The animation follows the player clock. Measure that clock against the
        // monotonic host clock; a player that claims to play but stops advancing
        // stops honestly instead of freezing the animation behind silent output.
        if drift.observe(host: now, player: player.currentTime) == .stalled {
            driftReport = drift.report
            stop()
            notice = "Audio output stopped advancing, so playback stopped. Check the output device and play again."
            return
        }
        driftReport = drift.report
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

/// Audible scrubbing for the audio workspace ruler (#180). Each grain is a real
/// offline mix of the project's clips over a short window starting at the
/// scrub position, played once by an actual player. Requests during
/// preparation coalesce to the newest position; positions without clips stay
/// silent rather than playing invented sound. No network or microphone.
@MainActor
final class StudioAudioScrubAudition: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPreparing = false
    @Published private(set) var lastGrain: StudioAudioPreviewWindow.Range?
    @Published private(set) var notice: String?
    var actualPlayerIsPlaying: Bool { player?.isPlaying == true }

    private struct Source {
        let document: StudioDocument
        let tracks: [AudioTrack]
        let timelineDuration: Double
        let stillCurrent: () -> Bool
    }
    private let mixer = StudioAudioMixService()
    private let scratchParent: URL
    private var planner = StudioAudioScrubPlanner()
    private var source: Source?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var player: AVAudioPlayer?
    private var output: StudioAudioMixService.Output?
    /// Outputs or failed-mix directories whose cleanup must be retried; never guessed paths.
    private var heldOutputs: [StudioAudioMixService.Output] = []
    private var heldRecoveries: [StudioAudioMixService.Recovery] = []
    private var whenIdle: [() -> Void] = []
    private let ownerID = UUID()
    private let auditionVolume: Float

    init(scratchParent: URL = FileManager.default.temporaryDirectory, auditionVolume: Float = 1) {
        self.scratchParent = scratchParent
        self.auditionVolume = auditionVolume.isFinite ? min(1, max(0, auditionVolume)) : 1
        super.init()
    }

    /// Request a grain at `time`. Returns false when nothing will sound because
    /// the request is stale, outside the timeline or the project has no audio.
    @discardableResult
    func scrub(document: StudioDocument, tracks: [AudioTrack], timelineDuration: Double, at time: Double,
               stillCurrent: @escaping () -> Bool) -> Bool {
        guard stillCurrent(), !document.audioClips.isEmpty, timelineDuration.isFinite, timelineDuration > 0 else { return false }
        source = Source(document: document, tracks: tracks, timelineDuration: timelineDuration, stillCurrent: stillCurrent)
        switch planner.request(time: time, timelineDuration: timelineDuration) {
        case .start(let range): return begin(range)
        case .queued: return true
        case .ignored: return false
        }
    }

    private func begin(_ range: StudioAudioPreviewWindow.Range) -> Bool {
        guard let source, source.stillCurrent(),
              let shifted = StudioAudioTimelineSession.windowed(document: source.document, tracks: source.tracks, range: range) else {
            // A silent position: no clip intersects the grain. Nothing plays.
            settle()
            return false
        }
        releasePlayer()
        let token = UUID(); generation = token
        isPreparing = true; notice = nil
        work = Task { [self] in
            defer { self.work = nil; self.settle() }
            do {
                let length = ceil(range.length * StudioAudioMixService.sampleRate) / StudioAudioMixService.sampleRate
                let result = try await self.mixer.mix(document: shifted.document, retainedAudioTracks: shifted.tracks,
                    durationSeconds: length, outputParent: self.scratchParent)
                guard self.generation == token, !Task.isCancelled, source.stillCurrent() else {
                    self.discard(result); return
                }
                self.output = result
                try StudioAudioSessionController.shared.begin(owner: self.ownerID) { [weak self] event in
                    guard let self, self.player != nil else { return }
                    self.releasePlayer()
                    self.notice = StudioAudioSessionController.message(for: event)
                }
                let next = try AVAudioPlayer(contentsOf: result.checkedURL())
                next.delegate = self; next.numberOfLoops = 0
                // Same anti-clipping rule as the full preview; clip volumes are unchanged.
                next.volume = self.auditionVolume * Float(1 / max(1, Double(result.receipt.peakAbsoluteSample)))
                guard next.prepareToPlay() else { throw StudioAudioMixService.MixError.codecFailure }
                self.player = next
                guard next.play(), next.isPlaying else { throw StudioAudioMixService.MixError.codecFailure }
                self.lastGrain = range
            } catch is CancellationError {
                self.releasePlayer()
            } catch StudioAudioMixService.MixError.busy {
                // Another offline mix (timeline preview or export) owns the mixer.
                // Scrubbing stays silent instead of competing with it.
                self.releasePlayer()
            } catch {
                if let failure = error as? StudioAudioMixService.Failure { self.heldRecoveries.append(failure.recovery) }
                self.releasePlayer()
                self.notice = "Scrub audio could not play: \(error.localizedDescription)"
            }
        }
        return true
    }

    /// Called when preparation ends: start the newest queued position, or run
    /// the callbacks waiting for the mixer to become free.
    /// Invariant: the planner has a grain in flight exactly while `work` exists.
    private func settle() {
        guard work == nil else { return }
        isPreparing = false
        // A waiting caller (for example timeline Play) takes priority over queued scrubs.
        if !whenIdle.isEmpty { planner.clearPending() }
        if let source, case .start(let next) = planner.finished(timelineDuration: source.timelineDuration) {
            if begin(next) { return }
        } else if source == nil {
            _ = planner.finished(timelineDuration: 0)
        }
        guard work == nil else { return }
        let callbacks = whenIdle; whenIdle = []
        for callback in callbacks { callback() }
    }

    /// Stop sounding and preparing. `then` runs once no scrub mix holds the
    /// shared mixer, so a following timeline play is not refused as busy.
    func stop(then: (() -> Void)? = nil) {
        planner.clearPending(); source = nil
        generation = UUID(); work?.cancel()
        releasePlayer()
        if let then {
            if work == nil { then() } else { whenIdle.append(then) }
        }
    }
    func close() { stop() }

    private func discard(_ result: StudioAudioMixService.Output) {
        do { try result.cleanup() } catch { heldOutputs.append(result) }
    }
    private func releasePlayer() {
        player?.stop(); player?.delegate = nil; player = nil
        StudioAudioSessionController.shared.end(owner: ownerID)
        if let output {
            self.output = nil
            discard(output)
        }
        heldOutputs = heldOutputs.filter { held in (try? held.cleanup()) == nil }
        heldRecoveries = heldRecoveries.filter { held in (try? held.cleanup()) == nil }
        if !heldOutputs.isEmpty || !heldRecoveries.isEmpty {
            notice = "Scrub audio stopped. A temporary output needs safe recovery and will be retried."
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == id else { return }
            self.releasePlayer()
            if !flag { self.notice = "Scrub audio ended with a playback error." }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == id else { return }
            self.releasePlayer(); self.notice = "The audio device could not decode this scrub grain."
        }
    }
}
