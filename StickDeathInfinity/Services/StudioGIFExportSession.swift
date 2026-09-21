import Foundation
import Combine
import Darwin

/// Captures one real document and owns its GIF until every consumer finishes.
/// A completed file is not a destination-save or publishing receipt.
@MainActor
final class StudioGIFExportSession: ObservableObject {
    struct Scope {
        let isStudioVisible: Bool
        let isForeground: Bool
        let accountID: String?
    }
    struct Source {
        let projectID: UUID
        let revision: Int
        let name: String
    }
    @Published private(set) var isRunning = false
    @Published private(set) var isSharing = false
    @Published private(set) var isClosed = false
    @Published private(set) var needsCleanup = false
    @Published private(set) var completedFrames = 0
    @Published private(set) var totalFrames = 0
    @Published private(set) var phase: StudioGIFEncoder.Phase?
    @Published private(set) var source: Source?
    @Published private(set) var output: StudioGIFExportService.Output?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?

    private let outputParent: URL
    private weak var editor: StudioViewModel?
    private var currentScope = Scope(isStudioVisible: false, isForeground: false, accountID: nil)
    private var accountID: String?
    private var task: Task<Void, Never>?
    private var runID: UUID?
    private var shareID: UUID?
    private var cancelled = false
    private var isStarting = false
    private var isBeginningShare = false
    private var isCleaning = false
    // A pre-return failure supplies no safe deletion handle. Check absence
    // only; never adopt or remove files through this path.
    private var unownedPartial: URL?

    init(outputParent: URL = FileManager.default.temporaryDirectory) { self.outputParent = outputParent }

    @discardableResult
    func start(from vm: StudioViewModel, scope: Scope) -> Bool {
        guard !isClosed, !isRunning, !isSharing, !isStarting, !isBeginningShare, !isCleaning else { return false }
        isStarting = true
        defer { isStarting = false }
        guard scope.isStudioVisible, scope.isForeground, vm.isEditing else {
            errorMessage = "Open the current Studio project before exporting GIF."; return false
        }
        guard vm.activeStrokeID == nil, vm.pendingBrushStroke == nil else {
            errorMessage = "Finish or resolve the current drawing before exporting GIF."; return false
        }
        currentScope = scope
        guard cleanupOutput() else { return false }
        guard !isClosed, currentScope.isStudioVisible, currentScope.isForeground,
              currentScope.accountID == scope.accountID, vm.isEditing,
              vm.activeStrokeID == nil, vm.pendingBrushStroke == nil else { return false }
        let document = vm.document
        var rasters: [String: Data] = [:]
        for id in Set(document.frames.compactMap(\.rasterAssetID)) {
            if let bytes = vm.rasterData(id) { rasters[id] = bytes }
        }
        let snapshot = StudioGIFEncoder.Snapshot(document: document, rasterDataByID: rasters)
        editor = vm; accountID = scope.accountID
        source = Source(projectID: document.id, revision: document.revision, name: document.name)
        errorMessage = nil; notice = nil; completedFrames = 0
        totalFrames = document.frames.count; phase = nil; cancelled = false
        // Published observers can synchronously close or change the scope.
        guard !isClosed, contextMatches(foreground: true) else { return false }
        let id = UUID(); runID = id; isRunning = true
        task = Task { [self, snapshot] in
            do {
                try checkContext()
                let result = try await StudioGIFExportService().export(snapshot, outputParent: outputParent) { [self] progress in
                    try checkContext()
                    phase = progress.phase; completedFrames = progress.completed; totalFrames = progress.total
                    try checkContext()
                }
                // Retain the deletion handle even if a synchronous observer
                // closes the panel while the completed output is published.
                output = result
                try checkContext()
                _ = try result.checkedURLs()
                notice = "GIF ready on this device from revision \(result.receipt.revision). GIF has no audio and uses a white background."
            } catch is CancellationError {
                notice = "GIF export cancelled."
            } catch {
                if case StudioGIFExportService.Failure.cleanup(let path) = error, output == nil {
                    unownedPartial = path; needsCleanup = true
                }
                errorMessage = error.localizedDescription
            }
            if isClosed || cancelled || !contextMatches(foreground: true) { _ = cleanupOutput() }
            if runID == id { runID = nil; task = nil; isRunning = false }
        }
        return true
    }

