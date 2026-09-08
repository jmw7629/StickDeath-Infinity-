import Foundation
import AVFoundation
import Combine
import CryptoKit
import Darwin

/// Owns one panel's Files import, derived waveform cache and single-clip audition.
/// No microphone, cloud, mixed timeline or export operation is implemented here.
/// The app's existing audio-session policy remains in charge of audible routing.
@MainActor
final class StudioAudioPreviewSession: NSObject, ObservableObject, AVAudioPlayerDelegate {
    struct Measurement: Equatable {
        let duration: Double
        let sampleRate: Double
        let channels: Int
        let peaks: [Float]
        let clipped: Bool
        init(_ imported: StudioAudioImportService.ImportedAudio) {
            duration = imported.duration; sampleRate = imported.sampleRate
            channels = imported.channelCount; peaks = imported.waveformPeaks
            clipped = imported.hasClippedSamples
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
    static let maximumCachedMeasurements = 32

    init(importer: StudioAudioImportService = .shared,
         scratchParent: URL = FileManager.default.temporaryDirectory) {
        self.importer = importer; self.scratchParent = scratchParent
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
    @discardableResult
    func importFile(_ url: URL, stillCurrent: @escaping () -> Bool,
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
                let result = try await self.importer.importAudio(from: url, scratchParent: self.scratchParent) { [weak self] value in
                    try Task.checkCancellation()
                    await self?.updateProgress(value, generation: id)
                }
                try Task.checkCancellation()
                guard self.generation == id else { return }
                guard stillCurrent() else { throw SessionError.staleProject }
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
        if measurements[track.id] != nil, fingerprints[track.id] == SHA256.hash(data: data) { onReady?(); return true }
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
        playingClipID = nil; currentTime = 0; playbackDuration = 0
        if state == .playing { state = .stopped }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); stop()
        if isBusy { state = .cancelled }
    }
    func close() {
        cancel(); measurements.removeAll(); cacheOrder.removeAll(); fingerprints.removeAll(); lastImportedClipID = nil
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
        case staleProject, invalidPlayback
        var errorDescription: String? {
            switch self {
            case .staleProject: return "The project changed while audio was loading. No clip was added; import again in the current project."
            case .invalidPlayback: return "This audio cannot be previewed on this device."
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
        let directory = parent.appendingPathComponent(".sdi-audio-analysis-\(UUID().uuidString)", isDirectory: true)
        guard Darwin.mkdir(directory.path, 0o700) == 0 else { throw StudioAudioImportService.ImportError.temporaryStorage }
        do {
            let source = directory.appendingPathComponent("saved.audio")
            let fd = Darwin.open(source.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw StudioAudioImportService.ImportError.temporaryStorage }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                var offset = 0
                while offset < data.count {
                    try Task.checkCancellation()
                    let end = min(offset + 64 * 1024, data.count)
                    try handle.write(contentsOf: data[offset..<end]); offset = end
                    await Task.yield()
                }
                try handle.close()
            } catch { try? handle.close(); throw error }
            let result = try await importer.importAudio(from: source, name: name, scratchParent: parent, progress: progress)
            try Task.checkCancellation()
            do { try FileManager.default.removeItem(at: directory) }
            catch { throw StudioAudioImportService.ImportError.cleanupFailed(directory: directory) }
            return result
        } catch {
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) }
                catch { throw StudioAudioImportService.ImportError.cleanupFailed(directory: directory) }
            }
            throw error
        }
    }
}
