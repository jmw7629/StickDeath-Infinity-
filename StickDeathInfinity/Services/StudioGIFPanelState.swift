import Foundation
import Combine

/// Keeps the GIF session observable alongside the unchanged PNG session.
/// A closed session is replaced only after owned cleanup/consumers finish and
/// the user explicitly starts a fresh export in the actual current scope.
@MainActor
final class StudioGIFPanelState: ObservableObject {
    /// The Spatter handoff request is format-neutral: the same saved-edit identity
    /// is used for a direct MP4 or a direct GIF export (#215).
    typealias DirectRequest = StudioMovieExportRequest
    @Published private(set) var session: StudioGIFExportSession
    @Published var maximumDimension: Int = 0
    @Published private(set) var directError: String?
    @Published private(set) var directSource: DirectRequest?
    private var handledDirectIDs: Set<UUID> = []
    private var observation: AnyCancellable?
    private let outputParent: URL

    init(outputParent: URL = FileManager.default.temporaryDirectory) {
        self.outputParent = outputParent
        session = StudioGIFExportSession(outputParent: outputParent)
        observeSession()
    }
    var isBusy: Bool { session.isRunning || session.isSharing }

    @discardableResult
    func start(from vm: StudioViewModel, scope: StudioGIFExportSession.Scope) -> Bool {
        guard !isBusy, scope.isStudioVisible, scope.isForeground else { return false }
        if session.isClosed {
            guard !session.needsCleanup, session.output == nil else { return false }
            session = StudioGIFExportSession(outputParent: outputParent)
            observeSession()
        }
        directError = nil; directSource = nil
        return session.start(from: vm, scope: scope, maximumDimension: maximumDimension == 0 ? nil : maximumDimension)
    }
    /// Direct GIF export handed off by a saved Spatter edit. Consume even rejected
    /// requests: presentation retries are not authority to rerun exports. Manual
    /// Export GIF remains available after a rejected handoff.
    @discardableResult
    func start(_ request: DirectRequest, from vm: StudioViewModel, scope: StudioGIFExportSession.Scope) -> Bool {
        guard handledDirectIDs.count < 64, handledDirectIDs.insert(request.editRequestID).inserted else {
            directError = "This direct export request was already handled. Use Export GIF to start a new export."
            return false
        }
        guard scope.isStudioVisible, scope.isForeground, scope.accountID == request.accountID,
              vm.isEditing, vm.document.id == request.projectID, vm.document.revision == request.revision,
              !vm.isDirty, !vm.isSaving, !vm.isPlaying, vm.textDraft == nil,
              vm.activeStrokeID == nil, vm.pendingBrushStroke == nil else {
            directError = "The saved Spatter edit or active account changed before export. Nothing was exported."
            return false
        }
        guard start(from: vm, scope: scope) else {
            directError = session.errorMessage ?? "GIF export could not start in the current Studio state."
            return false
        }
        directSource = request
        return true
    }
    /// Provenance is shown only for a still-owned, checked actual artifact whose
    /// encoder receipt names the requested project and revision.
    var directArtifactDescription: String? {
        guard let directSource, let output = session.output, !session.isRunning,
              !session.needsCleanup, !session.isClosed, !output.isCleaned,
              output.receipt.projectID == directSource.projectID,
              output.receipt.revision == directSource.revision,
              (try? output.checkedURLs()) != nil else { return nil }
        return "Spatter edit \(directSource.editRequestID.uuidString) · verified GIF from revision \(directSource.revision)"
    }
    private func observeSession() {
        observation = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
