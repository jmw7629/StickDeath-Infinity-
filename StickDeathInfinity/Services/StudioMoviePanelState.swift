import Foundation
import Combine

/// Keeps the movie session observable alongside the unchanged PNG session.
/// A closed session is replaced only after owned cleanup/consumers finish and
/// the user explicitly starts a fresh export in the actual current scope.
@MainActor
final class StudioMoviePanelState: ObservableObject {
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
               scope: StudioMovieExportSession.Scope) -> Bool {
        guard !isBusy, scope.isStudioVisible, scope.isForeground else { return false }
        if session.isClosed {
            guard !session.needsCleanup, session.output == nil else { return false }
            session = StudioMovieExportSession(outputParent: outputParent, limits: limits)
            observeSession()
        }
        return session.start(from: vm, background: background, scope: scope)
    }
    private func observeSession() {
        observation = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
