import Foundation
import Combine
import CoreGraphics
import ImageIO

/// One presented Studio image surface owns one session. Picking/decoding never
/// mutates a project; only the explicit Add action calls the canonical editor.
@MainActor
final class StudioImageImportSession: ObservableObject {
    struct Scope: Equatable {
        let isStudioVisible: Bool
        let isForeground: Bool
        /// Nil identifies the current local guest, not cloud authentication.
        let accountID: String?
    }
    struct Preview {
        let name: String
        let width: Int
        let height: Int
        let originalWidth: Int
        let originalHeight: Int
        let originalOrientation: Int
        let originalByteCount: Int
        let normalizedByteCount: Int
        let container: StudioImageImportService.Container
    }
    struct AppliedImage {
        let assetID: String
        let projectID: UUID
        let revision: Int
        let frameID: String
        let name: String
    }
    enum Status: Equatable { case idle, picking, transferring, decoding, preview, applied, cancelled, stale, failed, closed }
    enum SaveState: Equatable {
        case unavailable, projectChanged, unsaved, saving, saved
        var text: String {
            switch self {
            case .unavailable: return "Save state unavailable for this image"
            case .projectChanged: return "The project changed after this image was added"
            case .unsaved: return "Unsaved"
            case .saving: return "Saving…"
            case .saved: return "Saved"
            }
        }
    }
    @Published private(set) var status: Status = .idle
    @Published private(set) var isWorking = false
    @Published private(set) var notice: String?
    @Published private(set) var progressText: String?
    @Published private(set) var preview: Preview?
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var appliedImage: AppliedImage?
    @Published private(set) var isClosed = false

