import SwiftUI

// ═══════════════════════════════════════════════════════════════════
// Frame Timeline — < ▶ > | frame thumbnails (red border=selected) | +
//   onion skin icon | frame counter
// ═══════════════════════════════════════════════════════════════════

struct StudioTimeline: View {
    @ObservedObject var vm: StudioViewModel
    @StateObject private var audioPlayback = StudioAudioTimelineSession()
    @Environment(\.scenePhase) private var scenePhase
    @State private var timingCapture: StudioFrameTimingCapture?
    @State private var tweenCapture: StudioViewModel.TweenCapture?

    var body: some View {
        HStack(spacing: 6) {
            // Prev
            Button(action: { vm.prevFrame() }) {
                Text("‹")
                    .font(.specialElite(16)).fontWeight(.bold)
                    .foregroundColor(vm.currentFrameIndex > 0 ? .white.opacity(0.6) : .white.opacity(0.2))
            }
            .disabled(vm.currentFrameIndex == 0)

            // Play/Pause
            Button(action: toggleTimelinePlayback) {
                Image(systemName: audioPlayback.isPreparing ? "stop.fill" : vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Color(hex: "1E1E2A"))
                    .clipShape(Circle())
            }

            .accessibilityLabel(audioPlayback.isPreparing ? "Cancel audio preparation" : vm.isPlaying ? "Pause timeline" : "Play timeline")
            .accessibilityValue(audioPlayback.isPreparing ? "Preparing audio \(Int(audioPlayback.progress * 100)) percent" : "")
            .accessibilityIdentifier("studio.timeline.play")
            .accessibilityHint("Touch and hold for Loop playback options.")
            .contextMenu {
                Toggle("Loop playback", isOn: $vm.playbackLoops)
            }

            // Next
            Button(action: { vm.nextFrame() }) {
                Text("›")
                    .font(.specialElite(16)).fontWeight(.bold)
                    .foregroundColor(vm.currentFrameIndex < vm.frames.count - 1 ? .white.opacity(0.6) : .white.opacity(0.2))
            }
            .disabled(vm.currentFrameIndex >= vm.frames.count - 1)

            // Frame thumbnails
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 4) {
                        ForEach(Array(vm.frames.enumerated()), id: \.element.id) { i, frame in
                            Button(action: { vm.selectFrame(frame.id) }) {
                                ZStack(alignment: .bottomTrailing) {
                                    // Mini canvas render
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white)
                                        .frame(width: 36, height: 36)

                                    StudioFrameThumbnail(vm: vm, frame: frame)
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))

                                    // Exposure hold badge (frames held longer than one tick)
                                    if frame.durationTicks > 1 {
                                        Text("×\(frame.durationTicks)")
                                            .font(.specialElite(7))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 3).padding(.vertical, 1)
                                            .background(Color.black.opacity(0.65), in: Capsule())
                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                            .padding(2)
                                            .accessibilityHidden(true)
                                    }
                                    // Frame number
                                    Text("\(i + 1)")
                                        .font(.specialElite(7))
                                        .foregroundColor(vm.currentFrameIndex == i ? .red : .white.opacity(0.4))
                                        .padding(2)
                                }
                                .frame(width: 36, height: 36)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(vm.currentFrameIndex == i ? Color.red : Color.white.opacity(0.1),
                                                lineWidth: vm.currentFrameIndex == i ? 2 : 1)
                                )
                            }
                            .id(frame.id)
                            .accessibilityLabel("Frame \(i + 1)")
                            .accessibilityValue(vm.currentFrame.id == frame.id ? "Selected" : "Not selected")
                            .accessibilityHint("Exposure: \(frame.durationTicks) ticks at \(vm.fps) FPS")
                            .accessibilityIdentifier("studio.frame." + frame.id)
                            .contextMenu {
                                Button("Copy frame") { vm.copyFrame(frame.id) }
                                    .accessibilityIdentifier("studio.frame-menu.copy")
                                Button("Cut frame") { vm.cutFrame(frame.id) }
                                    .disabled(!vm.canCutTimelineFrame)
                                    .accessibilityIdentifier("studio.frame-menu.cut")
                                Button("Paste frame after this") { vm.pasteFrame(after: frame.id) }
                                    .disabled(!vm.canPasteTimelineFrame)
                                    .accessibilityIdentifier("studio.frame-menu.paste-after")
                                Button("Duplicate frame") { vm.duplicateFrame(frame.id) }
                                    .accessibilityIdentifier("studio.frame-menu.duplicate")
                                Button("Tween to next frame…") {
                                    tweenCapture = vm.prepareTween(frame.id)
                                    if tweenCapture == nil { vm.message = "Select a frame with a following endpoint, stop playback and finish any draft before tweening." }
                                }
                                .disabled(i + 1 >= vm.frames.count)
                                .accessibilityIdentifier("studio.frame-menu.tween")
                                Menu("Frame exposure") {
                                    ForEach([1, 2, 3, 6, 12, 24, 60], id: \.self) { ticks in
                                        Button("\(ticks) ticks (\(String(format: "%.2f", Double(ticks) / Double(vm.fps)))s)") {
                                            vm.setFrameHold(frame.id, ticks: ticks)
                                        }.accessibilityIdentifier("studio.frame-menu.hold.\(ticks)")
                                    }
                                }
                                Button("Frame range / timing…") {
                                    guard !vm.isPlaying else { vm.message = "Stop playback before editing frame timing."; return }
                                    guard let index = vm.frames.firstIndex(where: { $0.id == frame.id }) else { vm.message = "This frame is no longer available."; return }
                                    timingCapture = StudioFrameTimingCapture(document: vm.document, index: index)
                                }
                                .accessibilityIdentifier("studio.frame-menu.range-exposure")
                                Menu("Repeat frame") {
                                    ForEach([2, 4, 8, 12, 24], id: \.self) { copies in
                                        Button("Add \(copies) copies (\(String(format: "%.2f", Double(copies * frame.durationTicks) / Double(vm.fps)))s)") {
                                            _ = vm.repeatFrame(frame.id, additionalCopies: copies)
                                        }
                                        .disabled(vm.frames.count + copies > 1000)
                                        .accessibilityIdentifier("studio.frame-menu.repeat.\(copies)")
                                    }
                                }
                                .accessibilityIdentifier("studio.frame-menu.repeat")
                                Button("Move earlier") { vm.moveFrame(frame.id, offset: -1) }
                                    .disabled(i == 0)
                                    .accessibilityIdentifier("studio.frame-menu.earlier")
                                Button("Move later") { vm.moveFrame(frame.id, offset: 1) }
                                    .disabled(i == vm.frames.count - 1)
                                    .accessibilityIdentifier("studio.frame-menu.later")
                                Button("Delete this frame", role: .destructive) { vm.deleteFrame(frame.id) }
                                    .disabled(vm.frames.count <= 1)
                                    .accessibilityIdentifier("studio.frame-menu.delete")
                            }
                        }
                    }
                }
                .accessibilityIdentifier("studio.frame-timeline")
                .onChange(of: [vm.currentFrame.id, String(vm.currentFrameIndex)], initial: true) { _, _ in
                    // Reopened projects already have their selected frame. Scroll on
                    // initial presentation too, so that frame is visible immediately.
                    withAnimation { proxy.scrollTo(vm.currentFrame.id, anchor: .center) }
                }
            }

            // Add frame
            Button(action: { vm.addFrame() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 32, height: 32)
                    .background(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                    // The drawn circle stays 32 pt; the touch target is 44 pt.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Add frame")
            .accessibilityIdentifier("studio.add-frame")

            // Onion skin toggle
            Button(action: { vm.showOnionSkin.toggle() }) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 14))
                    .foregroundColor(vm.showOnionSkin ? .red : .white.opacity(0.3))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Onion skin")
            .accessibilityValue(vm.showOnionSkin ? "On" : "Off")
            .accessibilityIdentifier("studio.onion.toggle")

            Spacer()

            // Frame counter
            Text("\(vm.currentFrameIndex + 1)/\(vm.frames.count)")
                .font(.specialElite(10, relativeTo: .caption2)).monospacedDigit()
                .foregroundColor(.white.opacity(0.4))
        }
        // A timeline is a bounded control row, not a second flexible canvas.
        // The thumbnail label must never expand the horizontal scroll view
        // vertically when the editor receives a portrait or landscape proposal.
        .frame(height: 36)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(hex: "0A0A10"))
        .onDisappear { audioPlayback.close() }
        .onChange(of: vm.document.id) { _, _ in audioPlayback.close() }
        .onChange(of: vm.document.revision) { _, _ in audioPlayback.stop() }
        .onChange(of: vm.playbackLoops) { _, _ in audioPlayback.stop() }
        .onChange(of: vm.activePanel) { _, panel in
            if panel != .none { audioPlayback.stop() }
        }
        .onChange(of: vm.isPlaying) { _, playing in
            if !playing && audioPlayback.isPlaying { audioPlayback.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { audioPlayback.close() }
        }
        .onChange(of: audioPlayback.notice) { _, notice in
            if let notice { vm.message = notice }
        }
        .sheet(item: $timingCapture) { capture in
            StudioFrameTimingOptions(vm: vm, capture: capture)
        }
        .sheet(item: $tweenCapture) { capture in
            StudioTweenOptions(vm: vm, capture: capture)
        }
    }
    private func toggleTimelinePlayback() {
        if audioPlayback.isPreparing || audioPlayback.isPlaying {
            audioPlayback.stop(); vm.stopPlayback(); return
        }
        if vm.isPlaying { vm.stopPlayback(); return }
        guard vm.isEditing, scenePhase == .active, vm.activePanel == .none,
              !vm.isSaving, vm.activeStrokeID == nil, vm.pendingBrushStroke == nil, vm.textDraft == nil else {
            vm.message = "Finish the active edit or save before playing the timeline."
            return
        }
        guard !vm.document.audioClips.isEmpty else { vm.togglePlayback(); return }
        let id = vm.document.id, revision = vm.document.revision
        let fps = vm.fps
        let start = StudioAudioTransport.seconds(atTick: vm.document.startTick(ofFrame: vm.currentFrameIndex), fps: fps)
        let duration = vm.audioDuration
        _ = audioPlayback.play(document: vm.document, tracks: vm.projectAudioTracks,
            duration: duration, from: start, loop: vm.playbackLoops,
            frameClock: StudioAudioTransport.FrameClock(fps: fps, frameTicks: vm.document.frames.map(\.durationTicks)),
            stillCurrent: {
                vm.isEditing && scenePhase == .active && vm.activePanel == .none &&
                vm.document.id == id && vm.document.revision == revision
            }, onTime: { time, playing in
                guard vm.document.id == id, vm.document.revision == revision else { return }
                // Floor-safe: an exact frame-start time must not display the previous frame (#180).
                vm.displayAudioPlaybackTime(min(duration, StudioAudioTransport.floorSafeSeconds(max(0, time), fps: fps)), playing: playing)
            })
        if let notice = audioPlayback.notice { vm.message = notice }
    }
}


