import Foundation
import AppKit
import SwiftUI
import AVFoundation
import CryptoKit

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private enum TestError: Error { case failed(String), injected }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw TestError.failed(message) } }

@main @MainActor struct Tests {
    static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("sdi-mixed-export-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        var passed = 0
        func run(_ name: String, _ body: () async throws -> Void) async throws { print("RUN \(name)"); try await body(); passed += 1; print("PASS \(name)") }
        func parent(_ name: String) throws -> URL { let p = root.appendingPathComponent(name + "-" + UUID().uuidString); try fm.createDirectory(at: p, withIntermediateDirectories: false); return p }
        func empty(_ path: URL) throws { try require(fm.contentsOfDirectory(atPath: path.path).isEmpty, "partial output cleaned") }
        func onlyChild(_ path: URL) throws -> URL { let contents = try fm.contentsOfDirectory(at: path, includingPropertiesForKeys: nil); try require(contents.count == 1, "single captured output"); return contents[0] }
        let videoParent = try parent("video"), audioParent = try parent("audio")
        let toneURL = root.appendingPathComponent("generated.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: toneURL, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!; buffer.frameLength = 24_000
            for n in 0..<24_000 {
                buffer.floatChannelData![0][n] = Float(sin(Double(n) * 2 * .pi * 480 / 48_000)) * 0.25
                buffer.floatChannelData![1][n] = Float(sin(Double(n) * 2 * .pi * 960 / 48_000)) * 0.15
            }
            try file.write(from: buffer)
        }
        let originalAudio = try Data(contentsOf: toneURL)
        let track = AudioTrack(id: UUID(), name: "Generated stereo tone", format: "caf", audioData: originalAudio, startTime: 0, duration: 0.5)
        var document = try StudioDocument.new(name: "Real same-capture mux", width: 64, height: 32, fps: 12)
        document.frames = (0..<12).map { index in AnimationFrame(id: "frame-\(index)", elements: [DrawnElement(id: "stroke-\(index)", tool: .brush,
            points: [StrokePoint(x: 0, y: 16), StrokePoint(x: 64, y: 16)], color: index < 6 ? "#FF0000" : "#0000FF", width: 64, opacity: 1, layerID: document.activeLayerID)]) }
        document.activeFrameID = document.frames[0].id
        document.audioClips = [AudioClip(id: UUID().uuidString, soundName: track.name, track: 1, startTime: 0.25, duration: 0.5, volume: 0.5, assetID: track.id)]
        document.schemaVersion = 4
        document.audioClips[0].sourceOffset = 0.123
        document.audioClips[0].duration = 0.25
        document.audioClips.append(AudioClip(id: UUID().uuidString, soundName: track.name, track: 2,
            startTime: 0.6, duration: 0.4, volume: 0.8, assetID: track.id, sourceOffset: 0.05, isMuted: true))
        let snapshot = StudioMovieExportService.Snapshot(document: document, retainedAudioTracks: [track], rasterDataByID: [:])
        let service = StudioMixedMovieExportService()
        try await run("one real MP4 contains trimmed stereo gain muted clip silence and original pictures") {
            let p = try parent("success")
            let out = try await service.export(snapshot: snapshot, outputParent: p)
            let urls = try out.checkedURLs(), asset = AVURLAsset(url: urls[0])
            let audio = try await asset.loadTracks(withMediaType: .audio), video = try await asset.loadTracks(withMediaType: .video)
            try require(audio.count == 1 && video.count == 1, "actual tracks")
            try await verifyPixels(asset, track: video[0])
            let samples = try await decodeAudio(asset, track: audio[0])
            try require(samples.count == 96_000 && out.receipt.videoFrames == 12, "actual output duration")
            var error = [0.0, 0.0], silence: Float = 0
            for n in 0..<48_000 {
                for c in 0..<2 {
                    let actual = samples[n*2+c]
                    if (16_000..<20_000).contains(n) {
                        let expected = sin(Double(n - 12_000 + 5_904) * 2 * .pi * (c == 0 ? 480 : 960) / 48_000) * (c == 0 ? 0.125 : 0.075)
                        error[c] += pow(Double(actual)-expected,2)
                    }
                    if n < 10_000 || n > 28_000 { silence = max(silence,abs(actual)) }
                }
            }
            let rmse = error.map { sqrt($0 / 4_000) }
            print("ACTUAL_TRIM_RMSE=\(rmse) MUTED_SILENCE_PEAK=\(silence)")
            try require(rmse.allSatisfy{$0 < 0.008} && silence < 0.0005, "trim, gain or mute changed actual decoded samples")
            try require(fm.contentsOfDirectory(atPath:p.path).count == 1, "intermediate video/CAF not cleaned before success")
            try require(track.audioData == originalAudio && snapshot.document == document, "source changed")
            try out.cleanup(); try out.cleanup(); try empty(p)
            try require(out.isCleaned, "cleanup state")
            do { _ = try out.checkedURLs(); throw TestError.failed("cleaned output returned") }
            catch StudioMixedMovieExportService.ExportError.outputUnavailable {}
        }
        for phase in [StudioMixedMovieExportService.Phase.rendering, .mixing, .muxing, .verifying] {
            try await run("phase callback failure cleans all intermediate and final files: \(phase)") {
                let p=try parent("callback")
                do { _ = try await service.export(snapshot:snapshot,outputParent:p) { if $0.phase == phase { throw TestError.injected } }; throw TestError.failed("callback ignored") }
                catch TestError.injected {}
                try empty(p)
            }
        }
        try await run("actual task cancellation after visual component cleans its owned files") {
            let p=try parent("cancel");var task: Task<StudioMixedMovieExportService.Output,Error>?
            task=Task { try await service.export(snapshot:snapshot,outputParent:p) { if $0.phase == .mixing { task!.cancel() } } }
            do { _=try await task!.value;throw TestError.failed("cancel returned success") } catch is CancellationError {}
            try empty(p)
        }
        try await run("foreign intermediate survives failure and original recovery handle retries cleanup") {
            let p=try parent("foreign");var foreign:URL?;var recovery:StudioMixedMovieExportService.Recovery?
            do {
                _=try await service.export(snapshot:snapshot,outputParent:p) { value in
                    if value.phase == .mixing {
                        let file=try onlyChild(p).appendingPathComponent("foreign.txt")
                        try Data("foreign-preserved".utf8).write(to:file);foreign=file;throw TestError.injected
                    }
                };throw TestError.failed("foreign ignored")
            } catch let failure as StudioMixedMovieExportService.Failure {
                guard case TestError.injected = failure.underlying else { throw TestError.failed("original error lost") }
                recovery=failure.recovery
            }
            guard let foreign,let recovery else {throw TestError.failed("recovery missing")}
            try require(Data(contentsOf:foreign)==Data("foreign-preserved".utf8),"foreign deleted")
            try fm.removeItem(at:foreign);try await recovery.cleanup();try empty(p)
        }
        try await run("returned output rejects replacement and cleanup never adopts foreign bytes") {
            let p=try parent("replacement"),out=try await service.export(snapshot:snapshot,outputParent:p)
            let urls=try out.checkedURLs(),original=root.appendingPathComponent(UUID().uuidString+".mp4")
            try fm.moveItem(at:urls[0],to:original);let foreign=Data("foreign movie".utf8);try foreign.write(to:urls[0])
            do {_=try out.checkedURLs();throw TestError.failed("foreign handed to share")}catch is TestError {throw TestError.failed("foreign accepted")}catch{}
            do {try out.cleanup();throw TestError.failed("foreign cleanup succeeded")}catch is TestError {throw TestError.failed("foreign deleted")}catch{}
            try require(!out.isCleaned && Data(contentsOf:urls[0])==foreign,"false cleaned state")
            try fm.removeItem(at:urls[0]);try fm.moveItem(at:original,to:urls[0]);try out.cleanup();try empty(p)
        }
        print("STUDIO_MIXED_MOVIE_EXPORT_TESTS=PASS \(passed)/\(passed)")
    }
    static func verifyPixels(_ asset: AVAsset, track: AVAssetTrack) async throws {
        let reader = try AVAssetReader(asset: asset), output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); try require(reader.startReading(), "video decoder starts"); var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            guard let pixel = CMSampleBufferGetImageBuffer(sample) else { throw TestError.failed("actual decoded video pixels") }
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let data = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self), at = 16 * CVPixelBufferGetBytesPerRow(pixel) + 32 * 4
            let blue = data[at], green = data[at+1], red = data[at+2]
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            try require(green < 30 && (count < 6 ? red > 220 && blue < 30 : blue > 220 && red < 30), "real frame order/color \(count)")
            try require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: Int64(count), timescale: 12)) == 0, "actual decoded frame PTS")
            count += 1
        }
        try require(reader.status == .completed && count == 12, "actual full decoded video")
    }
    static func decodeAudio(_ asset: AVAsset, track: AVAssetTrack) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset), output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
        reader.add(output); try require(reader.startReading(), "audio decoder starts"); var values: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0, let block = CMSampleBufferGetDataBuffer(sample), CMBlockBufferGetDataLength(block) == count * 8 else { throw TestError.failed("real stereo PCM") }
            try require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: Int64(values.count / 2), timescale: 48_000)) == 0, "actual decoded audio PTS")
            var chunk = [Float](repeating: 0, count: count * 2)
            try require(chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 8, destination: $0.baseAddress!) } == noErr, "copy actual PCM")
            values += chunk
        }
        try require(reader.status == .completed, "actual audio completes"); return values
    }
}
