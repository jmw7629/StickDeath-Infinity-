import SwiftUI

// ═══════════════════════════════════════════════════════════════════════
// Sound Library Panel — Browse categories & sounds, add to timeline
// ═══════════════════════════════════════════════════════════════════════

struct SoundLibraryPanel: View {
    @ObservedObject var vm: StudioViewModel
    @State private var selectedCategoryIndex: Int? = nil
    @State private var search: String = ""

    var categories: [SoundCategory] { SoundLibrary.categories }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            if let catIdx = selectedCategoryIndex, categories.indices.contains(catIdx) {
                let cat = categories[catIdx]

                HStack {
                    Button(action: { selectedCategoryIndex = nil }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .bold))
                            Text(cat.name)
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(.white)
                    }

                    Text("\(cat.sounds.count) sounds")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.06)))

                    Spacer()

                    Button(action: { vm.activePanel = .none }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.25))
                    TextField("Search sounds...", text: $search)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: "12121a"))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06)))
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

                ScrollView {
                    LazyVStack(spacing: 6) {
                        let sounds = search.isEmpty ? cat.sounds : cat.sounds.filter { $0.name.lowercased().contains(search.lowercased()) }
                        ForEach(sounds) { sound in
                            SoundRow(sound: sound, tagColor: cat.color) {
                                vm.addAudioClip(sound: sound, track: nextAvailableTrack())
                                vm.activePanel = .audioTimeline
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(maxHeight: 220)

            } else {
                PanelHeader(title: "Sound Library", icon: "🎵", onClose: { vm.activePanel = .none })

                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(categories.enumerated()), id: \.element.id) { index, cat in
                            Button(action: { selectedCategoryIndex = index }) {
                                HStack(spacing: 10) {
                                    Text(cat.icon)
                                        .font(.system(size: 20))

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(cat.name)
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                            .foregroundColor(.white)
                                        Text("\(cat.sounds.count) sounds")
                                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.35))
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.2))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(hex: "12121a"))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.05)))
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(maxHeight: 300)
            }

            Button(action: { vm.activePanel = .audioTimeline }) {
                HStack {
                    Text("🎵")
                    Text("Open Audio Timeline")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .foregroundColor(Color(hex: "DC2626"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: "DC2626").opacity(0.1))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "DC2626").opacity(0.3)))
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color(hex: "1a1a24"))
        .cornerRadius(16, corners: [.topLeft, .topRight])
    }

    func nextAvailableTrack() -> Int {
        let usedTracks = Set(vm.audioClips.map { $0.track })
        for t in 1...4 {
            if !usedTracks.contains(t) { return t }
        }
        return 1
    }
}

// MARK: - Sound Row
struct SoundRow: View {
    let sound: SoundEffect
    let tagColor: Color
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: {}) {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(sound.name)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        Text("⏱")
                            .font(.system(size: 8))
                        Text(sound.duration)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(.white.opacity(0.4))

                    HStack(spacing: 1) {
                        ForEach(0..<sound.waveform.count, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.white.opacity(0.3))
                                .frame(width: 2, height: sound.waveform[i] * 12)
                        }
                    }

                    Text(sound.tag)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(tagColor)
                }
            }

            Spacer()

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color(hex: "DC2626"))
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: "DC2626").opacity(0.4), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: "12121a"))
        )
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Audio Timeline Panel — Multi-track timeline with transport controls
// ═══════════════════════════════════════════════════════════════════════

struct AudioTimelinePanel: View {
    @ObservedObject var vm: StudioViewModel

