import Foundation
import Darwin

/// Runs the reviewed visual renderer, current canonical audio mixer and reviewed
/// H.264/AAC mux from one immutable capture. The returned file owns its lifetime.
@MainActor final class StudioMixedMovieExportService {
    enum Phase { case rendering, mixing, muxing, verifying }
    struct Progress { let phase: Phase; let completed: Int; let total: Int }
    typealias Handler = @MainActor (Progress) throws -> Void
    private static var active = false

    @MainActor final class Output {
        let receipt: StudioAudioVideoMuxService.Receipt
        let directory: URL
        private let owned: StudioAudioVideoMuxService.Output
        private(set) var isCleaned = false
        fileprivate init(_ owned: StudioAudioVideoMuxService.Output) {
            self.owned = owned; receipt = owned.receipt; directory = owned.directory
        }
        func checkedURLs() throws -> [URL] {
            guard !isCleaned else { throw ExportError.outputUnavailable }
            return try owned.checkedURLs()
        }
        func cleanup() throws { if !isCleaned { try owned.cleanup(); isCleaned = true } }
    }
    @MainActor final class Recovery {
        fileprivate var video: StudioMovieExportService.VisualComponent?
        fileprivate var audio: StudioAudioVideoMuxService.AudioComponent?
        fileprivate var movie: StudioAudioVideoMuxService.Output?
        fileprivate var mixFailure: StudioAudioMixService.Recovery?
        fileprivate var muxFailure: StudioAudioVideoMuxService.Recovery?
        // The old renderer reports this path without a deletion capability.
        // Observe absence only; never infer ownership or remove it ourselves.
        fileprivate var unownedVisualPartial: URL?
        private var cleaning = false
        fileprivate init() {}
        fileprivate func cleanupComponents() throws {
            if let audio { try audio.cleanup(); self.audio = nil }
            if let video { try video.cleanup(); self.video = nil }
        }
        func cleanup() async throws {
            guard !cleaning else { throw ExportError.busy }
            cleaning = true
            defer { cleaning = false }
            if let muxFailure { try await muxFailure.cleanup(); self.muxFailure = nil }
            if let mixFailure { try mixFailure.cleanup(); self.mixFailure = nil }
            if let path = unownedVisualPartial {
                var info = stat()
                guard lstat(path.path, &info) != 0, errno == ENOENT else { throw ExportError.recoveryRequired }
                unownedVisualPartial = nil
            }
            try cleanupComponents()
            if let movie { try movie.cleanup(); self.movie = nil }
        }
    }
    struct Failure: Error, LocalizedError {
        let underlying: Error
        let recovery: Recovery
        var errorDescription: String? { "Mixed MP4 export needs temporary-file recovery. " + underlying.localizedDescription }
    }
    enum ExportError: LocalizedError {
        case busy, outputUnavailable, recoveryRequired, unresolvedAudio, unsupportedSnapshot
        var errorDescription: String? {
            switch self {
            case .busy: return "Another mixed MP4 export is already running."
            case .outputUnavailable: return "The rendered MP4 is no longer available."
            case .recoveryRequired: return "A temporary movie has an ownership conflict. Its files were preserved."
            case .unresolvedAudio: return "This project contains audio with missing sources or clips outside the animation. Restore the source or trim the clips to the animation before exporting."
            case .unsupportedSnapshot: return "This project exceeds the current mixed MP4 limits. Use up to 240 frames, 128 clips, 16 audio sources and an even-sized canvas."
            }
        }
    }

    func export(snapshot: StudioMovieExportService.Snapshot, outputParent: URL,
                movieLimits: StudioMovieExportService.Limits = .init(),
                progress: @escaping Handler = { _ in }) async throws -> Output {
        try Task.checkCancellation()
        guard !Self.active else { throw ExportError.busy }
        Self.active = true
        defer { Self.active = false }
        let capture: StudioMuxCapture
        do { capture = try StudioMuxCapture.capture(snapshot) }
        catch StudioMuxCapture.CaptureError.unresolvedAudio { throw ExportError.unresolvedAudio }
        catch StudioMuxCapture.CaptureError.unsupportedSnapshot { throw ExportError.unsupportedSnapshot }
        let recovery = Recovery()
        let mux = StudioAudioVideoMuxService(limits: .init(
            maximumOutputBytes: min(movieLimits.maximumOutputBytes, 80 * 1024 * 1024),
            operationTimeout: min(movieLimits.operationTimeout, 120),
            readinessTimeout: min(movieLimits.readinessTimeout, 10)))
        func report(_ value: Progress) throws {
            try Task.checkCancellation(); try progress(value); try Task.checkCancellation()
        }
        do {
            recovery.video = try await StudioMovieExportService(limits: movieLimits).exportVisualComponent(capture: capture,
                outputParent: outputParent) { value in
                    try report(.init(phase: .rendering, completed: value.completedFrames, total: value.totalFrames))
                }
            try report(.init(phase: .mixing, completed: 0, total: snapshot.document.audioClips.count))
            recovery.audio = try await mux.mixAudioComponent(capture: capture, outputParent: outputParent) { value in
                try Task.checkCancellation()
                try await progress(.init(phase: .mixing, completed: value.completed, total: value.total))
                try Task.checkCancellation()
            }
            guard let video = recovery.video, let audio = recovery.audio else { throw ExportError.outputUnavailable }
            recovery.movie = try await mux.mux(video: video, audio: audio, outputParent: outputParent) { value in
                try report(.init(phase: value.phase == .verifying || value.phase == .publishing ? .verifying : .muxing,
                                 completed: value.videoFrames, total: snapshot.document.frames.count))
            }
            try Task.checkCancellation()
            // Publish readiness only after both intermediate files are removed.
            try recovery.cleanupComponents()
            guard let movie = recovery.movie else { throw ExportError.outputUnavailable }
            _ = try movie.checkedURLs()
            try report(.init(phase: .verifying, completed: movie.receipt.videoFrames, total: movie.receipt.videoFrames))
            _ = try movie.checkedURLs()
            recovery.movie = nil
            return Output(movie)
        } catch {
            let original: Error
            if let failure = error as? StudioAudioMixService.Failure {
                recovery.mixFailure = failure.recovery; original = failure.underlying
            } else if let failure = error as? StudioAudioVideoMuxService.Failure {
                recovery.muxFailure = failure.recovery; original = failure.underlying
            } else {
                original = error
                if case StudioMovieExportService.ExportError.cleanupFailed(let path) = error {
                    recovery.unownedVisualPartial = path
                }
            }
            do { try await recovery.cleanup() }
            catch { throw Failure(underlying: original, recovery: recovery) }
            throw original
        }
    }
}
