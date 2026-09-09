import Foundation
import CoreGraphics
import ImageIO
import Darwin

private struct TestFailure: Error { let message: String }
private enum Injected: Error { case stopped }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure(message: message) }
}
private func rejects(_ action: () throws -> Void, matching: (Error) -> Bool = { _ in true }) throws {
    do { try action() } catch { try require(matching(error), "Unexpected error: \(error)"); return }
    throw TestFailure(message: "Expected an explicit failure")
}
private final class ErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var errors = [Error]()
    func append(_ error: Error) { lock.lock(); errors.append(error); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return errors.count }
}

@main struct StudioImageProviderFileTests {
    static let fm = FileManager.default
    static func names(_ url: URL) throws -> Set<String> { Set(try fm.contentsOfDirectory(atPath: url.path)) }
    static func write(_ data: Data, _ url: URL) throws { try data.write(to: url, options: .withoutOverwriting) }
    static func mode(_ url: URL) throws -> UInt16 {
        var info = stat(); try require(lstat(url.path, &info) == 0, "Missing permission fixture")
        return UInt16(info.st_mode & 0o777)
    }
    static func image() throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8,
            bytesPerRow: 128, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        let result = NSMutableData()
        let destination = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try require(CGImageDestinationFinalize(destination), "Fixture PNG encoding failed")
        return result as Data
    }
    static func main() async {
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-provider-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            var passed = 0
            func test(_ name: String, _ action: (URL, URL) async throws -> Void) async throws {
                let directory = root.appendingPathComponent("case-\(passed)")
                let scratch = directory.appendingPathComponent("scratch")
                try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
                try await action(directory, scratch)
                passed += 1; print("PASS \(name)")
            }
            try await test("actual byte copy, safe display metadata, private modes and idempotent cleanup") { directory, scratch in
                let source = directory.appendingPathComponent("Provider.JPG"), bytes = Data((0..<180_123).map { UInt8($0 % 251) })
                try write(bytes, source)
                var chunks = [StudioImageProviderFile.CopyProgress]()
                let copy = try StudioImageProviderFile.materialize(from: source, suggestedName: " My photo ", scratchParent: scratch,
                    progress: { chunks.append($0) })
                let url = try copy.url()
                try require(copy.displayName == "My photo" && copy.fileExtension == "jpg" && url.lastPathComponent == "image.jpg", "Metadata was not validated independently from owned filename")
                try require(try Data(contentsOf: url) == bytes && Data(contentsOf: source) == bytes, "Copied bytes changed")
                try require(try mode(url) == 0o600 && mode(url.deletingLastPathComponent()) == 0o700, "Copy is not private")
                try require(chunks.count == 3 && chunks.last?.completed == Int64(bytes.count), "Copy chunks/progress are not bounded")
                try copy.cleanup(); try copy.cleanup(); try copy.cancel()
                try rejects { _ = try copy.url() }
                try require(try names(scratch).isEmpty && Data(contentsOf: source) == bytes, "Cleanup touched source or retained owned output")
            }
            try await test("provider callback lifetime ends before actual asynchronous ImageIO import") { directory, scratch in
                let original = try image(), source = directory.appendingPathComponent("temporary.png")
                try write(original, source)
                let owned = try StudioImageProviderFile.materialize(from: source, scratchParent: scratch)
                try fm.removeItem(at: source) // Simulates provider removing its callback-only URL.
                let decoded = try await StudioImageImportService().importImage(from: owned.url(), name: owned.displayName, scratchParent: scratch)
                try require(decoded.originalData == original && decoded.width == 32 && decoded.height == 16, "Actual async importer lost provider bytes")
                try owned.cleanup(); try require(try names(scratch).isEmpty, "Decoder/provider scratch survived successful completion")
            }
            try await test("unsupported image bytes are copied honestly then rejected by actual decoder") { directory, scratch in
                let source = directory.appendingPathComponent("not-an-image.tmp")
                try write(Data("ordinary non-image bytes".utf8), source)
                let owned = try StudioImageProviderFile.materialize(from: source, scratchParent: scratch)
                do {
                    _ = try await StudioImageImportService().importImage(from: owned.url(), scratchParent: scratch)
                    throw TestFailure(message: "Provider copy was falsely treated as decoded image")
                } catch is StudioImageImportService.ImportError { }
                try owned.cleanup(); try require(try names(scratch).isEmpty, "Failed decode leaked provider copy")
            }
            try await test("zero and oversized source reject before copying; exact16MiB is accepted") { directory, scratch in
                let empty = directory.appendingPathComponent("empty.png"); try write(Data(), empty)
                try rejects { _ = try StudioImageProviderFile.materialize(from: empty, scratchParent: scratch) }
                let large = directory.appendingPathComponent("large.png")
                try write(Data(), large); let file = try FileHandle(forWritingTo: large)
                try file.truncate(atOffset: UInt64(StudioImageImportService.maximumEncodedBytes + 1)); try file.close()
                try rejects { _ = try StudioImageProviderFile.materialize(from: large, scratchParent: scratch) }
                let exact = directory.appendingPathComponent("exact.png")
                try write(Data(repeating: 73, count: StudioImageImportService.maximumEncodedBytes), exact)
                let started = Date()
                let owned = try StudioImageProviderFile.materialize(from: exact, scratchParent: scratch)
                print("EXACT_16_MIB_COPY_SECONDS=\(Date().timeIntervalSince(started))")
                try require(try Data(contentsOf: owned.url()) == Data(contentsOf: exact), "Exact boundary copy differed")
                try owned.cleanup(); try require(try names(scratch).isEmpty, "Boundary failure leaked output")
            }
            try await test("links, directory, FIFO and nonlocal URL cannot become a copied source") { directory, scratch in
                let real = directory.appendingPathComponent("real.png"); try write(Data([1, 2, 3]), real)
                let link = directory.appendingPathComponent("link.png"); try fm.createSymbolicLink(at: link, withDestinationURL: real)
                let fifo = directory.appendingPathComponent("fifo.png"); try require(mkfifo(fifo.path, 0o600) == 0, "FIFO fixture failed")
                for source in [link, directory, fifo, URL(string: "https://example.invalid/private.png")!, URL(string: real.absoluteString + "?query=1")!] {
                    try rejects { _ = try StudioImageProviderFile.materialize(from: source, scratchParent: scratch) }
                }
                try require(try names(scratch).isEmpty && Data(contentsOf: real) == Data([1, 2, 3]), "Invalid source touched unrelated data")
            }
            try await test("unsafe names/extensions and linked scratch reject without path injection") { directory, scratch in
                let source = directory.appendingPathComponent("photo.png"); try write(Data([1]), source)
                for name in ["", "..", "../escape", "a/b", "a\\b", "a:b", "a\nb", String(repeating: "x", count: 121), "x" + String(repeating: "\u{0301}", count: 500)] {
                    try rejects { _ = try StudioImageProviderFile.materialize(from: source, suggestedName: name, scratchParent: scratch) }
                }
                for suffix in ["../png", "a.b", "😈", "png\0", String(repeating: "a", count: 13)] {
                    try rejects { _ = try StudioImageProviderFile.materialize(from: source, fileExtension: suffix, scratchParent: scratch) }
                }
                let linked = directory.appendingPathComponent("linked-scratch")
                try fm.createSymbolicLink(at: linked, withDestinationURL: scratch)
                try rejects { _ = try StudioImageProviderFile.materialize(from: source, scratchParent: linked) }
                try rejects { _ = try StudioImageProviderFile.materialize(from: source, scratchParent: source) }
                let noExtension = try StudioImageProviderFile.materialize(from: source, fileExtension: "", scratchParent: scratch)
                try require(try noExtension.fileExtension == nil && noExtension.url().lastPathComponent == "image", "Explicit extensionless output changed")
                try noExtension.cleanup(); try require(try names(scratch).isEmpty, "Metadata failures leaked a directory")
            }
            try await test("source truncation, growth and same-length mutation reject and preserve changed source") { directory, scratch in
                for mutation in 0..<3 {
                    let source = directory.appendingPathComponent("mutation-\(mutation).png")
                    let initial = Data(repeating: 11, count: 200_000); try write(initial, source)
                    var didMutate = false
                    try rejects {
                        _ = try StudioImageProviderFile.materialize(from: source, scratchParent: scratch, progress: { _ in
                            guard !didMutate else { return }; didMutate = true
                            let handle = try FileHandle(forWritingTo: source); defer { try? handle.close() }
                            if mutation == 0 { try handle.truncate(atOffset: 10) }
                            else if mutation == 1 { try handle.seekToEnd(); try handle.write(contentsOf: Data([99])) }
                            else { try handle.write(contentsOf: Data([99])) }
                        })
                    } matching: { if case StudioImageProviderFile.Failure.sourceChanged = $0 { return true }; return false }
                    try require(try Data(contentsOf: source) != initial && names(scratch).isEmpty, "Changed source was overwritten or partial copy survived")
                }
            }
            try await test("replaced source path identity is detected even while original fd stays readable") { directory, scratch in
                let source = directory.appendingPathComponent("source.png"), moved = directory.appendingPathComponent("old.png")
                let bytes = Data(repeating: 8, count: 200_000); try write(bytes, source)
                var changed = false
                try rejects {
                    _ = try StudioImageProviderFile.materialize(from: source, scratchParent: scratch, progress: { _ in
                        guard !changed else { return }; changed = true
                        try fm.moveItem(at: source, to: moved); try write(bytes, source)
                    })
                } matching: { if case StudioImageProviderFile.Failure.sourceChanged = $0 { return true }; return false }
                try require(try Data(contentsOf: source) == bytes && Data(contentsOf: moved) == bytes && names(scratch).isEmpty, "Identity rejection altered source files")
            }
            try await test("NSProgress cancellation before first copy, between chunks and after final chunk") { directory, scratch in
                let source = directory.appendingPathComponent("cancel.png"), bytes = Data(repeating: 1, count: 150_000)
                try write(bytes, source)
                for boundary in [0, 1, 3] {
                    let cancellation = Progress(totalUnitCount: Int64(bytes.count)); var calls = 0
                    if boundary == 0 { cancellation.cancel() }
                    try rejects {
                        _ = try StudioImageProviderFile.materialize(from: source, scratchParent: scratch,
                            isCancelled: { cancellation.isCancelled }, progress: { _ in
                                calls += 1; if calls == boundary { cancellation.cancel() }
                            })
                    } matching: { $0 is CancellationError }
                    try require(try names(scratch).isEmpty && Data(contentsOf: source) == bytes, "Cancellation leaked copied bytes or changed source")
                }
                let retry = try StudioImageProviderFile.materialize(from: source, scratchParent: scratch)
                try retry.cancel(); try retry.cancel(); try rejects { _ = try retry.url() }
            }
            try await test("throwing progress retains its error and cleans only its operation") { directory, scratch in
                let source = directory.appendingPathComponent("source.png"); try write(Data(repeating: 2, count: 100_000), source)
                let sentinel = scratch.appendingPathComponent("other-job.txt"); try write(Data([7]), sentinel)
                try rejects {
                    _ = try StudioImageProviderFile.materialize(from: source, scratchParent: scratch, progress: { _ in throw Injected.stopped })
                } matching: { $0 is Injected }
                try require(try names(scratch) == ["other-job.txt"] && Data(contentsOf: sentinel) == Data([7]), "Cleanup deleted another job")
            }
            try await test("default cancellation predicate observes the actual current Swift task") { directory, scratch in
                let source = directory.appendingPathComponent("source.png"); try write(Data([1, 2, 3]), source)
                let task = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    _ = try StudioImageProviderFile.materialize(from: source, scratchParent: scratch)
                }
                do { try await task.value; throw TestFailure(message: "Cancelled Swift task copied a provider file") }
                catch is CancellationError { }
                try require(try names(scratch).isEmpty && Data(contentsOf: source) == Data([1, 2, 3]), "Task cancellation touched the source or scratch")
            }
            try await test("unknown cleanup entries are preserved and explicit cleanup can be retried") { directory, scratch in
                let source = directory.appendingPathComponent("source.png"); try write(Data([1, 2]), source)
                let owned = try StudioImageProviderFile.materialize(from: source, scratchParent: scratch)
                let copied = try owned.url(), foreign = copied.deletingLastPathComponent().appendingPathComponent("other-job.txt")
                try write(Data([42]), foreign)
                try rejects { try owned.cleanup() } matching: { if case StudioImageProviderFile.Failure.cleanupFailed = $0 { return true }; return false }
                try require(try Data(contentsOf: foreign) == Data([42]), "Cleanup removed an unknown entry")
                try fm.removeItem(at: foreign); try owned.cleanup(); try owned.cleanup()
                try require(try names(scratch).isEmpty, "Retry did not finish owned cleanup")
            }
            try await test("replaced output and directory identities never delete foreign data") { directory, scratch in
                let source = directory.appendingPathComponent("source.png"), target = directory.appendingPathComponent("foreign.png")
                try write(Data([1]), source); try write(Data([9]), target)
                let owned = try StudioImageProviderFile.materialize(from: source, scratchParent: scratch)
                let copied = try owned.url(); try fm.removeItem(at: copied)
                try fm.createSymbolicLink(at: copied, withDestinationURL: target)
                try rejects { _ = try owned.url() }; try rejects { try owned.cleanup() }
                try require(try Data(contentsOf: target) == Data([9]), "Replaced file cleanup followed a link")
                try fm.removeItem(at: copied); try owned.cleanup()
                let second = try StudioImageProviderFile.materialize(from: source, scratchParent: scratch)
                let originalDirectory = try second.url().deletingLastPathComponent(), moved = scratch.appendingPathComponent("moved-owned")
                try fm.moveItem(at: originalDirectory, to: moved)
                try fm.createDirectory(at: originalDirectory, withIntermediateDirectories: false)
                let foreign = originalDirectory.appendingPathComponent("foreign"); try write(Data([17]), foreign)
                try rejects { _ = try second.url() }; try rejects { try second.cleanup() }
                try require(try Data(contentsOf: foreign) == Data([17]), "Replaced directory was removed")
                try fm.removeItem(at: foreign); try fm.removeItem(at: originalDirectory)
                try fm.moveItem(at: moved, to: originalDirectory); try second.cleanup()
            }
            try await test("copy failure plus cleanup failure is surfaced and abandoned cleanup failure is reported") { directory, scratch in
                let source = directory.appendingPathComponent("source.png"); try write(Data(repeating: 2, count: 100_000), source)
                let failures = ErrorLog()
                try rejects {
                    _ = try StudioImageProviderFile.materialize(from: source, scratchParent: scratch, progress: { _ in
                        let child = try fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil).first!
                        try write(Data([51]), child.appendingPathComponent("foreign")); throw Injected.stopped
                    }, abandonedCleanupFailure: { failures.append($0) })
                } matching: { if case StudioImageProviderFile.Failure.operationAndCleanupFailed(let original) = $0 { return original is Injected }; return false }
                try require(failures.count == 1, "An abandoned cleanup failure was silently discarded")
                let child = try fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil).first!
                try require(try Data(contentsOf: child.appendingPathComponent("foreign")) == Data([51]), "Failure cleanup removed foreign bytes")
            }
            try await test("renamed scratch parent cleanup uses its owned descriptor and preserves replacement") { directory, scratch in
                let source = directory.appendingPathComponent("source.png"); try write(Data([1, 2]), source)
                let owned = try StudioImageProviderFile.materialize(from: source, scratchParent: scratch)
                let moved = directory.appendingPathComponent("moved-scratch")
                try fm.moveItem(at: scratch, to: moved)
                try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
                let sentinel = scratch.appendingPathComponent("other-job"); try write(Data([15]), sentinel)
                try rejects { _ = try owned.url() }
                try owned.cleanup()
                try require(try names(moved).isEmpty && Data(contentsOf: sentinel) == Data([15]), "Parent replacement redirected cleanup")
            }
            try await test("independent handles and concurrent cleanup preserve other jobs") { directory, scratch in
                let source = directory.appendingPathComponent("source.png"); try write(Data(repeating: 3, count: 65_000), source)
                let first = try StudioImageProviderFile.materialize(from: source, scratchParent: scratch)
                let second = try StudioImageProviderFile.materialize(from: source, scratchParent: scratch)
                let secondURL = try second.url(), failures = ErrorLog()
                DispatchQueue.concurrentPerform(iterations: 16) { _ in do { try first.cleanup() } catch { failures.append(error) } }
                try require(try failures.count == 0 && Data(contentsOf: secondURL).count == 65_000, "Concurrent cleanup escaped its ownership")
                try second.cleanup(); try require(try names(scratch).isEmpty, "Independent copies leaked")
            }
            try await test("dropped successful handle performs safe fallback cleanup") { directory, scratch in
                let source = directory.appendingPathComponent("source.png"); try write(Data([4]), source)
                let errors = ErrorLog()
                var owned: StudioImageProviderFile? = try StudioImageProviderFile.materialize(from: source, scratchParent: scratch,
                    abandonedCleanupFailure: { errors.append($0) })
                let url = try owned!.url(); try require(fm.fileExists(atPath: url.path), "Copy did not materialize")
                owned = nil
                try require(try names(scratch).isEmpty && errors.count == 0, "Abandoned successful copy leaked silently")
            }
            print("STUDIO_IMAGE_PROVIDER_FILE_TESTS=PASS \(passed) actual production cases")
        } catch {
            print("STUDIO_IMAGE_PROVIDER_FILE_TESTS=FAIL \(error)"); exit(1)
        }
    }
}
