import Foundation
import AVFoundation
import Darwin

private struct Failure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message: message) }
}
@main @MainActor struct StudioVoiceTests {
    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-voice-check-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            pcm.frameLength = 1600
            for index in 0..<1600 { pcm.floatChannelData![0][index] = sin(Float(index) * 0.1) * 0.25 }
            let end = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
            let output = try StudioSpeechFileWriter(parent: root)
            try require(output.consume(pcm) == nil, "Writer ended before terminal buffer")
            let url = try output.consume(end)!.get()
            let decoded = try await StudioAudioImportService.shared.importAudio(from: url, name: "Measured voice fixture")
            try require(abs(decoded.duration - 0.1) < 0.001 && decoded.waveformPeaks.contains(where: { $0 > 0.2 }), "Written PCM did not decode faithfully")
            try require(output.consume(pcm) == nil, "Terminal writer accepted late audio")
            output.discard()
            try require(!FileManager.default.fileExists(atPath: url.path), "Owned file survived discard")
            let empty = try StudioSpeechFileWriter(parent: root)
            if case .failure = empty.consume(end) { } else { throw Failure(message: "Empty synthesis was accepted") }
            empty.discard()
            let cancelled = try StudioSpeechFileWriter(parent: root)
            _ = cancelled.consume(pcm); cancelled.discard()
            try require(cancelled.consume(end) == nil, "Cancelled writer completed")
            let oversized = try StudioSpeechFileWriter(parent: root)
            let long = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_936_000)!
            long.frameLength = 1_936_000
            if case .failure = oversized.consume(long) { } else { throw Failure(message: "Overlong audio accepted") }
            oversized.discard()
            try require(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "Scratch leaked")
            print("PASS bounded speech file writer: real CAF decode, measured PCM, empty/cancel/late-buffer/limit cleanup")

            let session = StudioVoiceSession()
            session.generate(text: "", voiceID: "missing", speed: 1, pitch: 1)
            try require(!session.isBusy && session.prepared == nil && session.notice != nil, "Invalid voice input accepted")
            session.cancel()
            try require(session.prepared == nil && session.notice == nil && !session.isBusy, "Cancel retained output")
            print("PASS voice session rejects invalid input and clears uncommitted results")
            if ProcessInfo.processInfo.environment["SDI_VERIFY_SYSTEM_SPEECH"] == "1" {
                guard let installed = session.voices.first(where: { $0.language == "en-US" }) ?? session.voices.first else {
                    throw Failure(message: "System speech unavailable: no installed voices")
                }
                session.generate(text: "StickDeath Infinity. A real voice for this animation.", voiceID: installed.id, speed: 1, pitch: 1)
                let until = Date().addingTimeInterval(95)
                while session.isBusy && Date() < until { try await Task.sleep(nanoseconds: 100_000_000) }
                guard let generated = session.prepared else { throw Failure(message: session.notice ?? "Speech did not finish") }
                try require(generated.duration > 0 && generated.waveformPeaks.contains(where: { $0 > 0 }), "System speech has no measured signal")
                let docs = root.appendingPathComponent("documents")
                let storage = DeviceStorageManager(documentsDirectory: docs, cachesDirectory: docs)
                let vm = StudioViewModel(storage: storage)
                let created = await vm.createProject(name: "Voice integration", width: 64, height: 64, fps: 12)
                try require(created, "Project creation failed")
                let before = vm.document
                let clip = try vm.attachImportedAudio(generated.track, expectedProjectID: before.id, expectedRevision: before.revision, frameID: before.activeFrameID, trackNumber: 2)
                try require(vm.audioClips.contains { $0.id == clip && $0.track == 2 }, "Real generated audio was not attached")
                vm.undo(); try require(vm.audioClips.isEmpty, "Voice insertion was not undoable")
                vm.redo(); try require(vm.audioClips.count == 1, "Voice redo failed")
                await vm.backToProjects()
                let saved = try storage.loadAnimation(id: before.id)
                try require(saved?.audioTracks.first?.audioData == generated.originalData, "Generated audio bytes were not persisted")
                session.cancel()
                print("PASS installed system speech generated nonzero audio; actual Studio attach/Undo/Redo and saved bytes verified")
            } else {
                print("NOT RUN installed-voice synthesis and native UI; enable SDI_VERIFY_SYSTEM_SPEECH on an authorized Mac")
            }
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