    typealias ScopeProvider = @MainActor () -> Scope
    typealias Checkpoint = @MainActor () async throws -> Void
    private struct Capture: Equatable {
        let accountID: String?
        let projectID: UUID
        let revision: Int
        let frameID: String
        let layerID: String
    }
    private enum Source { case file(URL), photo(NSItemProvider) }
    private enum SessionError: LocalizedError {
        case unavailable, contextChanged, accountChanged, inactive, ineligible, previewUnavailable
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Open the Studio editor before importing an image. No image was added."
            case .contextChanged: return "The project, frame or layer changed. Cancel this preview and select the image again for the current editor."
            case .accountChanged: return "The active account changed. Open a new image import session in the current account."
            case .inactive: return "Return to the active Studio editor before adding this image."
            case .ineligible: return "Finish playback, saving and any active or rejected drawing before adding this image."
            case .previewUnavailable: return "The normalized image preview could not be decoded. No image was added."
            }
        }
    }
    private weak var studio: StudioViewModel?
    private var capture: Capture?
    private var token: UUID?
    private var request: Task<Void, Never>?
    private var requestID: UUID?
    private var imported: StudioImageImportService.ImportedImage?
    private let scratchParent: URL
    private let checkpoint: Checkpoint
    private let importer: StudioImageImportService
    private let cleanupFailure: @Sendable (Error) -> Void

    /// The checkpoint only controls scheduling in tests. Decode, provider copy,
    /// validation, attachment, undo and persistence always use production code.
    init(scratchParent: URL = FileManager.default.temporaryDirectory,
         importer: StudioImageImportService = .shared,
         cleanupFailure: @escaping @Sendable (Error) -> Void = { _ in
             NSLog("Studio image import cleanup needs attention. No image was added by that pending operation.")
         },
         checkpoint: @escaping Checkpoint = { await Task.yield(); try Task.checkCancellation() }) {
        self.scratchParent = scratchParent; self.importer = importer; self.checkpoint = checkpoint
        self.cleanupFailure = cleanupFailure
    }
    deinit { request?.cancel() }

    /// Capture before presenting either picker. A returned token authorizes this
    /// selection only, and is neither an image result nor a document mutation.
    @discardableResult
    func beginPicker(in studio: StudioViewModel, scope: Scope) -> UUID? {
        guard !isClosed, !isWorking, status != .picking else { return nil }
        if let capture, capture.accountID != scope.accountID {
            close(); notice = SessionError.accountChanged.localizedDescription; return nil
        }
        do {
            guard scope.isStudioVisible, studio.isEditing else { throw SessionError.unavailable }
            guard scope.isForeground else { throw SessionError.inactive }
            try Self.requireEligible(studio)
        } catch { fail(error); return nil }
        clearPreview(); appliedImage = nil; notice = nil; progressText = nil
        self.studio = studio
        capture = Capture(accountID: scope.accountID, projectID: studio.document.id,
            revision: studio.document.revision, frameID: studio.document.activeFrameID,
            layerID: studio.document.activeLayerID)
        let next = UUID(); token = next; status = .picking
        return next
    }

    @discardableResult
    func receiveFile(_ url: URL, token: UUID, currentScope: @escaping ScopeProvider) -> Bool {
        start(.file(url), token: token, currentScope: currentScope)
    }
    @discardableResult
    func receivePhoto(_ provider: NSItemProvider, token: UUID, currentScope: @escaping ScopeProvider) -> Bool {
        start(.photo(provider), token: token, currentScope: currentScope)
    }
    private func start(_ source: Source, token id: UUID, currentScope: @escaping ScopeProvider) -> Bool {
        guard !isClosed, !isWorking, status == .picking, token == id else { return false }
        do { try requireCurrent(id, scope: currentScope(), requireForeground: false) }
        catch { fail(error); return false }
        isWorking = true; requestID = id
        status = .transferring; progressText = "Preparing selected image…"; notice = nil
        request = Task { [weak self] in
            guard let self else { return }
            var owned: StudioImageProviderFile?
            defer {
                if self.requestID == id {
                    self.request = nil; self.requestID = nil; self.isWorking = false
                    self.progressText = nil
                }
            }
            do {
                try await self.checkpoint()
                try self.requireCurrent(id, scope: currentScope(), requireForeground: false)
                let url: URL, name: String?
                switch source {
                case .file(let selected): url = selected; name = nil
                case .photo(let provider):
                    let handle = try await StudioImagePickerTransfer.load(from: provider, scratchParent: self.scratchParent, cleanupFailure: self.cleanupFailure)
                    owned = handle
                    try self.requireCurrent(id, scope: currentScope(), requireForeground: false)
                    url = try handle.url(); name = handle.displayName
                }
                self.status = .decoding
                let result = try await self.importer.importImage(from: url, name: name, scratchParent: self.scratchParent) { [weak self] progress in
                    await self?.updateProgress(progress, token: id)
                }
                // A provider URL is never exposed to the UI. Its owned copy stays
                // alive throughout decode and is cleaned before publishing preview.
                if let handle = owned { try handle.cleanup(); owned = nil }
                try await self.checkpoint()
                try self.requireCurrent(id, scope: currentScope(), requireForeground: false)
                let thumbnail = try Self.thumbnail(result.normalizedPNG)
                self.imported = result
                self.preview = Preview(name: result.name, width: result.width, height: result.height,
                    originalWidth: result.originalWidth, originalHeight: result.originalHeight,
                    originalOrientation: result.originalOrientation, originalByteCount: result.originalData.count,
                    normalizedByteCount: result.normalizedPNG.count, container: result.container)
                self.previewImage = thumbnail; self.status = .preview
                self.notice = "Preview only. Add to current frame attaches the image on a new layer in one undoable edit."
            } catch {
                var failure = error
                if let handle = owned {
                    do { try handle.cleanup() }
                    catch { failure = error }
                }
                // Closing the UI must not hide a failed cleanup obligation.
                // The default reports a generic notice without paths or content.
                if Self.needsCleanupAttention(failure) { self.cleanupFailure(failure) }
                guard self.token == id, !self.isClosed else { return }
                self.fail(failure)
            }
        }
        return true
    }

    func pickerCancelled(token id: UUID) {
        guard token == id, status == .picking, !isWorking else { return }
        cancel()
    }
    func pickerFailed(_ error: Error, token id: UUID) {
        guard token == id, status == .picking, !isWorking else { return }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain && cocoa.code == CocoaError.userCancelled.rawValue {
            pickerCancelled(token: id)
        } else {
            status = .failed; notice = "The selected file could not be opened: " + error.localizedDescription
        }
    }
    func canApply(currentScope: Scope) -> Bool {
        guard !isClosed, !isWorking, imported != nil, status == .preview || status == .failed,
              let token else { return false }
        do { try requireCurrent(token, scope: currentScope, requireForeground: true); return true }
        catch { return false }
    }
    /// Only this explicit synchronous action attaches bytes. Failed attachment
    /// retains the decoded preview for retry while its original scope is current.
    @discardableResult
    func apply(currentScope: Scope) -> Bool {
        guard !isClosed, !isWorking, status == .preview || status == .failed,
              let imported, let captured = capture, let id = token else { return false }
        do {
            try requireCurrent(id, scope: currentScope, requireForeground: true)
            guard let studio else { throw SessionError.unavailable }
            let assetID = try studio.attachImportedImage(imported,
                expectedProjectID: captured.projectID, expectedRevision: captured.revision,
                frameID: captured.frameID, layerID: captured.layerID,
                checkCancellation: { try self.requireCurrent(id, scope: currentScope, requireForeground: true) })
            appliedImage = AppliedImage(assetID: assetID, projectID: captured.projectID,
                revision: studio.document.revision, frameID: captured.frameID, name: imported.name)
            self.imported = nil
            status = .applied; notice = "Added \(imported.name) on a new image layer in one undoable edit."
            return true
        } catch { fail(error); return false }
    }

    /// Temporary inactivity during a system picker preserves its transfer and
    /// preview. It never permits Add. Background/closed surfaces call close().
    /// Switching accounts or leaving Studio ends this session immediately.
    func refreshScope(_ scope: Scope) {
        guard !isClosed, let capture else { return }
        if scope.accountID != capture.accountID {
            close(); notice = SessionError.accountChanged.localizedDescription
        } else if !scope.isStudioVisible {
            close(); notice = SessionError.unavailable.localizedDescription
        }
    }
    func saveState(in studio: StudioViewModel, currentScope: Scope) -> SaveState {
        guard !isClosed, currentScope.isStudioVisible, currentScope.isForeground,
              currentScope.accountID == capture?.accountID, studio.isEditing,
              let result = appliedImage else { return .unavailable }
        guard studio.document.id == result.projectID, studio.document.revision == result.revision else { return .projectChanged }
        if studio.isSaving { return .saving }
        return studio.isDirty ? .unsaved : .saved
    }
    func cancel() {
        guard !isClosed else { return }
        let alreadyApplied = appliedImage != nil
        token = nil; request?.cancel(); capture = nil; studio = nil
        clearPreview(); appliedImage = nil; progressText = nil
        status = .cancelled
        notice = alreadyApplied ? "Import preview dismissed. The previously added image remains in the project."
            : "Image import cancelled. No image was added by this pending selection."
    }
    func close() {
        guard !isClosed else { return }
        cancel(); isClosed = true; status = .closed
        notice = "Image import session closed."
    }
    func waitForCompletion() async { let active = request; await active?.value }

    private func requireCurrent(_ id: UUID, scope: Scope, requireForeground: Bool) throws {
        try Task.checkCancellation()
        guard !isClosed, token == id else { throw CancellationError() }
        guard let capture, let studio, studio.isEditing, scope.isStudioVisible else { throw SessionError.unavailable }
        guard scope.accountID == capture.accountID else { throw SessionError.accountChanged }
        guard !requireForeground || scope.isForeground else { throw SessionError.inactive }
        guard studio.document.id == capture.projectID, studio.document.revision == capture.revision,
              studio.document.activeFrameID == capture.frameID, studio.document.activeLayerID == capture.layerID else { throw SessionError.contextChanged }
        try Self.requireEligible(studio)
    }
    private static func requireEligible(_ studio: StudioViewModel) throws {
        guard !studio.isSaving, !studio.isPlaying, studio.activeStrokeID == nil,
              studio.pendingBrushStroke == nil else { throw SessionError.ineligible }
    }
    private func updateProgress(_ progress: StudioImageImportService.Progress, token id: UUID) {
        guard token == id, !isClosed else { return }
        switch progress.phase {
        case .reading: progressText = "Reading image bytes: \(progress.completed) of \(progress.total)"
        case .validating: progressText = "Validating the image…"
        case .decoding: progressText = "Decoding image pixels…"
        case .encoding: progressText = "Preparing normalized image pixels…"
        }
    }
    private func fail(_ error: Error) {
        if error is CancellationError { status = .cancelled }
        else if let error = error as? SessionError {
            switch error {
            case .accountChanged:
                close(); notice = error.localizedDescription; return
            case .unavailable, .contextChanged: status = .stale
            default: status = .failed
            }
        } else { status = .failed }
        notice = error.localizedDescription
    }
    private static func needsCleanupAttention(_ error: Error) -> Bool {
        if case StudioImageImportService.ImportError.cleanupFailed = error { return true }
        if let error = error as? StudioImageProviderFile.Failure {
            switch error {
            case .cleanupFailed, .operationAndCleanupFailed: return true
            default: break
            }
        }
        return false
    }
    private func clearPreview() { imported = nil; preview = nil; previewImage = nil }
    private static func thumbnail(_ png: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), image.width > 0, image.height > 0,
              image.width <= 640, image.height <= 640 else { throw SessionError.previewUnavailable }
        return image
    }
}
