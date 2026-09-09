import Foundation

/// Bridges the actual Photos item provider. Its temporary URL is valid only
/// inside the callback, so the bounded copy must finish before that callback
/// returns. The returned handle is not a decoded image or a document edit.
enum StudioImagePickerTransfer {
    enum Failure: LocalizedError {
        case unsupportedRepresentation, unavailable, timedOut, invalidDeadline
        var errorDescription: String? {
            switch self {
            case .unsupportedRepresentation: return "Choose a still JPEG, PNG or HEIF image. This photo representation is not supported."
            case .unavailable: return "The photo provider could not supply the selected file. Try again when it is available."
            case .timedOut: return "The photo transfer timed out. No image was added. Try again when the photo is downloaded."
            case .invalidDeadline: return "The photo transfer could not start."
            }
        }
    }

    /// Registered order preserves the provider's preferred supported format;
    /// requesting generic image/data can cause undocumented transcoding.
    static func preferredType(in provider: NSItemProvider) -> String? {
        let supported: Set<String> = ["public.jpeg", "public.png", "public.heic", "public.heif"]
        return provider.registeredTypeIdentifiers.first { supported.contains($0) }
    }

    static func load(from provider: NSItemProvider,
                     scratchParent: URL = FileManager.default.temporaryDirectory,
                     timeoutSeconds: TimeInterval = 120,
                     cleanupFailure: @escaping @Sendable (Error) -> Void = { _ in
                         NSLog("StickDeath photo transfer cleanup requires attention.")
                     }) async throws -> StudioImageProviderFile {
        try Task.checkCancellation()
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 120 else {
            throw Failure.invalidDeadline
        }
        guard let type = preferredType(in: provider) else { throw Failure.unsupportedRepresentation }
        let name = provider.suggestedName ?? "Imported photo"
        let state = CallbackState(cleanupFailure: cleanupFailure)
        let owned: StudioImageProviderFile = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.begin(continuation, timeoutSeconds: timeoutSeconds) else { return }
                let progress = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    guard state.claimCallback() else { return }
                    guard error == nil, let url else {
                        state.finish(.failure(Failure.unavailable)); return
                    }
                    do {
                        // This synchronous bounded copy is intentionally inside
                        // the provider callback. ImageIO decoding happens later.
                        let copy = try StudioImageProviderFile.materialize(from: url,
                            suggestedName: name, scratchParent: scratchParent,
                            isCancelled: { state.isCancelled },
                            abandonedCleanupFailure: cleanupFailure)
                        state.finish(.success(copy))
                    } catch { state.finish(.failure(error)) }
                }
                state.attach(progress)
            }
        } onCancel: { state.cancel(CancellationError()) }
        do { try Task.checkCancellation(); return owned }
        catch {
            let cancellation = error
            do { try owned.cleanup() }
            catch { throw StudioImageProviderFile.Failure.operationAndCleanupFailed(operation: cancellation) }
            throw cancellation
        }
    }

    /// No user callbacks or continuation resumes run while this lock is held.
    /// Cancellation resolves the waiter even if an external provider never
    /// calls back. A late callback cannot publish an owned file into a new edit.
    private final class CallbackState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<StudioImageProviderFile, Error>?
        private var progress: Progress?
        private var timer: DispatchWorkItem?
        private var finished = false
        private var callbackClaimed = false
        private var terminalError: Error?
        private let cleanupFailure: @Sendable (Error) -> Void

        init(cleanupFailure: @escaping @Sendable (Error) -> Void) { self.cleanupFailure = cleanupFailure }

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return terminalError != nil
        }

        func begin(_ value: CheckedContinuation<StudioImageProviderFile, Error>,
                   timeoutSeconds: TimeInterval) -> Bool {
            let work = DispatchWorkItem { [weak self] in self?.cancel(Failure.timedOut) }
            lock.lock()
            if finished {
                let error = terminalError ?? CancellationError(); lock.unlock()
                value.resume(throwing: error); return false
            }
            continuation = value; timer = work
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: work)
            return true
        }

        func attach(_ value: Progress) {
            lock.lock()
            let cancelNow = terminalError != nil
            if !finished { progress = value }
            lock.unlock()
            if cancelNow { value.cancel() }
        }

        func claimCallback() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !finished, !callbackClaimed else { return false }
            callbackClaimed = true; return true
        }

        func cancel(_ error: Error) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true; terminalError = error
            let waiter = continuation, pending = progress, deadline = timer
            continuation = nil; progress = nil; timer = nil
            lock.unlock()
            deadline?.cancel(); pending?.cancel(); waiter?.resume(throwing: error)
        }

        func finish(_ result: Result<StudioImageProviderFile, Error>) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                if case .success(let owned) = result {
                    do { try owned.cleanup() } catch { cleanupFailure(error) }
                } else if case .failure(let error) = result,
                          let transferError = error as? StudioImageProviderFile.Failure {
                    switch transferError {
                    case .cleanupFailed, .operationAndCleanupFailed: cleanupFailure(error)
                    default: break
                    }
                }
                return
            }
            finished = true
            let waiter = continuation, deadline = timer
            continuation = nil; progress = nil; timer = nil
            lock.unlock()
            deadline?.cancel(); waiter?.resume(with: result)
        }
    }
}