    private let trackColors: [Color] = [
        Color(hex: "DC2626"), Color(hex: "3B82F6"),
        Color(hex: "22C55E"), Color(hex: "A855F7")
    ]

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            // Header
            HStack {
                Text("🎵")
                    .font(.system(size: 16))
                Text("Audio Timeline")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                Text("\(vm.audioClips.count) clips")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.06)))

                Button(action: { vm.snapEnabled.toggle() }) {
                    Text("Snap: \(vm.snapEnabled ? "ON" : "OFF")")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(vm.snapEnabled ? Color(hex: "DC2626") : .white.opacity(0.4))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(vm.snapEnabled ? Color(hex: "DC2626").opacity(0.15) : Color.white.opacity(0.04)))
                }

                Spacer()

                Button(action: { vm.activePanel = .soundLibrary }) {
                    Text("+ Add")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(hex: "DC2626")))
                }

                Button(action: { vm.activePanel = .none }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            // Transport controls
            HStack(spacing: 8) {
                Button(action: { vm.audioPlayheadTime = 0 }) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }

                Button(action: { vm.isPlaying.toggle() }) {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color(hex: "DC2626")))
                }

                Button(action: { vm.audioPlayheadTime = vm.audioDuration }) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }

                Text(formatTime(vm.audioPlayheadTime))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "DC2626"))

                Text("/")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))

                Text(formatTime(vm.audioDuration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            // Timeline tracks
            GeometryReader { geo in
                let trackHeight: CGFloat = 40
                let rulerHeight: CGFloat = 16
                let labelWidth: CGFloat = 40
                let totalWidth = geo.size.width - labelWidth

                ZStack(alignment: .topLeading) {
                    Color(hex: "0d0d14")

                    // Ruler
                    HStack(spacing: 0) {
                        Color.clear.frame(width: labelWidth)
                        let tickCount = max(1, Int(vm.audioDuration) + 1)
                        ForEach(0..<tickCount, id: \.self) { sec in
                            Text(formatTime(Double(sec)))
                                .font(.system(size: 7, weight: .medium, design: .monospaced))
                                .foregroundColor(Color(hex: "DC2626").opacity(0.6))
                                .frame(width: totalWidth / CGFloat(tickCount), alignment: .leading)
                        }
                    }
                    .frame(height: rulerHeight)

                    // Tracks
                    VStack(spacing: 0) {
                        Color.clear.frame(height: rulerHeight)

                        ForEach(1...4, id: \.self) { trackNum in
                            ZStack(alignment: .leading) {
                                HStack(spacing: 0) {
                                    VStack(spacing: 2) {
                                        Text("\(trackNum)")
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.4))
                                        Image(systemName: "speaker.wave.2.fill")
                                            .font(.system(size: 8))
                                            .foregroundColor(.white.opacity(0.2))
                                    }
                                    .frame(width: labelWidth, height: trackHeight)
                                    .background(Color.white.opacity(0.02))

                                    Rectangle()
                                        .fill(Color.white.opacity(trackNum % 2 == 0 ? 0.02 : 0.01))
                                        .frame(height: trackHeight)
                                        .overlay(
                                            Rectangle().fill(Color.white.opacity(0.04)).frame(height: 0.5),
                                            alignment: .bottom
                                        )
                                }

                                // Audio clips on this track
                                ForEach(vm.audioClips.filter { $0.track == trackNum }) { clip in
                                    let duration = vm.audioDuration > 0 ? vm.audioDuration : 5.0
                                    let clipX = labelWidth + (clip.startTime / duration) * totalWidth
                                    let clipW = (clip.duration / duration) * totalWidth
                                    let trackColor = trackColors[safe: (trackNum - 1)] ?? .red

                                    Button(action: { vm.selectedAudioClip = clip }) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(trackColor.opacity(0.5))
                                            Text(String(format: "%.1fs", clip.duration))
                                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                                .foregroundColor(.white.opacity(0.7))
                                        }
                                        .frame(width: max(clipW, 20), height: trackHeight - 8)
                                    }
                                    .offset(x: clipX, y: 4)
                                }
                            }
                        }
                    }

                    // Playhead
                    let duration = vm.audioDuration > 0 ? vm.audioDuration : 5.0
                    let playheadX = labelWidth + (vm.audioPlayheadTime / duration) * totalWidth
                    Rectangle()
                        .fill(Color(hex: "DC2626"))
                        .frame(width: 2)
                        .offset(x: playheadX)
                        .gesture(
                            DragGesture()
                                .onChanged { val in
                                    let t = max(0, min(duration, (val.location.x - labelWidth) / totalWidth * duration))
                                    vm.audioPlayheadTime = t
                                }
                        )
                }
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 14)

            // Selected clip info bar
            if let clip = vm.selectedAudioClip {
                let trackColor = trackColors[safe: (clip.track - 1)] ?? .red
                HStack(spacing: 8) {
                    Circle()
                        .fill(trackColor)
                        .frame(width: 10, height: 10)

                    Text(clip.soundName)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.4))

                    Slider(value: Binding(
                        get: { clip.volume },
                        set: { newVal in
                            if let idx = vm.audioClips.firstIndex(where: { $0.id == clip.id }) {
                                vm.audioClips[idx].volume = newVal
                                vm.selectedAudioClip = vm.audioClips[idx]
                            }
                        }
                    ), in: 0...1)
                    .accentColor(Color(hex: "DC2626"))
                    .frame(width: 60)

                    Text("\(Int(clip.volume * 100))%")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))

                    Spacer()

                    Button(action: {
                        vm.deleteAudioClip(clip.id)
                    }) {
                        Text("Delete")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(hex: "DC2626"))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }

            Spacer().frame(height: 10)
        }
        .background(Color(hex: "1a1a24"))
        .cornerRadius(16, corners: [.topLeft, .topRight])
    }

    func formatTime(_ t: Double) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        let frac = Int((t - Double(Int(t))) * 100)
        return String(format: "%02d:%02d.%02d", mins, secs, frac)
    }
}

// Safe subscript for Color array
extension Array where Element == Color {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
