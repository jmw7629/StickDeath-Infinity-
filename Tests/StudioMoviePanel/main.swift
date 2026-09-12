import AppKit
import Combine
import SwiftUI
import AVFoundation

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}
@main @MainActor struct MoviePanelTests {
    static let fm = FileManager.default
    static let scope = StudioMovieExportSession.Scope(isStudioVisible: true, isForeground: true, accountID: nil)
    static func create(_ parent: URL) async throws -> (StudioViewModel, StudioMoviePanelState, URL) {
        try fm.createDirectory(at: parent, withIntermediateDirectories: false)
        let output = parent.appendingPathComponent("output")
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        let vm = StudioViewModel(storage: DeviceStorageManager(documentsDirectory: parent.appendingPathComponent("documents")))
        let created = await vm.createProject(name: "Actual movie panel", width: 64, height: 32, fps: 12)
        try require(created, "Production project create failed")
        try require(vm.commitElement(DrawnElement(id: UUID().uuidString, tool: .brush,
            points: [.init(x: 0,y: 16),.init(x: 64,y: 16)], color: "#FF0000", width: 64,
            opacity: 1, layerID: vm.activeLayerID)), "Production stroke failed")
        return (vm, StudioMoviePanelState(outputParent: output), output)
    }
    static func idle(_ state: StudioMoviePanelState) async throws {
        let deadline = Date().addingTimeInterval(15)
        while state.session.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        try require(!state.session.isRunning, "Movie panel work exceeded bounded wait")
    }
    static func actualRedMovie(_ state: StudioMoviePanelState) async throws {
        guard let output = state.session.output else { throw Failure(message: state.session.errorMessage ?? "Missing actual movie") }
        _ = try output.checkedURLs()
        let asset = AVURLAsset(url: output.movieURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        try require(tracks.count == 1, "Missing actual video track")
        let reader = try AVAssetReader(asset: asset)
        let track = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(track); try require(reader.startReading(), "Actual decoder unavailable")
        guard let sample = track.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else { throw Failure(message: "No real decoded frame") }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        try require(CVPixelBufferGetWidth(buffer) == 64 && CVPixelBufferGetHeight(buffer) == 32, "Wrong snapshot size")
        let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let index = 16 * CVPixelBufferGetBytesPerRow(buffer) + 32 * 4
        try require(pixels[index+2] > 240 && pixels[index] < 16 && pixels[index+1] < 16, "Panel output is not the actual red drawing")
        while track.copyNextSampleBuffer() != nil {}
        try require(reader.status == .completed, "Actual movie decode incomplete")
    }
    static func main() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-movie-panel-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        await test("actual movie exports through observable panel state then safely starts after close") {
            let (vm,state,output) = try await create(root.appendingPathComponent("fresh"))
            var notifications = 0
            let observer = state.objectWillChange.sink { notifications += 1 }
            try require(state.start(from: vm, background: .white, scope: scope) && state.isBusy, "Real export did not lock formats")
            let first = state.session
            try await idle(state); try await actualRedMovie(state)
            first.close(); try require(first.output == nil && fm.contentsOfDirectory(atPath: output.path).isEmpty, "Closed owned output leaked")
            try require(state.start(from: vm, background: .white, scope: scope) && state.session !== first, "A clean closed session prevented explicit new export")
            try await idle(state); try await actualRedMovie(state)
            try require(notifications > 4, "Nested production progress did not reach the panel observer")
            observer.cancel(); state.session.close()
        }
        await test("active native consumer ownership blocks session replacement through close") {
            let (vm,state,_) = try await create(root.appendingPathComponent("consumer"))
            try require(state.start(from: vm, background: .white, scope: scope), "Export refused")
            try await idle(state)
            let original = state.session
            guard let request = original.beginSharing(scope: scope) else { throw Failure(message: "Actual share request missing") }
            original.close()
            try require(state.isBusy && !state.start(from: vm, background: .white, scope: scope) && state.session === original,
                        "Closed active consumer was replaced")
            try require(request.checkedURLs().count == 2, "Active consumer files disappeared")
            request.finish(completed: false, error: nil)
            try require(!state.isBusy && original.output == nil, "Finished closed consumer did not release owned files")
            try require(state.start(from: vm, background: .white, scope: scope), "Finished consumer blocked explicit new export")
            try await idle(state); try await actualRedMovie(state); state.session.close()
        }
        await test("cleanup conflict prevents replacing a closed session until identity is restored") {
            let folder = root.appendingPathComponent("conflict"); let (vm,state,_) = try await create(folder)
            try require(state.start(from: vm, background: .white, scope: scope), "Export refused")
            try await idle(state)
            let original = state.session; let file = original.output!.movieURL; let backup = folder.appendingPathComponent("owned-original.mp4")
            try fm.moveItem(at: file, to: backup); let foreign = Data("Unowned replacement".utf8); try foreign.write(to: file)
            original.close()
            try require(original.needsCleanup && !state.start(from: vm, background: .white, scope: scope) && state.session === original,
                        "Unknown file permitted ownership replacement")
            try require(Data(contentsOf: file) == foreign, "Panel state deleted an unknown file")
            try fm.removeItem(at: file); try fm.moveItem(at: backup, to: file)
            try require(original.retryCleanup() && original.output == nil, "Restored ownership cleanup failed")
            try require(state.start(from: vm, background: .white, scope: scope), "Actual safe cleanup did not permit a new export")
            try await idle(state); try await actualRedMovie(state); state.session.close()
        }
        await test("unavailable current scope does not replace a closed session or create files") {
            let (vm,state,output) = try await create(root.appendingPathComponent("scope")); let original = state.session; original.close()
            for context in [StudioMovieExportSession.Scope(isStudioVisible: false,isForeground: true,accountID: nil),
                            .init(isStudioVisible: true,isForeground: false,accountID: nil)] {
                try require(!state.start(from: vm, background: .white, scope: context) && state.session === original,
                            "Unavailable context replaced the session")
            }
            try require(fm.contentsOfDirectory(atPath: output.path).isEmpty, "Unavailable scope wrote files")
        }
        // These are actual codec/file/ownership tests of the production lease.
        // Callback events below are explicit probes, not UIKit runtime claims.
        await test("completion-only lease preserves actual decoded files after close and failed presentation") {
            let (vm,state,_) = try await create(root.appendingPathComponent("lease-close"))
            try require(state.start(from: vm, background: .white, scope: scope), "Export refused")
            try await idle(state); try await actualRedMovie(state)
            var request = state.session.beginSharing(scope: scope)
            guard request != nil else { throw Failure(message: "Missing request") }
            weak var weakRequest = request
            let lease = try StudioMovieShareLifetime.shared.reserve(request!)
            defer { lease.consumerCompleted(completed: false, error: nil) }
            lease.offeredToUIKit(); state.session.close(); request = nil
            lease.presentationEndedWithoutCompletion()
            lease.failBeforeHandoff(Failure(message: "Late presentation failure"))
            try require(StudioMovieShareLifetime.shared.isReserved && !lease.isFinished && state.isBusy,
                        "Dismissal or late failure released an offered URL")
            try require(StudioMovieShareLifetime.shared.pendingMessage != nil && weakRequest != nil,
                        "Uncertain consumer was silently lost")
            try await actualRedMovie(state)
            lease.consumerCompleted(completed: false, error: nil)
            try require(!StudioMovieShareLifetime.shared.isReserved && state.session.output == nil && !state.isBusy,
                        "Real cancellation callback failed to release the closed owner")
        }
        await test("one global outstanding consumer blocks another share without deleting either actual movie") {
            let (vm,a,_) = try await create(root.appendingPathComponent("lease-first"))
            try require(a.start(from: vm, background: .white, scope: scope), "First export refused")
            try await idle(a)
            let requestA = a.session.beginSharing(scope: scope)!
            let leaseA = try StudioMovieShareLifetime.shared.reserve(requestA)
            defer { leaseA.consumerCompleted(completed: false, error: nil); a.session.close() }
            leaseA.offeredToUIKit(); leaseA.presentationEndedWithoutCompletion()
            let (vmB,b,_) = try await create(root.appendingPathComponent("lease-second"))
            try require(b.start(from: vmB, background: .white, scope: scope), "Second export refused")
            try await idle(b)
            let requestB = b.session.beginSharing(scope: scope)!
            var rejection: Error?
            do { _ = try StudioMovieShareLifetime.shared.reserve(requestB) }
            catch { rejection = error }
            try require(rejection is StudioMovieShareLifetime.ShareError, "Second share was not bounded")
            requestB.finish(completed: false, error: rejection) // never offered to UIKit
            try require(!b.session.isSharing && a.session.isSharing, "Rejected pre-handoff request released the active consumer")
            try await actualRedMovie(a); try await actualRedMovie(b)
            leaseA.consumerCompleted(completed: true, error: nil)
            try require(a.session.notice == "The share sheet reported completion.", "Consumer result was invented or dropped")
            b.session.close()
        }
        await test("pre-handoff failure releases its lease while post-handoff error waits for consumer callback") {
            let (vm,state,_) = try await create(root.appendingPathComponent("lease-before"))
            try require(state.start(from: vm, background: .white, scope: scope), "Export refused")
            try await idle(state)
            let request = state.session.beginSharing(scope: scope)!
            let lease = try StudioMovieShareLifetime.shared.reserve(request)
            state.session.close()
            lease.failBeforeHandoff(NSError(domain: "Actual presentation probe", code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: "Before UIKit received URL"]))
            try require(lease.isFinished && !StudioMovieShareLifetime.shared.isReserved && state.session.output == nil,
                        "Unhanded request did not clean the closed owner")
            try require(state.start(from: vm, background: .white, scope: scope), "Fresh export blocked")
            try await idle(state)
            let next = try StudioMovieShareLifetime.shared.reserve(state.session.beginSharing(scope: scope)!)
            defer { next.consumerCompleted(completed: false, error: nil); state.session.close() }
            next.offeredToUIKit(); next.presentationEndedWithoutCompletion()
            next.consumerCompleted(completed: false, error: NSError(domain: "Actual consumer probe", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Destination reported an error"]))
            try require(!state.session.isSharing && state.session.errorMessage == "Destination reported an error",
                        "Actual consumer error did not remain factual")
            try await actualRedMovie(state)
        }
        await test("duplicate late callback cannot release a newer sharing lease") {
            let (vm,state,_) = try await create(root.appendingPathComponent("lease-replay"))
            try require(state.start(from: vm, background: .white, scope: scope), "Export refused")
            try await idle(state)
            let old = try StudioMovieShareLifetime.shared.reserve(state.session.beginSharing(scope: scope)!)
            old.offeredToUIKit(); old.consumerCompleted(completed: false, error: nil)
            let current = try StudioMovieShareLifetime.shared.reserve(state.session.beginSharing(scope: scope)!)
            defer { current.consumerCompleted(completed: false, error: nil); state.session.close() }
            current.offeredToUIKit()
            old.consumerCompleted(completed: true, error: nil)
            old.presentationEndedWithoutCompletion(); old.failBeforeHandoff(nil)
            try require(StudioMovieShareLifetime.shared.isReserved && state.session.isSharing && !current.isFinished,
                        "Late callback released a different consumer")
            try require(StudioMovieShareLifetime.shared.pendingMessage == nil, "Late callback contaminated current presentation")
            try await actualRedMovie(state)
        }
        print("STUDIO_MOVIE_PANEL_TESTS=\(failed == 0 ? "PASS" : "FAIL") \(passed)/\(passed + failed)")
        if failed != 0 { exit(1) }
    }
}
