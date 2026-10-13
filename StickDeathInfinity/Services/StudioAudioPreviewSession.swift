import Foundation
import AVFoundation
import Combine
import CryptoKit
import Darwin

/// One process-wide owner of the system audio session for Studio playback (#180).
/// Playback sets `.playback`/`.default` and activates the session so the ring
/// switch does not silence previews; interruptions and a lost output route stop
/// every registered owner honestly instead of letting a stalled player poll.
/// The session is deactivated with `notifyOthersOnDeactivation` when the last
/// owner ends. On platforms without AVAudioSession this is a no-op.
@MainActor
final class StudioAudioSessionController {
    enum Event: Equatable { case interruptionBegan, routeLost }
    static let shared = StudioAudioSessionController()
    private var owners: [UUID: @MainActor (Event) -> Void] = [:]
    private var observers: [NSObjectProtocol] = []
    private(set) var isActive = false
    private(set) var lastEvent: Event?
    private init() {}
    var activeOwnerCount: Int { owners.count }

    enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            if case .unavailable(let detail) = self { return "The audio session could not be activated for playback: \(detail)" }
            return nil
        }
    }

    /// Register `owner` and make the shared session active for playback.
    func begin(owner: UUID, onEvent: @escaping @MainActor (Event) -> Void) throws {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch { throw Failure.unavailable(error.localizedDescription) }
        if observers.isEmpty {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                Task { @MainActor in self?.dispatch(.interruptionBegan) }
            })
            observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
                Task { @MainActor in self?.dispatch(.routeLost) }
            })
        }
        #endif
        owners[owner] = onEvent
        isActive = true
    }

    /// Unregister `owner`; the last owner deactivates the session.
    func end(owner: UUID) {
        guard owners.removeValue(forKey: owner) != nil else { return }
        guard owners.isEmpty else { return }
        #if os(iOS) || os(tvOS)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        // Deactivation can legitimately fail while another app's audio is
        // still being torn down; the next `begin` re-activates regardless.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        isActive = false
    }

    /// Test and system entry point: stops every owner with the given event.
    func dispatch(_ event: Event) {
        lastEvent = event
        for handler in owners.values { handler(event) }
    }
    static func message(for event: Event) -> String {
        switch event {
        case .interruptionBegan: return "Audio playback was interrupted by another app or a call and has stopped. Play again when ready."
        case .routeLost: return "The audio output device was disconnected, so playback stopped."
        }
    }
}

/// Owns one panel's Files import, derived waveform cache and single-clip audition.
/// No microphone, cloud, mixed timeline or export operation is implemented here.
/// `StudioAudioSessionController` owns the playback category and interruption policy.
@MainActor
final class StudioAudioPreviewSession: NSObject, ObservableObject, AVAudioPlayerDelegate {
    struct Measurement: Equatable {
        let duration: Double
        let sampleRate: Double
        let channels: Int
        let peaks: [Float]
        /// Measured RMS per bin (#192); empty only for records older than RMS support.
        let rms: [Float]
        let clipped: Bool
        /// True when the values came from the persistent cache instead of a fresh decode.
        let restoredFromCache: Bool
        init(_ imported: StudioAudioImportService.ImportedAudio) {
            duration = imported.duration; sampleRate = imported.sampleRate
            channels = imported.channelCount; peaks = imported.waveformPeaks; rms = imported.waveformRMS
            clipped = imported.hasClippedSamples; restoredFromCache = false
        }
        init(record: StudioWaveformRecord) {
            duration = record.duration; sampleRate = record.sampleRate; channels = record.channels
            peaks = record.peaks; rms = record.rms; clipped = record.clipped; restoredFromCache = true
        }
    }
    enum State: Equatable {
        case idle, importing, analyzing, ready, playing, stopped, cancelled
        case failed(String)
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var isBusy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var playingClipID: String?
    @Published private(set) var currentTime = 0.0
    @Published private(set) var playbackDuration = 0.0
    @Published private(set) var measurements: [UUID: Measurement] = [:]
    @Published private(set) var lastImportedClipID: String?
    private var cacheOrder: [UUID] = []
    private var fingerprints: [UUID: SHA256.Digest] = [:]
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var player: AVAudioPlayer?
    private var playerIdentity: ObjectIdentifier?
    private var playbackTimer: Timer?
    private let importer: StudioAudioImportService
    private let scratchParent: URL
    private let sessionOwnerID = UUID()
    /// Digest-keyed persistent waveform records (#192/#193); in-memory LRU above.
    private let waveformCache: StudioWaveformCache
    private var pendingRestore: [AudioTrack] = []
    private var pendingRestoreStillCurrent: (() -> Bool)?
    @Published private(set) var restoredFromCacheCount = 0
    static let maximumCachedMeasurements = 32
    static let maximumRestoreAnalyses = 16

