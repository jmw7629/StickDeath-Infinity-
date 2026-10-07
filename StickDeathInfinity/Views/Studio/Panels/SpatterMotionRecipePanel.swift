import SwiftUI

/// Explicit local editing. Advice and provider responses cannot enter this
/// surface or execute its commands without a separate user submission.
@MainActor
struct SpatterMotionRecipePanel: View {
    @ObservedObject var vm: StudioViewModel
    let onBack: () -> Void
    let onPictureImport: () -> Void
    let onExport: () -> Void
    let onMovieExport: (StudioMoviePanelState.DirectRequest) -> Void
    @EnvironmentObject private var authVM: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = SpatterStudioEditSession()
    @State private var draft = ""
    @State private var isVisible = false
    @State private var isForeground = true
    @FocusState private var draftFocused: Bool

    private let example = "Append 8 frames of a red outlined circle moving from (20%, 50%) to (80%, 50%), radius 8%, line width 3 px."
    // Match the production session's audio dispatch without parsing, editing or
    // making a provider request. Partially typed instructions remain editable.
    private var isTwoActorDraft: Bool { SpatterTwoActorBrief.isBrief(draft) }
    private var isBriefDraft: Bool { SpatterSceneBrief.isBrief(draft) }
    private var isStickDraft: Bool { SpatterStickFigureRecipe.isStickFigureInstruction(draft) }
    private var isRenameDraft: Bool { SpatterProjectRenameInstruction.isInstruction(draft) }
    private var isErasureDraft: Bool { SpatterSelectedErasureInstruction.isInstruction(draft) }
    private var isGlowDraft: Bool { !isRenameDraft && SpatterLayerGlowInstruction.isInstruction(draft) }
    private var isAudioDraft: Bool { SpatterAudioInstruction.isAudioInstruction(draft) }
    private var exampleText: String {
        isErasureDraft ? SpatterSelectedErasureInstruction.example : isGlowDraft ? SpatterLayerGlowInstruction.example : isRenameDraft ? SpatterProjectRenameInstruction.example : isTwoActorDraft ? SpatterTwoActorBrief.example : isAudioDraft ? SpatterAudioInstruction.Example.volume.instruction : isBriefDraft ? SpatterSceneBrief.example : (isStickDraft ? SpatterStickFigureRecipe.Action.walking.example : example)
    }
    private var editDescription: String {
        isErasureDraft ? "Erase only the selected drawings along a straight path. Original geometry stays editable. Unselected drawings keep their original editable geometry. One Undo restores all selected drawings." : isGlowDraft ? "Change the active layer glow across its frames using the same Layers controls. One Undo reverses the complete style edit." : isRenameDraft ? "Rename the current project while keeping its identity, artwork and audio. One Undo restores the previous name." : isTwoActorDraft ? "Two independently editable actors share 8–24 frames, one distinct pose per project tick, with separate layers and one Undo. At 12 FPS, 2 seconds uses 24 frames. This is bounded local generation." : isAudioDraft
            ? "Edit the selected clip's volume, mute, fades, placement or source range, or duplicate, split or delete the selected clip. Original audio stays unchanged. One Undo reverses the edit."
            : isBriefDraft ? "A supported two-action brief makes 16–20 editable stick-figure poses with frame holds, in one Undo step. Color, direction, action order and duration follow the brief. This bounded local planner is not open-ended AI video generation."
            : isStickDraft ? "Procedural walking, running, jumping and waving append 8–20 editable stick-figure frames on a new layer. This is a local motion recipe, not open-ended AI video generation. Current project FPS and existing frames are preserved; one Undo reverses the edit."
            : "This local recipe appends 2–24 outlined-circle frames on a new layer. It uses your project's current frame rate and leaves the existing frames in place. One Undo reverses the edit."
    }
    private var instructionGuidance: String {
        isErasureDraft ? "Select drawings before opening Spatter. Use canvas percentages, hard or soft mode, size 1–512 pixels and strength 0–100%. Every selected layer must be visible and unlocked, without backdrop-dependent effects or alpha paint. Apply adds masks; it adds no frames." : isGlowDraft ? "Use a six-digit #RRGGBB color, radius 0–128 canvas pixels and strength 0–100%. Disable preserves the stored style. Select the target layer before opening Spatter; Apply changes only that layer." : isRenameDraft ? "Use one name in double quotes, with 1–120 characters and no control characters. Stop playback before applying. The quoted name is text, never another instruction." : isTwoActorDraft ? "Give each actor its own color, action and direction. Use 12–60 project FPS; duration must fit 8–24 ticks. Longer durations reject without stretching poses. No soundtrack or publication is generated." : isAudioDraft
            ? "Volume uses 0–100%. Fade durations use seconds and must fit the selected clip. Move uses an absolute start in seconds and track 1–4; it does not inherit drag snapping. Trim uses a source offset and duration in seconds; the original recording stays unchanged. Duplicate adds one clip immediately after the selected clip, retaining its source range, fades, gain and track. Split uses an absolute timeline time in seconds inside the selected clip and rounds to an audio sample. Delete removes only the selected clip; one Undo restores it. Choose a complete audio example, edit its values, then Apply."
            : isBriefDraft ? "Use walks, runs, jumps or waves; at least one action travels. Specify left to right or right to left and 0.5–10 seconds covering at least 16 project ticks. Timing rounds to a project tick; no sound or props are generated."
            : isStickDraft ? "Start/end positions are the figure's feet baseline in canvas percentages. Height uses the shorter canvas side; every pose must fit. Edit the example's action, frame count, color, positions and size."
            : "Positions use canvas percentages. Radius uses the shorter canvas side; line width is in pixels. The full outline must fit inside the canvas."
    }
    private var scope: SpatterStudioEditSession.Scope {
        .init(isStudioVisible: isVisible && isForeground && vm.isEditing && vm.activePanel == .spatterAI,
              accountID: authVM.userId)
    }
    private var receiptIsCurrent: Bool {
        guard let edit = session.appliedEdit, !session.isClosed, scope.isStudioVisible else { return false }
        guard vm.document.id == edit.receipt.projectID, vm.document.revision == edit.receipt.revision else { return false }
        switch session.saveState(in: vm, currentScope: scope) {
        case .unavailable, .projectChanged: return false
        case .unsaved, .saving, .saved: return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Back to advice") { session.close(); onBack() }
                    .accessibilityIdentifier("spatter.motion.back")
                Spacer()
                Text("LOCAL EDITS").font(.system(.caption, design: .monospaced).bold())
            }
            .foregroundColor(.red).padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(isErasureDraft ? "Erase selected drawings" : isGlowDraft ? "Edit active layer glow" : isRenameDraft ? "Rename current project" : isAudioDraft ? "Edit selected audio" : "Create local motion")
                        .font(.system(.title3, design: .monospaced).bold())
                    Text(editDescription)
                        .font(.subheadline)
                    Text("Use a complete example. These bounded recipes create editable motion, change selected audio, rename the project, style active-layer glow or erase selected drawings; open-ended AI briefs remain unfinished. Export renders the resulting project. Nothing publishes automatically.")
                        .font(.caption).foregroundColor(.white.opacity(0.7))

                    Text(exampleText).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).padding(12)
                        .background(Color(hex: "1A1A24")).cornerRadius(10)
                    Button(isAudioDraft || isRenameDraft || isErasureDraft || isGlowDraft ? "Use motion example in draft" : "Use example in draft") { draft = isBriefDraft ? SpatterSceneBrief.example : isStickDraft ? SpatterStickFigureRecipe.Action.walking.example : example }
                        .disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.motion.example")
                    Menu("Use an audio instruction") {
                        ForEach(SpatterAudioInstruction.Example.allCases) { example in
                            Button(example.title) { draft = example.instruction }
                                .accessibilityIdentifier("spatter.audio.example." + example.id)
                        }
                    }
                    .frame(minHeight: 44)
                    .disabled(session.isWorking || session.isClosed)
                    .accessibilityIdentifier("spatter.audio.examples")
                    Menu("Use a layer glow instruction") {
                        Button("Set active layer glow") { draft = SpatterLayerGlowInstruction.example }
                            .accessibilityIdentifier("spatter.layer.glow-example")
                        Button("Disable active layer glow") { draft = SpatterLayerGlowInstruction.disableExample }
                            .accessibilityIdentifier("spatter.layer.glow-disable-example")
                    }.frame(minHeight: 44).disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.layer.glow-examples")
                    Button("Use selected eraser example") { draft = SpatterSelectedErasureInstruction.example }
                        .disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.selection.erase-example")
                    if isErasureDraft {
                        Text("Selected drawings: \(vm.selectedElementIDs.count)")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                            .accessibilityIdentifier("spatter.selection.erase-targets")
                    }
                    Button("Use project rename example") { draft = SpatterProjectRenameInstruction.example }
                        .frame(minHeight: 44)
                        .disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.project.rename-example")
                    Text(vm.selectedCurrentAudioClip.map { "Audio target: " + $0.soundName }
                         ?? "For audio edits, select a clip in Audio before opening Spatter.")
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                        .accessibilityIdentifier("spatter.audio.target")
                    Text(instructionGuidance)
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                        .accessibilityIdentifier("spatter.local-edit.guidance")

