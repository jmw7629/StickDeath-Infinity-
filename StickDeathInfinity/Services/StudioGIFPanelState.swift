import Foundation
import Combine

/// Keeps the GIF session observable alongside the unchanged PNG session.
/// A closed session is replaced only after owned cleanup/consumers finish and
/// the user explicitly starts a fresh export in the actual current scope.
@MainActor
final class StudioGIFPanelState: ObservableObject {
    @Published private(set) var session: StudioGIFExportSession
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
        return session.start(from: vm, scope: scope)
    }
    private func observeSession() {
        observation = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
