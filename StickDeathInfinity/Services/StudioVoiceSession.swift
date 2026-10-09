import Foundation
import AVFoundation
import Combine

/// Creates real, device-local speech files. No microphone or provider connection.
@MainActor
final class StudioVoiceSession: NSObject, ObservableObject, AVAudioPlayerDelegate {
    struct Voice: Identifiable {
        let id: String
        let name: String
        let language: String
    }
    @Published private(set) var voices: [Voice] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isPlaying = false
    @Published private(set) var prepared: StudioAudioImportService.ImportedAudio?
    @Published private(set) var notice: String?
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var writer: StudioSpeechFileWriter?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()

    override init() {
        super.init()
        voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            if #available(iOS 17, macOS 14, *) {
                return !voice.voiceTraits.contains(.isPersonalVoice)
            }
            return true
        }.sorted { ($0.language, $0.name, $0.identifier) < ($1.language, $1.name, $1.identifier) }
            .map { Voice(id: $0.identifier, name: $0.name, language: $0.language) }
    }

    func cancel() {
        generation = UUID()
        deadline?.cancel(); deadline = nil
        work?.cancel(); work = nil
        synthesizer.stopSpeaking(at: .immediate)
        writer?.discard(); writer = nil
        stopPreview()
        prepared = nil; isBusy = false; notice = nil
    }

    func generate(text: String, voiceID: String, speed: Double, pitch: Double) {
        cancel()
        let script = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty, script.count <= 1_500, script.utf8.count <= 12_000,
              speed.isFinite, (0.5...2).contains(speed), pitch.isFinite, (0.5...2).contains(pitch),
              voices.contains(where: { $0.id == voiceID }),
              let voice = AVSpeechSynthesisVoice(identifier: voiceID) else {
            notice = "Choose an installed system voice and enter 1–1,500 characters."
            return
        }
        let token = generation
        do {
            let output = try StudioSpeechFileWriter()
            writer = output; isBusy = true
            let utterance = AVSpeechUtterance(string: script)
            utterance.voice = voice
            utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                                 max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(speed)))
            utterance.pitchMultiplier = Float(pitch)
            synthesizer.write(utterance) { [weak self] buffer in
                // Write while the framework owns the buffer; only send a URL/error across actors.
                guard let result = output.consume(buffer) else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { output.discard(); return }
                    self.finish(result, output: output, token: token, name: "Voice · \(voice.name)")
                }
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
                guard let self, self.generation == token, self.isBusy else { return }
                self.cancel()
                self.notice = "The system voice did not finish within 90 seconds. Try a shorter script or another installed voice."
            }
        } catch { notice = error.localizedDescription }
    }

    private func finish(_ result: Result<URL, Error>, output: StudioSpeechFileWriter, token: UUID, name: String) {
        work = Task { [weak self] in
            defer { output.discard() }
            do {
                let url = try result.get()
                let imported = try await StudioAudioImportService.shared.importAudio(from: url, name: String(name.prefix(120)))
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.prepared = imported
                self.isBusy = false
                self.deadline?.cancel(); self.deadline = nil
                self.writer = nil; self.work = nil
                self.notice = String(format: "Ready · %.1f seconds. Preview before adding to the timeline.", imported.duration)
            } catch {
                guard let self, self.generation == token else { return }
                self.synthesizer.stopSpeaking(at: .immediate)
                self.isBusy = false; self.prepared = nil
                self.deadline?.cancel(); self.deadline = nil
                self.writer = nil; self.work = nil
                self.notice = error.localizedDescription
            }
        }
    }

    func preview() {
        if isPlaying { stopPreview(); return }
        guard let prepared else { return }
        do {
            let audition = try AVAudioPlayer(data: prepared.originalData)
            audition.delegate = self
            guard audition.prepareToPlay(), audition.play() else {
                throw StudioDocumentError.unavailable("The system could not start audio playback.")
            }
            player = audition; isPlaying = true
        } catch { notice = error.localizedDescription; stopPreview() }
    }
    func stopPreview() { player?.stop(); player = nil; isPlaying = false }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.stopPreview()
            if !flag { self.notice = "Voice playback could not finish." }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.stopPreview(); self.notice = "Voice playback could not decode the audio."
        }
    }
}

/// Serializes framework callbacks, closes output before decode, and rejects late
/// callbacks after cancellation. Owns only its unique private scratch directory.
final class StudioSpeechFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let url: URL
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var frames: Int64 = 0
    private var bytes: Int64 = 0
    private var terminal = false

    init(parent: URL = FileManager.default.temporaryDirectory) throws {
        directory = parent.appendingPathComponent("sdi-voice-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("voice.caf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    deinit { discard() }

    func consume(_ buffer: AVAudioBuffer) -> Result<URL, Error>? {
        lock.lock(); defer { lock.unlock() }
        guard !terminal else { return nil }
        do {
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                throw StudioDocumentError.invalid("The system voice returned unsupported audio.")
            }
            if pcm.frameLength == 0 {
                terminal = true; file = nil
                guard frames > 0 else {
                    throw StudioDocumentError.unavailable("This voice produced no audio. Choose another installed voice.")
                }
                return .success(url)
            }
            let incoming = pcm.format
            guard incoming.sampleRate.isFinite, (8_000...96_000).contains(incoming.sampleRate),
                  (1...2).contains(incoming.channelCount) else {
                throw StudioDocumentError.invalid("The system voice returned an unsupported audio format.")
            }
            let nextFrames = frames + Int64(pcm.frameLength)
            let nextBytes = bytes + Int64(pcm.frameLength) * Int64(incoming.channelCount) * 4
            guard Double(nextFrames) / incoming.sampleRate <= 120, nextBytes <= 15 * 1024 * 1024 else {
                throw StudioDocumentError.invalid("Voice audio exceeds the 2 minute / 15 MB limit. Shorten the script.")
            }
            if let format {
                guard format == incoming else { throw StudioDocumentError.invalid("The system voice changed audio format.") }
            } else {
                format = incoming
                file = try AVAudioFile(forWriting: url, settings: incoming.settings,
                                       commonFormat: incoming.commonFormat, interleaved: incoming.isInterleaved)
            }
            try file!.write(from: pcm)
            frames = nextFrames; bytes = nextBytes
            return nil
        } catch {
            terminal = true; file = nil
            return .failure(error)
        }
    }
    func discard() {
        lock.lock(); defer { lock.unlock() }
        terminal = true; file = nil
        try? FileManager.default.removeItem(at: directory)
    }
}