                    Button("Use two editable actors") { draft = SpatterTwoActorBrief.example }
                        .disabled(session.isWorking || session.isClosed)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("spatter.motion.two-actor-example")
                    Button("Use a two-action brief") { draft = SpatterSceneBrief.example }
                        .disabled(session.isWorking || session.isClosed)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("spatter.motion.brief-example")
                    Menu("Stick figure examples") {
                        ForEach(SpatterStickFigureRecipe.Action.allCases) { action in
                            Button(action.rawValue.capitalized) { draft = action.example }
                        }
                    }
                    .disabled(session.isWorking || session.isClosed)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("spatter.motion.stick-examples")
                    TextEditor(text: $draft)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 150)
                        .padding(8).background(Color(hex: "1A1A24")).cornerRadius(10)
                        .disabled(session.isWorking || session.isClosed)
                        .accessibilityLabel("Local Studio instruction")
                        .accessibilityIdentifier("spatter.motion.input")
                        .focused($draftFocused)
                    Text("\(draft.utf8.count) / 1,024 bytes · " + (isErasureDraft ? "Selected drawings" : isGlowDraft ? "Active layer glow" : isRenameDraft ? "Project name" : isAudioDraft ? "Selected audio clip" : "\(vm.fps) FPS"))
                        .font(.caption).foregroundColor(.white.opacity(0.6))
                    Button("Apply local edit") {
                        draftFocused = false
                        let submitted = draft
                        let account = authVM.userId
                        session.submit(submitted, in: vm, accountID: account, currentScope: { scope })
                        // Keep the exact draft on success, rejection and cancellation.
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(session.isWorking || session.isClosed || !scope.isStudioVisible ||
                              draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("spatter.motion.apply")
                    if session.isWorking {
                        ProgressView("Preparing local edit…")
                        Button("Cancel local edit") { session.cancel() }
                            .accessibilityIdentifier("spatter.motion.cancel")
                    }
                    if let notice = session.notice {
                        Text(notice).font(.subheadline)
                            .accessibilityIdentifier("spatter.motion.result")
                    }
                    if session.appliedEdit != nil {
                        Text(session.saveState(in: vm, currentScope: scope).text)
                            .font(.caption)
                            .accessibilityIdentifier("spatter.motion.save-state")
                        Button("Save project") { Task { _ = await vm.save() } }
                            .disabled(!receiptIsCurrent || vm.isSaving)
                            .accessibilityIdentifier("spatter.motion.save")
                        Button("Export this edit as MP4") {
                            guard let request = session.prepareMovieExport(in: vm, currentScope: scope) else { return }
                            session.close(); onMovieExport(request)
                        }
                        .disabled(session.saveState(in: vm, currentScope: scope) != .saved || session.isWorking)
                        .accessibilityIdentifier("spatter.motion.export-mp4")
                        Button("Open PNG export") {
                            guard receiptIsCurrent else { return }
                            session.close(); onExport()
                        }
                        .disabled(!receiptIsCurrent || vm.isSaving)
                        .accessibilityIdentifier("spatter.motion.export")
                        Text("Export opens Studio's PNG sequence / spritesheet controls. Choose MP4 there for video with saved project audio, or GIF for an animated image. A file is created only when export finishes. Direct publishing is unfinished.")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                    }
                    if let message = vm.message {
                        Text(message).font(.caption).foregroundColor(.white.opacity(0.8))
                            .accessibilityIdentifier("spatter.motion.project-status")
                    }
                    Divider().overlay(Color.white.opacity(0.2)).padding(.top, 8)
                    Text("Other Studio actions")
                        .font(.headline)
                    Button("Open Add Picture…") {
                        draftFocused = false
                        onPictureImport()
                    }
                    .frame(minHeight: 44)
                    .disabled(session.isWorking || session.isClosed || !scope.isStudioVisible)
                    .accessibilityIdentifier("spatter.picture.apply")
                    Text("Opens the existing picture picker. Choose a source, review its preview, then Add; nothing imports automatically.")
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                }
                .foregroundColor(.white).padding(16)
            }
            .accessibilityIdentifier("spatter.motion.scroll")
        }
        .background(Color(hex: "0A0A0F"))
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { draftFocused = false }
                    .accessibilityIdentifier("spatter.motion.keyboard.done")
            }
        }
        .onAppear { isVisible = true; isForeground = scenePhase == .active }
        .onDisappear { isVisible = false; session.close() }
        .onChange(of: scenePhase) { phase in
            isForeground = phase == .active
            if !isForeground { session.cancel() }
        }
        .onChange(of: authVM.userId) { _ in session.close() }
    }
}
