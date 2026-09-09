import Foundation
import CoreGraphics
import ImageIO

private struct TestFailure: Error { let message: String }
private enum Injected: Error { case provider }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure(message: message) }
}
private final class Observation: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func record() { lock.lock(); calls += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func waitForCall(_ message: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while count == 0 {
            try require(clock.now < deadline, message)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

@main struct StudioImagePickerTransferTests {
    static let fm = FileManager.default
    static func image() throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 24, height: 12, bitsPerComponent: 8,
            bytesPerRow: 96, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 12))
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try require(CGImageDestinationFinalize(destination), "PNG fixture failed")
        return bytes as Data
    }
    static func provider(_ url: URL, name: String = "My photo", type: String = "public.png") -> NSItemProvider {
        let result = NSItemProvider(); result.suggestedName = name
        result.registerFileRepresentation(forTypeIdentifier: type, fileOptions: [], visibility: .ownProcess) { done in
            done(url, false, nil); return Progress(totalUnitCount: 1)
        }
        return result
    }
    static func reject(_ action: () async throws -> StudioImageProviderFile,
                       matching: (Error) -> Bool = { _ in true }) async throws {
        do {
            let owned = try await action(); try owned.cleanup()
        } catch {
            try require(matching(error), "Unexpected failure: \(error)"); return
        }
        throw TestFailure(message: "Expected explicit transfer failure")
    }
    static func empty(_ url: URL) throws -> Bool { try fm.contentsOfDirectory(atPath: url.path).isEmpty }

