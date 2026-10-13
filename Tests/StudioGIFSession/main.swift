import AppKit
import SwiftUI
import Combine
import ImageIO
import UniformTypeIdentifiers

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}

@main @MainActor struct StudioGIFSessionTests {
    typealias Session = StudioGIFExportSession
    static let fm = FileManager.default
    static let visible = Session.Scope(isStudioVisible: true, isForeground: true, accountID: nil)
    final class WeakBox<T: AnyObject> { weak var value: T?; init(_ value: T?) { self.value = value } }

    static func directory(_ root: URL, _ name: String) throws -> URL {
        let p = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: p, withIntermediateDirectories: false)
        return p
    }
    static func contents(_ url: URL) throws -> [URL] { try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
    static func editor(_ root: URL) async throws -> StudioViewModel {
        let vm = StudioViewModel(storage: DeviceStorageManager(documentsDirectory: root.appendingPathComponent("documents")))
        let created = await vm.createProject(name: "Real GIF session", width: 64, height: 32, fps: 12)
        try require(created, "Actual project creation failed")
        return vm
    }
    static func draw(_ vm: StudioViewModel, _ color: String = "#FF0000") throws {
        try require(vm.commitElement(DrawnElement(id: UUID().uuidString, tool: .brush,
            points: [.init(x: 0, y: 16), .init(x: 64, y: 16)], color: color,
            width: 64, opacity: 1, layerID: vm.activeLayerID)), "Actual drawing failed")
    }
    static func idle(_ session: Session) async throws {
        let end = Date().addingTimeInterval(12)
        while session.isRunning && Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        try require(!session.isRunning, "GIF session exceeded bounded deadline")
    }
    static func ready(_ root: URL) async throws -> (StudioViewModel, Session, URL) {
        let vm = try await editor(root); try draw(vm)
        let outputParent = try directory(root, "output"), s = Session(outputParent: outputParent)
        try require(s.start(from: vm, scope: visible), "GIF did not start")
        try await idle(s)
        try require(s.output != nil && s.errorMessage == nil, "Actual GIF not ready: \(s.errorMessage ?? "nil")")
        return (vm, s, outputParent)
    }
    static func centerPixel(_ url: URL, index: Int) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.gif.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw Failure(message: "Actual GIF failed to decode") }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw Failure(message: "Decode context unavailable") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let offset = (image.height / 2 * image.width + image.width / 2) * 4
        return Array(pixels[offset..<offset + 4])
    }

    static func immutableCapture(_ root: URL) async throws {
        let vm = try await editor(root); try draw(vm); vm.duplicateFrame()
        let saved = await vm.save(); try require(saved, "Actual save failed")
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("documents"))
        let reopened = StudioViewModel(storage: storage)
        let metadata = try storage.loadAnimation(id: vm.document.id)!.metadata
        let opened = await reopened.openProject(metadata); try require(opened, "Actual reopen failed")
        let sourceRevision = reopened.document.revision, sourceIDs = reopened.document.frames.map(\.id)
        let parent = try directory(root, "output"), s = Session(outputParent: parent)
        try require(s.start(from: reopened, scope: visible), "Reopened source did not start")
        try draw(reopened, "#0000FF") // after synchronous immutable capture
        let savedLater = await reopened.save(); try require(savedLater, "Later project save failed")
        try await idle(s)
        guard let output = s.output else { throw Failure(message: s.errorMessage ?? "Missing output") }
        try require(output.receipt.revision == sourceRevision && output.receipt.frameIDs == sourceIDs,
                    "Later edit changed captured revision/frame identity")
        try require(output.receipt.delaysCentiseconds == [8,9] && !output.receipt.audioIncluded && !output.receipt.editorGuidesIncluded,
                    "Actual receipt lost timing or scope")
        for index in 0..<2 { try require(centerPixel(output.gifURL, index: index) == [255,0,0,255], "Later blue edit leaked into captured GIF") }
        try require(s.notice?.contains("no audio") == true && output.checkedURLs().count == 2, "Factual completion missing")
        s.close(); try require(contents(parent).isEmpty, "Owned files were not removed")
        let original = try storage.loadAnimation(id: vm.document.id)!
        try require(StudioDocumentArchive.decode(original.editableDocumentData!).document.revision == reopened.document.revision, "GIF cleanup changed saved project")
    }
    static func cancelledAtFrame(_ root: URL, close: Bool, background: Bool) async throws {
        let vm = try await editor(root); try draw(vm)
        for _ in 0..<8 { vm.duplicateFrame() }
        let p = try directory(root, "output"), s = Session(outputParent: p)
        let token = s.$completedFrames.dropFirst().sink { n in
            if n == 1 {
                if close { s.close() }
                else if background { s.refreshScope(.init(isStudioVisible: true, isForeground: false, accountID: nil)) }
                else { s.cancel() }
            }
        }
        try require(s.start(from: vm, scope: visible), "Cancellation fixture did not start")
        try await idle(s); token.cancel()
        try require(s.output == nil && contents(p).isEmpty && s.notice?.contains("cancelled") == true,
                    "Cancellation left output or claimed readiness")
    }
    static func closedDuringOutput(_ root: URL) async throws {
        let vm = try await editor(root); try draw(vm)
        let p = try directory(root, "output"), s = Session(outputParent: p)
        let token = s.$output.dropFirst().sink { if $0 != nil { s.close() } }
        try require(s.start(from: vm, scope: visible), "Output observer fixture failed")
        try await idle(s); token.cancel()
        try require(s.isClosed && s.output == nil && contents(p).isEmpty, "Synchronous close lost output deletion handle")
    }
    static func closedDuringStart(_ root: URL) async throws {
        let vm = try await editor(root), p = try directory(root, "output"), s = Session(outputParent: p)
        let token = s.$source.dropFirst().sink { if $0 != nil { s.close() } }
        try require(!s.start(from: vm, scope: visible), "Closed source observer began a task")
        token.cancel(); try require(!s.isRunning && s.isClosed && contents(p).isEmpty, "Closed start wrote files")
    }
    static func shareCancellation(_ root: URL) async throws {
        let (vm,s,_) = try await ready(root)
        guard let output = s.output, let first = s.beginSharing(scope: visible) else { throw Failure(message: "Actual share request unavailable") }
        let bytes = try Data(contentsOf: output.gifURL)
        try require(!s.start(from: vm, scope: visible) && s.beginSharing(scope: visible) == nil, "Concurrent consumer/export accepted")
        first.finish(completed: false, error: nil)
        guard let next = s.beginSharing(scope: visible) else { throw Failure(message: "Cancelled GIF was not reusable") }
        first.finish(completed: true, error: nil)
        try require(s.isSharing && next.checkedURLs().first == output.gifURL && Data(contentsOf: output.gifURL) == bytes,
                    "Stale completion released or altered newer share")
        next.finish(completed: false, error: nil); try require(s.notice?.contains("cancelled") == true, "Cancellation invented successful destination save")
        s.close()
    }
    static func shareSurvivesOwnerClose(_ root: URL) async throws {
        let vm = try await editor(root); try draw(vm)
        let p = try directory(root, "output")
        var session: Session? = Session(outputParent: p)
        try require(session!.start(from: vm, scope: visible), "Share lifetime export did not start")
        try await idle(session!)
        guard let request = session?.beginSharing(scope: visible) else { throw Failure(message: "Share lease missing") }
        let urls = try request.checkedURLs(), weakSession = WeakBox(session)
        session?.refreshScope(.init(isStudioVisible: true, isForeground: true, accountID: "changed-account"))
        session = nil
        try require(weakSession.value?.isClosed == true && request.checkedURLs() == urls && contents(p).count == 1,
                    "Account close removed active consumer files")
        request.finish(completed: false, error: nil)
        try require(contents(p).isEmpty && weakSession.value == nil, "Consumer callback did not release closed owner")
        withExtendedLifetime(vm) {}
    }

    static func abandonedShare(_ root: URL) async throws {
        let (vm,s,p) = try await ready(root)
        var request: Session.ShareRequest? = s.beginSharing(scope: visible)
        try require(request != nil, "Share request missing")
        s.close(); request = nil
        let end = Date().addingTimeInterval(3)
        while s.isSharing && Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        try require(!s.isSharing && contents(p).isEmpty, "Abandoned request did not finish its owned session")
        withExtendedLifetime(vm) {}
    }
    static func conflictCleanup(_ root: URL) async throws {
        let (vm,s,p) = try await ready(root)
        guard let output = s.output else { throw Failure(message: "Missing GIF") }
        let unknown = output.directory.appendingPathComponent("owner-note.txt"), original = try Data(contentsOf: output.gifURL)
        try Data("preserve this file".utf8).write(to: unknown)
        s.close()
        try require(s.needsCleanup && contents(output.directory).count == 3 && Data(contentsOf: output.gifURL) == original,
                    "Cleanup deleted files before checking the full directory")
        try require(!s.retryCleanup() && fm.fileExists(atPath: unknown.path), "Retry adopted unrelated file")
        try fm.removeItem(at: unknown) // remove only this test's exact known fixture
        try require(s.retryCleanup() && contents(p).isEmpty, "Safe retry could not remove original owned output")
        withExtendedLifetime(vm) {}
    }
    static func drawingAndScopeGuards(_ root: URL) async throws {
        let vm = try await editor(root), p = try directory(root, "output"), s = Session(outputParent: p)
        try require(!s.start(from: vm, scope: .init(isStudioVisible: false, isForeground: true, accountID: nil)), "Hidden export started")
        try require(!s.start(from: vm, scope: .init(isStudioVisible: true, isForeground: false, accountID: nil)), "Background export started")
        try require(vm.beginStrokeInput(id: "in-flight"), "Actual touch guard setup failed")
        try require(!s.start(from: vm, scope: visible) && s.errorMessage?.contains("drawing") == true, "Unfinished stroke exported")
        vm.finishStrokeInput(id: "in-flight")
        try require(contents(p).isEmpty, "Rejected start wrote output")
    }
    static func shareErrors(_ root: URL) async throws {
        let (vm,s,_) = try await ready(root)
        guard let request = s.beginSharing(scope: visible) else { throw Failure(message: "Missing share") }
        request.finish(completed: false, error: NSError(domain: "GIFConsumerFixture", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Destination refused the file"]))
        try require(s.errorMessage == "Destination refused the file" && s.notice == nil && s.output?.isCleaned == false,
                    "Consumer failure discarded output or fabricated success")
        s.close(); withExtendedLifetime(vm) {}
    }

    static func main() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("Actual-SDI-GIF-Session-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let cases: [(String, (URL) async throws -> Void)] = [
            ("saved project captures immutable actual GIF frames timing and pixels", immutableCapture),
            ("cancel after first actual rendered frame leaves no output", { try await cancelledAtFrame($0, close: false, background: false) }),
            ("close during rendering leaves no output", { try await cancelledAtFrame($0, close: true, background: false) }),
            ("background cancels real GIF rendering", { try await cancelledAtFrame($0, close: false, background: true) }),
            ("synchronous output observer closes with owned cleanup", closedDuringOutput),
            ("synchronous source observer prevents a closed export", closedDuringStart),
            ("share cancellation retry and stale completion preserve actual bytes", shareCancellation),
            ("account change retains files until consumer callback", shareSurvivesOwnerClose),
            ("abandoned private share request releases closed owner", abandonedShare),
            ("unknown files block cleanup without deleting owned siblings", conflictCleanup),
            ("unfinished drawing hidden and background scope reject export", drawingAndScopeGuards),
            ("real consumer error preserves export with factual failure", shareErrors)
        ]
        for (index, entry) in cases.enumerated() {
            try await entry.1(directory(root, "case-\(index)")); print("PASS " + entry.0)
        }
        print("PASS \(cases.count) actual GIF session groups; native UIKit integration not exercised")
    }
}