private struct StudioTweenOptions: View {
    @ObservedObject var vm: StudioViewModel
    let capture: StudioViewModel.TweenCapture
    @Environment(\.dismiss) private var dismiss
    @State private var count = 6
    @State private var easing: StudioTweenEasing = .easeInOut
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Editable in-betweens") {
                    Stepper("\(count) new frames", value: $count, in: 1...24)
                        .accessibilityIdentifier("studio.tween.count")
                    Picker("Easing", selection: $easing) {
                        ForEach(StudioTweenEasing.allCases) { value in Text(value.title).tag(value) }
                    }.pickerStyle(.menu).accessibilityIdentifier("studio.tween.easing")
                    Text("Adds \(String(format: "%.2f", Double(count) / Double(vm.fps))) seconds. Endpoint artwork and exposure holds stay unchanged. Existing audio stays at its current times.")
                    Text("Duplicate a frame, then move, resize or rotate its artwork for the next pose. Drawings pair by order with matching styles and layers. Images pair by the same original on each layer; crop, carried flips, pixel selection and stacking must match. Quarter turns and Additional angle both interpolate along the shortest rotation. Erasers, drawing effects and alpha paint cannot tween. New frames stay editable; later endpoint changes do not regenerate them.")
                        .font(.custom("SpecialElite-Regular", size: 13, relativeTo: .footnote))
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("studio.tween.error") }
                Button("Insert in-betweens") {
                    do { try vm.applyTween(capture, count: count, easing: easing); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.disabled(vm.prepareTween(capture.frameID) != capture)
                    .accessibilityIdentifier("studio.tween.apply")
                if vm.prepareTween(capture.frameID) != capture {
                    Text("The editor changed. Close this sheet and reopen Tween for the current endpoints.").foregroundStyle(.secondary)
                }
            }
            .font(.specialElite(14))
            .navigationTitle("Tween frames")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}

