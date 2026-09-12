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
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("sdi-mux-test-" + UUID().uuidString)
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
        let snapshot = StudioMovieExportService.Snapshot(document: document, retainedAudioTracks: [track], rasterDataByID: [:])
        let capture = try StudioMuxCapture.capture(snapshot), originalProof = capture.proof
        let service = StudioAudioVideoMuxService()
        try await run("existing public export rejects full audio snapshot") {
            do { _ = try await StudioMovieExportService().export(snapshot: snapshot, outputParent: videoParent, background: .white); throw TestError.failed("ordinary silent export") }
            catch StudioMovieExportService.ExportError.audioUnsupported {}
            try empty(videoParent)
        }
        let movie = try await StudioMovieExportService().exportVisualComponent(capture: capture, outputParent: videoParent)
        let audio = try await service.mixAudioComponent(capture: capture, outputParent: audioParent)
        let originalVideoURL = try movie.checkedSource().0, originalAudioURL = try audio.checkedSource().0
        let originalVideo = try Data(contentsOf: originalVideoURL), originalMixedAudio = try Data(contentsOf: originalAudioURL)
        func inputsIntact() throws { _ = try movie.checkedSource(); _ = try audio.checkedSource(); try require(Data(contentsOf: originalVideoURL) == originalVideo, "video source preserved"); try require(Data(contentsOf: originalAudioURL) == originalMixedAudio, "CAF source preserved"); try require(track.audioData == originalAudio, "original encoded asset preserved") }
        try await run("same immutable capture actual H264 and AAC decode pixels stereo timing volume and silence") {
            let p = try parent("success")
            let output = try await service.mux(video: movie, audio: audio, outputParent: p)
            let urls = try output.checkedURLs(), asset = AVURLAsset(url: urls[0])
            let at = try await asset.loadTracks(withMediaType: .audio), vt = try await asset.loadTracks(withMediaType: .video)
            try require(at.count == 1 && vt.count == 1, "actual audio/video tracks")
            try require(output.receipt.decodedAudioFrames == 48_000 && output.receipt.videoFrames == 12, "actual mux counts")
            try require(capture.proof == originalProof && capture.snapshot.document.audioClips == document.audioClips && capture.snapshot.retainedAudioTracks[0].audioData == track.audioData, "full immutable origin retained")
            try await verifyPixels(asset, track: vt[0])
            let samples = try await decodeAudio(asset, track: at[0])
            try require(samples.count == 96_000, "actual exact stereo sample count")
            var squared = [Double](repeating: 0, count: 2), error = squared, silence: Float = 0
            for n in 0..<48_000 {
                for c in 0..<2 {
                    let actual = Double(samples[n * 2 + c])
                    if (16_000..<32_000).contains(n) {
                        let expected = sin(Double(n - 12_000) * 2 * .pi * (c == 0 ? 480 : 960) / 48_000) * (c == 0 ? 0.125 : 0.075)
                        error[c] += pow(actual - expected, 2); squared[c] += actual * actual
                    }
                    if n < 10_000 || n > 38_000 { silence = max(silence, abs(Float(actual))) }
                }
            }
            for c in 0..<2 { let rms = sqrt(squared[c] / 16_000), rmse = sqrt(error[c] / 16_000)
                print("ACTUAL_CHANNEL_\(c)_RMS=\(rms) RMSE=\(rmse)")
                try require(abs(rms - (c == 0 ? 0.125 : 0.075) / sqrt(2)) < 0.004, "stereo volume once")
                try require(rmse < 0.008, "sample aligned channel frequency and phase")
            }
            print("ACTUAL_SILENCE_PEAK=\(silence) ENCODED_BYTES=\(output.receipt.encodedBytes)")
            try require(silence < 0.0005, "real leading and trailing silence")
            let disk = try JSONDecoder().decode(StudioAudioVideoMuxService.Receipt.self, from: Data(contentsOf: urls[1]))
            try require(disk.sha256 == SHA256.hash(data: Data(contentsOf: urls[0])).map { String(format: "%02x", $0) }.joined(), "actual receipt hashes completed file")
            try output.cleanup(); try output.cleanup(); try empty(p); try inputsIntact()
        }
        try await run("equal content proofs from separate captures cannot substitute origin") {
            let other = try StudioMuxCapture.capture(snapshot), otherAudio = try await service.mixAudioComponent(capture: other, outputParent: audioParent)
            try require(other.proof == capture.proof && other !== capture, "fixture same proof distinct origin")
            let p = try parent("different-capture")
            do { _ = try await service.mux(video: movie, audio: otherAudio, outputParent: p); throw TestError.failed("mixed distinct origin") } catch StudioAudioVideoMuxService.MuxError.mismatchedCapture {}
            try otherAudio.cleanup(); try empty(p); try inputsIntact()
        }
        try await run("same project revision but changed audio yields different proof and rejects") {
            var changed = document; changed.audioClips[0].volume = 0.25
            let other = try StudioMuxCapture.capture(.init(document: changed, retainedAudioTracks: [track], rasterDataByID: [:]))
            try require(other.proof.projectID == capture.proof.projectID && other.proof.revision == capture.proof.revision && other.proof.snapshotSHA256 != capture.proof.snapshotSHA256, "content proof not revision only")
            let otherAudio = try await service.mixAudioComponent(capture: other, outputParent: audioParent), p = try parent("different-content")
            do { _ = try await service.mux(video: movie, audio: otherAudio, outputParent: p); throw TestError.failed("mixed different snapshot") } catch StudioAudioVideoMuxService.MuxError.mismatchedCapture {}
            try otherAudio.cleanup(); try empty(p)
        }
        try await run("capture value ownership and raster byte proof") {
            var changed = document; changed.frames[0].elements[0].color = "#00FF00"; changed.audioClips[0].volume = 0.1
            try require(capture.snapshot.document.frames[0].elements[0].color == "#FF0000" && capture.proof == originalProof, "later value edit cannot change capture")
            let a = try StudioMuxCapture.capture(.init(document: document, retainedAudioTracks: [track], rasterDataByID: ["unused-raster": Data([1,2,3])]))
            let b = try StudioMuxCapture.capture(.init(document: document, retainedAudioTracks: [track], rasterDataByID: ["unused-raster": Data([1,2,4])]))
            try require(a.proof.snapshotSHA256 != b.proof.snapshotSHA256, "proof binds even retained unused raster bytes")
        }
        try await run("unresolved legacy missing extra assets and out of range clip reject") {
            var badTrack = track; badTrack.legacySourceFilename = "legacy.wav"
            var snapshots = [StudioMovieExportService.Snapshot(document: document, retainedAudioTracks: [], rasterDataByID: [:]), .init(document: document, retainedAudioTracks: [badTrack], rasterDataByID: [:])]
            let extra = AudioTrack(id: UUID(), name: track.name, format: track.format, audioData: track.audioData, startTime: 0, duration: track.duration); snapshots.append(.init(document: document, retainedAudioTracks: [track, extra], rasterDataByID: [:]))
            var beyond = document; beyond.audioClips[0].startTime = 0.75; snapshots.append(.init(document: beyond, retainedAudioTracks: [track], rasterDataByID: [:]))
            for bad in snapshots { do { _ = try StudioMuxCapture.capture(bad); throw TestError.failed("unresolved audio captured") } catch StudioMuxCapture.CaptureError.unresolvedAudio {} }
        }
        try await run("rational duration rejects fractional audio sample count") {
            var bad = document; bad.fps = 7
            do { _ = try StudioMuxCapture.capture(.init(document: bad, retainedAudioTracks: [track], rasterDataByID: [:])); throw TestError.failed("rounded sample duration") } catch StudioMuxCapture.CaptureError.unsupportedSnapshot {}
        }
        try await run("real overlapping over range CAF rejects without normalization") {
            var loud = document
            loud.audioClips = (0..<5).map { AudioClip(id: "loud-\($0)", soundName: track.name, track: 1, startTime: 0.25, duration: 0.5, volume: 1, assetID: track.id) }
            let loudCapture = try StudioMuxCapture.capture(.init(document: loud, retainedAudioTracks: [track], rasterDataByID: [:]))
            let v = try await StudioMovieExportService().exportVisualComponent(capture: loudCapture, outputParent: videoParent), a = try await service.mixAudioComponent(capture: loudCapture, outputParent: audioParent)
            try require(a.checkedSource().1.overRangeSampleCount > 0, "actual measured overload")
            let p = try parent("overload")
            do { _ = try await service.mux(video: v, audio: a, outputParent: p); throw TestError.failed("silently normalized overload") } catch StudioAudioVideoMuxService.MuxError.overload {}
            try v.cleanup(); try a.cleanup(); try empty(p)
        }
        try await run("output bytes and wall clock bounds clean partial outputs") {
            for limits in [StudioAudioVideoMuxService.Limits(maximumOutputBytes: 1), .init(operationTimeout: 0.000000001)] {
                let p = try parent("limit")
                do { _ = try await StudioAudioVideoMuxService(limits: limits).mux(video: movie, audio: audio, outputParent: p); throw TestError.failed("ignored limit") } catch StudioAudioVideoMuxService.MuxError.limitExceeded {}
                try empty(p); try inputsIntact()
            }
        }
        try await run("callback failure at each writing finalizing verifying publishing stage") {
            for phase in [StudioAudioVideoMuxService.Phase.writing, .finalizing, .verifying, .publishing] {
                let p = try parent("callback")
                do { _ = try await service.mux(video: movie, audio: audio, outputParent: p, progress: { if $0.phase == phase { throw TestError.injected } }); throw TestError.failed("callback swallowed") } catch TestError.injected {}
                try empty(p); try inputsIntact()
            }
        }
        try await run("real task cancellation after writer starts preserves sources") {
            let p = try parent("cancel"); var task: Task<StudioAudioVideoMuxService.Output, Error>?
            task = Task { try await service.mux(video: movie, audio: audio, outputParent: p, progress: { if $0.phase == .writing { task!.cancel() } }) }
            do { _ = try await task!.value; throw TestError.failed("cancel returned output") } catch is CancellationError {}
            try empty(p); try inputsIntact()
        }
        try await run("process lease rejects overlapping mux while first completes") {
            let p = try parent("concurrent"), p2 = try parent("concurrent-rejected")
            var nested: Task<StudioAudioVideoMuxService.Output, Error>?
            let output = try await service.mux(video: movie, audio: audio, outputParent: p, progress: { progress in
                if progress.phase == .writing && nested == nil { nested = Task { try await StudioAudioVideoMuxService().mux(video: movie, audio: audio, outputParent: p2) } }
            })
            do { _ = try await nested!.value; throw TestError.failed("overlap accepted") } catch StudioAudioVideoMuxService.MuxError.busy {}
            try output.cleanup(); try empty(p); try empty(p2)
        }
        try await run("unknown foreign entry preserves full set original error and retry cleanup") {
            let p = try parent("foreign-entry"), sentinel = Data("foreign caller bytes".utf8); var foreign: URL?
            do {
                _ = try await service.mux(video: movie, audio: audio, outputParent: p, progress: { progress in
                    if progress.phase == .publishing { foreign = try onlyChild(p).appendingPathComponent("foreign.txt"); try sentinel.write(to: foreign!, options: .withoutOverwriting); throw TestError.injected }
                }); throw TestError.failed("foreign success")
            } catch let failure as StudioAudioVideoMuxService.Failure {
                guard case TestError.injected = failure.underlying else { throw TestError.failed("lost original callback error") }
                try require(Data(contentsOf: foreign!) == sentinel, "foreign preserved")
                try require(fm.fileExists(atPath: foreign!.deletingLastPathComponent().appendingPathComponent("animation.mp4").path), "whole owned set preserved")
                try fm.removeItem(at: foreign!); try await failure.recovery.cleanup(); try empty(p)
            }
            try inputsIntact()
        }
        try await run("publishing identical byte movie and manifest replacement cannot be adopted") {
            for name in ["animation.mp4", "manifest.json"] {
                let p = try parent("clone"), moved = root.appendingPathComponent(UUID().uuidString); var foreign: URL?, bytes: Data?
                do {
                    _ = try await service.mux(video: movie, audio: audio, outputParent: p, progress: { progress in
                        if progress.phase == .publishing { foreign = try onlyChild(p).appendingPathComponent(name); bytes = try Data(contentsOf: foreign!); try fm.moveItem(at: foreign!, to: moved); try bytes!.write(to: foreign!, options: .withoutOverwriting) }
                    }); throw TestError.failed("adopted identical foreign clone")
                } catch let failure as StudioAudioVideoMuxService.Failure {
                    try require(Data(contentsOf: foreign!) == bytes!, "foreign clone preserved")
                    try require(Data(contentsOf: moved) == bytes!, "original inode preserved")
                    try fm.removeItem(at: foreign!); try fm.moveItem(at: moved, to: foreign!); try await failure.recovery.cleanup(); try empty(p)
                }
                try inputsIntact()
            }
        }
        try await run("returned output rejects foreign replacement and cleanup is retryable") {
            let p = try parent("returned-clone"), output = try await service.mux(video: movie, audio: audio, outputParent: p)
            let url = try output.checkedURLs()[0], bytes = try Data(contentsOf: url), moved = root.appendingPathComponent(UUID().uuidString)
            try fm.moveItem(at: url, to: moved); try bytes.write(to: url, options: .withoutOverwriting)
            do { _ = try output.checkedURLs(); throw TestError.failed("returned clone shared") } catch StudioAudioVideoMuxService.MuxError.outputUnavailable {}
            do { try output.cleanup(); throw TestError.failed("returned clone removed") } catch StudioAudioVideoMuxService.MuxError.cleanupFailed {}
            try require(Data(contentsOf: url) == bytes, "returned foreign preserved")
            try fm.removeItem(at: url); try fm.moveItem(at: moved, to: url); try output.cleanup(); try output.cleanup(); try empty(p)
        }
        try await run("same inode output corruption rejects and preserves changed bytes") {
            let p = try parent("corruption"), output = try await service.mux(video: movie, audio: audio, outputParent: p)
            let url = try output.checkedURLs()[0], bytes = try Data(contentsOf: url)
            let handle = try FileHandle(forWritingTo: url); try handle.write(contentsOf: Data([bytes[0] ^ 0xff])); try handle.close()
            do { _ = try output.checkedURLs(); throw TestError.failed("corrupt output shared") } catch StudioAudioVideoMuxService.MuxError.outputUnavailable {}
            do { try output.cleanup(); throw TestError.failed("changed output removed") } catch StudioAudioVideoMuxService.MuxError.cleanupFailed {}
            try require(fm.fileExists(atPath: url.path), "corrupt bytes preserved")
            let repair = try FileHandle(forWritingTo: url); try repair.write(contentsOf: bytes); try repair.close(); try output.cleanup(); try empty(p)
        }
        try await run("source audio mutation before or during mux cannot become successful receipt") {
            for during in [false, true] {
                let p = try parent("source-change")
                func change() throws { let h = try FileHandle(forWritingTo: originalAudioURL); try h.seek(toOffset: UInt64(originalMixedAudio.count - 1)); try h.write(contentsOf: Data([originalMixedAudio.last! ^ 0xff])); try h.close() }
                if !during { try change() }
                do { _ = try await service.mux(video: movie, audio: audio, outputParent: p, progress: { if during && $0.phase == .publishing { try change() } }); throw TestError.failed("changed source accepted") }
                catch is TestError { throw TestError.failed("changed source test did not reject") }
                catch { /* Actual checked-source failure; cleanup must still succeed. */ }
                let h = try FileHandle(forWritingTo: originalAudioURL); try h.write(contentsOf: originalMixedAudio); try h.close()
                try empty(p); try inputsIntact()
            }
        }
        try await run("full audio visual component inherits movie and manifest identity transfer repair") {
            for name in ["animation.mp4", "manifest.json"] {
                let p = try parent("component-clone"), moved = root.appendingPathComponent(UUID().uuidString); var foreign: URL?, bytes: Data?
                do {
                    _ = try await StudioMovieExportService().exportVisualComponent(capture: capture, outputParent: p, progress: { progress in
                        if progress.phase == .publishing { foreign = try onlyChild(p).appendingPathComponent(name); bytes = try Data(contentsOf: foreign!); try fm.moveItem(at: foreign!, to: moved); try bytes!.write(to: foreign!, options: .withoutOverwriting) }
                    }); throw TestError.failed("component adopted clone")
                } catch StudioMovieExportService.ExportError.cleanupFailed {
                    try require(Data(contentsOf: foreign!) == bytes! && Data(contentsOf: moved) == bytes!, "component clone/original lost")
                    try require(capture.proof == originalProof && capture.snapshot.document.audioClips == document.audioClips, "component changed full audio origin")
                }
            }
        }
        try await run("mux directory and parent replacement preserve both trees and allow restored cleanup") {
            for replaceParent in [false, true] {
                let p = try parent("replacement-tree"), moved = root.appendingPathComponent(UUID().uuidString), sentinel = Data("foreign tree".utf8)
                var original: URL?, foreign: URL?
                do {
                    _ = try await service.mux(video: movie, audio: audio, outputParent: p, progress: { progress in
                        if progress.phase == .publishing {
                            original = replaceParent ? p : try onlyChild(p)
                            try fm.moveItem(at: original!, to: moved); try fm.createDirectory(at: original!, withIntermediateDirectories: false)
                            foreign = original!.appendingPathComponent("foreign.txt"); try sentinel.write(to: foreign!, options: .withoutOverwriting)
                        }
                    }); throw TestError.failed("replacement tree published")
                } catch let failure as StudioAudioVideoMuxService.Failure {
                    try require(Data(contentsOf: foreign!) == sentinel, "foreign tree lost")
                    let preserved = replaceParent ? try onlyChild(moved) : moved
                    try require(fm.fileExists(atPath: preserved.appendingPathComponent("animation.mp4").path) && fm.fileExists(atPath: preserved.appendingPathComponent("manifest.json").path), "original tree outputs lost")
                    do { try await failure.recovery.cleanup(); throw TestError.failed("unrestored foreign tree cleaned") } catch StudioAudioVideoMuxService.MuxError.cleanupFailed {}
                    try fm.removeItem(at: original!); try fm.moveItem(at: moved, to: original!); try await failure.recovery.cleanup(); try empty(p)
                }
                try inputsIntact()
            }
        }
        try await run("unsafe destination rejects without changing external sentinel") {
            let real = try parent("real"), link = root.appendingPathComponent("linked-parent")
            try fm.createSymbolicLink(at: link, withDestinationURL: real)
            let file = real.appendingPathComponent("foreign.txt"), sentinel = Data([7,8,9]); try sentinel.write(to: file)
            do { _ = try await service.mux(video: movie, audio: audio, outputParent: link); throw TestError.failed("symlink destination accepted") } catch StudioAudioVideoMuxService.MuxError.unsafeDestination {}
            try require(Data(contentsOf: file) == sentinel && fm.contentsOfDirectory(atPath: real.path).count == 1, "external destination unchanged")
        }
        try await run("valid different-audio MP4 same-inode substitution rejects verifying and publishing") {
            var quieter = document; quieter.audioClips[0].volume = 0.25
            let otherCapture = try StudioMuxCapture.capture(.init(document: quieter, retainedAudioTracks: [track], rasterDataByID: [:]))
            let otherVideo = try await StudioMovieExportService().exportVisualComponent(capture: otherCapture, outputParent: videoParent)
            let otherAudio = try await service.mixAudioComponent(capture: otherCapture, outputParent: audioParent)
            let controlParent = try parent("substitution-controls")
            let normal = try await service.mux(video: movie, audio: audio, outputParent: controlParent)
            let different = try await service.mux(video: otherVideo, audio: otherAudio, outputParent: controlParent)
            let normalURL = try normal.checkedURLs()[0]
            // Two hardware encodes of identical artwork may have different H.264
            // payloads. Copy the original compressed video into the quieter AAC
            // control so this regression isolates audio substitution exclusively.
            let differentURL = root.appendingPathComponent("audio-only-substitution.mp4")
            try await audioOnlySubstitutionFixture(videoURL: normalURL,
                audioURL: different.checkedURLs()[0], outputURL: differentURL)
            let normalDigest = try await compressedVideoDigest(normalURL), differentDigest = try await compressedVideoDigest(differentURL)
            try require(normalDigest == differentDigest, "substitution controls must retain identical actual H264 payloads")
            let normalAsset = AVURLAsset(url: normalURL), differentAsset = AVURLAsset(url: differentURL)
            let nt = try await normalAsset.loadTracks(withMediaType: .audio), dt = try await differentAsset.loadTracks(withMediaType: .audio)
            let n = try await decodeAudio(normalAsset, track: nt[0]), d = try await decodeAudio(differentAsset, track: dt[0])
            try require(n.count == d.count && n.count == 96_000, "substitution has real identical full audio timing")
            let normalPower = n[32_000..<64_000].reduce(0.0) { $0 + Double($1 * $1) }
            let differentPower = d[32_000..<64_000].reduce(0.0) { $0 + Double($1 * $1) }
            try require(differentPower / normalPower > 0.20 && differentPower / normalPower < 0.30, "substitution is actual quieter AAC, not corrupt bytes")
            print("ACTUAL_VALID_SUBSTITUTION_AUDIO_POWER_RATIO=\(differentPower / normalPower)")
            let differentBytes = try Data(contentsOf: differentURL)
            for phase in [StudioAudioVideoMuxService.Phase.verifying, .publishing] {
                let p = try parent("valid-audio-substitution"); var replaced = false
                do {
                    let unexpected = try await service.mux(video: movie, audio: audio, outputParent: p, progress: { progress in
                        if progress.phase == phase {
                            let file = try onlyChild(p).appendingPathComponent("animation.mp4")
                            let before = try fm.attributesOfItem(atPath: file.path)[.systemFileNumber] as! NSNumber
                            try require(Data(contentsOf: file) != differentBytes, "actual completed MP4 differs before substitution")
                            let handle = try FileHandle(forWritingTo: file); try handle.write(contentsOf: differentBytes)
                            try handle.truncate(atOffset: UInt64(differentBytes.count)); try handle.close()
                            let after = try fm.attributesOfItem(atPath: file.path)[.systemFileNumber] as! NSNumber
                            try require(before == after && Data(contentsOf: file) == differentBytes, "actual valid-media substitution retains original inode")
                            replaced = true
                        }
                    })
                    print("ACTUAL_VALID_AUDIO_SUBSTITUTION_ACCEPTED=true phase=\(phase)")
                    try unexpected.cleanup(); throw TestError.failed("different valid AAC adopted at callback")
                } catch StudioAudioVideoMuxService.MuxError.verificationFailed {
                    try require(replaced, "actual valid-media replacement callback ran")
                }
                try empty(p); try inputsIntact()
            }
            try normal.cleanup(); try different.cleanup(); try otherVideo.cleanup(); try otherAudio.cleanup(); try empty(controlParent)
        }
        try await run("identical completed mux rewrite remains valid at verifying callback") {
            let p = try parent("identical-mux"); var rewritten = false
            let output = try await service.mux(video: movie, audio: audio, outputParent: p, progress: { progress in
                if progress.phase == .verifying {
                    let file = try onlyChild(p).appendingPathComponent("animation.mp4"), bytes = try Data(contentsOf: file)
                    let handle = try FileHandle(forWritingTo: file); try handle.write(contentsOf: bytes); try handle.close(); rewritten = true
                }
            })
            try require(rewritten, "actual verifying callback ran")
            let url = try output.checkedURLs()[0], asset = AVURLAsset(url: url), tracks = try await asset.loadTracks(withMediaType: .video)
            try await verifyPixels(asset, track: tracks[0]); try output.cleanup(); try empty(p); try inputsIntact()
        }
        try await run("full audio visual component rejects valid different-picture callback substitution") {
            var green = document
            for index in green.frames.indices { green.frames[index].elements[0].color = "#00FF00" }
            let greenCapture = try StudioMuxCapture.capture(.init(document: green, retainedAudioTracks: [track], rasterDataByID: [:]))
            let control = try await StudioMovieExportService().exportVisualComponent(capture: greenCapture, outputParent: videoParent)
            let bytes = try Data(contentsOf: control.checkedSource().0)
            let greenDigest = try await compressedVideoDigest(control.checkedSource().0), originalDigest = try await compressedVideoDigest(originalVideoURL)
            try require(greenDigest != originalDigest, "valid green component has different actual H264 pictures")
            for phase in [StudioMovieExportService.Phase.verifying, .publishing] {
                let p = try parent("component-picture-substitution"); var replaced = false
                do {
                    let unexpected = try await StudioMovieExportService().exportVisualComponent(capture: capture, outputParent: p, progress: { progress in
                        if progress.phase == phase {
                            let file = try onlyChild(p).appendingPathComponent("animation.mp4")
                            let inode = try fm.attributesOfItem(atPath: file.path)[.systemFileNumber] as! NSNumber
                            let handle = try FileHandle(forWritingTo: file); try handle.write(contentsOf: bytes); try handle.truncate(atOffset: UInt64(bytes.count)); try handle.close()
                            try require(fm.attributesOfItem(atPath: file.path)[.systemFileNumber] as! NSNumber == inode, "component substitution preserves inode")
                            replaced = true
                        }
                    }); try unexpected.cleanup(); throw TestError.failed("valid different component picture accepted")
                } catch StudioMovieExportService.ExportError.verificationFailed { try require(replaced, "component callback ran") }
                try empty(p); try require(capture.proof == originalProof && capture.snapshot.document.audioClips == document.audioClips, "component retained full audio origin")
            }
            try control.cleanup(); try inputsIntact()
        }
        try await run("short and nondivisor frame rates preserve exact aligned audio video timing") {
            for (fps, count) in [(60, 1), (7, 7), (59, 59)] {
                var timed = document; timed.fps = fps
                timed.frames = (0..<count).map { index in
                    AnimationFrame(id: "timed-frame-\(index)", elements: [DrawnElement(id: "timed-stroke-\(index)", tool: .brush,
                        points: [StrokePoint(x: 0, y: 16), StrokePoint(x: 64, y: 16)], color: index.isMultiple(of: 2) ? "#FF0000" : "#0000FF", width: 64, opacity: 1, layerID: timed.activeLayerID)])
                }
                timed.activeFrameID = timed.frames[0].id
                let seconds = Double(count) / Double(fps), expectedSamples = count * 48_000 / fps
                timed.audioClips = [AudioClip(id: "timed-audio", soundName: track.name, track: 1, startTime: 0, duration: min(seconds, 0.5), volume: 0.5, assetID: track.id)]
                let origin = try StudioMuxCapture.capture(.init(document: timed, retainedAudioTracks: [track], rasterDataByID: [:]))
                let v = try await StudioMovieExportService().exportVisualComponent(capture: origin, outputParent: videoParent)
                let a = try await service.mixAudioComponent(capture: origin, outputParent: audioParent), p = try parent("exact-timing")
                let output = try await service.mux(video: v, audio: a, outputParent: p)
                let asset = AVURLAsset(url: try output.checkedURLs()[0]), duration = try await asset.load(.duration)
                try require(CMTimeCompare(duration, CMTime(value: Int64(count), timescale: CMTimeScale(fps))) == 0, "no container duration rounding")
                let audioTracks = try await asset.loadTracks(withMediaType: .audio), videoTracks = try await asset.loadTracks(withMediaType: .video)
                let decoded = try await decodeAudio(asset, track: audioTracks[0])
                try require(decoded.count == expectedSamples * 2 && decoded.contains { abs($0) > 0.001 }, "actual short/full AAC includes exact samples and real tone")
                let reader = try AVAssetReader(asset: asset), pictures = AVAssetReaderTrackOutput(track: videoTracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(pictures); try require(reader.startReading(), "timed pixel reader starts"); var frames = 0
                while let sample = pictures.copyNextSampleBuffer() {
                    if CMSampleBufferGetNumSamples(sample) == 0 { continue }
                    guard let pixel = CMSampleBufferGetImageBuffer(sample) else { throw TestError.failed("timed frame has actual pixels") }
                    CVPixelBufferLockBaseAddress(pixel, .readOnly)
                    let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self), at = 16 * CVPixelBufferGetBytesPerRow(pixel) + 32 * 4
                    let blue = base[at], red = base[at + 2]
                    CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
                    try require(frames.isMultiple(of: 2) ? red > 220 && blue < 30 : blue > 220 && red < 30, "actual timed frame order")
                    try require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: Int64(frames), timescale: CMTimeScale(fps))) == 0, "exact nondivisor frame PTS")
                    frames += 1
                }
                try require(reader.status == .completed && frames == count, "full exact timed movie reopens")
                print("ACTUAL_TIMING_FPS=\(fps) FRAMES=\(frames) AUDIO_SAMPLES=\(decoded.count / 2)")
                try output.cleanup(); try v.cleanup(); try a.cleanup(); try empty(p); try inputsIntact()
            }
        }
        try inputsIntact(); try movie.cleanup(); try audio.cleanup(); try empty(videoParent); try empty(audioParent)
        print("STUDIO_AUDIO_VIDEO_MUX_TESTS=PASS \(passed)/\(passed)")
    }

    /// Test-owned control, never an application export path. Both tracks are
    /// passed through without an encoder; assertions below decode its actual
    /// AAC and compare every original compressed H.264 sample.
    static func audioOnlySubstitutionFixture(videoURL: URL, audioURL: URL, outputURL: URL) async throws {
        let video = AVURLAsset(url: videoURL), audio = AVURLAsset(url: audioURL)
        let videoTracks = try await video.loadTracks(withMediaType: .video)
        let audioTracks = try await audio.loadTracks(withMediaType: .audio)
        try require(videoTracks.count == 1 && audioTracks.count == 1, "one fixture track of each kind")
        let vt = videoTracks[0], at = audioTracks[0]
        let vf = try await vt.load(.formatDescriptions), af = try await at.load(.formatDescriptions)
        try require(vf.count == 1 && af.count == 1, "fixture has actual H264 and AAC formats")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vf[0])
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: af[0])
        vi.mediaTimeScale = try await vt.load(.naturalTimeScale)
        vi.transform = try await vt.load(.preferredTransform)
        writer.movieTimeScale = 48_000
        try require(writer.canAdd(vi) && writer.canAdd(ai), "fixture writer accepts compressed tracks")
        writer.add(vi); writer.add(ai)
        let vr = try AVAssetReader(asset: video), ar = try AVAssetReader(asset: audio)
        let vo = AVAssetReaderTrackOutput(track: vt, outputSettings: nil)
        let ao = AVAssetReaderTrackOutput(track: at, outputSettings: nil)
        try require(vr.canAdd(vo) && ar.canAdd(ao), "fixture readers accept compressed tracks")
        vr.add(vo); ar.add(ao)
        defer { if writer.status == .writing { writer.cancelWriting() }; vr.cancelReading(); ar.cancelReading() }
        try require(writer.startWriting(), "fixture writer starts")
        writer.startSession(atSourceTime: .zero)
        try require(vr.startReading() && ar.startReading(), "fixture readers start")
        let start = ProcessInfo.processInfo.systemUptime
        func checkpoint() throws {
            try Task.checkCancellation()
            try require(ProcessInfo.processInfo.systemUptime - start < 15, "bounded fixture writer")
        }
        var videoDone = false, audioDone = false
        while !videoDone || !audioDone {
            try checkpoint()
            if !videoDone && vi.isReadyForMoreMediaData {
                if let sample = vo.copyNextSampleBuffer() { try require(vi.append(sample), "fixture copies original H264 sample") }
                else { videoDone = true; vi.markAsFinished() }
            }
            if !audioDone && ai.isReadyForMoreMediaData {
                if let sample = ao.copyNextSampleBuffer() { try require(ai.append(sample), "fixture copies quieter AAC sample") }
                else { audioDone = true; ai.markAsFinished() }
            }
            try require(writer.status == .writing, "fixture remains writable")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try require(vr.status == .completed && ar.status == .completed, "fixture compressed sources complete")
        writer.endSession(atSourceTime: try await video.load(.duration))
        writer.finishWriting {}
        while writer.status == .writing { try checkpoint(); try await Task.sleep(nanoseconds: 1_000_000) }
        try require(writer.status == .completed, "fixture MP4 finalizes")
    }

    static func compressedVideoDigest(_ url: URL) async throws -> SHA256.Digest {
        let asset = AVURLAsset(url: url), tracks = try await asset.loadTracks(withMediaType: .video)
        try require(tracks.count == 1, "one real video track")
        let reader = try AVAssetReader(asset: asset), output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: nil)
        reader.add(output); try require(reader.startReading(), "compressed reader starts"); var digest = SHA256(), frames = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw TestError.failed("actual video payload") }
            let count = CMBlockBufferGetDataLength(block); try require(count > 0 && count <= 16 * 1024 * 1024, "bounded compressed payload")
            var bytes = [UInt8](repeating: 0, count: count)
            try require(bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) } == noErr, "read actual payload")
            digest.update(data: Data(bytes)); frames += 1
        }
        try require(reader.status == .completed && frames == 12, "full actual compressed video control")
        return digest.finalize()
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
