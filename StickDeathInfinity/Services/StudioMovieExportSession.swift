import Foundation
import Combine
import Darwin

/// Private MP4 session foundation. The panel must report its scalar scope and
/// close the session when dismissed. PNG sessions and UI remain independent.
@MainActor
final class StudioMovieExportSession: ObservableObject {
    typealias Service = StudioMovieExportService
    struct Scope {
        let isStudioVisible: Bool
        let isForeground: Bool
        let accountID: String?
    }
    struct Source {
        let projectID: UUID
        let revision: Int
        let name: String
        let frameCount: Int
    }
    @Published private(set) var isRunning = false
    @Published private(set) var isSharing = false
    @Published private(set) var isClosed = false
    @Published private(set) var completedFrames = 0
    @Published private(set) var totalFrames = 0
    @Published private(set) var phase: Service.Phase?
    @Published private(set) var source: Source?
    @Published private(set) var output: Service.Output?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var needsCleanup = false

    private let outputParent: URL
    private let limits: Service.Limits
    private weak var editor: StudioViewModel?
    private var currentScope = Scope(isStudioVisible: false, isForeground: false, accountID: nil)
    private var capturedAccountID: String?
    private var task: Task<Void, Never>?
    private var activeRunID: UUID?
    private var activeShareID: UUID?
    private var cancellationRequested = false
    private var isStarting = false
    private var isCleaning = false
    // A pre-return service cleanup failure does not give us a deletion handle.
    // Keep this for read-only recovery checking; never delete by this URL.
    private var unownedPartial: URL?

    init(outputParent: URL = FileManager.default.temporaryDirectory, limits: Service.Limits = .init()) {
        self.outputParent = outputParent; self.limits = limits
    }

    @discardableResult
    func start(from vm: StudioViewModel, background: Service.Background, scope: Scope) -> Bool {
        guard !isClosed, !isRunning, !isSharing, !isStarting else { return false }
        isStarting = true
        defer { isStarting = false }
        guard scope.isStudioVisible, scope.isForeground, vm.isEditing else {
            errorMessage = "Open the current Studio project before exporting MP4."; return false
        }
        guard vm.activeStrokeID == nil, vm.pendingBrushStroke == nil else {
            errorMessage = "Finish or resolve the current drawing before exporting MP4."; return false
        }
        currentScope = scope
        guard cleanupOwnedOutput() else { return false }
        // Cleanup publishes state. Honor a synchronous observer changing scope,
        // closing the panel, or changing input before we capture a new project.
        guard !isClosed, currentScope.isStudioVisible, currentScope.isForeground,
              currentScope.accountID == scope.accountID, vm.isEditing,
              vm.activeStrokeID == nil, vm.pendingBrushStroke == nil else {
            errorMessage = "Studio changed before the MP4 snapshot was captured."; return false
        }
        // One synchronous MainActor capture; the task never retains the VM.
        let document = vm.document
        var rasters: [String: Data] = [:]
        for id in Set(document.frames.compactMap(\.rasterAssetID)) {
            if let bytes = vm.rasterData(id) { rasters[id] = bytes }
        }
        let snapshot = Service.Snapshot(document: document,
            retainedAudioTracks: vm.projectAudioTracks, rasterDataByID: rasters)
        editor = vm; capturedAccountID = scope.accountID
        source = Source(projectID: document.id, revision: document.revision,
                        name: document.name, frameCount: document.frames.count)
        errorMessage = nil; notice = nil; phase = nil
        completedFrames = 0; totalFrames = document.frames.count
        cancellationRequested = false
        let runID = UUID(); activeRunID = runID
        isRunning = true
        task = Task { [self, snapshot] in
            do {
                try checkRunningContext()
                let result = try await Service(limits: limits).export(snapshot: snapshot,
                    outputParent: outputParent, background: background) { [self] progress in
                        try checkRunningContext()
                        phase = progress.phase
                        completedFrames = progress.completedFrames; totalFrames = progress.totalFrames
                        // Published observers can synchronously cancel or close.
                        try checkRunningContext()
                    }
                output = result
                try checkRunningContext()
                _ = try result.checkedURLs()
                notice = "MP4 ready on this device from revision \(result.manifest.documentRevision). No audio was included."
            } catch is CancellationError {
                notice = "MP4 export cancelled."
            } catch {
                if case Service.ExportError.cleanupFailed(let path) = error, output == nil {
                    unownedPartial = path; needsCleanup = true
                }
                errorMessage = error.localizedDescription
            }
            if isClosed || cancellationRequested || !contextMatches(requireForeground: true) {
                _ = cleanupOwnedOutput()
            }
            // Publish idle only after this run has completed its cleanup.
            if activeRunID == runID {
                activeRunID = nil; task = nil; isRunning = false
            }
        }
        return true
    }

