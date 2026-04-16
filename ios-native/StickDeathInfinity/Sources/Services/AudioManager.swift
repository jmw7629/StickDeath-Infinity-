// AudioManager.swift
// Audio playback engine for the Studio timeline
// Plays sound clips synced to animation frames using AVAudioPlayer

import Foundation
import AVFoundation

@MainActor
class AudioManager: ObservableObject {
    static let shared = AudioManager()

    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var volume: Float = 1.0

    private var players: [UUID: AVAudioPlayer] = [:]
    private var audioSession: AVAudioSession { AVAudioSession.sharedInstance() }

    private init() {
        configureSession()
    }

    // MARK: - Audio Session
    private func configureSession() {
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            print("⚠️ Audio session setup failed: \(error)")
        }
    }

    // MARK: - Load Sound from URL (Supabase storage)
    func loadSound(id: UUID, url: URL) async -> Bool {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let player = try AVAudioPlayer(data: data)
            player.prepareToPlay()
            player.volume = volume
            players[id] = player
            return true
        } catch {
            print("⚠️ Failed to load sound \(id): \(error)")
            return false
        }
    }

    // MARK: - Load Sound from Bundle
    func loadBundledSound(id: UUID, name: String, ext: String = "mp3") -> Bool {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            print("⚠️ Bundled sound not found: \(name).\(ext)")
            return false
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.volume = volume
            players[id] = player
            return true
        } catch {
            print("⚠️ Failed to load bundled sound: \(error)")
            return false
        }
    }

    // MARK: - Load Sound from Data
    func loadSound(id: UUID, data: Data) -> Bool {
        do {
            let player = try AVAudioPlayer(data: data)
            player.prepareToPlay()
            player.volume = volume
            players[id] = player
            return true
        } catch {
            print("⚠️ Failed to load sound data: \(error)")
            return false
        }
    }

    // MARK: - Playback Control
    func play(id: UUID, at time: TimeInterval = 0) {
        guard let player = players[id] else { return }
        player.currentTime = time
        player.volume = volume
        player.play()
        isPlaying = true
    }

    func pause(id: UUID) {
        players[id]?.pause()
    }

    func stop(id: UUID) {
        players[id]?.stop()
        players[id]?.currentTime = 0
    }

    func stopAll() {
        for player in players.values {
            player.stop()
            player.currentTime = 0
        }
        isPlaying = false
    }

    func setVolume(_ v: Float, for id: UUID) {
        players[id]?.volume = v
    }

    func setGlobalVolume(_ v: Float) {
        volume = v
        for player in players.values {
            player.volume = v
        }
    }

    // MARK: - Timeline Sync
    /// Play clips that should be active at the given frame
    func syncToFrame(
        frame: Int,
        fps: Int,
        clips: [SoundClip],
        assetURLs: [String: URL]  // assetId -> URL
    ) {
        let frameTime = Double(frame) / Double(fps)

        for clip in clips {
            let clipStart = Double(clip.startFrame) / Double(fps)
            if frame >= clip.startFrame && frame < clip.startFrame + clip.durationFrames {
                // Should be playing
                if let player = players[clip.id] {
                    if !player.isPlaying {
                        let offset = frameTime - clipStart
                        player.currentTime = offset
                        player.volume = clip.volume * volume
                        player.play()
                    }
                } else if let url = assetURLs[clip.assetId] {
                    // Lazy load
                    Task {
                        if await loadSound(id: clip.id, url: url) {
                            play(id: clip.id, at: frameTime - clipStart)
                            setVolume(clip.volume * volume, for: clip.id)
                        }
                    }
                }
            } else {
                // Should not be playing
                if let player = players[clip.id], player.isPlaying {
                    player.stop()
                }
            }
        }
    }

    // MARK: - Duration
    func duration(id: UUID) -> TimeInterval {
        players[id]?.duration ?? 0
    }

    func isLoaded(id: UUID) -> Bool {
        players[id] != nil
    }

    // MARK: - Cleanup
    func unload(id: UUID) {
        players[id]?.stop()
        players.removeValue(forKey: id)
    }

    func unloadAll() {
        stopAll()
        players.removeAll()
    }
}
