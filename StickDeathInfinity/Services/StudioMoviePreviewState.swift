import Foundation
import AVFoundation
import Combine

/// Plays only a validated export lease. No remote URL, generated thumbnail or
/// editor snapshot can stand in for decoding the actual rendered movie.
@MainActor
final class StudioMoviePreviewState: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isReady = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isWaiting = false
    @Published private(set) var didFinish = false
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var errorMessage: String?
    private var request: StudioMovieExportSession.PreviewRequest?
    private var ownedPlayer: AVPlayer?
    private var generation = UUID()
    private var itemObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var readinessTask: Task<Void, Never>?
    private var seekID: UUID?

    @discardableResult
    func load(session: StudioMovieExportSession, scope: StudioMovieExportSession.Scope) -> Bool {
        stop()
        errorMessage = nil
        guard let lease = session.beginPreview(scope: scope, stopConsumer: { [weak self] in self?.stop() }) else {
            errorMessage = "The current MP4 is not available for preview."
            return false
        }
        do {
            let url = try lease.checkedURL()
            guard url.isFileURL else { throw StudioMovieExportService.ExportError.outputUnavailable }
            request = lease
            let id = generation
            let item = AVPlayerItem(url: url)
            let playback = AVPlayer(playerItem: item)
            playback.allowsExternalPlayback = false
            playback.actionAtItemEnd = .pause
            itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
                Task { @MainActor in
                    guard let self, self.generation == id, let item else { return }
                    switch item.status {
                    case .readyToPlay:
                        let seconds = item.duration.seconds
                        guard seconds.isFinite, seconds > 0 else {
                            self.fail("The movie has no playable duration."); return
                        }
                        self.readinessTask?.cancel(); self.readinessTask = nil
                        self.duration = seconds; self.isReady = true
                    case .failed:
                        self.fail(item.error?.localizedDescription ?? "The exported movie could not be played.")
                    case .unknown: break
                    @unknown default: self.fail("The movie preview state is unsupported.")
                    }
                }
            }
            playbackObservation = playback.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self, weak playback] _, _ in
                Task { @MainActor in
                    guard let self, self.generation == id, let playback else { return }
                    self.isPlaying = playback.timeControlStatus == .playing
                    self.isWaiting = playback.timeControlStatus == .waitingToPlayAtSpecifiedRate
                }
            }
            timeObserver = playback.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
                Task { @MainActor in
                    guard let self, self.generation == id, self.seekID == nil,
                          let seconds = self.player?.currentTime().seconds, seconds.isFinite else { return }
                    self.currentTime = min(self.duration, max(0, seconds))
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                                 object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == id, self.seekID == nil,
                          let seconds = self.player?.currentTime().seconds,
                          seconds.isFinite, seconds >= self.duration - 0.02 else { return }
                    self.didFinish = true; self.isPlaying = false; self.isWaiting = false; self.currentTime = self.duration
                }
            }
            failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                                                                     object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == id else { return }
                    self.fail("The movie stopped before playback completed. Try previewing it again.")
                }
            }
            // A validated local file should become ready promptly. Do not leave
            // an unresponsive decoder or a permanent spinner owning the export.
            readinessTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                catch { return }
                guard let self, self.generation == id, !self.isReady else { return }
                self.fail("The movie preview did not become ready. Try previewing it again.")
            }
            ownedPlayer = playback; player = playback
            guard generation == id, request?.id == lease.id, session.isPreviewing, !session.isClosed else {
                stop(); return false
            }
            return true
        } catch {
            lease.finish()
            fail(error.localizedDescription)
            return false
        }
    }

    func togglePlayback() {
        guard isReady, let player else { return }
        if isPlaying || isWaiting || player.rate != 0 { player.pause() }
        else if didFinish || currentTime >= duration {
            seek(to: 0, resume: true)
        } else { player.play() }
    }

    func seek(to seconds: Double, resume: Bool = false) {
        guard isReady, let player, seconds.isFinite else { return }
        let id = generation, seek = UUID()
        seekID = seek
        player.pause()
        let target = min(duration, max(0, seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] completed in
            Task { @MainActor in
                guard let self, self.generation == id, self.seekID == seek, let player else { return }
                self.seekID = nil
                guard completed, player.currentTime().seconds.isFinite else {
                    self.fail("The movie preview could not seek to that position."); return
                }
                self.currentTime = max(0, min(self.duration, player.currentTime().seconds))
                self.didFinish = self.currentTime >= self.duration
                if resume { self.didFinish = false; player.play() }
            }
        }
    }

    func stop() {
        // Invalidate asynchronous callbacks before releasing the decoder and
        // only then finish the lease that permits its owner to delete files.
        generation = UUID(); seekID = nil
        readinessTask?.cancel(); readinessTask = nil
        itemObservation?.invalidate(); itemObservation = nil
        playbackObservation?.invalidate(); playbackObservation = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil; ownedPlayer = nil
        isReady = false; isPlaying = false; isWaiting = false; didFinish = false; currentTime = 0; duration = 0
        let lease = request; request = nil; lease?.finish()
    }

    private func fail(_ message: String) { stop(); errorMessage = message }

    deinit {
        readinessTask?.cancel()
        itemObservation?.invalidate(); playbackObservation?.invalidate()
        if let timeObserver, let player = ownedPlayer { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        ownedPlayer?.pause(); ownedPlayer?.replaceCurrentItem(with: nil)
        // PreviewRequest's deinit releases its owner on MainActor after the
        // decoder and its observers above have been stopped.
    }
}
