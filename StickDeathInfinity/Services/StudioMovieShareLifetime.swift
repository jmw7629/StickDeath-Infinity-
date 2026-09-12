import Foundation
import Combine

/// At most one MP4 can await a UIKit consumer completion in this process.
/// Once offered to UIKit, disappearance/dismissal/timeouts are not proof that
/// an activity extension stopped reading. Keep the unfinished request alive.
/// No view, VM, account object, or UI callback is retained here.
@MainActor
final class StudioMovieShareLifetime: ObservableObject {
    static let shared = StudioMovieShareLifetime()
    @Published private(set) var isReserved = false
    @Published private(set) var pendingMessage: String?
    private var active: Lease?
    private init() {}

    enum ShareError: LocalizedError {
        case reserved
        var errorDescription: String? {
            "Another MP4 is still reserved by the sharing app. Wait for it to finish before sharing again."
        }
    }
    func reserve(_ request: StudioMovieExportSession.ShareRequest) throws -> Lease {
        guard active == nil else { throw ShareError.reserved }
        let lease = Lease(request: request, owner: self)
        active = lease; isReserved = true; pendingMessage = nil
        return lease
    }
    private func markPending(_ lease: Lease) {
        guard active === lease else { return }
        pendingMessage = "Waiting for the sharing app to finish. The MP4 is still reserved."
    }
    private func release(_ lease: Lease) {
        guard active === lease else { return }
        active = nil; isReserved = false; pendingMessage = nil
    }

    @MainActor final class Lease {
        private let request: StudioMovieExportSession.ShareRequest
        private weak var owner: StudioMovieShareLifetime?
        private(set) var wasOffered = false
        private(set) var isFinished = false
        fileprivate init(request: StudioMovieExportSession.ShareRequest, owner: StudioMovieShareLifetime) {
            self.request = request; self.owner = owner
        }
        /// Call immediately before passing the URL to UIActivityViewController.
        func offeredToUIKit() { if !isFinished { wasOffered = true } }
        func presentationEndedWithoutCompletion() {
            guard wasOffered, !isFinished else { return }
            owner?.markPending(self)
        }
        /// Legal only before UIKit has received any URL. A post-handoff failure
        /// instead keeps its lease until completionWithItemsHandler arrives.
        func failBeforeHandoff(_ error: Error?) {
            guard !wasOffered, !isFinished else { return }
            finish(completed: false, error: error)
        }
        /// The presenter invokes this only from completionWithItemsHandler.
        func consumerCompleted(completed: Bool, error: Error?) {
            guard wasOffered, !isFinished else { return }
            finish(completed: completed, error: error)
        }
        private func finish(completed: Bool, error: Error?) {
            guard !isFinished else { return }
            isFinished = true
            // Keep the registry reserved through synchronous session cleanup.
            request.finish(completed: completed, error: error)
            owner?.release(self)
        }
    }
}
