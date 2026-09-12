import SwiftUI
import UIKit

/// Real UIKit sharing with completion-bound file ownership. No video preview
/// consumer is created. Closing a presentation alone never releases a URL that
/// has been offered to UIKit; the bounded shared lease awaits its callback.
@MainActor
struct StudioMovieSharePresenter: UIViewControllerRepresentable {
    let request: StudioMovieExportSession.ShareRequest
    let session: StudioMovieExportSession
    let isAllowed: @MainActor () -> Bool
    let onTerminal: (UUID) -> Void

    func makeUIViewController(context: Context) -> Host {
        Host(request: request, session: session, isAllowed: isAllowed, onTerminal: onTerminal)
    }
    func updateUIViewController(_ controller: Host, context: Context) { controller.updateAuthorization(isAllowed) }
    static func dismantleUIViewController(_ controller: Host, coordinator: ()) { controller.detachFromPanel() }

    final class Host: UIViewController, UIAdaptivePresentationControllerDelegate {
        private let request: StudioMovieExportSession.ShareRequest
        private let session: StudioMovieExportSession
        private var onTerminal: ((UUID) -> Void)?
        private var isAllowed: @MainActor () -> Bool
        private var activity: Activity?
        private var lease: StudioMovieShareLifetime.Lease?
        private var deadline: Task<Void, Never>?
        private var attempted = false
        private var dismissedWithoutCompletion = false
        private var finished = false

        init(request: StudioMovieExportSession.ShareRequest, session: StudioMovieExportSession,
             isAllowed: @escaping @MainActor () -> Bool, onTerminal: @escaping (UUID) -> Void) {
            self.request = request; self.session = session; self.isAllowed = isAllowed; self.onTerminal = onTerminal
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("Programmatic movie sharing only") }
        override func loadView() {
            view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false
        }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); presentMovieIfPossible() }
        func updateAuthorization(_ allowed: @escaping @MainActor () -> Bool) {
            isAllowed = allowed
            if !allowed() { endWithoutCompletion() }
        }
        private func presentMovieIfPossible() {
            guard !attempted, !finished else { return }
            attempted = true
            guard isAllowed() else { failBeforeHandoff(nil); return }
            guard let window = view.window, presentedViewController == nil, !isBeingDismissed else {
                failBeforeHandoff(PresentationError.unavailable); return
            }
            let visibleBounds = view.convert(window.bounds, from: window).intersection(view.bounds)
            guard !visibleBounds.isNull, !visibleBounds.isEmpty,
                  visibleBounds.width.isFinite, visibleBounds.height.isFinite else {
                failBeforeHandoff(PresentationError.unavailable); return
            }
            do {
                let urls = try request.checkedURLs()
                guard let movie = urls.first, movie.isFileURL, movie.pathExtension.lowercased() == "mp4" else {
                    throw PresentationError.invalidMovie
                }
                let reservation = try StudioMovieShareLifetime.shared.reserve(request)
                lease = reservation
                // The initializer receives the URL; ownership must already be
                // reserved even if presentation subsequently fails or times out.
                reservation.offeredToUIKit()
                let controller = Activity(movieURL: movie)
                controller.appeared = { [weak self] in
                    guard let self else { return }
                    self.deadline?.cancel(); self.deadline = nil
                    if !self.isAllowed() { self.endWithoutCompletion() }
                }
                controller.completionWithItemsHandler = { [weak self, reservation] _, completed, _, error in
                    Task { @MainActor in
                        // This callback, not a dismiss animation completion,
                        // is the terminal event for the actual consumer lease.
                        reservation.consumerCompleted(completed: completed, error: error)
                        self?.completeUI()
                    }
                }
                if let popover = controller.popoverPresentationController {
                    popover.sourceView = view; popover.sourceRect = visibleBounds; popover.permittedArrowDirections = []
                }
                controller.presentationController?.delegate = self
                activity = controller
                deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    guard let self, self.activity?.didAppear != true else { return }
                    self.endWithoutCompletion()
                }
                present(controller, animated: true) { [weak self, weak controller] in
                    guard let self, let controller, !self.finished else { return }
                    controller.presentationController?.delegate = self
                    if controller.presentingViewController == nil || controller.view.window == nil {
                        self.endWithoutCompletion()
                    }
                }
            } catch { failBeforeHandoff(error) }
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { endWithoutCompletion() }
        func detachFromPanel() {
            guard !finished else { return }
            // Drop all UI callbacks, close the owner, and retain only its
            // unfinished request in the registry if UIKit has seen the URL.
            onTerminal = nil; isAllowed = { false }
            session.close()
            endWithoutCompletion()
        }
        private func endWithoutCompletion() {
            guard !finished else { return }
            guard let lease, lease.wasOffered else { failBeforeHandoff(nil); return }
            lease.presentationEndedWithoutCompletion()
            guard !dismissedWithoutCompletion else { return }
            dismissedWithoutCompletion = true; deadline?.cancel(); deadline = nil
            activity?.appeared = nil
            // Keep completionWithItemsHandler installed. Dismissal does not
            // finish the lease, whether or not its completion block runs.
            if let activity, activity.presentingViewController != nil { activity.dismiss(animated: false) }
        }
        private func failBeforeHandoff(_ error: Error?) {
            guard !finished else { return }
            guard lease?.wasOffered != true else { endWithoutCompletion(); return }
            if let lease { lease.failBeforeHandoff(error) }
            else { request.finish(completed: false, error: error) }
            completeUI()
        }
        private func completeUI() {
            guard !finished else { return }
            finished = true; deadline?.cancel(); deadline = nil
            activity?.appeared = nil
            activity = nil; lease = nil
            let callback = onTerminal; onTerminal = nil; isAllowed = { false }
            callback?(request.id)
        }
    }
    final class Activity: UIActivityViewController {
        var appeared: (() -> Void)?
        private(set) var didAppear = false
        init(movieURL: URL) { super.init(activityItems: [movieURL], applicationActivities: nil) }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); didAppear = true; appeared?() }
    }
    private enum PresentationError: LocalizedError {
        case unavailable, invalidMovie
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The iOS share sheet could not open. Try sharing again."
            case .invalidMovie: return "The MP4 is unavailable. Export it again before sharing."
            }
        }
    }
}
