import SwiftUI
import UIKit

/// Explicit local editing. Advice and provider responses cannot enter this
/// surface or execute its commands without a separate user submission.
@MainActor
struct SpatterMotionRecipePanel: View {
    @ObservedObject var vm: StudioViewModel
    let onBack: () -> Void
    let onPictureImport: () -> Void
    let onExport: () -> Void
    let onMovieExport: (StudioMoviePanelState.DirectRequest) -> Void
    /// Optional: the Export panel's movie state, so a completed direct export that
    /// this panel handed off can show its factual receipt here. Nil keeps the
    /// existing call site valid; the receipt is then shown only in the Export panel.
    var movieState: StudioMoviePanelState? = nil
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
    private var isDuplicateRangeDraft: Bool { SpatterFrameDuplicateRangeInstruction.isInstruction(draft) }
    private var isReverseDraft: Bool { SpatterFrameReverseInstruction.isInstruction(draft) }
    private var isNavigationDraft: Bool { SpatterNavigationInstruction.isInstruction(draft) }
    private var isLayerStructureDraft: Bool { SpatterLayerStructureInstruction.isInstruction(draft) }
    private var isLayerUpdateDraft: Bool { SpatterLayerUpdateInstruction.isInstruction(draft) }
    private var isLayerDuplicateDraft: Bool { !isLayerUpdateDraft && !SpatterProjectRenameInstruction.isInstruction(draft) && SpatterLayerDuplicateInstruction.isInstruction(draft) }
    private var isLayerOrderDraft: Bool { !isLayerUpdateDraft && !SpatterProjectRenameInstruction.isInstruction(draft) && SpatterLayerOrderInstruction.isInstruction(draft) }
    private var isGridDraft: Bool { !isLayerUpdateDraft && !SpatterProjectRenameInstruction.isInstruction(draft) && SpatterGridInstruction.isInstruction(draft) }
    private var isOnionDraft: Bool { !isLayerUpdateDraft && !SpatterProjectRenameInstruction.isInstruction(draft) && SpatterOnionInstruction.isInstruction(draft) }
    private var isFrameActionDraft: Bool { !isLayerUpdateDraft && !SpatterProjectRenameInstruction.isInstruction(draft) && SpatterFrameActionInstruction.isInstruction(draft) }
    private var isLayerDraft: Bool { isLayerStructureDraft || isLayerUpdateDraft || isLayerDuplicateDraft || isLayerOrderDraft }
    private var isRenameDraft: Bool { !isLayerUpdateDraft && SpatterProjectRenameInstruction.isInstruction(draft) }
    private var isAudioTrackDraft: Bool { SpatterAudioTrackInstruction.isInstruction(draft) }
    private var isDrawingDuplicateDraft: Bool { SpatterDrawingDuplicateInstruction.isInstruction(draft) }
    private var isErasureDraft: Bool { SpatterSelectedErasureInstruction.isInstruction(draft) }
    private var isExposureDraft: Bool { !isLayerDraft && !isRenameDraft && SpatterFrameExposureInstruction.isInstruction(draft) }
    private var isGlowDraft: Bool { !isLayerDraft && !isRenameDraft && SpatterLayerGlowInstruction.isInstruction(draft) }
    // Selection/image/text grammars take precedence over the broad audio first-word classifier.
    private var isSelectionTranslateDraft: Bool { SpatterSelectionTranslateInstruction.isInstruction(draft) }
    private var isSelectionTransformDraft: Bool { SpatterSelectionTransformInstruction.isInstruction(draft) }
    private var isSelectionReflectDraft: Bool { SpatterSelectionReflectInstruction.isInstruction(draft) }
    private var isSelectionDraft: Bool { isSelectionTranslateDraft || isSelectionTransformDraft || isSelectionReflectDraft }
    private var isImageRotationDraft: Bool { SpatterImageRotationInstruction.isInstruction(draft) }
    private var isImageCropDraft: Bool { SpatterImageCropInstruction.isInstruction(draft) }
    private var isImagePlacementDraft: Bool { SpatterImagePlacementInstruction.isInstruction(draft) }
    private var isImageEditDraft: Bool { isImageRotationDraft || isImageCropDraft || isImagePlacementDraft }
    private var isTextUpdateDraft: Bool { SpatterTextUpdateInstruction.isInstruction(draft) }
    private var isAudioDraft: Bool { !isLayerDraft && !isSelectionDraft && !isImageEditDraft && !isTextUpdateDraft && SpatterAudioInstruction.isAudioInstruction(draft) }
    private var isOrderDraft: Bool { !isLayerDraft && !isRenameDraft && SpatterArtworkOrderInstruction.isInstruction(draft) }
    private var isImageDraft: Bool { !isLayerDraft && !isRenameDraft && SpatterImageReflectionInstruction.isInstruction(draft) }
    private var selectedImage: StudioViewModel.ImageMoveCapture? {
        guard vm.selectedElementIDs.isEmpty, !vm.isPlaying,
              let image = vm.currentImageMoveCapture(), image.placement.layerID == vm.activeLayerID else { return nil }
        return image
    }
    private var exampleText: String {
        if isSelectionTranslateDraft { return SpatterSelectionTranslateInstruction.example }
        if isSelectionTransformDraft { return SpatterSelectionTransformInstruction.example }
        if isSelectionReflectDraft { return SpatterSelectionReflectInstruction.horizontalExample }
        if isImageRotationDraft { return SpatterImageRotationInstruction.clockwiseExample }
        if isImageCropDraft { return SpatterImageCropInstruction.example }
        if isImagePlacementDraft { return SpatterImagePlacementInstruction.angleExample }
        if isTextUpdateDraft { return SpatterTextUpdateInstruction.colorExample }
        if isAudioTrackDraft {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if text.hasPrefix("pan") { return SpatterAudioTrackInstruction.panExample }
            if text.hasPrefix("solo") || text.hasPrefix("unsolo") { return SpatterAudioTrackInstruction.soloExample }
            return SpatterAudioTrackInstruction.volumeExample
        }
        if SpatterFrameCutInstruction.isInstruction(draft) { return SpatterFrameCutInstruction.example }
        if isDrawingDuplicateDraft { return SpatterDrawingDuplicateInstruction.example }
        if isDuplicateRangeDraft { return SpatterFrameDuplicateRangeInstruction.example }
        if isReverseDraft { return SpatterFrameReverseInstruction.example }
        if isExposureDraft, let instruction = try? SpatterFrameExposureInstruction.parse(draft), let frames = instruction.frames {
            return "Set frames \(frames.lowerBound) through \(frames.upperBound) exposure to \(instruction.ticks) ticks."
        }
        if isNavigationDraft { return (try? SpatterNavigationInstruction.parse(draft))?.example ?? SpatterNavigationInstruction.frameExample }
        if isLayerStructureDraft { return (try? SpatterLayerStructureInstruction.parse(draft))?.example ?? SpatterLayerStructureInstruction.addExample }
        if isGridDraft { return SpatterGridInstruction.settingsExample }
        if isOnionDraft { return SpatterOnionInstruction.settingsExample }
        if isFrameActionDraft { return (try? SpatterFrameActionInstruction.parse(draft))?.example ?? SpatterFrameActionInstruction.Action.duplicate.example }
        if isLayerOrderDraft { return SpatterLayerOrderInstruction.upExample }
        if isLayerUpdateDraft {
            let text = draft.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
            if text.hasPrefix("hide") { return SpatterLayerUpdateInstruction.hideExample }
            if text.hasPrefix("show") { return SpatterLayerUpdateInstruction.showExample }
            if text.contains("lock") { return SpatterLayerUpdateInstruction.lockExample((try? SpatterLayerUpdateInstruction.parse(draft))?.lock ?? .position) }
            if text.contains("blend") { return SpatterLayerUpdateInstruction.blendExample((try? SpatterLayerUpdateInstruction.parse(draft))?.blend ?? .multiply) }
        }
        if isOrderDraft { return SpatterArtworkOrderInstruction.forwardExample }
        if isImageDraft { return SpatterImageReflectionInstruction.horizontalExample }
        return
        isLayerDuplicateDraft ? SpatterLayerDuplicateInstruction.example : isLayerUpdateDraft ? (draft.trimmingCharacters(in:.whitespacesAndNewlines).lowercased().hasPrefix("rename") ? SpatterLayerUpdateInstruction.renameExample : SpatterLayerUpdateInstruction.opacityExample) : isExposureDraft ? SpatterFrameExposureInstruction.example : isErasureDraft ? SpatterSelectedErasureInstruction.example : isGlowDraft ? SpatterLayerGlowInstruction.example : isRenameDraft ? SpatterProjectRenameInstruction.example : isTwoActorDraft ? SpatterTwoActorBrief.example : isAudioDraft ? SpatterAudioInstruction.Example.volume.instruction : isBriefDraft ? SpatterSceneBrief.example : (isStickDraft ? SpatterStickFigureRecipe.Action.walking.example : example)
    }
    private var editDescription: String {
        if isSelectionDraft { return "Move, scale/rotate or flip the captured drawing selection with the same Move commands. Geometry stays editable, images and mixed artwork are excluded, and one Undo restores the prior placement." }
        if isImageEditDraft { return "Rotate a quarter turn, crop to a source rectangle, or position/size/angle the selected image using the same Move controls. The original file and other instances stay intact. One Undo reverses the edit." }
        if isTextUpdateDraft { return "Replace the selected text box's content and optionally its color. Typography, size, box and position are unchanged. One Undo restores the previous text." }
        if isAudioTrackDraft { return "Set volume, mute, pan or solo for one of the four audio tracks. Track gain and pan combine with each clip's own gain in playback and export; solo silences the other tracks during playback. Clips and source audio are preserved; one Undo restores the prior setting." }
        if SpatterFrameCutInstruction.isInstruction(draft) { return "Cut the current frame captured when Spatter opens. It remains in the frame clipboard for pasting. One Undo restores it; at least one frame must remain. Audio timing is unchanged." }
        if isDrawingDuplicateDraft { return "Duplicate the captured drawing selection on its original layers. Copies get fresh identities and remain selected for Move. One Undo removes the copies; the clipboard stays unchanged. Images and mixed selections are excluded." }
        if isDuplicateRangeDraft { return "Duplicate a consecutive frame range after its originals, with fresh identities, preserved artwork and exposure, and one Undo step." }
        if isReverseDraft { return "Reverse a consecutive frame range as one undoable edit. Frame artwork and exposures stay editable; audio times stay unchanged." }
        if isNavigationDraft { return "Select an existing frame or layer using the same Studio commands. Numbers start at 1; layers follow the top-to-bottom Layers list. Artwork is unchanged." }
        if isLayerStructureDraft { return "Create a named blank layer, or delete only the captured active layer and its contents across all frames using the same Layers commands. Existing original image files are preserved. One Undo restores the prior document." }
        if isGridDraft { return "Show or hide the canvas grid, or configure its spacing, opacity and tint. It is an editor guide, not a background image or exported artwork. Guides are not part of Undo history; change them again to go back." }
        if isOnionDraft { return "Show or hide neighboring-frame guides, or configure their counts, opacity and tint. These persistent editor guides do not change frame timing, artwork or export pixels. Guides are not part of Undo history; change them again to go back." }
        if isFrameActionDraft { return "Add blank frames, or duplicate, move and delete the captured active frame using the same timeline commands. One Undo restores the previous timeline. Frame movement preserves exposure; duplication adds its copied duration; deletion removes its duration." }
        if isLayerOrderDraft { return "Move the entire active layer one position up or down using the same Layers controls. Artwork, visibility and lock settings stay intact. One Undo restores layer order." }
        if isOrderDraft { return "Move selected drawings, an image, or mixed artwork one step forward or backward within each layer. Other layers keep their order. One Undo reverses the edit." }
        if isImageDraft { return "Flip the selected image horizontally or vertically using the same Move controls. Its original file, crop and other image instances stay intact. One Undo reverses the edit." }
        return
        isLayerDuplicateDraft ? "Duplicate the active layer across existing frames with fresh artwork identities and linked original images. Layer appearance and locks follow the same Layers operation. One Undo removes the duplicate; no frames are added." : isLayerUpdateDraft ? "Rename the active layer, change its opacity, blend mode or lock mode, or hide/show it using the same Layers controls. Artwork stays editable; one Undo restores the prior settings. No frames are added." : isExposureDraft ? "Change the selected frame or an explicit range of up to 96 existing frames to 1–600 ticks each. Duration is ticks divided by project FPS; no frames are added. One Undo restores its prior exposure." : isErasureDraft ? "Erase only the selected drawings along a straight path. Original geometry stays editable. Unselected drawings keep their original editable geometry. One Undo restores all selected drawings." : isGlowDraft ? "Change the active layer glow across its frames using the same Layers controls. One Undo reverses the complete style edit." : isRenameDraft ? "Rename the current project while keeping its identity, artwork and audio. One Undo restores the previous name." : isTwoActorDraft ? "Two independently editable actors share 8–24 frames, one distinct pose per project tick, with separate layers and one Undo. At 12 FPS, 2 seconds uses 24 frames. This is bounded local generation." : isAudioDraft
            ? "Edit the selected clip's volume, mute, fades, placement or source range, or duplicate, split or delete the selected clip. Original audio stays unchanged. One Undo reverses the edit."
            : isBriefDraft ? "A supported two-action brief makes 16–20 editable stick-figure poses with frame holds, in one Undo step. Color, direction, action order and duration follow the brief. This bounded local planner is not open-ended AI video generation."
            : isStickDraft ? "Procedural walking, running, jumping and waving append 8–20 editable stick-figure frames on a new layer. This is a local motion recipe, not open-ended AI video generation. Current project FPS and existing frames are preserved; one Undo reverses the edit."
            : "This local recipe appends 2–24 outlined-circle frames on a new layer. It uses your project's current frame rate and leaves the existing frames in place. One Undo reverses the edit."
    }
    private var instructionGuidance: String {
        if isSelectionDraft { return "Select 1–1,024 drawings with Move before opening Spatter; deselect images. Use Move selected drawings by (10%, -5%). (canvas percentages, -100 to 100), Scale selected drawings to 150% and rotate 45 degrees. (10–1,000%, -180 to 180 degrees) or Flip selected drawings horizontally. Selected layers must be visible and unlocked; Apply rechecks the exact selection." }
        if isImageEditDraft { return "Select one image with Move before opening Spatter. Deselect drawings and stop playback. Use Rotate selected image clockwise., Crop selected image to (10%, 10%, 80%, 80%). (source percentages: x, y, width, height) or Place selected image at (10%, 20%) with size (40%, 30%) and angle 25 degrees. (canvas percentages; the box must fit). The layer must be visible and unlocked." }
        if isTextUpdateDraft { return "Select exactly one text box with Move before opening Spatter. Use Set selected text to \"Hello\". or add in #RRGGBB for a color. Quoted text is content only (1–2,048 characters); it is never read as another instruction." }
        if isAudioTrackDraft { return "Use Set audio track 1 volume to 40%., Mute/Unmute audio track 1., Pan audio track 2 to L40. (L100–R100 or center) or Solo/Unsolo audio track 3. Tracks are 1–4. Stop playback, then Apply; one Undo restores the prior setting." }
        if isDuplicateRangeDraft { return "Use Duplicate frames 1 through 12. Choose 1–96 existing frames. Stop playback, then Apply. Audio clips keep their current times." }
        if isReverseDraft { return "Use Reverse frames 1 through 12. Choose 2–96 existing frames. Stop playback, then Apply to reverse the captured range." }
        if isExposureDraft { return "Use Set selected frame exposure to 12 ticks. or Set frames 1 through 12 exposure to 2 ticks. Range numbers are one-based and must already exist. A batch contains at most 96 frames, with 1–600 ticks per frame. One Undo restores the whole timing edit." }
        if isNavigationDraft { return "Stop playback. Select frame 1. or Select layer 1. chooses that existing target in this project. Missing numbers reject; selecting a locked layer does not unlock it. Examples fill the draft; Apply selects the target." }
        if isLayerStructureDraft { return "Add layer named \"Foreground\". creates a blank layer. Delete active layer. removes the captured layer and its contents across all frames. Select the target before opening Spatter. Locked/last-layer deletion rejects. Examples only fill the draft; Apply performs the reversible edit." }
        if isGridDraft { return "Stop playback. Show/Hide preserves settings; configuring preserves visibility. Specify all three settings: 8–160 whole canvas points spacing, 5–60% opacity, and blue, gray or red tint. Onion skin is unchanged. Examples only fill the draft." }
        if isOnionDraft { return "Stop playback. Show/Hide preserves settings; configuring preserves visibility. Set all four settings explicitly: 0–2 previous and next frames, 5–80% opacity, tinted or untinted. Only existing neighboring frames appear. Examples fill the draft; Apply performs the edit." }
        if isFrameActionDraft { return "Select the frame and stop playback before opening Spatter. Add blank frame. or Add 12 blank frames. inserts 1–96 blank frames after it in one Undo step. Duplicate active frame 12 times. adds up to 96 editable copies with the original exposure. Move and delete target only the active frame; moving past an end or deleting the last frame rejects. Choosing an example only fills the draft; Apply performs the edit." }
        if isLayerOrderDraft { return "Use Move active layer up. or Move active layer down. Select the target layer before opening Spatter. The top layer cannot move up and the bottom layer cannot move down; those requests reject without editing." }
        if isOrderDraft { return "Select artwork with Move before opening Spatter. Use Bring selected artwork forward. or Send selected artwork backward. Mixed selection must explicitly include its image. Selected layers must be visible and unlocked; Apply rechecks the exact selection." }
        if isImageDraft { return "Select one image with Move before opening Spatter. Deselect drawings and stop playback. Use Flip selected image horizontally. or Flip selected image vertically. The layer must be visible and unlocked. Apply checks the exact selection again; choosing an example only fills the draft." }
        return
        isLayerDraft ? "Select the target layer before opening Spatter. Use Duplicate active layer., Rename active layer to \"Foreground\"., or Set active layer opacity to 50%. Names have 1–120 characters; quoted text is only a name. Opacity is 0–100%. Use Hide active layer. or Show active layer. to change visibility without changing artwork or lock settings. Apply validates the captured layer and revision; Undo reverses the complete edit." : isErasureDraft ? "Select drawings before opening Spatter. Use canvas percentages, hard or soft mode, size 1–512 pixels and strength 0–100%. Every selected layer must be visible and unlocked, without backdrop-dependent effects or alpha paint. Apply adds masks; it adds no frames." : isGlowDraft ? "Use a six-digit #RRGGBB color, radius 0–128 canvas pixels and strength 0–100%. Disable preserves the stored style. Select the target layer before opening Spatter; Apply changes only that layer." : isRenameDraft ? "Use one name in double quotes, with 1–120 characters and no control characters. Stop playback before applying. The quoted name is text, never another instruction." : isTwoActorDraft ? "Give each actor its own color, action and direction. Use 12–60 project FPS; duration must fit 8–24 ticks. Longer durations reject without stretching poses. No soundtrack or publication is generated." : isAudioDraft
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
                Text("LOCAL EDITS").font(.specialElite(12, relativeTo: .caption))
            }
            .foregroundColor(.red).padding(16)

            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(isSelectionDraft ? "Transform selected drawings" : isImageEditDraft ? "Edit selected image" : isTextUpdateDraft ? "Edit selected text" : isDuplicateRangeDraft ? "Duplicate frame range" : isReverseDraft ? "Reverse frame range" : isNavigationDraft ? "Select frame or layer" : isGridDraft ? "Edit grid guides" : isOnionDraft ? "Edit onion-skin guides" : isFrameActionDraft ? "Edit active frame" : isLayerOrderDraft ? "Move active layer" : isOrderDraft ? "Order selected artwork" : isImageDraft ? "Flip selected image" : isLayerDuplicateDraft ? "Duplicate active layer" : isLayerUpdateDraft ? "Edit active layer" : isExposureDraft ? "Edit selected frame exposure" : isErasureDraft ? "Erase selected drawings" : isGlowDraft ? "Edit active layer glow" : isRenameDraft ? "Rename current project" : isAudioDraft ? "Edit selected audio" : "Create local motion")
                        .font(.specialElite(20, relativeTo: .title3))
                    Text(editDescription)
                        .font(.subheadline)
                    Text("Use a complete example. These local edits create supported motion, edit selected audio, flip a selected image, rename the project, change frame exposure, edit layers or erase selected drawings. Open-ended AI briefs remain unfinished. Export renders the resulting project. Nothing publishes automatically.")
                        .font(.caption).foregroundColor(.white.opacity(0.7))