private struct StudioFrameTimingCapture: Identifiable {
    let id = UUID()
    let projectID: UUID
    let revision: Int
    let frameIDs: [String]
    let initialIndex: Int
    let initialTicks: Int
    let frameTicks: [Int]
    let fps: Int
    init(document: StudioDocument, index: Int) {
        projectID = document.id; revision = document.revision
        frameIDs = document.frames.map(\.id); initialIndex = index
        initialTicks = document.frames[index].durationTicks
        frameTicks = document.frames.map(\.durationTicks); fps = document.fps
    }
}

private struct StudioFrameTimingOptions: View {
    @ObservedObject var vm: StudioViewModel
    let capture: StudioFrameTimingCapture
    @Environment(\.dismiss) private var dismiss
    @State private var first: Int
    @State private var count = 1
    @State private var ticks: Int
    @State private var error: String?
    @State private var deletingIDs: [String] = []
    @State private var confirmingDelete = false
    /// 1-based timeline position the selected range should start at.
    @State private var targetPosition: Int
    init(vm: StudioViewModel, capture: StudioFrameTimingCapture) {
        self.vm = vm; self.capture = capture
        _first = State(initialValue: capture.initialIndex + 1)
        _ticks = State(initialValue: capture.initialTicks)
        _targetPosition = State(initialValue: capture.initialIndex + 1)
    }
    private var lastTargetPosition: Int { max(1, capture.frameIDs.count - count + 1) }
    private func moveRangeToTarget() {
        guard isCurrent, (1...lastTargetPosition).contains(targetPosition), targetPosition != first else { return }
        let ids = Array(capture.frameIDs[(first-1)..<last])
        vm.message = nil
        if vm.moveFrames(ids, toPosition: targetPosition - 1, expectedRevision: capture.revision) { dismiss() }
        else { error = vm.message ?? "The frames could not be moved." }
    }
    private var last: Int { min(capture.frameIDs.count, first + count - 1) }
    private var isCurrent: Bool {
        vm.document.id == capture.projectID && vm.document.revision == capture.revision && !vm.isPlaying && vm.isEditing
    }
    private var rangeTicks: [Int] { Array(capture.frameTicks[(first-1)..<last]) }
    private func scaledHolds(_ multiplier: Double) -> [Int]? {
        // Refuse lost poses or excessive holds instead of silently clamping.
        guard rangeTicks.allSatisfy({ Double($0) * multiplier >= 1 && Double($0) * multiplier <= 600 }) else { return nil }
        return rangeTicks.map { Int((Double($0) * multiplier).rounded()) }
    }
    private func retimeRange(_ multiplier: Double) {
        do {
            guard isCurrent, let holds = scaledHolds(multiplier) else { throw StudioCommandError.invalidSettings }
            let ids = Array(capture.frameIDs[(first-1)..<last])
            let commands: [StudioCommand] = zip(ids, holds).map { .setFrameHold(.init(frame: .id($0.0), ticks: $0.1)) }
            _ = try vm.applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
                expectedRevision: capture.revision, action: .apply(commands)))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private func moveRange(_ direction: StudioCommandDirection) {
        do {
            guard isCurrent, direction == .earlier ? first > 1 : last < capture.frameIDs.count else {
                throw StudioCommandError.cannotMove
            }
            let ids = Array(capture.frameIDs[(first-1)..<last])
            // Move toward the boundary first so each swap crosses only the
            // neighboring unselected frame, retaining order inside the range.
            let ordered = direction == .earlier ? ids : Array(ids.reversed())
            let commands: [StudioCommand] = ordered.map {
                .moveFrame(.init(target: .id($0), direction: direction))
            }
            _ = try vm.applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
                expectedRevision: capture.revision, action: .apply(commands)))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Frame range") {
                    Stepper("Start frame: \(first)", value: $first, in: 1...capture.frameIDs.count)
                        .accessibilityIdentifier("studio.frame-timing.first")
                    Stepper("Frames: \(count)", value: $count, in: 1...min(96, capture.frameIDs.count - first + 1))
                        .accessibilityIdentifier("studio.frame-timing.count")
                    Text("Frames \(first) through \(last)")
                }
                Section("Exposure") {
                    Stepper("\(ticks) ticks per frame", value: $ticks, in: 1...600)
                        .accessibilityIdentifier("studio.frame-timing.ticks")
                    Text("Range duration: \(String(format: "%.2f", Double((last-first+1) * ticks) / Double(capture.fps))) seconds at \(capture.fps) FPS.")
                    Text("Artwork stays editable. One Undo restores the whole range. Audio clips keep their existing start times.")
                }
                Section("Relative timing") {
                    Text("Current range: \(String(format: "%.2f", Double(rangeTicks.reduce(0, +)) / Double(capture.fps))) seconds")
                    ForEach([0.5, 2.0], id: \.self) { multiplier in
                        Button(multiplier == 0.5 ? "Twice as fast" : "Half speed") { retimeRange(multiplier) }
                            .disabled(!isCurrent || scaledHolds(multiplier) == nil)
                            .accessibilityIdentifier(multiplier == 0.5 ? "studio.frame-timing.faster" : "studio.frame-timing.slower")
                        if let holds = scaledHolds(multiplier) {
                            Text("Result: \(String(format: "%.2f", Double(holds.reduce(0, +)) / Double(capture.fps))) seconds")
                        }
                    }
                    Text("Scales each existing hold independently, rounded to whole ticks. A result outside 1–600 ticks disables the action. Project FPS and audio times stay unchanged. One Undo restores the timing.")
                }
                Section("Frame order") {
                    Button("Move selected range earlier") { moveRange(.earlier) }
                        .disabled(!isCurrent || first <= 1)
                        .accessibilityIdentifier("studio.frame-timing.move-earlier")
                    Button("Move selected range later") { moveRange(.later) }
                        .disabled(!isCurrent || last >= capture.frameIDs.count)
                        .accessibilityIdentifier("studio.frame-timing.move-later")
                    Stepper("Start at frame \(min(targetPosition, lastTargetPosition))", value: $targetPosition, in: 1...lastTargetPosition)
                        .accessibilityIdentifier("studio.frame-timing.position")
                    Button("Move selected range to frame \(min(targetPosition, lastTargetPosition))") { moveRangeToTarget() }
                        .disabled(!isCurrent || min(targetPosition, lastTargetPosition) == first)
                        .accessibilityIdentifier("studio.frame-timing.move-to")
                    Text("Moves the range across one neighboring frame while preserving its internal order, exposure and selected frame. Audio times stay unchanged. One Undo restores the order.")
                    Button("Duplicate selected range") {
                        do {
                            guard isCurrent else { throw StudioCommandError.staleRevision }
                            let ids = Array(capture.frameIDs[(first-1)..<last])
                            _ = try vm.applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
                                expectedRevision: capture.revision, action: .apply([.duplicateFrameRange(.init(frameIDs: ids))])))
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(!isCurrent || capture.frameIDs.count + last-first+1 > 1000)
                        .accessibilityIdentifier("studio.frame-timing.duplicate-range")
                    Text("Copies are inserted after the range with new identities and the same exposure. Audio clips keep their current times.")
                    Button("Reverse selected range") {
                        guard isCurrent else { error = "The project changed. Reopen frame timing."; return }
                        do {
                            let ids = Array(capture.frameIDs[(first-1)..<last])
                            _ = try vm.applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
                                expectedRevision: capture.revision, action: .apply([.reverseFrames(.init(frameIDs: ids))])))
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(!isCurrent || count < 2)
                        .accessibilityIdentifier("studio.frame-timing.reverse")
                    Text("Reverses frames \(first) through \(last), keeping each frame's existing exposure and artwork. Audio stays at its current times. One Undo restores the order.")
                }
                Section("Remove frames") {
                    Button("Delete selected range…", role: .destructive) {
                        deletingIDs = Array(capture.frameIDs[(first-1)..<last])
                        confirmingDelete = true
                    }
                    .disabled(!isCurrent || last-first+1 >= capture.frameIDs.count)
                    .accessibilityIdentifier("studio.frame-timing.delete-range")
                    Text("Deletes only the chosen frames. At least one frame must remain. Audio clips keep their existing times; one Undo restores the entire range.")
                }
                if !isCurrent { Text("The project changed. Close and reopen frame timing before applying.").foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red) }
                Button("Apply frame timing") {
                    guard isCurrent else { error = "The project changed. Reopen frame timing."; return }
                    do {
                        let commands: [StudioCommand] = (first...last).map {
                            .setFrameHold(.init(frame: .id(capture.frameIDs[$0 - 1]), ticks: ticks))
                        }
                        _ = try vm.applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
                            expectedRevision: capture.revision, action: .apply(commands)))
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.disabled(!isCurrent)
                    .accessibilityIdentifier("studio.frame-timing.apply")
            }
            .font(.specialElite(14))
            .navigationTitle("Frame range & timing")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .confirmationDialog("Delete \(deletingIDs.count) selected frames?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete selected frames", role: .destructive) {
                    do {
                        guard isCurrent, !deletingIDs.isEmpty,
                              deletingIDs.count < capture.frameIDs.count,
                              Set(deletingIDs).isSubset(of: Set(capture.frameIDs)) else {
                            throw StudioCommandError.staleRevision
                        }
                        let commands: [StudioCommand] = deletingIDs.map { .deleteFrame(.id($0)) }
                        _ = try vm.applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
                            expectedRevision: capture.revision, action: .apply(commands)))
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                    deletingIDs = []
                }
                Button("Cancel", role: .cancel) { deletingIDs = [] }
            } message: {
                Text("This removes the selected frames and their artwork from this project. Audio timing stays unchanged. Undo restores the whole operation.")
            }
            .onChange(of: first) { _, _ in count = min(count, capture.frameIDs.count - first + 1) }
        }.preferredColorScheme(.dark)
    }
}