    init(importer: StudioAudioImportService = .shared,
         scratchParent: URL = FileManager.default.temporaryDirectory,
         waveformCache: StudioWaveformCache = .shared) {
        self.importer = importer; self.scratchParent = scratchParent; self.waveformCache = waveformCache
        super.init()
    }
    var notice: String? {
        if case .failed(let message) = state { return message }
        if state == .cancelled { return "Audio operation cancelled. No new clip was added." }
        return nil
    }
    var actualPlayerIsPlaying: Bool { player?.isPlaying == true }
    var actualPlayerVolume: Float? { player?.volume }

    /// `attach` is called only with a successfully decoded immutable result and
    /// must perform the VM's exact project/revision transaction, not a URL save.
    typealias AudioPreparation = (@escaping @Sendable (StudioAudioImportService.Progress) async throws -> Void) async throws -> StudioAudioImportService.ImportedAudio

    @discardableResult
    func importFile(_ url: URL, name: String? = nil, expectedSHA256: String? = nil,
                    prepare: AudioPreparation? = nil, stillCurrent: @escaping () -> Bool,
                    attach: @escaping (AudioTrack) throws -> String) -> Bool {
        guard !isBusy else { return false }
        guard stillCurrent() else { state = .failed("The project changed. Select the audio file again in the current project."); return false }
        stop()
        let id = UUID(); generation = id
        isBusy = true; state = .importing; progress = 0; lastImportedClipID = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.task = nil }
            do {
                let result: StudioAudioImportService.ImportedAudio
                if let prepare {
                    result = try await prepare { [weak self] value in
                        try Task.checkCancellation()
                        await self?.updateProgress(value, generation: id)
                    }
                } else {
                    result = try await self.importer.importAudio(from: url, name: name, scratchParent: self.scratchParent) { [weak self] value in
                        try Task.checkCancellation()
                        await self?.updateProgress(value, generation: id)
                    }
                }
                try Task.checkCancellation()
                guard self.generation == id else { return }
                guard stillCurrent() else { throw SessionError.staleProject }
                if let expectedSHA256,
                   SHA256.hash(data: result.originalData).map({ String(format: "%02x", $0) }).joined() != expectedSHA256 {
                    throw SessionError.changedResource
                }
                // No await between the final lease check and the atomic VM edit.
                let clipID = try attach(result.track)
                self.remember(result, for: result.id)
                self.lastImportedClipID = clipID; self.progress = 1; self.state = .ready
            } catch is CancellationError {
                if self.generation == id { self.state = .cancelled }
            } catch {
                if self.generation == id { self.state = .failed(Self.message(error)) }
            }
        }
        return true
    }

    /// Reanalyzes saved immutable bytes. Only derived measurements are cached;
    /// the saved track ID is retained and no source URL enters project storage.
    @discardableResult
    func analyze(_ track: AudioTrack, stillCurrent: @escaping () -> Bool) -> Bool {
        analyze(track, stillCurrent: stillCurrent, onReady: nil)
    }
    private func analyze(_ track: AudioTrack, stillCurrent: @escaping () -> Bool, onReady: (() -> Void)?) -> Bool {
        guard !isBusy, stillCurrent() else { return false }
        guard let data = track.audioData, !data.isEmpty,
              data.count <= StudioAudioImportService.maximumEncodedBytes else {
            state = .failed("This audio asset is missing or exceeds the 16 MB preview limit."); return false
        }
        let digest = SHA256.hash(data: data)
        if measurements[track.id] != nil, fingerprints[track.id] == digest { onReady?(); return true }
        // A persisted record for exactly these bytes needs no decode (#192).
        if restoreFromCache(track, data: data, digest: digest) { state = .ready; onReady?(); return true }
        stop()
        let id = UUID(); generation = id
        isBusy = true; state = .analyzing; progress = 0
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.task = nil }
            do {
                let result = try await StudioSavedAudioAnalysis.run(data: data, name: track.name,
                    importer: self.importer, scratchParent: self.scratchParent) { [weak self] value in
                    try Task.checkCancellation()
                    await self?.updateProgress(value, generation: id)
                }
                try Task.checkCancellation()
                guard self.generation == id else { return }
                guard stillCurrent() else { throw SessionError.staleProject }
                self.remember(result, for: track.id)
                self.progress = 1; self.state = .ready
                self.isBusy = false; onReady?()
            } catch is CancellationError {
                if self.generation == id { self.state = .cancelled }
            } catch {
                if self.generation == id { self.state = .failed(Self.message(error)) }
            }
        }
        return true
    }

    /// Load a cached record for `track` into the in-memory measurements.
    private func restoreFromCache(_ track: AudioTrack, data: Data, digest: SHA256.Digest) -> Bool {
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard let record = waveformCache.record(forSHA256: hex, byteCount: data.count),
              abs(record.duration - track.duration) <= 0.001 else { return false }
        cacheOrder.removeAll { $0 == track.id }; cacheOrder.append(track.id)
        measurements[track.id] = Measurement(record: record); fingerprints[track.id] = digest
        restoredFromCacheCount += 1
        trimMemory()
        return true
    }

    /// Restore every project waveform on open (#192/#193): cached records load
    /// synchronously; the remaining assets (at most `maximumRestoreAnalyses`)
    /// are decoded one at a time in the background while `stillCurrent` holds.
    /// Returns how many waveforms came straight from the persistent cache.
    @discardableResult
    func restoreMeasurements(for tracks: [AudioTrack], stillCurrent: @escaping () -> Bool) -> Int {
        guard stillCurrent() else { return 0 }
        var restored = 0, missing: [AudioTrack] = []
        for track in tracks {
            guard track.legacySourceFilename == nil, let data = track.audioData, !data.isEmpty,
                  data.count <= StudioAudioImportService.maximumEncodedBytes else { continue }
            let digest = SHA256.hash(data: data)
            if measurements[track.id] != nil, fingerprints[track.id] == digest { continue }
            if restoreFromCache(track, data: data, digest: digest) { restored += 1 } else { missing.append(track) }
        }
        pendingRestore = Array(missing.prefix(Self.maximumRestoreAnalyses))
        pendingRestoreStillCurrent = stillCurrent
        continueRestore()
        return restored
    }
    private func continueRestore() {
        guard !isBusy, let stillCurrent = pendingRestoreStillCurrent, stillCurrent() else {
            if pendingRestoreStillCurrent?() != true { pendingRestore.removeAll(); pendingRestoreStillCurrent = nil }
            return
        }
        guard !pendingRestore.isEmpty else { pendingRestoreStillCurrent = nil; return }
        let next = pendingRestore.removeFirst()
        // The next analysis starts on a later actor turn so the finishing task's
        // deferred `task = nil` cannot clear the new task's cancellation handle.
        if !analyze(next, stillCurrent: stillCurrent, onReady: { [weak self] in
            Task { @MainActor [weak self] in self?.continueRestore() }
        }) {
            pendingRestore.removeAll(); pendingRestoreStillCurrent = nil
        }
    }

    @discardableResult
    func preview(_ clip: AudioClip, track: AudioTrack, stillCurrent: @escaping () -> Bool) -> Bool {
        guard clip.assetID == track.id, stillCurrent() else { return false }
        guard clip.duration.isFinite, track.duration.isFinite,
              abs(clip.duration - track.duration) <= 0.001 else {
            state = .failed("Trimmed or inconsistent audio clips cannot be previewed in this version."); return false
        }
        if playingClipID == clip.id { stop(); return true }
        return analyze(track, stillCurrent: stillCurrent) { [weak self] in
            guard stillCurrent() else { return }
            _ = self?.play(clipID: clip.id, track: track, volume: clip.volume)
        }
    }
    func pickerFailed(_ error: Error) {
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain && value.code == NSUserCancelledError { return }
        state = .failed("Files could not provide this audio. Download it locally and check its access, then try again.")
    }

    /// Preview or add the exact checked catalogue bytes without blocking UI reads/hashes.
    /// A nil attach closure means audition only; no project is mutated.
    @discardableResult
    func useCatalogueSound(_ sound: StudioSoundCatalogue.Sound, catalogue: StudioSoundCatalogue,
                           stillCurrent: @escaping () -> Bool,
                           attach: ((AudioTrack) throws -> String)? = nil) -> Bool {
        guard !isBusy, stillCurrent() else { return false }
        stop()
        let id = UUID(); generation = id
        isBusy = true; state = attach == nil ? .analyzing : .importing
        progress = 0; lastImportedClipID = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.task = nil }
            do {
                let data = try await catalogue.loadResource(sound)
                try Task.checkCancellation()
                guard self.generation == id, stillCurrent() else { throw SessionError.staleProject }
                let result = try await StudioSavedAudioAnalysis.run(data: data, name: sound.title,
                    importer: self.importer, scratchParent: self.scratchParent) { [weak self] value in
                        try Task.checkCancellation()
                        await self?.updateProgress(value, generation: id)
                    }
                try Task.checkCancellation()
                guard self.generation == id else { return }
                guard stillCurrent() else { throw SessionError.staleProject }
                guard abs(result.duration - sound.duration) <= 0.001,
                      result.sampleRate == sound.sampleRate, result.channelCount == sound.channels else {
                    throw SessionError.changedResource
                }
                let track = result.track
                if let attach {
                    let clipID = try attach(track)
                    self.remember(result, for: track.id)
                    self.lastImportedClipID = clipID; self.progress = 1; self.state = .ready
                } else {
                    self.remember(result, for: track.id)
                    self.progress = 1; self.state = .ready; self.isBusy = false
                    _ = self.play(clipID: sound.id, track: track, volume: 1)
                }
            } catch is CancellationError {
                if self.generation == id { self.state = .cancelled }
            } catch {
                if self.generation == id { self.state = .failed(Self.message(error)) }
            }
        }
        return true
    }

    /// Start one actual AVAudioPlayer after analysis of the same immutable asset.
    /// A true result means the player accepted playback, not audible device proof.
    @discardableResult
    func play(clipID: String, track: AudioTrack, volume: Double) -> Bool {
        guard !isBusy else { return false }
        stop()
        guard volume.isFinite, (0...1).contains(volume),
              let measurement = measurements[track.id], let data = track.audioData,
              !data.isEmpty, data.count <= StudioAudioImportService.maximumEncodedBytes,
              fingerprints[track.id] == SHA256.hash(data: data),
              track.duration.isFinite, abs(track.duration - measurement.duration) <= 0.001 else {
            state = .failed("Analyze this saved audio before previewing it. Its data may be unavailable."); return false
        }
        do {
            // Playback category + activation before the player (#180); an
            // interruption or lost route stops this audition with a notice.
            try StudioAudioSessionController.shared.begin(owner: sessionOwnerID) { [weak self] event in
                guard let self, self.player != nil else { return }
                self.stop(); self.state = .failed(StudioAudioSessionController.message(for: event))
            }
            let next = try AVAudioPlayer(data: data)
            guard next.duration.isFinite, next.duration > 0,
                  abs(next.duration - measurement.duration) <= max(0.1, measurement.duration * 0.01) else { throw SessionError.invalidPlayback }
            next.delegate = self; next.volume = Float(volume); next.numberOfLoops = 0
            guard next.prepareToPlay() else { throw SessionError.invalidPlayback }
            player = next; playerIdentity = ObjectIdentifier(next)
            guard next.play(), next.isPlaying else { throw SessionError.invalidPlayback }
            playingClipID = clipID; playbackDuration = next.duration; currentTime = 0; state = .playing
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.readPlaybackTime() }
            }
            return true
        } catch let failure as StudioAudioSessionController.Failure {
            stop(); state = .failed(failure.localizedDescription)
            return false
        } catch {
            stop(); state = .failed("Audio preview could not start on this device. No playback success was recorded.")
            return false
        }
    }
    func setVolume(_ value: Double, clipID: String) {
        guard playingClipID == clipID, value.isFinite, (0...1).contains(value) else { return }
        player?.volume = Float(value)
    }
    func stop() {
        playbackTimer?.invalidate(); playbackTimer = nil
        player?.stop(); player?.delegate = nil; player = nil; playerIdentity = nil
        StudioAudioSessionController.shared.end(owner: sessionOwnerID)
        playingClipID = nil; currentTime = 0; playbackDuration = 0
        if state == .playing { state = .stopped }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); stop()
        pendingRestore.removeAll(); pendingRestoreStillCurrent = nil
        if isBusy { state = .cancelled }
    }
    func close() {
        cancel(); measurements.removeAll(); cacheOrder.removeAll(); fingerprints.removeAll(); lastImportedClipID = nil
        restoredFromCacheCount = 0
        if !isBusy { state = .idle }
    }
    private func updateProgress(_ value: StudioAudioImportService.Progress, generation id: UUID) {
        guard generation == id, isBusy else { return }
        let fraction = value.total > 0 ? min(1, max(0, Double(value.completed) / Double(value.total))) : 0
        progress = value.phase == .reading ? fraction * 0.35 : 0.35 + fraction * 0.65
    }
    private func remember(_ value: StudioAudioImportService.ImportedAudio, for id: UUID) {
        cacheOrder.removeAll { $0 == id }; cacheOrder.append(id); measurements[id] = Measurement(value)
        fingerprints[id] = SHA256.hash(data: value.originalData)
        // Persist the measured record so the next open of this project (or any
        // project using the same bytes) restores its waveform without decoding.
        // A full or unwritable cache only costs a later re-analysis.
        try? waveformCache.store(value.waveformRecord)
        trimMemory()
    }
    private func trimMemory() {
        while cacheOrder.count > Self.maximumCachedMeasurements {
            let removed = cacheOrder.removeFirst(); measurements.removeValue(forKey: removed); fingerprints.removeValue(forKey: removed)
        }
    }
    private func readPlaybackTime() {
        guard let player, state == .playing else { return }
        currentTime = min(playbackDuration, max(0, player.currentTime))
        // A route interruption may stop the player without its finish callback.
        if !player.isPlaying { stop(); state = .stopped }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.playerIdentity == identity else { return }
            self.stop(); self.state = flag ? .stopped : .failed("Audio preview ended with a playback error.")
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.playerIdentity == identity else { return }
            self.stop(); self.state = .failed("Audio preview could not decode this asset.")
        }
    }
    private static func message(_ error: Error) -> String {
        if let error = error as? StudioAudioImportService.ImportError { return error.localizedDescription }
        if let error = error as? StudioDocumentError { return error.localizedDescription }
        if let error = error as? SessionError { return error.localizedDescription }
        return "Audio could not be imported or analyzed. The project has not changed."
    }
    private enum SessionError: LocalizedError {
        case staleProject, invalidPlayback, changedResource
        var errorDescription: String? {
            switch self {
            case .staleProject: return "The project changed while audio was loading. No clip was added; import again in the current project."
            case .invalidPlayback: return "This audio cannot be previewed on this device."
            case .changedResource: return "The sound file changed while loading. No clip was added."
            }
        }
    }
}