                    Text(exampleText).font(.specialElite(12, relativeTo: .caption))
                        .textSelection(.enabled).padding(12)
                        .background(Color(hex: "1A1A24")).cornerRadius(10)
                    Button(isFrameActionDraft || isOrderDraft || isImageDraft || isLayerDraft || isExposureDraft || isAudioDraft || isRenameDraft || isErasureDraft || isGlowDraft ? "Use motion example in draft" : "Use example in draft") { draft = isBriefDraft ? SpatterSceneBrief.example : isStickDraft ? SpatterStickFigureRecipe.Action.walking.example : example }
                        .disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.motion.example")
                    Menu("Use an artwork order instruction") {
                        Button("Bring selected artwork forward") { draft = SpatterArtworkOrderInstruction.forwardExample }
                        Button("Send selected artwork backward") { draft = SpatterArtworkOrderInstruction.backwardExample }
                    }
                    .disabled(session.isWorking || session.isClosed)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("spatter.artwork.order-examples")
                    Menu("Use an image flip instruction") {
                        Button("Flip selected image horizontally") { draft = SpatterImageReflectionInstruction.horizontalExample }
                            .accessibilityIdentifier("spatter.image.horizontal-example")
                        Button("Flip selected image vertically") { draft = SpatterImageReflectionInstruction.verticalExample }
                            .accessibilityIdentifier("spatter.image.vertical-example")
                    }
                    .frame(minHeight: 44)
                    .disabled(session.isWorking || session.isClosed || selectedImage == nil)
                    .accessibilityIdentifier("spatter.image.examples")
                    if isImageDraft || isImageEditDraft || selectedImage == nil {
                        Text(selectedImage.map { image in
                            "Selected image on " + (vm.layers.first { $0.id == image.placement.layerID }?.name ?? "Unavailable layer")
                        } ?? "For image edits, select one image with Move before opening Spatter.")
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                        .accessibilityIdentifier("spatter.image.target")
                    }
                    Menu("Use an image edit instruction") {
                        Button("Rotate selected image clockwise") { draft = SpatterImageRotationInstruction.clockwiseExample }
                        Button("Rotate selected image counterclockwise") { draft = SpatterImageRotationInstruction.counterclockwiseExample }
                        Button("Crop selected image") { draft = SpatterImageCropInstruction.example }
                        Button("Place selected image") { draft = SpatterImagePlacementInstruction.example }
                        Button("Place selected image with angle") { draft = SpatterImagePlacementInstruction.angleExample }
                    }
                    .frame(minHeight: 44)
                    .disabled(session.isWorking || session.isClosed || selectedImage == nil)
                    .accessibilityIdentifier("spatter.image.edit-examples")
                    Menu("Use a selected drawings instruction") {
                        Button("Move selected drawings") { draft = SpatterSelectionTranslateInstruction.example }
                        Button("Scale and rotate selected drawings") { draft = SpatterSelectionTransformInstruction.example }
                        Button("Scale selected drawings") { draft = SpatterSelectionTransformInstruction.scaleExample }
                        Button("Rotate selected drawings") { draft = SpatterSelectionTransformInstruction.rotateExample }
                        Button("Flip selected drawings horizontally") { draft = SpatterSelectionReflectInstruction.horizontalExample }
                        Button("Flip selected drawings vertically") { draft = SpatterSelectionReflectInstruction.verticalExample }
                    }
                    .frame(minHeight: 44)
                    .disabled(session.isWorking || session.isClosed)
                    .accessibilityIdentifier("spatter.selection.transform-examples")
                    Menu("Use a selected text instruction") {
                        Button("Set selected text") { draft = SpatterTextUpdateInstruction.example }
                        Button("Set selected text and color") { draft = SpatterTextUpdateInstruction.colorExample }
                    }
                    .frame(minHeight: 44)
                    .disabled(session.isWorking || session.isClosed)
                    .accessibilityIdentifier("spatter.text.examples")
                    if isSelectionDraft || isTextUpdateDraft {
                        Text("Selected drawings: \(vm.selectedElementIDs.count)")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                            .accessibilityIdentifier("spatter.selection.transform-targets")
                    }
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
                    Button("Use duplicate frame range example") { draft = SpatterFrameDuplicateRangeInstruction.example }
                        .frame(minHeight: 44).disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.frame.duplicate-range-example")
                    Button("Use reverse frame range example") { draft = SpatterFrameReverseInstruction.example }
                    Button("Use frame range timing example") { draft = SpatterFrameExposureInstruction.rangeExample }
                        .frame(minHeight:44).disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.frame.exposure-range-example")
                    Menu("Use an audio track instruction") {
                        Button("Track volume") { draft = SpatterAudioTrackInstruction.volumeExample }
                        Button("Mute track") { draft = SpatterAudioTrackInstruction.muteExample }
                        Button("Unmute track") { draft = SpatterAudioTrackInstruction.unmuteExample }
                        Button("Pan track") { draft = SpatterAudioTrackInstruction.panExample }
                        Button("Center track pan") { draft = SpatterAudioTrackInstruction.centerExample }
                        Button("Solo track") { draft = SpatterAudioTrackInstruction.soloExample }
                        Button("Unsolo track") { draft = SpatterAudioTrackInstruction.unsoloExample }
                    }.frame(minHeight: 44).disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.audio.track-examples")
                    Button("Use cut current frame example") { draft = SpatterFrameCutInstruction.example }
                    Button("Use duplicate selected drawings example") { draft = SpatterDrawingDuplicateInstruction.example }
                        .frame(minHeight: 44).disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.selection.duplicate-example")
                    Button("Use selected eraser example") { draft = SpatterSelectedErasureInstruction.example }
                        .disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.selection.erase-example")
                    if isErasureDraft {
                        Text("Selected drawings: \(vm.selectedElementIDs.count)")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                            .accessibilityIdentifier("spatter.selection.erase-targets")
                    }
                    Menu("Use a frame or layer selection instruction") {
                        Button("Select frame 1") { draft = SpatterNavigationInstruction.frameExample }
                        Button("Select layer 1") { draft = SpatterNavigationInstruction.layerExample }
                    }
                    .frame(minHeight:44).disabled(session.isWorking || session.isClosed)
                    .accessibilityIdentifier("spatter.navigation.examples")
                    Button("Use layer rename example") { draft = SpatterLayerUpdateInstruction.renameExample }
                        .frame(minHeight:44).disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.layer.rename-example")
                    Button("Use layer opacity example") { draft = SpatterLayerUpdateInstruction.opacityExample }
                        .frame(minHeight:44).disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.layer.opacity-example")
                    Menu("Use a layer lock instruction") {
                        Button("Unlock editing") { draft = SpatterLayerUpdateInstruction.lockExample(.free) }
                        Button("Lock all artwork editing") { draft = SpatterLayerUpdateInstruction.lockExample(.full) }
                        Button("Lock artwork position") { draft = SpatterLayerUpdateInstruction.lockExample(.position) }
                        Button("Preserve existing alpha") { draft = SpatterLayerUpdateInstruction.lockExample(.alpha) }
                    }
                    .frame(minHeight:44).disabled(session.isWorking || session.isClosed)
                    .accessibilityIdentifier("spatter.layer.lock-examples")
                    Menu("Use a layer blend instruction") {
                        ForEach(SpatterLayerUpdateInstruction.blendModes, id: \.rawValue) { mode in
                            Button(mode.title) { draft = SpatterLayerUpdateInstruction.blendExample(mode) }
                        }
                    }
                    .frame(minHeight:44).disabled(session.isWorking || session.isClosed)
                    .accessibilityIdentifier("spatter.layer.blend-examples")
                    Menu("Use a layer order instruction") {
                        Button("Move active layer up") { draft = SpatterLayerOrderInstruction.upExample }
                        Button("Move active layer down") { draft = SpatterLayerOrderInstruction.downExample }
                    }
                    .frame(minHeight:44).disabled(session.isWorking || session.isClosed)
                    .accessibilityIdentifier("spatter.layer.order-examples")
                    Menu("Use a layer visibility instruction") {
                        Button("Hide active layer") { draft = SpatterLayerUpdateInstruction.hideExample }
                        Button("Show active layer") { draft = SpatterLayerUpdateInstruction.showExample }
                    }
                    .frame(minHeight:44).disabled(session.isWorking || session.isClosed)
                    .accessibilityIdentifier("spatter.layer.visibility-examples")
                    Button("Use layer duplicate example") { draft = SpatterLayerDuplicateInstruction.example }
                        .frame(minHeight:44)
                        .disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.layer.duplicate-example")
                    Menu("Use a grid instruction") {
                        Button("Show grid") { draft = SpatterGridInstruction.showExample }
                        Button("Hide grid") { draft = SpatterGridInstruction.hideExample }
                        Button("Configure grid") { draft = SpatterGridInstruction.settingsExample }
                    }.frame(minHeight:44).disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.grid.examples")
                    Menu("Use an onion-skin instruction") {
                        Button("Show onion skin") { draft = SpatterOnionInstruction.showExample }
                        Button("Hide onion skin") { draft = SpatterOnionInstruction.hideExample }
                        Button("Configure onion skin") { draft = SpatterOnionInstruction.settingsExample }
                    }.frame(minHeight:44).disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.onion.examples")
                    Menu("Create or delete a layer") {
                        Button(SpatterLayerStructureInstruction.addExample) { draft = SpatterLayerStructureInstruction.addExample }
                        Button(SpatterLayerStructureInstruction.deleteExample) { draft = SpatterLayerStructureInstruction.deleteExample }
                    }.frame(minHeight: 44).disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.layer.structure-examples")
                    Menu("Use an active frame instruction") {
                        Button("Add 12 blank frames.") { draft = "Add 12 blank frames." }
                        Button("Duplicate active frame 12 times.") { draft = "Duplicate active frame 12 times." }
                        ForEach(SpatterFrameActionInstruction.Action.allCases, id: \.rawValue) { action in
                            Button(action.example) { draft = action.example }
                        }
                    }
                    .frame(minHeight:44).disabled(session.isWorking || session.isClosed)
                    .accessibilityIdentifier("spatter.frame.action-examples")
                    Button("Use frame exposure example") { draft = SpatterFrameExposureInstruction.example }
                        .frame(minHeight: 44)
                        .disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.frame.exposure-example")
                    Button("Use project rename example") { draft = SpatterProjectRenameInstruction.example }
                        .frame(minHeight: 44)
                        .disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.project.rename-example")
                    Text(isImageDraft ? "Image edits affect only the selected instance." : isLayerDraft ? "Active layer: " + (vm.layers.first { $0.id == vm.activeLayerID }?.name ?? "Unavailable") : (vm.selectedCurrentAudioClip.map { "Audio target: " + $0.soundName }
                         ?? "For audio edits, select a clip in Audio before opening Spatter."))
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
                        .font(.specialElite(17, relativeTo: .body))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 150)
                        .padding(8).background(Color(hex: "1A1A24")).cornerRadius(10)
                        .disabled(session.isWorking || session.isClosed)
                        .accessibilityLabel("Local Studio instruction")
                        .accessibilityIdentifier("spatter.motion.input")
                        .focused($draftFocused)
                        .id("spatter-instruction-editor")
                    Text("\(draft.utf8.count) / 1,024 bytes · " + (isFrameActionDraft ? "Active frame" : isOrderDraft ? "Selected artwork" : isImageDraft ? "Selected image" : isLayerDraft ? "Active layer" : isExposureDraft ? "Selected frame · \(vm.fps) FPS" : isErasureDraft ? "Selected drawings" : isGlowDraft ? "Active layer glow" : isRenameDraft ? "Project name" : isAudioDraft ? "Selected audio clip" : "\(vm.fps) FPS"))
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
                        Text(notice).font(.specialElite(15, relativeTo: .subheadline))
                            .accessibilityIdentifier("spatter.motion.result")
                    }
                    if session.appliedEdit != nil {
                        Text(session.saveState(in: vm, currentScope: scope).text)
                            .font(.caption)
                            .accessibilityIdentifier("spatter.motion.save-state")
                        Button("Save project") { Task { _ = await vm.save() } }
                            .disabled(!receiptIsCurrent || vm.isSaving)
                            .accessibilityIdentifier("spatter.motion.save")
                        // Offered only while the document revision still equals the receipt
                        // revision; otherwise the session explains that the document changed.
                        Button("Undo Spatter edit") { session.undoAppliedEdit(in: vm, currentScope: scope) }
                            .disabled(!session.canUndoAppliedEdit(in: vm, currentScope: scope))
                            .accessibilityIdentifier("spatter.motion.undo")
                        if let edit = session.appliedEdit, vm.document.id == edit.receipt.projectID, vm.document.revision != edit.receipt.revision {
                            Text("The document changed after this Spatter edit (revision \(vm.document.revision) vs \(edit.receipt.revision)). Use Studio's Undo history to step back through later changes.")
                                .font(.caption).foregroundColor(.white.opacity(0.7))
                                .accessibilityIdentifier("spatter.motion.undo-unavailable")
                        }
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
                    if let movieState { SpatterExportReceiptView(state: movieState) }
                    if let message = vm.message {
                        Text(message).font(.caption).foregroundColor(.white.opacity(0.8))
                            .accessibilityIdentifier("spatter.motion.project-status")
                    }
                    Divider().overlay(Color.white.opacity(0.2)).padding(.top, 8)
                    Text("Other Studio actions")
                        .font(.specialElite(17, relativeTo: .headline))
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
            .onChange(of: draftFocused) { focused in
                if focused { proxy.scrollTo("spatter-instruction-editor", anchor: .top) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                // The containing Studio can retain its full-height geometry while
                // the keyboard covers it. Keep the focused editor above the keys.
                if draftFocused { proxy.scrollTo("spatter-instruction-editor", anchor: .top) }
            }
            }
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

// MARK: - Export receipt from the real movie session (#215)

extension SpatterExportReceipt {
    /// Builds a receipt only for a still-owned, verified direct export whose
    /// manifest matches the Spatter request. Nil means "no factual receipt",
    /// never a placeholder. The GIF session has no direct-request path yet.
    @MainActor
    static func make(from state: StudioMoviePanelState) -> SpatterExportReceipt? {
        guard let request = state.directSource, let output = state.session.output,
              !state.session.isRunning, !state.session.needsCleanup, !state.session.isClosed, !output.isCleaned,
              output.manifest.projectID == request.projectID, output.manifest.documentRevision == request.revision,
              output.manifest.durationDenominator > 0, let urls = try? output.checkedURLs(), let movieURL = urls.first else { return nil }
        let duration = Double(output.manifest.durationNumerator) / Double(output.manifest.durationDenominator)
        return try? SpatterExportReceipt.make(editRequestID: request.editRequestID, revision: request.revision, fileURL: movieURL,
            expectedByteCount: output.manifest.encodedBytes, durationSeconds: duration, frameCount: output.manifest.frameIDs.count)
    }
}

/// Read-only display of the last verified direct export receipt.
struct SpatterExportReceiptView: View {
    @ObservedObject var state: StudioMoviePanelState
    var body: some View {
        if let receipt = SpatterExportReceipt.make(from: state) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Verified MP4 receipt").font(.specialElite(12, relativeTo: .caption))
                Text(receipt.summary).font(.caption).textSelection(.enabled)
                Text("Measured from the real output file. Export creates a device file only; nothing was published.")
                    .font(.caption2).foregroundColor(.white.opacity(0.6))
            }
            .accessibilityIdentifier("spatter.motion.export-receipt")
        } else if let error = state.directError {
            Text(error).font(.caption).foregroundColor(.white.opacity(0.8))
                .accessibilityIdentifier("spatter.motion.export-receipt-error")
        }
    }
}
