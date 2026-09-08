import Foundation
import AVFoundation
import Darwin

private struct Failure: Error { let message: String }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}
private actor DecodePause {
    var reached = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pauseOnce() async {
        guard !reached else { return }
        reached = true
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

@main @MainActor struct StudioAudioImportTests {
    static let fm = FileManager.default
    static let service = StudioAudioImportService()
    static func write<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    // Known synthetic PCM fixtures, not production-library sounds or a mirror
    // decoder. Apple AVFoundation must parse/decode these real RIFF files.
    static func wave(frames: Int, rate: Int = 8192, channels: Int = 1,
                     float: Bool = false, sample: (Int, Int) -> Float) -> Data {
        let sampleBytes = float ? 4 : 2, dataBytes = frames * channels * sampleBytes
        var result = Data("RIFF".utf8); write(UInt32(36 + dataBytes), to: &result)
        result.append(Data("WAVEfmt ".utf8)); write(UInt32(16), to: &result)
        write(UInt16(float ? 3 : 1), to: &result); write(UInt16(channels), to: &result)
        write(UInt32(rate), to: &result); write(UInt32(rate * channels * sampleBytes), to: &result)
        write(UInt16(channels * sampleBytes), to: &result); write(UInt16(sampleBytes * 8), to: &result)
        result.append(Data("data".utf8)); write(UInt32(dataBytes), to: &result)
        for frame in 0..<frames {
            for channel in 0..<channels {
                let value = sample(frame, channel)
                if float { write(value.bitPattern, to: &result) }
                else { write(Int16(max(-32768, min(32767, Int((value * 32768).rounded())))), to: &result) }
            }
        }
        return result
    }
    static func file(_ root: URL, _ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name); try data.write(to: url, options: .withoutOverwriting); return url
    }
    static func checkClean(_ scratch: URL) throws {
        try require(try fm.contentsOfDirectory(atPath: scratch.path) == ["sentinel"], "Import left an owned temporary copy or removed unrelated data")
    }
    static func rejects(_ operation: () async throws -> Void,
                        matching expected: StudioAudioImportService.ImportError? = nil) async throws {
        do { try await operation(); throw Failure(message: "Unsafe import unexpectedly succeeded") }
        catch let error as StudioAudioImportService.ImportError {
            if let expected { try require(String(describing: error) == String(describing: expected), "Wrong rejection: \(error)") }
        }
    }
    static func encodedAudio(_ root: URL, extension suffix: String, formatID: AudioFormatID) throws -> URL {
        let url = root.appendingPathComponent("synthetic.\(suffix)")
        try autoreleasepool {
            var settings: [String: Any] = [AVFormatIDKey: formatID, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1]
            if formatID == kAudioFormatMPEG4AAC { settings[AVEncoderBitRateKey] = 96000 }
            else {
                settings[AVLinearPCMBitDepthKey] = 16
                settings[AVLinearPCMIsFloatKey] = false
                settings[AVLinearPCMIsBigEndianKey] = suffix == "aiff"
            }
            let writer = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 4096)!
            buffer.frameLength = 4096
            for index in 0..<4096 { buffer.floatChannelData![0][index] = 0.5 * sin(Float(index) * 2 * .pi * 440 / 48000) }
            try writer.write(from: buffer)
        }
        return url
    }

    static func main() async {
        do { try await run() }
        catch { print("STUDIO_AUDIO_IMPORT_TESTS=FAIL \(error)"); exit(1) }
    }
    static func run() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-audio-import-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let scratch = root.appendingPathComponent("scratch")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        _ = try file(scratch, "sentinel", Data("unrelated original".utf8))
        var passed = 0
        func test(_ name: String, _ body: () async throws -> Void) async throws {
            do { try await body(); try checkClean(scratch); passed += 1; print("PASS \(name)") }
            catch { print("FAIL \(name): \(error)"); throw error }
        }
        let signal = wave(frames: 16384) { frame, _ in [-Float(0.5), 0, 0.25, 1][frame / 4096] }
        let signalURL = try file(root, "known-signal.unknown-extension", signal)
        try await test("actual PCM decode measures duration and four known peak intervals, independent of filename") {
            let result = try await service.importAudio(from: signalURL, name: "Measured signal", scratchParent: scratch)
            try require(result.container == .wav && result.decodedFrameCount == 16384 && result.duration == 2
                        && result.sampleRate == 8192 && result.channelCount == 1, "Incorrect decoded audio identity or timing")
            try require(result.originalData == signal && result.track.audioData == signal && result.track.id == result.id
                        && result.track.startTime == 0 && result.track.legacySourceFilename == nil, "Original bytes or stable track identity changed")
            try require(result.waveformPeaks.count == 256, "Wrong measured envelope size")
            for index in 0..<256 {
                let expected: Float = [0.5, 0, 0.25, 32767.0 / 32768.0][index / 64]
                try require(abs(result.waveformPeaks[index] - expected) < 0.00001, "Wrong measured peak at \(index)")
            }
            try require(!result.hasClippedSamples && (try Data(contentsOf: signalURL)) == signal, "Import changed original or invented clipping")
        }
        try await test("silence is exactly zero and very short files keep a bounded envelope") {
            for count in [4, 5000] {
                let source = try file(root, "silence-\(count).wav", wave(frames: count) { _, _ in 0 })
                let result = try await service.importAudio(from: source, scratchParent: scratch)
                try require(result.waveformPeaks == [Float](repeating: 0, count: 256), "Silence has invented waveform values")
                try require(result.decodedFrameCount == count, "Short source was padded or truncated")
            }
        }
        try await test("stereo envelope measures both channels rather than averaging phase cancellation") {
            let source = try file(root, "stereo.wav", wave(frames: 8192, channels: 2) { frame, channel in
                channel == 0 ? 0.25 : (frame < 4096 ? -0.75 : 0)
            })
            let result = try await service.importAudio(from: source, scratchParent: scratch)
            try require(result.channelCount == 2 && result.duration == 1, "Stereo duration/channels wrong")
            for bin in 0..<256 { try require(result.waveformPeaks[bin] == (bin < 128 ? 0.75 : 0.25), "Stereo peak omitted a channel") }
        }
        try await test("floating PCM clipping is measured and nonfinite samples are rejected") {
            let source = try file(root, "float.wav", wave(frames: 4096, float: true) { _, _ in 1.5 })
            let result = try await service.importAudio(from: source, scratchParent: scratch)
            try require(result.hasClippedSamples && result.waveformPeaks.allSatisfy { $0 == 1 }, "Clipping measurement wrong")
            let invalid = try file(root, "nan.wav", wave(frames: 4096, float: true) { _, _ in .nan })
            try await rejects({ _ = try await service.importAudio(from: invalid, scratchParent: scratch) }, matching: .invalidAudio)
        }
        try await test("native Apple CAF AIFF and AAC M4A encoders produce real importable audio") {
            for (suffix, formatID) in [("caf", kAudioFormatLinearPCM), ("aiff", kAudioFormatLinearPCM), ("m4a", kAudioFormatMPEG4AAC)] {
                let source = try encodedAudio(root, extension: suffix, formatID: formatID)
                let bytes = try Data(contentsOf: source)
                let result = try await service.importAudio(from: source, scratchParent: scratch)
                try require(result.originalData == bytes && result.sampleRate == 48000 && result.channelCount == 1,
                            "Encoded asset did not roundtrip unchanged")
                try require(result.duration > 0.07 && result.duration < 0.12 && result.waveformPeaks.max()! > 0.4,
                            "Encoded audio did not decode the actual known signal")
                try require(result.container.rawValue == suffix || (suffix == "aiff" && result.container == .aifc), "Wrong actual container")
            }
        }
        try await test("empty nonaudio and truncated declared PCM fail with complete scratch cleanup") {
            for (name, data) in [("empty.wav", Data()), ("text.wav", Data("not audio".utf8)), ("truncated.wav", signal.dropLast(20))] {
                let source = try file(root, name, Data(data))
                try await rejects { _ = try await service.importAudio(from: source, scratchParent: scratch) }
                try require(try Data(contentsOf: source) == data, "Failed import changed its source")
            }
        }
        try await test("remote URL symlink directory and FIFO are rejected without reading streams") {
            let link = root.appendingPathComponent("link.wav")
            try fm.createSymbolicLink(at: link, withDestinationURL: signalURL)
            let fifo = root.appendingPathComponent("pipe.wav")
            try require(mkfifo(fifo.path, 0o600) == 0, "Fixture FIFO creation failed")
            for source in [URL(string: "https://example.invalid/not-a-request.wav")!,
                           URL(string: "file:///tmp/ambiguous%00.wav")!, link, root, fifo] {
                try await rejects({ _ = try await service.importAudio(from: source, scratchParent: scratch) }, matching: .unsafeSource)
            }
        }
        try await test("encoded byte sample-rate channel and duration bounds reject real files") {
            let oversized = try file(root, "oversized.wav", Data())
            let handle = try FileHandle(forWritingTo: oversized)
            try handle.truncate(atOffset: UInt64(StudioAudioImportService.maximumEncodedBytes + 1)); try handle.close()
            try await rejects({ _ = try await service.importAudio(from: oversized, scratchParent: scratch) }, matching: .limitExceeded)
            for (name, frames, rate, channels) in [("rate", 512, 192000, 1), ("channels", 512, 8192, 3), ("duration", 8000 * 301, 8000, 1)] {
                let source = try file(root, "\(name).wav", wave(frames: frames, rate: rate, channels: channels) { _, _ in 0 })
                try await rejects({ _ = try await service.importAudio(from: source, scratchParent: scratch) }, matching: .limitExceeded)
            }
        }
        try await test("excessive RIFF metadata is bounded before invoking the audio parser") {
            var chunks = Data("WAVE".utf8)
            for _ in 0...StudioAudioImportService.maximumContainerChunks {
                chunks.append(Data("JUNK".utf8)); write(UInt32(0), to: &chunks)
            }
            chunks.append(signal.dropFirst(12))
            var data = Data("RIFF".utf8); write(UInt32(chunks.count), to: &data); data.append(chunks)
            let source = try file(root, "metadata-work-limit.wav", data)
            try await rejects({ _ = try await service.importAudio(from: source, scratchParent: scratch) }, matching: .limitExceeded)
        }
        try await test("source size and metadata changes during copy are surfaced") {
            let changed = try file(root, "changing.wav", signal)
            try await rejects({
                _ = try await service.importAudio(from: changed, scratchParent: scratch) { state in
                    if state.phase == .reading && state.completed == signal.count {
                        let handle = try FileHandle(forWritingTo: changed)
                        try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
                    }
                }
            }, matching: .sourceChanged)
            let retimed = try file(root, "retimed.wav", signal)
            try await rejects({
                _ = try await service.importAudio(from: retimed, scratchParent: scratch) { state in
                    if state.phase == .reading {
                        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: retimed.path)
                    }
                }
            }, matching: .sourceChanged)
        }
        try await test("copy cancellation removes partial output and does not alter the original") {
            do {
                _ = try await service.importAudio(from: signalURL, scratchParent: scratch) { state in
                    if state.phase == .reading { throw CancellationError() }
                }
                throw Failure(message: "Copy cancellation succeeded")
            } catch is CancellationError { }
            try require(try Data(contentsOf: signalURL) == signal, "Cancellation changed original data")
        }
        try await test("mid-decode Task cancellation and global lease prevent concurrent imports") {
            let pause = DecodePause()
            let first = Task {
                try await service.importAudio(from: signalURL, scratchParent: scratch) { state in
                    if state.phase == .decoding { await pause.pauseOnce() }
                }
            }
            for _ in 0..<400 {
                if await pause.reached { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard await pause.reached else { first.cancel(); await pause.resume(); throw Failure(message: "Decoder never reached a bounded chunk") }
            try await rejects({ _ = try await StudioAudioImportService().importAudio(from: signalURL, scratchParent: scratch) }, matching: .busy)
            first.cancel(); await pause.resume()
            do { _ = try await first.value; throw Failure(message: "Mid-decode Task cancellation was ignored") }
            catch is CancellationError { }
            _ = try await service.importAudio(from: signalURL, scratchParent: scratch)
        }
        try await test("duplicate source names preserve separate stable IDs through actual atomic storage and source deletion") {
            let one = try await service.importAudio(from: signalURL, name: "Same name", scratchParent: scratch)
            let two = try await service.importAudio(from: signalURL, name: "Same name", scratchParent: scratch)
            try require(one.id != two.id, "Colliding names reused an asset ID")
            let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("documents"))
            let id = UUID(), now = Date()
            let metadata = AnimationMetadata(id: id, title: "Audio roundtrip", fps: 12, canvasWidth: 64, canvasHeight: 64,
                frameCount: 1, layerCount: 1, createdAt: now, modifiedAt: now, thumbnailData: nil)
            try storage.saveAnimation(.init(id: id, metadata: metadata, frames: [.init(imageData: nil)], audioTracks: [one.track, two.track]))
            let stored = try storage.loadAnimation(id: id)!
            try require(stored.audioTracks.map(\.id) == [one.id, two.id] && stored.audioTracks.allSatisfy { $0.audioData == signal && $0.duration == 2 && $0.format == "wav" },
                        "Actual storage lost imported identity, bytes or timing")
            let transient = try file(root, "delete-after-import.wav", signal)
            let result = try await service.importAudio(from: transient, scratchParent: scratch)
            try fm.removeItem(at: transient)
            let reopened = try file(root, "reopened-from-project.wav", result.track.audioData!)
            let decoded = try await service.importAudio(from: reopened, scratchParent: scratch)
            try require(decoded.waveformPeaks == result.waveformPeaks && decoded.duration == result.duration, "Persisted bytes depend on vanished picker URL")
        }
        try await test("scratch symlink and invalid names fail without altering neighboring files") {
            let link = root.appendingPathComponent("scratch-link")
            try fm.createSymbolicLink(at: link, withDestinationURL: scratch)
            try await rejects({ _ = try await service.importAudio(from: signalURL, scratchParent: link) }, matching: .temporaryStorage)
            for name in ["", "\n", String(repeating: "x", count: 121), "line\nbreak"] {
                try await rejects({ _ = try await service.importAudio(from: signalURL, name: name, scratchParent: scratch) }, matching: .invalidName)
            }
        }
        print("STUDIO_AUDIO_IMPORT_TESTS=PASS \(passed) actual production cases")
    }
}