    func refreshScope(_ scope: Scope) {
        currentScope = scope
        guard source != nil else { return }
        if !contextMatches(requireForeground: false) { close() }
        else if !scope.isForeground { cancel() }
    }
    func cancel() {
        guard isRunning else { return }
        cancellationRequested = true
        notice = "Cancelling MP4 export…"
        task?.cancel()
    }
    func close() {
        isClosed = true
        cancel()
        if !isRunning && !isSharing, cleanupOwnedOutput() {
            notice = "MP4 export closed. Its owned files were removed."
        }
    }

    /// Retain this request through the complete real consumer lifetime. Obtain
    /// checked URLs immediately before passing them to UIActivityViewController.
    /// Close/dismiss never deletes files while this request is active.
    func beginSharing(scope: Scope) -> ShareRequest? {
        refreshScope(scope)
        guard !isClosed, !isRunning, !isSharing, contextMatches(requireForeground: true),
              let output else { return nil }
        do { _ = try output.checkedURLs() }
        catch { errorMessage = error.localizedDescription; needsCleanup = true; return nil }
        let id = UUID(); activeShareID = id
        errorMessage = nil; notice = nil; isSharing = true
        guard !isClosed, contextMatches(requireForeground: true) else {
            finishSharing(id: id, completed: false, error: nil); return nil
        }
        return ShareRequest(id: id, owner: self, output: output)
    }
    @discardableResult
    func retryCleanup() -> Bool {
        guard !isRunning, !isSharing else { return false }
        guard cleanupOwnedOutput() else { return false }
        errorMessage = nil; notice = "Previous movie files were cleared. No unknown file was deleted."
        return true
    }

    private func checkRunningContext() throws {
        try Task.checkCancellation()
        guard !isClosed, !cancellationRequested, contextMatches(requireForeground: true) else {
            throw CancellationError()
        }
    }
    private func contextMatches(requireForeground: Bool) -> Bool {
        guard let source, let editor, editor.isEditing,
              editor.document.id == source.projectID,
              currentScope.accountID == capturedAccountID,
              currentScope.isStudioVisible else { return false }
        return !requireForeground || currentScope.isForeground
    }
    private func cleanupOwnedOutput() -> Bool {
        guard !isCleaning else { return false }
        isCleaning = true
        defer { isCleaning = false }
        if let partial = unownedPartial {
            var info = stat()
            guard lstat(partial.path, &info) != 0, errno == ENOENT else {
                needsCleanup = true
                errorMessage = "A partial movie needs recovery. Its files were preserved; another export cannot start until that conflict is resolved."
                return false
            }
            unownedPartial = nil
        }
        if let output {
            do { try output.cleanup() }
            catch {
                needsCleanup = true; errorMessage = error.localizedDescription
                return false
            }
            self.output = nil
        }
        needsCleanup = false
        return true
    }
    private func finishSharing(id: UUID, completed: Bool, error: Error?) {
        guard activeShareID == id, isSharing else { return }
        activeShareID = nil
        if let error { errorMessage = error.localizedDescription; notice = nil }
        else { notice = completed ? "The share sheet reported completion." : "Sharing cancelled. The MP4 remains available." }
        if isClosed {
            if cleanupOwnedOutput() { notice = "Sharing ended. Export files were removed after the panel closed." }
        }
        isSharing = false
    }

    @MainActor final class ShareRequest: Identifiable {
        let id: UUID
        private var owner: StudioMovieExportSession?
        private let output: Service.Output
        private var finished = false
        fileprivate init(id: UUID, owner: StudioMovieExportSession, output: Service.Output) {
            self.id = id; self.owner = owner; self.output = output
        }
        func checkedURLs() throws -> [URL] {
            guard !finished, owner?.activeShareID == id else { throw Service.ExportError.outputUnavailable }
            return try output.checkedURLs()
        }
        func finish(completed: Bool, error: Error?) {
            guard !finished else { return }
            finished = true
            owner?.finishSharing(id: id, completed: completed, error: error)
            owner = nil
        }
        deinit {
            // If the UI abandons its request, release the session's sharing
            // state on its actor; no guessed success or immediate file deletion.
            if let owner, !finished {
                let requestID = id
                Task { @MainActor in owner.finishSharing(id: requestID, completed: false, error: nil) }
            }
        }
    }
}
