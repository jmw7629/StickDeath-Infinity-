import AppKit
import SwiftUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

// Long-project export benchmark harness (#202). It drives the production
// StudioMovieExportService and StudioExportService with a generated document
// of the requested size and prints wall time, peak resident memory and output
// bytes. It is a measurement tool, not a pass/fail test: numbers printed on a
// development Mac do not establish iPhone behaviour and must be recorded as
// such. Usage: sdi-export-benchmark <frames> <width> <height> <fps> [png]
typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }

private struct Failure: Error { let message: String }

@main @MainActor struct StudioExportBenchmark {
    static func peakResidentBytes() -> UInt64 {
        var info = rusage()
        guard getrusage(RUSAGE_SELF, &info) == 0 else { return 0 }
        return UInt64(info.ru_maxrss) // bytes on macOS
    }
    static func document(frames: Int, width: Int, height: Int, fps: Int) throws -> StudioDocument {
        var doc = try StudioDocument.new(name: "Benchmark \(frames)f \(width)x\(height)", width: width, height: height, fps: fps)
        doc.frames = (0..<frames).map { index in
            let y = CGFloat(index % max(1, height))
            return AnimationFrame(id: "frame-\(index)", elements: [DrawnElement(id: "stroke-\(index)", tool: .brush,
                points: [StrokePoint(x: 0, y: y), StrokePoint(x: CGFloat(width), y: CGFloat(height) - y)],
                color: index % 2 == 0 ? "#E03030" : "#12121A", width: 24, opacity: 1, layerID: doc.activeLayerID)])
        }
        doc.activeFrameID = doc.frames[0].id
        return doc
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let arguments = CommandLine.arguments
        guard arguments.count >= 5, let frames = Int(arguments[1]), let width = Int(arguments[2]),
              let height = Int(arguments[3]), let fps = Int(arguments[4]) else {
            print("usage: sdi-export-benchmark <frames> <width> <height> <fps> [png]"); exit(2)
        }
        let png = arguments.count > 5 && arguments[5] == "png"
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-export-benchmark-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let doc = try document(frames: frames, width: width, height: height, fps: fps)
        let before = peakResidentBytes(), started = ProcessInfo.processInfo.systemUptime
        var lastProgress = 0
        print("BENCHMARK start kind=\(png ? "png" : "mp4") frames=\(frames) size=\(width)x\(height) fps=\(fps) host=\(ProcessInfo.processInfo.hostName) thermal=\(StudioExportPreflight.currentThermal())")
        if png {
            let output = try await StudioExportService().export(document: doc, format: .pngSequence, outputParent: root,
                progress: { done, total in if done - lastProgress >= 100 || done == total { lastProgress = done; print("BENCHMARK progress \(done)/\(total)") } })
            let bytes = try output.imageURLs.reduce(0) { $0 + ((try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            print("BENCHMARK result kind=png images=\(output.imageURLs.count) bytes=\(bytes)")
        } else {
            let snapshot = StudioMovieExportService.Snapshot(document: doc, retainedAudioTracks: [], rasterDataByID: [:])
            let output = try await StudioMovieExportService().export(snapshot: snapshot, outputParent: root, background: .white,
                progress: { value in
                    if value.completedFrames - lastProgress >= 100 || value.phase != .rendering { lastProgress = value.completedFrames; print("BENCHMARK progress \(value.phase) \(value.completedFrames)/\(value.totalFrames)") }
                })
            print("BENCHMARK result kind=mp4 frames=\(output.manifest.frameIDs.count) bytes=\(output.manifest.encodedBytes) codec=\(output.manifest.codec)")
            try output.cleanup()
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        print(String(format: "BENCHMARK done seconds=%.2f peakResidentBytesBefore=%llu peakResidentBytesAfter=%llu", elapsed, before, peakResidentBytes()))
        print("BENCHMARK note=development-host measurement; not an iPhone result")
    }
}
