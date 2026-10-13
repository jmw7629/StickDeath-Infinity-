import AppKit
import Combine
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}
@main @MainActor struct GIFPanelTests {
    static let fm = FileManager.default
    static let scope = StudioGIFExportSession.Scope(isStudioVisible: true, isForeground: true, accountID: nil)
    static func create(_ parent: URL) async throws -> (StudioViewModel, StudioGIFPanelState, URL) {
        try fm.createDirectory(at: parent, withIntermediateDirectories: false)
        let output = parent.appendingPathComponent("output")
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        let vm = StudioViewModel(storage: DeviceStorageManager(documentsDirectory: parent.appendingPathComponent("documents")))
        let created = await vm.createProject(name: "Actual GIF panel", width: 64, height: 32, fps: 12)
        try require(created, "Production project create failed")
        try require(vm.commitElement(DrawnElement(id: UUID().uuidString, tool: .brush,
            points: [.init(x: 0,y: 16),.init(x: 64,y: 16)], color: "#FF0000", width: 64,
            opacity: 1, layerID: vm.activeLayerID)), "Production stroke failed")
        return (vm, StudioGIFPanelState(outputParent: output), output)
    }
    static func idle(_ state: StudioGIFPanelState) async throws {
        let deadline = Date().addingTimeInterval(15)
        while state.session.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        try require(!state.session.isRunning, "GIF panel work exceeded bounded wait")
    }
    static func actualRedGIF(_ state: StudioGIFPanelState) async throws {
        guard let output = state.session.output else { throw Failure(message: state.session.errorMessage ?? "Missing actual GIF") }
        _ = try output.checkedURLs()
        guard let source = CGImageSourceCreateWithURL(output.gifURL as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.gif.identifier,
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "Actual GIF did not decode") }
        try require(image.width == 64 && image.height == 32, "Wrong actual GIF canvas")
        var pixels = [UInt8](repeating: 0, count: 64 * 32 * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 64, height: 32, bitsPerComponent: 8,
                bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw Failure(message: "Decode unavailable") }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 32))
        }
        let offset = (16 * 64 + 32) * 4
        try require(Array(pixels[offset..<offset+4]) == [255,0,0,255], "Panel output lost actual red drawing")
    }

    static func main() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-GIF-panel-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        await test("actual GIF exports through observable panel state then safely starts after close") {
            let (vm,state,output) = try await create(root.appendingPathComponent("fresh"))
            var notifications = 0
            let observer = state.objectWillChange.sink { notifications += 1 }
            try require(state.start(from: vm, scope: scope) && state.isBusy, "Real export did not lock formats")
            let first = state.session
            try await idle(state); try await actualRedGIF(state)
            first.close(); try require(first.output == nil && fm.contentsOfDirectory(atPath: output.path).isEmpty, "Closed owned output leaked")
            try require(state.start(from: vm, scope: scope) && state.session !== first, "A clean closed session prevented explicit new export")
            try await idle(state); try await actualRedGIF(state)
            try require(notifications > 4, "Nested production progress did not reach the panel observer")
            observer.cancel(); state.session.close()
        }
        await test("active native consumer ownership blocks session replacement through close") {
            let (vm,state,_) = try await create(root.appendingPathComponent("consumer"))
            try require(state.start(from: vm, scope: scope), "Export refused")
            try await idle(state)
            let original = state.session
            guard let request = original.beginSharing(scope: scope) else { throw Failure(message: "Actual share request missing") }
            original.close()
            try require(state.isBusy && !state.start(from: vm, scope: scope) && state.session === original,
                        "Closed active consumer was replaced")
            try require(request.checkedURLs().count == 2, "Active consumer files disappeared")
            request.finish(completed: false, error: nil)
            try require(!state.isBusy && original.output == nil, "Finished closed consumer did not release owned files")
            try require(state.start(from: vm, scope: scope), "Finished consumer blocked explicit new export")
            try await idle(state); try await actualRedGIF(state); state.session.close()
        }
        await test("cleanup conflict prevents replacing a closed session until identity is restored") {
            let folder = root.appendingPathComponent("conflict"); let (vm,state,_) = try await create(folder)
            try require(state.start(from: vm, scope: scope), "Export refused")
            try await idle(state)
            let original = state.session; let file = original.output!.gifURL; let backup = folder.appendingPathComponent("owned-original.gif")
            try fm.moveItem(at: file, to: backup); let foreign = Data("Unowned replacement".utf8); try foreign.write(to: file)
            original.close()
            try require(original.needsCleanup && !state.start(from: vm, scope: scope) && state.session === original,
                        "Unknown file permitted ownership replacement")
            try require(Data(contentsOf: file) == foreign, "Panel state deleted an unknown file")
            try fm.removeItem(at: file); try fm.moveItem(at: backup, to: file)
            try require(original.retryCleanup() && original.output == nil, "Restored ownership cleanup failed")
            try require(state.start(from: vm, scope: scope), "Actual safe cleanup did not permit a new export")
            try await idle(state); try await actualRedGIF(state); state.session.close()
        }
        await test("unavailable current scope does not replace a closed session or create files") {
            let (vm,state,output) = try await create(root.appendingPathComponent("scope")); let original = state.session; original.close()
            for context in [StudioGIFExportSession.Scope(isStudioVisible: false,isForeground: true,accountID: nil),
                            .init(isStudioVisible: true,isForeground: false,accountID: nil)] {
                try require(!state.start(from: vm, scope: context) && state.session === original,
                            "Unavailable context replaced the session")
            }
            try require(fm.contentsOfDirectory(atPath: output.path).isEmpty, "Unavailable scope wrote files")
        }
        // These are actual codec/file/ownership tests of the production lease.
        // Callback events below are explicit probes, not UIKit runtime claims.
        await test("completion-only lease preserves actual decoded files after close and failed presentation") {
            let (vm,state,_) = try await create(root.appendingPathComponent("lease-close"))
            try require(state.start(from: vm, scope: scope), "Export refused")
            try await idle(state); try await actualRedGIF(state)
            var request = state.session.beginSharing(scope: scope)
            guard request != nil else { throw Failure(message: "Missing request") }
            weak var weakRequest = request
            let lease = try StudioGIFShareLifetime.shared.reserve(request!)
            defer { lease.consumerCompleted(completed: false, error: nil) }
            lease.offeredToUIKit(); state.session.close(); request = nil
            lease.presentationEndedWithoutCompletion()
            lease.failBeforeHandoff(Failure(message: "Late presentation failure"))
            try require(StudioGIFShareLifetime.shared.isReserved && !lease.isFinished && state.isBusy,
                        "Dismissal or late failure released an offered URL")
            try require(StudioGIFShareLifetime.shared.pendingMessage != nil && weakRequest != nil,
                        "Uncertain consumer was silently lost")
            try await actualRedGIF(state)
            lease.consumerCompleted(completed: false, error: nil)
            try require(!StudioGIFShareLifetime.shared.isReserved && state.session.output == nil && !state.isBusy,
                        "Real cancellation callback failed to release the closed owner")
        }
        await test("one global outstanding consumer blocks another share without deleting either actual GIF") {
            let (vm,a,_) = try await create(root.appendingPathComponent("lease-first"))
            try require(a.start(from: vm, scope: scope), "First export refused")
            try await idle(a)
            let requestA = a.session.beginSharing(scope: scope)!
            let leaseA = try StudioGIFShareLifetime.shared.reserve(requestA)
            defer { leaseA.consumerCompleted(completed: false, error: nil); a.session.close() }
            leaseA.offeredToUIKit(); leaseA.presentationEndedWithoutCompletion()
            let (vmB,b,_) = try await create(root.appendingPathComponent("lease-second"))
            try require(b.start(from: vmB, scope: scope), "Second export refused")
            try await idle(b)
            let requestB = b.session.beginSharing(scope: scope)!
            var rejection: Error?
            do { _ = try StudioGIFShareLifetime.shared.reserve(requestB) }
            catch { rejection = error }
            try require(rejection is StudioGIFShareLifetime.ShareError, "Second share was not bounded")
            requestB.finish(completed: false, error: rejection) // never offered to UIKit
            try require(!b.session.isSharing && a.session.isSharing, "Rejected pre-handoff request released the active consumer")
            try await actualRedGIF(a); try await actualRedGIF(b)
            leaseA.consumerCompleted(completed: true, error: nil)
            try require(a.session.notice == "The share sheet reported completion.", "Consumer result was invented or dropped")
            b.session.close()
        }
        await test("pre-handoff failure releases its lease while post-handoff error waits for consumer callback") {
            let (vm,state,_) = try await create(root.appendingPathComponent("lease-before"))
            try require(state.start(from: vm, scope: scope), "Export refused")
            try await idle(state)
            let request = state.session.beginSharing(scope: scope)!
            let lease = try StudioGIFShareLifetime.shared.reserve(request)
            state.session.close()
            lease.failBeforeHandoff(NSError(domain: "Actual presentation probe", code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: "Before UIKit received URL"]))
            try require(lease.isFinished && !StudioGIFShareLifetime.shared.isReserved && state.session.output == nil,
                        "Unhanded request did not clean the closed owner")
            try require(state.start(from: vm, scope: scope), "Fresh export blocked")
            try await idle(state)
            let next = try StudioGIFShareLifetime.shared.reserve(state.session.beginSharing(scope: scope)!)
            defer { next.consumerCompleted(completed: false, error: nil); state.session.close() }
            next.offeredToUIKit(); next.presentationEndedWithoutCompletion()
            next.consumerCompleted(completed: false, error: NSError(domain: "Actual consumer probe", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Destination reported an error"]))
            try require(!state.session.isSharing && state.session.errorMessage == "Destination reported an error",
                        "Actual consumer error did not remain factual")
            try await actualRedGIF(state)
        }
        await test("duplicate late callback cannot release a newer sharing lease") {
            let (vm,state,_) = try await create(root.appendingPathComponent("lease-replay"))
            try require(state.start(from: vm, scope: scope), "Export refused")
            try await idle(state)
            let old = try StudioGIFShareLifetime.shared.reserve(state.session.beginSharing(scope: scope)!)
            old.offeredToUIKit(); old.consumerCompleted(completed: false, error: nil)
            let current = try StudioGIFShareLifetime.shared.reserve(state.session.beginSharing(scope: scope)!)
            defer { current.consumerCompleted(completed: false, error: nil); state.session.close() }
            current.offeredToUIKit()
            old.consumerCompleted(completed: true, error: nil)
            old.presentationEndedWithoutCompletion(); old.failBeforeHandoff(nil)
            try require(StudioGIFShareLifetime.shared.isReserved && state.session.isSharing && !current.isFinished,
                        "Late callback released a different consumer")
            try require(StudioGIFShareLifetime.shared.pendingMessage == nil, "Late callback contaminated current presentation")
            try await actualRedGIF(state)
        }
        print("STUDIO_GIF_PANEL_TESTS=\(failed == 0 ? "PASS" : "FAIL") \(passed)/\(passed + failed)")
        if failed != 0 { exit(1) }
    }
}
