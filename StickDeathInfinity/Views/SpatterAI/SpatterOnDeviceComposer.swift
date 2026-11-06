import SwiftUI

/// A separate, explicit local drafting route. Existing cloud advice, local FAQ,
/// saved preferences and the transactional Studio edit session keep their owners.
@MainActor
struct SpatterOnDeviceComposer: View {
    struct Capture: Equatable {
        let accountID: String?
        let existingDraft: String
        let snapshot: SpatterContextSnapshot
        let selectedElementIDs: Set<String>
        let selectedAudioClipID: String?
        let playhead: Double?
        let image: StudioViewModel.ImageMoveCapture?
        let artwork: StudioViewModel.SelectionHandleCapture?
        let wand: StudioViewModel.CommandScreenContext.Wand?
        let canApply: Bool
        let visible: Bool
    }
    let capture: Capture
    let context: StudioCommandContext
    let disabled: Bool
    /// Re-read live state before accepting a model response; no View snapshot
    /// captured at request time can assert that the editor is still current.
    let stillCurrent: (Capture) -> Bool
    let onPrepared: (String) -> Void
    @State private var brief = ""
    @State private var availability = SpatterOnDeviceGenerator.availability
    @State private var notice: String?
    @State private var task: Task<Void, Never>?
    @State private var timeout: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Free on-device draft").font(.specialElite(17, relativeTo: .headline))
            Text(availability.message).font(.specialElite(12, relativeTo: .caption))
            Text("Describe a short stick-figure scene or an edit to timing, layer visibility, grid or an audio track. Spatter drafts a supported instruction for you to review and edit below. Apply local edit commits your reviewed instruction. Project changes support Undo; grid and onion-skin changes are view settings. No cloud fallback is used.")
                .font(.specialElite(12, relativeTo: .caption)).foregroundColor(.white.opacity(0.7))
            TextField("Describe your scene or edit…", text: $brief, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder)
                .disabled(working || disabled)
                .accessibilityIdentifier("spatter.ondevice.brief")
            Button(working ? "Preparing on-device draft…" : "Draft on this device") { start() }
                .disabled(working || disabled || !availability.canGenerate || !capture.visible || !capture.canApply || capture.snapshot.isPlaying || brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .frame(minHeight: 44)
                .accessibilityIdentifier("spatter.ondevice.generate")
            if working {
                Button("Cancel on-device draft") { cancel("On-device draft cancelled. Nothing changed.") }
                    .accessibilityIdentifier("spatter.ondevice.cancel")
            } else {
                Button("Check on-device availability") { availability = SpatterOnDeviceGenerator.availability }
                    .font(.specialElite(12, relativeTo: .caption))
            }
            if let notice {
                Text(notice).font(.specialElite(12, relativeTo: .caption)).textSelection(.enabled)
                    .accessibilityIdentifier("spatter.ondevice.result")
            }
        }
        .onChange(of: capture) { _ in
            if working { cancel("The account, project, tool, frame, layer, selection or audio context changed. Draft again for the current editor.") }
        }
        .onChange(of: disabled) { value in if value && working { cancel("Studio became busy. Draft again when it is ready.") } }
        .onDisappear { cancel(nil) }
    }

    private enum ContextError: LocalizedError {
        case changed
        var errorDescription: String? { "The Studio context or editable draft changed. Draft again; nothing changed." }
    }

    private func start() {
        guard !working, !disabled, capture.visible, capture.canApply, !capture.snapshot.isPlaying, stillCurrent(capture) else { return }
        do { _ = try SpatterOnDevicePlan.validateBrief(brief) }
        catch { notice = error.localizedDescription; return }
        availability = SpatterOnDeviceGenerator.availability
        guard availability.canGenerate else { notice = availability.message; return }
        let id = UUID(), captured = capture, input = brief
        generation = id; working = true; notice = nil
        // Screen facts are local only; do not send editable artwork, credentials
        // or historical conversations. Names are bounded, untrusted model data.
        let facts = capture.snapshot.summary + " · audio clips \(capture.snapshot.audioClipCount) · grid \(capture.snapshot.gridEnabled) · onion \(capture.snapshot.onionEnabled)"
        task = Task { @MainActor in
            do {
                let proposal = try await SpatterOnDeviceGenerator.propose(brief: input, context: facts)
                try Task.checkCancellation()
                guard generation == id else { return }
                guard stillCurrent(captured) else { throw ContextError.changed }
                _ = try SpatterOnDevicePlan.prepare(proposal, in: context)
                try Task.checkCancellation()
                guard generation == id else { return }
                guard stillCurrent(captured) else { throw ContextError.changed }
                onPrepared(proposal)
                notice = "On-device instruction prepared and validated. Review the editable draft and Preview plan below, then explicitly Apply. Nothing has changed yet."
            } catch is CancellationError {
                if generation == id { notice = "On-device draft cancelled. Nothing changed." }
            } catch {
                if generation == id { notice = error.localizedDescription }
            }
            guard generation == id else { return }
            timeout?.cancel(); timeout = nil; task = nil; working = false
        }
        timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard generation == id, working else { return }
            cancel("On-device drafting reached its 30-second limit. Try a smaller brief. Nothing changed.")
        }
    }
    private func cancel(_ message: String?) {
        generation = UUID(); task?.cancel(); timeout?.cancel()
        task = nil; timeout = nil; working = false
        if let message { notice = message }
    }
}
