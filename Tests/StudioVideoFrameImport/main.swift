import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import Darwin

private struct TestFailure: Error { let message: String }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure(message: message) }
}

@main struct VideoFrameImportTests {
    static let fm = FileManager.default
    static func center(_ data: Data) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw TestFailure(message: "undecodable output PNG") }
        var pixel = [UInt8](repeating: 0, count: 4)
        let rendered = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
        }
        try require(rendered, "output pixel sampling failed")
        return pixel
    }

    static func main() async {
        do { try await run() }
        catch { print("FAIL production video frame import: \(error)"); exit(1) }
    }
    static func run() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-video-frame-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let scratch = root.appendingPathComponent("scratch")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        let movie = root.appendingPathComponent("original.mov")
        try await VideoFrameFixture.makeMovie(movie, rotate: false)
        let service = StudioVideoFrameImportService()
        func clean() throws { try require(fm.contentsOfDirectory(atPath: scratch.path).isEmpty, "temporary video copy leaked") }
        func extract(_ index: Int, _ fps: Int = 30) async throws -> StudioVideoFrameImportService.Frame {
            try await service.extract(from: movie, projectFrameIndex: index, fps: fps, scratchParent: scratch)
        }
        let red = try await extract(0)
        let green = try await extract(21) // .7s lies inside the .4–1.1s green sample.
        let blue = try await extract(40)
        for (frame, channel) in [(red, 0), (green, 1), (blue, 2)] {
            let pixels = try center(frame.image.normalizedPNG)
            // Test source-sample identity, not lossless RGB reproduction from H.264.
            print("Decoded H.264 fixture channel \(channel): \(pixels)")
            try require(Int(pixels[channel]) - Int(pixels[(channel + 1) % 3]) > 140
                && Int(pixels[channel]) - Int(pixels[(channel + 2) % 3]) > 140,
                "wrong source pixels: \(pixels)")
            try require(frame.image.originalData == frame.image.normalizedPNG, "snapshot original must be its actual PNG")
            try require(frame.image.width == 96 && frame.image.height == 64, "unexpected source geometry")
            try clean()
        }
        try require(abs(green.requestedSeconds - 0.7) < 0.000001, "project playhead mapped incorrectly")
        let mapped = try await service.extract(from: movie, projectFrameIndex: 21, fps: 30,
            mapping: .init(sourceStartSeconds: 0.4, sourceEndSeconds: 2, projectStartSeconds: 0.2, speed: 2),
            scratchParent: scratch)
        try require(abs(mapped.requestedSeconds - 0.7) < 0.000001
            && abs(mapped.sourceRequestedSeconds - 1.4) < 0.000001, "trim/speed/project offset mapping was ignored")
        try require(try center(mapped.image.normalizedPNG)[2] > 200, "mapped source seek did not decode blue")
        let slowed = try await service.extract(from: movie, projectFrameIndex: 21, fps: 30,
            mapping: .init(speed: 0.25), scratchParent: scratch)
        try require(try center(slowed.image.normalizedPNG)[0] > 200, "quarter-speed seek did not decode red")
        for mapping in [StudioVideoFrameImportService.Mapping(sourceStartSeconds: .nan),
                        .init(sourceStartSeconds: -1), .init(sourceStartSeconds: 0.5, sourceEndSeconds: 0.4),
                        .init(projectStartSeconds: 1), .init(speed: 0), .init(speed: .infinity),
                        .init(sourceEndSeconds: 0.7), .init(sourceEndSeconds: 3)] {
            do {
                _ = try await service.extract(from: movie, projectFrameIndex: 21, fps: 30,
                    mapping: mapping, scratchParent: scratch)
                throw TestFailure(message: "invalid/outside mapping accepted")
            } catch is StudioVideoFrameImportService.Failure { }
            try clean()
        }
        let again = try await extract(21)
        try require(again.image.normalizedPNG == green.image.normalizedPNG, "seek was not repeatable")
        let rotated = root.appendingPathComponent("rotated.mov")
        try await VideoFrameFixture.makeMovie(rotated, rotate: true)
        let upright = try await service.extract(from: rotated, projectFrameIndex: 21, fps: 30, scratchParent: scratch)
        try require(upright.image.width == 64 && upright.image.height == 96 && upright.image.originalOrientation == 1,
            "preferred track orientation was not baked into pixels")
        try clean()
        for (frame, fps) in [(-1, 30), (0, 0), (0, 121), (60, 30), (300, 30)] {
            do { _ = try await extract(frame, fps); throw TestFailure(message: "invalid/outside time accepted") }
            catch is StudioVideoFrameImportService.Failure { }
            try clean()
        }
        let link = root.appendingPathComponent("link.mov")
        try fm.createSymbolicLink(at: link, withDestinationURL: movie)
        do {
            _ = try await service.extract(from: link, projectFrameIndex: 0, fps: 30, scratchParent: scratch)
            throw TestFailure(message: "symlink accepted")
        } catch is StudioImageProviderFile.Failure { }
        try clean()
        let invalid = root.appendingPathComponent("invalid.mp4")
        try Data("not a movie".utf8).write(to: invalid)
        do {
            _ = try await service.extract(from: invalid, projectFrameIndex: 0, fps: 30, scratchParent: scratch)
            throw TestFailure(message: "malformed media accepted")
        } catch let failure as TestFailure { throw failure } catch { }
        try clean()
        let oversized = root.appendingPathComponent("oversized.mov")
        try Data([0]).write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(StudioImageImportService.maximumEncodedBytes + 1)); try handle.close()
        do {
            _ = try await service.extract(from: oversized, projectFrameIndex: 0, fps: 30, scratchParent: scratch)
            throw TestFailure(message: "oversized file accepted")
        } catch StudioImageProviderFile.Failure.limitExceeded { }
        try clean()
        let cancellation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await extract(0)
        }
        do { _ = try await cancellation.value; throw TestFailure(message: "cancelled task published pixels") }
        catch is CancellationError { }
        try clean()
        try fm.removeItem(at: movie)
        try require(try center(green.image.normalizedPNG)[1] > 200, "snapshot depends on original movie lifetime")
        print("PASS production video-frame extraction: variable-timestamp seeks, exact project time, repeatability, orientation, invalid/outside times, symlink, malformed/oversized media, cancellation, cleanup and independent PNG lifetime")
    }
}
