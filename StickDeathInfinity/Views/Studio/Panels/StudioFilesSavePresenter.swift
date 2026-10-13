import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One export request whose files may be handed to a system consumer. The MP4
/// and GIF sessions' share requests already carry this contract; the PNG panel
/// adapts its session below. `finish` runs exactly once per request.
@MainActor
protocol StudioExportFileRequest: AnyObject {
    var id: UUID { get }
    func checkedURLs() throws -> [URL]
    func finish(completed: Bool, error: Error?)
}
extension StudioMovieExportSession.ShareRequest: StudioExportFileRequest {}
extension StudioGIFExportSession.ShareRequest: StudioExportFileRequest {}

/// Save to Files without the share sheet (#185): the system document picker
/// copies the exported files into the folder the person chooses. The picker's
/// delegate callback, not its dismissal animation, ends the request; the files
/// stay owned by their export session until then. No destination is recorded,
/// so a completed save is a copy receipt, never a publication or upload claim.
@MainActor
struct StudioFilesSavePresenter: UIViewControllerRepresentable {
    let request: StudioExportFileRequest
    let isAllowed: @MainActor () -> Bool
    let onTerminal: (UUID) -> Void

    func makeUIViewController(context: Context) -> Host {
        Host(request: request, isAllowed: isAllowed, onTerminal: onTerminal)
    }
    func updateUIViewController(_ controller: Host, context: Context) { controller.updateAuthorization(isAllowed) }
    static func dismantleUIViewController(_ controller: Host, coordinator: ()) { controller.detachFromPanel() }

    final class Host: UIViewController, UIDocumentPickerDelegate {
        private let request: StudioExportFileRequest
        private var isAllowed: @MainActor () -> Bool
        private var onTerminal: ((UUID) -> Void)?
        private var picker: UIDocumentPickerViewController?
        private var attempted = false
        private var finished = false

        init(request: StudioExportFileRequest, isAllowed: @escaping @MainActor () -> Bool, onTerminal: @escaping (UUID) -> Void) {
            self.request = request; self.isAllowed = isAllowed; self.onTerminal = onTerminal
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("Programmatic export saving only") }
        override func loadView() {
            view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false
        }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); presentIfPossible() }
        func updateAuthorization(_ allowed: @escaping @MainActor () -> Bool) {
            isAllowed = allowed
            if !allowed() { end(completed: false, error: nil) }
        }
        private func presentIfPossible() {
            guard !attempted, !finished else { return }
            attempted = true
            guard isAllowed() else { end(completed: false, error: nil); return }
            guard view.window != nil, presentedViewController == nil, !isBeingDismissed else {
                end(completed: false, error: PresentationError.unavailable); return
            }
            do {
                let urls = try request.checkedURLs()
                guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { throw PresentationError.unavailable }
                // asCopy keeps the export directory untouched: the picker writes
                // copies, and the session's own cleanup rules still apply.
                let controller = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
                controller.delegate = self
                controller.shouldShowFileExtensions = true
                picker = controller
                present(controller, animated: true) { [weak self, weak controller] in
                    guard let self, let controller, !self.finished else { return }
                    if controller.presentingViewController == nil || controller.view.window == nil {
                        self.end(completed: false, error: PresentationError.unavailable)
                    }
                }
            } catch { end(completed: false, error: error) }
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // UIKit has finished copying every exported file when this arrives.
            end(completed: !urls.isEmpty, error: nil)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { end(completed: false, error: nil) }
        func detachFromPanel() {
            guard !finished else { return }
            onTerminal = nil; isAllowed = { false }
            end(completed: false, error: nil)
        }
        private func end(completed: Bool, error: Error?) {
            guard !finished else { return }
            finished = true
            if let picker, picker.presentingViewController != nil { picker.dismiss(animated: false) }
            picker = nil
            request.finish(completed: completed, error: error)
            let callback = onTerminal; onTerminal = nil; isAllowed = { false }
            callback?(request.id)
        }
    }
    private enum PresentationError: LocalizedError {
        case unavailable
        var errorDescription: String? { "The Files save sheet could not open. Try again." }
    }
}