    func refreshScope(_ scope: Scope) {
        currentScope = scope
        guard source != nil else { return }
        if !contextMatches(foreground: false) { close() }
        else if !scope.isForeground { cancel() }
    }
    func cancel() {
        guard isRunning else { return }
        cancelled = true; task?.cancel(); notice = "Cancelling GIF export…"
    }
    func close() {
        isClosed = true; cancel()
        if !isRunning && !isSharing { _ = cleanupOutput() }
    }
    @discardableResult
    func retryCleanup() -> Bool {
        guard !isRunning, !isSharing, !isStarting, !isBeginningShare else { return false }
        guard cleanupOutput() else { return false }
        errorMessage = nil; notice = "Previous GIF files were cleared. Conflicting files were preserved."
        return true
    }
    func beginSharing(scope: Scope) -> ShareRequest? {
        guard !isBeginningShare else { return nil }
        isBeginningShare = true
        defer { isBeginningShare = false }
        refreshScope(scope)
        guard !isClosed, !isRunning, !isSharing, !isStarting, !isCleaning, !needsCleanup,
              contextMatches(foreground: true), let output else { return nil }
        do { _ = try output.checkedURLs() }
        catch { needsCleanup = true; errorMessage = error.localizedDescription; return nil }
        let id = UUID(); shareID = id
        errorMessage = nil; notice = nil; isSharing = true
        guard !isClosed, contextMatches(foreground: true) else {
            finishSharing(id: id, completed: false, error: nil); return nil
        }
        return ShareRequest(id: id, owner: self, output: output)
    }

    private func contextMatches(foreground: Bool) -> Bool {
        guard let source, let editor, editor.isEditing, editor.document.id == source.projectID,
              currentScope.accountID == accountID, currentScope.isStudioVisible else { return false }
        return !foreground || currentScope.isForeground
    }
    private func checkContext() throws {
        try Task.checkCancellation()
        guard !isClosed, !cancelled, contextMatches(foreground: true) else { throw CancellationError() }
    }
    private func cleanupOutput() -> Bool {
        guard !isCleaning else { return false }
        isCleaning = true
        defer { isCleaning = false }
        if let path = unownedPartial {
            var info = stat()
            // fileExists follows links and would treat a dangling replacement
            // as absent. lstat must specifically report ENOENT.
            guard lstat(path.path, &info) != 0, errno == ENOENT else {
                needsCleanup = true; errorMessage = "Previous temporary GIF files need recovery. They were preserved."; return false
            }
            unownedPartial = nil
        }
        if let output {
            do { try output.cleanup() }
            catch { needsCleanup = true; errorMessage = error.localizedDescription; return false }
            self.output = nil
        }
        needsCleanup = false
        return true
    }
    private func finishSharing(id: UUID, completed: Bool, error: Error?) {
        guard shareID == id, isSharing else { return }
        shareID = nil
        if let error { errorMessage = error.localizedDescription; notice = nil }
        else { notice = completed ? "The share sheet reported completion." : "Sharing cancelled. The GIF remains available." }
        if isClosed, cleanupOutput() { notice = "Sharing ended. The closed panel's GIF files were removed." }
        isSharing = false
    }

    /// Retain until the real consumer callback. Dismissal alone is not a
    /// consumer-completion event; the native presenter must keep this request.
    @MainActor final class ShareRequest: Identifiable {
        let id: UUID
        private var owner: StudioGIFExportSession?
        private let output: StudioGIFExportService.Output
        private var finished = false
        fileprivate init(id: UUID, owner: StudioGIFExportSession, output: StudioGIFExportService.Output) {
            self.id = id; self.owner = owner; self.output = output
        }
        func checkedURLs() throws -> [URL] {
            guard !finished, owner?.shareID == id else { throw StudioGIFExportService.Failure.unavailable }
            return try output.checkedURLs()
        }
        func finish(completed: Bool, error: Error?) {
            guard !finished else { return }
            finished = true
            owner?.finishSharing(id: id, completed: completed, error: error); owner = nil
        }
        deinit {
            if let owner, !finished {
                let id = id
                Task { @MainActor in owner.finishSharing(id: id, completed: false, error: nil) }
            }
        }
    }
}
