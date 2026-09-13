import Foundation
import AVFoundation
import CryptoKit
import Darwin

private enum ProbeError: Error { case failed(String), cancelledAtProgress }
private func check(_ value: Bool, _ reason: String) throws { if !value { throw ProbeError.failed(reason) } }
private func near(_ a: Float, _ b: Float, _ tolerance: Float = 0.0001) throws { try check(abs(a - b) < tolerance, "sample \(a) != \(b)") }
private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private final class Box: @unchecked Sendable {
    let root: URL
    init(_ root: URL) { self.root = root }
    func directory() throws -> URL { let dirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil); guard dirs.count == 1 else { throw ProbeError.failed("expected one directory") }; return dirs[0] }
}
private actor Barrier {
    var entered = false, released = false
    func wait() async { entered = true; while !released { await Task.yield() } }
    func release() { released = true }
}
@main struct Tests {
    static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-mix-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = root.appendingPathComponent("mixes", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        var count = 0
        func test(_ name: String, _ body: () async throws -> Void) async throws { print("RUN \(name)"); try await body(); count += 1; print("PASS \(name)") }
        func document(_ clips: [AudioClip]) throws -> StudioDocument { var value = try StudioDocument.new(name: "Mix fixture", width: 32, height: 32, fps: 12); value.audioClips = clips; return value }
        func clip(_ asset: AudioTrack, start: Double = 0, duration: Double? = nil, volume: Double = 1, track: Int = 1) -> AudioClip {
            AudioClip(id: UUID().uuidString, soundName: asset.name, track: track, startTime: start, duration: duration ?? asset.duration, volume: volume, assetID: asset.id)
        }
        func fixture(rate: Double = 48000, channels: Int = 2, seconds: Double = 0.1, format: String = "wav", compressed: Bool = false, samples: (Int, Int) -> Float) throws -> AudioTrack {
            let url = root.appendingPathComponent(UUID().uuidString + "." + format)
            let frames = Int(rate * seconds)
            let pcm: AVAudioFormat
            if channels > 2 {
                pcm = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Quadraphonic)!)
            } else {
                pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false)!
            }
            do {
                var settings = pcm.settings
                settings[AVLinearPCMIsNonInterleaved] = false
                if compressed { settings = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate,
                                             AVNumberOfChannelsKey: channels, AVEncoderBitDepthHintKey: 16] }
                let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let b = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(frames))!; b.frameLength = AVAudioFrameCount(frames)
                for c in 0..<channels { for n in 0..<frames { b.floatChannelData![c][n] = samples(n,c) } }; try f.write(from: b)
            }
            return AudioTrack(id: UUID(), name: "Generated \(format)", format: format, audioData: try Data(contentsOf: url), startTime: 0, duration: Double(frames)/rate)
        }
        func read(_ output: StudioAudioMixService.Output) throws -> [[Float]] {
            let file = try AVAudioFile(forReading: output.checkedURL(), commonFormat: .pcmFormatFloat32, interleaved: false)
            try check(file.processingFormat.channelCount == 2 && file.processingFormat.sampleRate == 48000, "mix PCM format")
            let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!; try file.read(into: b)
            try check(file.length == output.receipt.frameCount && b.frameLength == file.length, "actual length")
            return (0..<2).map { Array(UnsafeBufferPointer(start: b.floatChannelData![$0], count: Int(b.frameLength))) }
        }
        func empty() throws { try check(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "partial output remains") }
        func rejects(_ body: () async throws -> Void) async throws { do { try await body() } catch is ProbeError { throw ProbeError.failed("probe itself failed") } catch { return }; throw ProbeError.failed("expected rejection") }
        let stereo = try fixture { (n: Int, c: Int) -> Float in
            let phase = Double(n) * (2.0 * Double.pi / 48000.0)
            if c == 0 { return Float(sin(phase * 480.0)) * 0.2 }
            return Float(cos(phase * 960.0)) * 0.3
        }
        let mono = try fixture(rate: 24000, channels: 1, format: "caf") { n,_ in Float(sin(Double(n)*2*Double.pi*240/24000))*0.25 }
        let originalHashes = [digest(stereo.audioData!), digest(mono.audioData!)]
        try await test("sample-exact stereo timing, volume once, real CAF decode and source snapshot receipt") {
            let doc = try document([clip(stereo, start: 0.05, volume: 0.5)])
            let out = try await StudioAudioMixService().mix(document: doc, retainedAudioTracks: [stereo], durationSeconds: 0.2, outputParent: scratch)
            let pcm = try read(out); try check(out.receipt.projectID == doc.id && out.receipt.revision == doc.revision && pcm[0].count == 9600, "receipt")
            for n in 0..<2400 { try near(pcm[0][n],0); try near(pcm[1][n],0) }
            for n in 0..<4800 { try near(pcm[0][2400+n], Float(sin(Double(n)*2*Double.pi*480/48000))*0.1); try near(pcm[1][2400+n],Float(cos(Double(n)*2*Double.pi*960/48000))*0.15) }
            for n in 7200..<9600 { try near(pcm[0][n],0); try near(pcm[1][n],0) }
            try out.cleanup(); try out.cleanup(); try empty()
        }
        try await test("overlapping lanes and repeated asset clips sum without per-track gain") {
            let out = try await StudioAudioMixService().mix(document: document([clip(stereo,volume:0.25,track:1),clip(stereo,volume:0.5,track:4)]), retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch)
            let pcm=try read(out);try near(pcm[1][0],0.225);try check(out.receipt.clipCount==2 && out.receipt.assetCount==1,"repeated asset");try out.cleanup()
        }
        try await test("mono conversion duplicates both channels and real Apple resampling retains tone timing") {
            let out=try await StudioAudioMixService().mix(document:document([clip(mono)]),retainedAudioTracks:[mono],durationSeconds:0.1,outputParent:scratch)
            let pcm=try read(out);for n in 200..<4600 {try near(pcm[0][n],pcm[1][n]);try near(pcm[0][n],Float(sin(Double(n)*2*Double.pi*240/48000))*0.25,0.001)};try out.cleanup()
        }
        try await test("empty canonical audio renders a real silent CAF across the requested duration") {
            let out=try await StudioAudioMixService().mix(document:document([]),retainedAudioTracks:[],durationSeconds:0.2,outputParent:scratch);let pcm=try read(out);try check(pcm.flatMap{$0}.allSatisfy{$0==0} && out.receipt.peakAbsoluteSample==0,"silence");try out.cleanup()
        }
        try await test("floating-point overlap preserves over-range samples and reports actual peak") {
            let loud=try fixture { _,_ in 0.8 };let out=try await StudioAudioMixService().mix(document:document([clip(loud),clip(loud)]),retainedAudioTracks:[loud],durationSeconds:0.1,outputParent:scratch);let pcm=try read(out);try near(pcm[0][0],1.6);try near(out.receipt.peakAbsoluteSample,1.6);try check(out.receipt.overRangeSampleCount==9600,"over-range count");try out.cleanup()
        }
        try await test("existing clip duration cuts only its explicit end and zero volume stays real silence") {
            let out=try await StudioAudioMixService().mix(document:document([clip(stereo,duration:0.05),clip(stereo,start:0.1,volume:0)]),retainedAudioTracks:[stereo],durationSeconds:0.2,outputParent:scratch);let pcm=try read(out);try check(pcm[1][0] > 0.29 && pcm[1][2400...].allSatisfy{$0==0},"explicit duration/volume");try out.cleanup()
        }
        try await test("nonfinite or unaligned output duration and clip end beyond range fail without truncation") {
            for duration in [Double.nan,Double.infinity,0,-1,0.00001,0.05] {try await rejects { _=try await StudioAudioMixService().mix(document:document([clip(stereo)]),retainedAudioTracks:[stereo],durationSeconds:duration,outputParent:scratch) }};try empty()
        }
        try await test("missing, duplicate, legacy and unreferenced retained audio fail rather than disappear") {
            try await rejects {_=try await StudioAudioMixService().mix(document:document([clip(stereo)]),retainedAudioTracks:[],durationSeconds:0.1,outputParent:scratch)}
            try await rejects {_=try await StudioAudioMixService().mix(document:document([clip(stereo)]),retainedAudioTracks:[stereo,stereo],durationSeconds:0.1,outputParent:scratch)}
            var legacy=stereo;legacy.legacySourceFilename="audio_1.wav"
            try await rejects {_=try await StudioAudioMixService().mix(document:document([clip(legacy)]),retainedAudioTracks:[legacy],durationSeconds:0.1,outputParent:scratch)}
            try await rejects {_=try await StudioAudioMixService().mix(document:document([]),retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch)}
            var unresolved=clip(stereo);unresolved.assetID=nil
            try await rejects {_=try await StudioAudioMixService().mix(document:document([unresolved]),retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch)};try empty()
        }
        try await test("duration metadata, malformed containers, truncation and source-channel bounds are strict") {
            var changed=stereo;changed.duration=0.11
            var corrupt=stereo;corrupt.audioData=Data("invalid audio".utf8)
            var truncated=stereo;truncated.audioData!.removeLast(16)
            let surround=try fixture(channels:4) {_,_ in 0.1}
            for asset in [changed,corrupt,truncated,surround] {try await rejects {_=try await StudioAudioMixService().mix(document:document([clip(asset)]),retainedAudioTracks:[asset],durationSeconds:0.2,outputParent:scratch)}};try empty()
        }
        try await test("input, normalized decode and repeated-clip cumulative work limits reject before output") {
            var limit=StudioAudioMixService.Limits();limit.maximumEncodedBytes=1
            try await rejects {_=try await StudioAudioMixService().mix(document:document([clip(stereo)]),retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch,limits:limit)}
            limit=StudioAudioMixService.Limits();limit.maximumDecodedSamples=9599
            try await rejects {_=try await StudioAudioMixService().mix(document:document([clip(stereo)]),retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch,limits:limit)}
            limit=StudioAudioMixService.Limits();limit.maximumMixedSamples=19199
            try await rejects {_=try await StudioAudioMixService().mix(document:document([clip(stereo),clip(stereo)]),retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch,limits:limit)};try empty()
        }
        try await test("cancellation while memory decoder is suspended closes callbacks and permits another real mix") {
            for _ in 0..<4 {try await rejects {_=try await StudioAudioMixService().mix(document:document([clip(stereo)]),retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch,progress:{p in if p.phase == .decoding {throw CancellationError()} })};try empty()}
            let out=try await StudioAudioMixService().mix(document:document([clip(stereo)]),retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch);_=try read(out);try out.cleanup()
        }
        try await test("real task cancellation during mixing cleans owned output and releases global lease") {
            let barrier=Barrier();let doc=try document([clip(stereo)]);let task=Task {try await StudioAudioMixService().mix(document:doc,retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch,progress:{p in if p.phase == .mixing {await barrier.wait()}})}
            while !(await barrier.entered) {await Task.yield()};task.cancel();await barrier.release();do {_=try await task.value;throw ProbeError.failed("cancel succeeded")}catch is CancellationError{};try empty()
        }
        try await test("process-wide lease prevents concurrent mixer instances without stealing output") {
            let barrier=Barrier();let doc=try document([clip(stereo)]);let task=Task {try await StudioAudioMixService().mix(document:doc,retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch,progress:{p in if p.phase == .mixing {await barrier.wait()}})}
            while !(await barrier.entered) {await Task.yield()};try await rejects {_=try await StudioAudioMixService().mix(document:doc,retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch)};await barrier.release();let out=try await task.value;try out.cleanup()
        }
        try await test("late callback failure preserves foreign entries and returns retryable captured recovery") {
            let box=Box(scratch)
            do {_=try await StudioAudioMixService().mix(document:document([clip(stereo)]),retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch,progress:{p in if p.phase == .validating {try Data("foreign".utf8).write(to:box.directory().appendingPathComponent("foreign.txt"));throw ProbeError.cancelledAtProgress}});throw ProbeError.failed("expected failure")}
            catch let failure as StudioAudioMixService.Failure {try check(failure.underlying is ProbeError,"original failure retained");let foreign=failure.recovery.directory.appendingPathComponent("foreign.txt");try check(try Data(contentsOf:foreign)==Data("foreign".utf8),"foreign deleted");try FileManager.default.removeItem(at:foreign);try failure.recovery.cleanup()};try empty()
        }
        try await test("replaced output file is preserved and restoration permits identity-bound cleanup") {
            let out=try await StudioAudioMixService().mix(document:document([clip(stereo)]),retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch);let url=try out.checkedURL();let moved=root.appendingPathComponent("owned.caf");try FileManager.default.moveItem(at:url,to:moved);try Data("foreign".utf8).write(to:url)
            do {try out.cleanup();throw ProbeError.failed("foreign removed")}catch StudioAudioMixService.MixError.ownershipConflict{}
            try check(try Data(contentsOf:url)==Data("foreign".utf8),"foreign bytes");try FileManager.default.removeItem(at:url);try FileManager.default.moveItem(at:moved,to:url);try out.cleanup();try empty()
        }
        try await test("checked handoff detects same-inode output mutation rather than reporting stale success") {
            let out=try await StudioAudioMixService().mix(document:document([clip(stereo)]),retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch);let url=try out.checkedURL();let handle=try FileHandle(forWritingTo:url);try handle.seek(toOffset:100);try handle.write(contentsOf:Data([99]));try handle.close()
            do {_=try out.checkedURL();throw ProbeError.failed("changed output accepted")}catch StudioAudioMixService.MixError.outputChanged{};try out.cleanup();try empty()
        }

        try await test("fractional clip boundaries round at most half a sample without shifting source origin") {
            let out=try await StudioAudioMixService().mix(document:document([clip(stereo,start:0.050004,duration:0.049996)]),retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch)
            let pcm=try read(out);try near(pcm[1][2399],0);try near(pcm[1][2400],0.3);try check(pcm[0].count==4800,"rounded extent");try out.cleanup()
        }
        try await test("complete expected PCM digest rejects finalization-time same-inode sample corruption") {
            let box=Box(scratch)
            do {_=try await StudioAudioMixService().mix(document:document([clip(stereo)]),retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch,progress:{p in
                if p.phase == .validating {
                    let url=try box.directory().appendingPathComponent("mix.caf");let data=try Data(contentsOf:url)
                    var offset=8
                    while offset+12 <= data.count {
                        let length=data[(offset+4)..<(offset+12)].reduce(UInt64(0)){($0<<8)|UInt64($1)}
                        if String(decoding:data[offset..<(offset+4)],as:UTF8.self)=="data" {
                            let h=try FileHandle(forWritingTo:url);try h.seek(toOffset:UInt64(offset+16));var sample:Float=0.123
                            try withUnsafeBytes(of:&sample){try h.write(contentsOf:Data($0))};try h.close();break
                        }
                        offset += 12+Int(length)
                    }
                }
            });throw ProbeError.failed("mutated samples accepted")}
            catch StudioAudioMixService.MixError.outputChanged {}
            try empty()
        }
        try await test("nonfinite decoded samples are rejected instead of contaminating the mix") {
            let bad=try fixture {n,_ in n==20 ? Float.nan : 0.1}
            try await rejects {_=try await StudioAudioMixService().mix(document:document([clip(bad)]),retainedAudioTracks:[bad],durationSeconds:0.1,outputParent:scratch)};try empty()
        }
        try await test("same-inode mutation during suspended full decode cannot return a stale ready receipt") {
            let box=Box(scratch)
            do {_=try await StudioAudioMixService().mix(document:document([clip(stereo)]),retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch,progress:{p in
                if p.phase == .validating && p.completed == 4096 {
                    let url=try box.directory().appendingPathComponent("mix.caf")
                    let h=try FileHandle(forUpdating:url);try h.seek(toOffset:100);let old=try h.read(upToCount:1)!
                    try h.seek(toOffset:100);try h.write(contentsOf:Data([old[0] ^ 1]));try h.close()
                }
            });throw ProbeError.failed("stale ready receipt")}
            catch StudioAudioMixService.MixError.outputChanged {}
            try empty()
        }
        try await test("task cancellation during output decoder suspension retains callback memory until disposal") {
            let barrier=Barrier();let doc=try document([clip(stereo)])
            let task=Task {try await StudioAudioMixService().mix(document:doc,retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch,progress:{p in
                if p.phase == .validating && p.completed == 4096 {await barrier.wait()}
            })}
            while !(await barrier.entered) {await Task.yield()};task.cancel();await barrier.release()
            do {_=try await task.value;throw ProbeError.failed("validation cancel succeeded")}catch is CancellationError{}
            try empty()
        }
        try await test("replaced staging directory survives cancellation and captured recovery is retryable") {
            let box=Box(scratch), moved=root.appendingPathComponent("original-mix-directory")
            do {_=try await StudioAudioMixService().mix(document:document([clip(stereo)]),retainedAudioTracks:[stereo],durationSeconds:0.1,outputParent:scratch,progress:{p in if p.phase == .mixing {
                let directory=try box.directory();try FileManager.default.moveItem(at:directory,to:moved);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false);try Data("foreign directory".utf8).write(to:directory.appendingPathComponent("keep.txt"));throw CancellationError()
            }});throw ProbeError.failed("replaced directory accepted")}
            catch let f as StudioAudioMixService.Failure {try check(f.underlying is CancellationError,"cancel cause");let foreign=f.recovery.directory.appendingPathComponent("keep.txt");try check(try Data(contentsOf:foreign)==Data("foreign directory".utf8),"foreign removed");try FileManager.default.removeItem(at:foreign);try FileManager.default.removeItem(at:f.recovery.directory);try FileManager.default.moveItem(at:moved,to:f.recovery.directory);try f.recovery.cleanup()};try empty()
        }
        try await test("symlink output and unsafe parent cannot redirect reads writes or cleanup") {
            let link=root.appendingPathComponent("parent-link");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:scratch)
            try await rejects {_=try await StudioAudioMixService().mix(document:document([]),retainedAudioTracks:[],durationSeconds:0.1,outputParent:link)};try empty()
            let out=try await StudioAudioMixService().mix(document:document([]),retainedAudioTracks:[],durationSeconds:0.1,outputParent:scratch);let original=try out.checkedURL(), moved=root.appendingPathComponent("moved-owned.caf"), foreign=root.appendingPathComponent("foreign.txt");try Data("keep".utf8).write(to:foreign);try FileManager.default.moveItem(at:original,to:moved);try FileManager.default.createSymbolicLink(at:original,withDestinationURL:foreign)
            do {_=try out.checkedURL();throw ProbeError.failed("symlink accepted")}catch StudioAudioMixService.MixError.ownershipConflict{}
            do {try out.cleanup();throw ProbeError.failed("symlink deleted")}catch StudioAudioMixService.MixError.ownershipConflict{}
            try check(try Data(contentsOf:foreign)==Data("keep".utf8),"foreign changed");try FileManager.default.removeItem(at:original);try FileManager.default.moveItem(at:moved,to:original);try out.cleanup();try empty()
        }
        try await test("malformed declared chunks and unfinalized CAF lengths fail before mixing") {
            var wav=stereo;var data=stereo.audioData!;data.removeLast(16);let count=UInt32(data.count-8);for k in 0..<4 {data[4+k]=UInt8((count >> (k*8)) & 255)};wav.audioData=data
            var caf=mono;var cd=mono.audioData!;for k in 12..<20 {cd[k]=255};caf.audioData=cd
            for asset in [wav,caf] {try await rejects {_=try await StudioAudioMixService().mix(document:document([clip(asset)]),retainedAudioTracks:[asset],durationSeconds:0.1,outputParent:scratch)}};try empty()
        }


        try await test("actual Apple Lossless CAF decoding and 44.1kHz resampling preserve asymmetric channels") {
            let compressed=try fixture(rate:44100,format:"caf",compressed:true) {_,channel in channel==0 ? 0.125 : -0.25}
            let out=try await StudioAudioMixService().mix(document:document([clip(compressed,volume:0.5)]),retainedAudioTracks:[compressed],durationSeconds:0.1,outputParent:scratch)
            let pcm=try read(out);for n in 200..<4600 {try near(pcm[0][n],0.0625);try near(pcm[1][n],-0.125)};try out.cleanup();try empty()
        }
        try await test("real 120-second mix stays bounded and repeat boundaries contain the original samples") {
            let asset=try fixture(seconds:20,format:"caf") {n,channel in channel==0 ? (n%480==0 ? 0.2 : 0) : -0.1}
            let repeated=(0..<6).map {clip(asset,start:Double($0)*20,volume:0.5,track:($0%4)+1)}
            let start=Date();let out=try await StudioAudioMixService().mix(document:document(repeated),retainedAudioTracks:[asset],durationSeconds:120,outputParent:scratch)
            try check(out.receipt.frameCount==5_760_000 && out.receipt.bytes<48*1024*1024,"120-second bounds")
            let pcm=try read(out);for n in stride(from:0,to:5_760_000,by:960_000) {try near(pcm[0][n],0.1);try near(pcm[1][n],-0.05)}
            print("BOUND120_SECONDS=\(Date().timeIntervalSince(start)) OUTPUT_BYTES=\(out.receipt.bytes)")
            try out.cleanup();try empty()
        }

        try check(originalHashes==[digest(stereo.audioData!),digest(mono.audioData!)],"source originals changed")
        print("STUDIO_AUDIO_MIX_TESTS=PASS \(count)/\(count)")
    }
}