    static func main() async {
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-picker-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            var passed = 0
            func test(_ name: String, _ action: (URL, URL) async throws -> Void) async throws {
                let folder = root.appendingPathComponent("case-\(passed)")
                let scratch = folder.appendingPathComponent("scratch")
                try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
                try await action(folder, scratch)
                try require(try empty(scratch), "Owned scratch leaked after \(name)")
                passed += 1; print("PASS \(name)")
            }
            try await test("real NSItemProvider callback copy survives asynchronous ImageIO decoding") { folder, scratch in
                let bytes = try image(), source = folder.appendingPathComponent("source.png")
                try bytes.write(to: source, options: .withoutOverwriting)
                let owned = try await StudioImagePickerTransfer.load(from: provider(source), scratchParent: scratch)
                try require(try Data(contentsOf: owned.url()) == bytes, "Actual provider bytes changed")
                try fm.removeItem(at: source)
                let image = try await StudioImageImportService().importImage(from: owned.url(), name: owned.displayName, scratchParent: scratch)
                try require(image.originalData == bytes && image.width == 24 && image.height == 12, "Real decoder lost provider bytes")
                try owned.cleanup(); try owned.cleanup()
            }
            try await test("registered preferred supported format retained without generic coercion") { folder, scratch in
                let source = folder.appendingPathComponent("source.png"); try image().write(to: source)
                let p = provider(source, type: "public.heic")
                p.registerDataRepresentation(forTypeIdentifier: "public.png", visibility: .ownProcess) { done in done(nil, Injected.provider); return nil }
                try require(StudioImagePickerTransfer.preferredType(in: p) == "public.heic", "Preferred registered representation changed")
                let owned = try await StudioImagePickerTransfer.load(from: p, scratchParent: scratch)
                try owned.cleanup()
            }
            try await test("unsupported representations make no provider load") { _, scratch in
                let p = NSItemProvider(), calls = Observation()
                p.registerFileRepresentation(forTypeIdentifier: "public.movie", fileOptions: [], visibility: .ownProcess) { _ in calls.record(); return nil }
                try await reject({ try await StudioImagePickerTransfer.load(from: p, scratchParent: scratch) }, matching: { if case StudioImagePickerTransfer.Failure.unsupportedRepresentation = $0 { return true }; return false })
                try require(calls.count == 0, "Unsupported provider was loaded")
            }
            try await test("already cancelled task makes no provider load") { _, scratch in
                let p = NSItemProvider(), calls = Observation()
                p.registerFileRepresentation(forTypeIdentifier: "public.png", fileOptions: [], visibility: .ownProcess) { _ in calls.record(); return nil }
                let task = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await StudioImagePickerTransfer.load(from: p, scratchParent: scratch)
                }
                try await reject({ try await task.value }, matching: { $0 is CancellationError })
                try require(calls.count == 0, "Cancelled provider was loaded")
            }
            try await test("provider error is explicit with no image success") { _, scratch in
                let p = NSItemProvider()
                p.registerFileRepresentation(forTypeIdentifier: "public.png", fileOptions: [], visibility: .ownProcess) { done in done(nil, false, Injected.provider); return nil }
                try await reject({ try await StudioImagePickerTransfer.load(from: p, scratchParent: scratch) }, matching: { if case StudioImagePickerTransfer.Failure.unavailable = $0 { return true }; return false })
            }
            try await test("silent provider has a bounded deadline and cancels returned progress") { _, scratch in
                let p = NSItemProvider(), cancelled = Observation()
                p.registerFileRepresentation(forTypeIdentifier: "public.png", fileOptions: [], visibility: .ownProcess) { _ in
                    let progress = Progress(totalUnitCount: 1); progress.cancellationHandler = { cancelled.record() }; return progress
                }
                let began = Date()
                try await reject({ try await StudioImagePickerTransfer.load(from: p, scratchParent: scratch, timeoutSeconds: 0.1) }, matching: { if case StudioImagePickerTransfer.Failure.timedOut = $0 { return true }; return false })
                try require(Date().timeIntervalSince(began) < 2, "Provider deadline did not bound waiting")
                try await cancelled.waitForCall("Actual NSProgress cancellation callback did not arrive")
                try require(cancelled.count == 1, "Actual NSProgress cancellation not forwarded")
            }
            try await test("cancel during provider wait rejects once and ignores a late callback") { folder, scratch in
                let source = folder.appendingPathComponent("late.png"), bytes = try image(); try bytes.write(to: source)
                let p = NSItemProvider(), started = Observation(), callback = Observation()
                p.registerFileRepresentation(forTypeIdentifier: "public.png", fileOptions: [], visibility: .ownProcess) { done in
                    started.record()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { done(source, false, nil); callback.record() }
                    return Progress(totalUnitCount: 1)
                }
                let task = Task { try await StudioImagePickerTransfer.load(from: p, scratchParent: scratch) }
                try await started.waitForCall("Actual provider did not start before cancellation")
                try require(started.count == 1, "Actual provider did not start")
                task.cancel()
                try await reject({ try await task.value }, matching: { $0 is CancellationError })
                try await callback.waitForCall("Late provider completion did not finish after cancellation")
                try require(callback.count == 1, "Late provider completion ran more than once")
                try require(fm.fileExists(atPath: source.path), "Late provider callback deleted original file")
                try require(try Data(contentsOf: source) == bytes, "Late provider callback changed original bytes")
            }
            try await test("late completion after deadline cannot create retained scratch") { folder, scratch in
                let source = folder.appendingPathComponent("late.png"), bytes = try image(); try bytes.write(to: source)
                let p = NSItemProvider(), callback = Observation()
                p.registerFileRepresentation(forTypeIdentifier: "public.png", fileOptions: [], visibility: .ownProcess) { done in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { done(source, false, nil); callback.record() }
                    return Progress(totalUnitCount: 1)
                }
                try await reject { try await StudioImagePickerTransfer.load(from: p, scratchParent: scratch, timeoutSeconds: 0.05) }
                try await callback.waitForCall("Late provider completion did not finish after deadline")
                try require(callback.count == 1, "Late deadline completion ran more than once")
                try require(fm.fileExists(atPath: source.path), "Late callback deleted source")
                try require(try Data(contentsOf: source) == bytes, "Late deadline callback changed original bytes")
            }
            try await test("zero byte and oversized actual provider files reject") { folder, scratch in
                for size in [0, StudioImageProviderFile.maximumEncodedBytes + 1] {
                    let source = folder.appendingPathComponent("size-\(size).png")
                    try Data().write(to: source)
                    let handle = try FileHandle(forWritingTo: source); try handle.truncate(atOffset: UInt64(size)); try handle.close()
                    try await reject { try await StudioImagePickerTransfer.load(from: provider(source), scratchParent: scratch) }
                    try require(fm.fileExists(atPath: source.path), "Rejected source was deleted")
                }
            }
            try await test("invalid photo names reject without changing caller files") { folder, scratch in
                let source = folder.appendingPathComponent("source.png"); try image().write(to: source)
                try await reject { try await StudioImagePickerTransfer.load(from: provider(source, name: "../bad"), scratchParent: scratch) }
                try require(fm.fileExists(atPath: source.path), "Source removed")
            }
            try await test("a successful byte transfer is not falsely called a decoded image") { folder, scratch in
                let source = folder.appendingPathComponent("invalid.png"); try Data("invalid image".utf8).write(to: source)
                let owned = try await StudioImagePickerTransfer.load(from: provider(source), scratchParent: scratch)
                do {
                    _ = try await StudioImageImportService().importImage(from: owned.url(), scratchParent: scratch)
                    throw TestFailure(message: "Invalid bytes were accepted as an image")
                } catch is StudioImageImportService.ImportError { }
                try owned.cleanup()
            }
            try await test("nonfinite, zero and excessive deadlines fail before external work") { _, scratch in
                let p = NSItemProvider()
                for deadline in [Double.nan, .infinity, 0, -1, 121] {
                    try await reject({ try await StudioImagePickerTransfer.load(from: p, scratchParent: scratch, timeoutSeconds: deadline) }, matching: { if case StudioImagePickerTransfer.Failure.invalidDeadline = $0 { return true }; return false })
                }
            }
            print("PASS \(passed) production photo picker transfer groups")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
