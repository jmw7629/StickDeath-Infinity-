import SwiftUI

// ═══════════════════════════════════════════════════════════════════
// Frame Timeline — < ▶ > | frame thumbnails (red border=selected) | +
//   onion skin icon | frame counter
// ═══════════════════════════════════════════════════════════════════

struct StudioTimeline: View {
    @ObservedObject var vm: StudioViewModel
    @State private var tweenCapture: StudioViewModel.TweenCapture?

    var body: some View {
        HStack(spacing: 6) {
            // Prev
            Button(action: { vm.prevFrame() }) {
                Text("‹")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(vm.currentFrameIndex > 0 ? .white.opacity(0.6) : .white.opacity(0.2))
            }
            .disabled(vm.currentFrameIndex == 0)

            // Play/Pause
            Button(action: { vm.togglePlayback() }) {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Color(hex: "1E1E2A"))
                    .clipShape(Circle())
            }

            // Next
            Button(action: { vm.nextFrame() }) {
                Text("›")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(vm.currentFrameIndex < vm.frames.count - 1 ? .white.opacity(0.6) : .white.opacity(0.2))
            }
            .disabled(vm.currentFrameIndex >= vm.frames.count - 1)

            // Frame thumbnails
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
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

                                    // Frame number
                                    Text("\(i + 1)")
                                        .font(.system(size: 7, weight: .bold, design: .monospaced))
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
            }

            .accessibilityIdentifier("studio.add-frame")

            // Onion skin toggle
            Button(action: { vm.showOnionSkin.toggle() }) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 14))
                    .foregroundColor(vm.showOnionSkin ? .red : .white.opacity(0.3))
            }

            Spacer()

            // Frame counter
            Text("\(vm.currentFrameIndex + 1)/\(vm.frames.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
        }
        // A timeline is a bounded control row, not a second flexible canvas.
        // The thumbnail label must never expand the horizontal scroll view
        // vertically when the editor receives a portrait or landscape proposal.
        .frame(height: 36)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(hex: "0A0A10"))
        .sheet(item: $tweenCapture) { capture in
            StudioTweenOptions(vm: vm, capture: capture)
        }
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
                    Text("Drawings pair by order and must use matching styles, sample counts and layers. Copy a frame, then move, scale or rotate its drawings to create the next pose. Raster references, erasers, effects and alpha paint are unsupported. Each new frame stays independently editable; later endpoint changes do not regenerate it.")
                        .font(.footnote)
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
            .navigationTitle("Tween frames")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}