/// Creates and removes only its own private scratch directory. All file copying
/// and decode work runs off MainActor; original saved bytes are never modified.
private actor StudioSavedAudioAnalysis {
    private static let shared = StudioSavedAudioAnalysis()
    private var busy = false
    static func run(data: Data, name: String, importer: StudioAudioImportService, scratchParent: URL,
                    progress: @Sendable (StudioAudioImportService.Progress) async throws -> Void) async throws -> StudioAudioImportService.ImportedAudio {
        try await shared.perform(data: data, name: name, importer: importer,
                                                    scratchParent: scratchParent, progress: progress)
    }
    private func perform(data: Data, name: String, importer: StudioAudioImportService, scratchParent: URL,
                         progress: @Sendable (StudioAudioImportService.Progress) async throws -> Void) async throws -> StudioAudioImportService.ImportedAudio {
        try Task.checkCancellation()
        guard !busy else { throw StudioAudioImportService.ImportError.busy }
        busy = true; defer { busy = false }
        guard data.count <= StudioAudioImportService.maximumEncodedBytes,
              scratchParent.isFileURL, scratchParent.host == nil || scratchParent.host == "localhost", scratchParent.query == nil, scratchParent.fragment == nil,
              !scratchParent.path.utf8.contains(0) else { throw StudioAudioImportService.ImportError.temporaryStorage }
        let values = try scratchParent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw StudioAudioImportService.ImportError.temporaryStorage }
        let parent = scratchParent.resolvingSymlinksInPath().standardizedFileURL
        let scratch = try StudioAudioImportScratch.create(in: parent)
        do {
            let fd = try scratch.createSourceFile()
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                var offset = 0
                while offset < data.count {
                    try Task.checkCancellation()
                    try scratch.verify()
                    let end = min(offset + 64 * 1024, data.count)
                    try handle.write(contentsOf: data[offset..<end]); offset = end
                    await Task.yield()
                }
                try handle.close()
            } catch { try? handle.close(); throw error }
            try scratch.verify()
            let result = try await importer.importAudio(from: scratch.sourceURL, name: name, scratchParent: parent) { value in
                try await progress(value)
                try scratch.verify()
            }
            try Task.checkCancellation()
            try scratch.verify()
            try scratch.cleanup()
            return result
        } catch {
            let operationError = error
            do { try scratch.cleanup() }
            catch { throw StudioAudioImportService.ImportError.cleanupFailed(directory: scratch.directoryURL) }
            throw operationError
        }
    }
}
