import Foundation
import Combine

/// Keeps the movie session observable alongside the unchanged PNG session.
/// A closed session is replaced only after owned cleanup/consumers finish and
/// the user explicitly starts a fresh export in the actual current scope.
@MainActor
final class StudioMoviePanelState: ObservableObject {
    typealias DirectRequest = StudioMovieExportRequest
    @Published private(set) var directError: String?
    @Published private(set) var directSource: DirectRequest?
    private var handledDirectIDs: Set<UUID> = []
    @Published private(set) var session: StudioMovieExportSession
    private var observation: AnyCancellable?
    private let outputParent: URL
    private let limits: StudioMovieExportService.Limits

    init(outputParent: URL = FileManager.default.temporaryDirectory,
         limits: StudioMovieExportService.Limits = .init()) {
        self.outputParent = outputParent; self.limits = limits
        session = StudioMovieExportSession(outputParent: outputParent, limits: limits)
        observeSession()
    }
    var isBusy: Bool { session.isRunning || session.isSharing || session.isRecovering }

    @discardableResult
    func start(from vm: StudioViewModel, background: StudioMovieExportService.Background,
               scope: StudioMovieExportSession.Scope,
               expectedRequest: DirectRequest? = nil) -> Bool {
        guard !isBusy, scope.isStudioVisible, scope.isForeground else { return false }
        if session.isClosed {
            guard !session.needsCleanup, session.output == nil else { return false }
            session = StudioMovieExportSession(outputParent: outputParent, limits: limits)
            observeSession()
        }
        directError = nil; directSource = nil
        return session.start(from: vm, background: background, scope: scope, expectedRequest: expectedRequest)
    }
    /// Consume even rejected requests: presentation retries are not authority
    /// to rerun exports. Manual Export remains available after a rejected handoff.
    @discardableResult
    func start(_ request: DirectRequest, from vm: StudioViewModel, scope: StudioMovieExportSession.Scope) -> Bool {
        guard handledDirectIDs.count < 64, handledDirectIDs.insert(request.editRequestID).inserted else {
            directError = "This direct export request was already handled. Use Export MP4 to start a new export."
            return false
        }
        guard scope.isStudioVisible, scope.isForeground, scope.accountID == request.accountID,
              vm.isEditing, vm.document.id == request.projectID, vm.document.revision == request.revision,
              !vm.isDirty, !vm.isSaving, !vm.isPlaying, vm.textDraft == nil,
              vm.activeStrokeID == nil, vm.pendingBrushStroke == nil else {
            directError = "The saved Spatter edit or active account changed before export. Nothing was exported."
            return false
        }
        guard start(from: vm, background: .white, scope: scope, expectedRequest: request) else {
            directError = session.errorMessage ?? "MP4 export could not start in the current Studio state."
            return false
        }
        directSource = request
        return true
    }
    /// Provenance is shown only for a still-owned, checked actual artifact.
    var directArtifactDescription: String? {
        guard let directSource, let output = session.output, !session.isRunning,
              !session.needsCleanup, !session.isClosed, !output.isCleaned,
              output.manifest.projectID == directSource.projectID,
              output.manifest.documentRevision == directSource.revision,
              (try? output.checkedURLs()) != nil else { return nil }
        return "Spatter edit \(directSource.editRequestID.uuidString) · verified MP4 from revision \(directSource.revision)"
    }
    private func observeSession() {
        observation = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
