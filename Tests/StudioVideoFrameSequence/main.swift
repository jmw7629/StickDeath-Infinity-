import Foundation
import CoreGraphics
import ImageIO
import Darwin

private struct Failure: Error { let message: String }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}
@main struct VideoFrameSequenceTests {
    static func color(_ data: Data) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure(message: "Invalid real PNG") }
        var pixel = [UInt8](repeating: 0, count: 4)
        let ok = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
        }
        try require(ok, "PNG pixel decode failed"); return pixel
    }
    static func main() async {
        do { try await run() } catch { print("FAIL video sequence: \(error)"); exit(1) }
    }
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-video-sequence-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let scratch = root.appendingPathComponent("scratch")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        try Data("preserve".utf8).write(to: scratch.appendingPathComponent("sentinel"))
        func clean() throws { try require(try fm.contentsOfDirectory(atPath: scratch.path) == ["sentinel"], "Sequence copy leaked or unrelated data removed") }
        let movie = root.appendingPathComponent("rotated.mov")
        try await VideoFrameFixture.makeMovie(movie, rotate: true)
        let original = try Data(contentsOf: movie)
        let service = StudioVideoFrameImportService()
        let frames = try await service.extractSequence(from: movie, projectFrameIndex: 0, fps: 2, frameCount: 4,
            scratchParent: scratch)
        try require(frames.count == 4 && Set(frames.map { $0.image.id }).count == 4, "Sequence not complete/unique")
        for (index, channel) in [0, 1, 1, 2].enumerated() {
            let frame = frames[index], pixel = try color(frames[index].image.normalizedPNG)
            try require(frame.requestedSeconds == Double(index) / 2 && frame.sourceRequestedSeconds == Double(index) / 2,
                "Sequence frame timing incorrect")
            try require(frame.image.width == 64 && frame.image.height == 96 && frame.image.originalOrientation == 1,
                "Sequence lost movie orientation")
            try require(Int(pixel[channel]) - Int(pixel[(channel + 1) % 3]) > 140,
                "Sequence decoded wrong actual source sample")
        }
        try clean()
        let mapped = try await service.extractSequence(from: movie, projectFrameIndex: 1, fps: 4, frameCount: 3,
            mapping: .init(sourceStartSeconds: 0.5, sourceEndSeconds: 2, projectStartSeconds: 0.25, speed: 2),
            scratchParent: scratch)
        try require(mapped.map { $0.sourceRequestedSeconds } == [0.5, 1, 1.5], "Sequence ignored trim/speed/project offset")
        try clean()
        let single = try await service.extract(from: movie, projectFrameIndex: 1, fps: 2, scratchParent: scratch)
        try require(single.image.normalizedPNG == frames[1].image.normalizedPNG, "Existing single-frame API changed pixels")
        try clean()
        for count in [0, 25] {
            do { _ = try await service.extractSequence(from: movie, projectFrameIndex: 0, fps: 2, frameCount: count, scratchParent: scratch); throw Failure(message: "Invalid sequence count accepted") }
            catch StudioVideoFrameImportService.Failure.sequenceLimit { }
            try clean()
        }
        do {
            _ = try await service.extractSequence(from: movie, projectFrameIndex: 0, fps: 2, frameCount: 3,
                mapping: .init(sourceEndSeconds: 1), scratchParent: scratch)
            throw Failure(message: "Exclusive trim endpoint returned partial sequence")
        } catch StudioVideoFrameImportService.Failure.outsideTrim { }
        try clean()
        do {
            _ = try await service.extractSequence(from: movie, projectFrameIndex: 0, fps: 2, frameCount: 5, scratchParent: scratch)
            throw Failure(message: "Exclusive movie endpoint returned partial sequence")
        } catch StudioVideoFrameImportService.Failure.outsideVideo { }
        try clean()
        let cancelled = Task {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return try await service.extractSequence(from: movie, projectFrameIndex: 0, fps: 12, frameCount: 24, scratchParent: scratch)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw Failure(message: "Cancelled sequence succeeded") } catch is CancellationError { }
        try clean()
        try require(try Data(contentsOf: movie) == original, "Original movie changed")
        print("PASS 7 real video-sequence groups: decoded order/orientation, mapping, single-frame compatibility, count bounds, exclusive trim, exclusive source, cancellation/cleanup/original")
    }
}
