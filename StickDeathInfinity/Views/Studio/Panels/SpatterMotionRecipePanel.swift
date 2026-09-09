import SwiftUI

/// Explicit local editing. Advice and provider responses cannot enter this
/// surface or execute its commands without a separate user submission.
@MainActor
struct SpatterMotionRecipePanel: View {
    @ObservedObject var vm: StudioViewModel
    let onBack: () -> Void
    let onExport: () -> Void
    @EnvironmentObject private var authVM: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = SpatterStudioEditSession()
    @State private var draft = ""
    @State private var isVisible = false
    @State private var isForeground = true
    @FocusState private var draftFocused: Bool

    private let example = "Append 8 frames of a red outlined circle moving from (20%, 50%) to (80%, 50%), radius 8%, line width 3 px."
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
                Text("LOCAL MOTION").font(.system(.caption, design: .monospaced).bold())
            }
            .foregroundColor(.red).padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Create editable circle motion")
                        .font(.system(.title3, design: .monospaced).bold())
                    Text("This local recipe appends 2–24 outlined-circle frames on a new layer. It uses your project's current frame rate and leaves the existing frames in place. One Undo reverses the edit.")
                        .font(.subheadline)
                    Text("Use the complete form below. Other shapes, free-form briefs, video and audio generation are unfinished. This operation stays on this device.")
                        .font(.caption).foregroundColor(.white.opacity(0.7))

                    Text(example).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).padding(12)
                        .background(Color(hex: "1A1A24")).cornerRadius(10)
                    Button("Use example in draft") { draft = example }
                        .disabled(session.isWorking || session.isClosed)
                        .accessibilityIdentifier("spatter.motion.example")
                    Text("Positions use canvas percentages. Radius uses the shorter canvas side; line width is in pixels. The full outline must fit inside the canvas.")
                        .font(.caption).foregroundColor(.white.opacity(0.7))

                    TextEditor(text: $draft)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 150)
                        .padding(8).background(Color(hex: "1A1A24")).cornerRadius(10)
                        .disabled(session.isWorking || session.isClosed)
                        .accessibilityLabel("Local motion instruction")
                        .accessibilityIdentifier("spatter.motion.input")
                        .focused($draftFocused)
                    Text("\(draft.utf8.count) / 1,024 bytes · \(vm.fps) FPS")
                        .font(.caption).foregroundColor(.white.opacity(0.6))
                    Button("Add editable frames") {
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
                        Button("Open PNG export") {
                            guard receiptIsCurrent else { return }
                            session.close(); onExport()
                        }
                        .disabled(!receiptIsCurrent || vm.isSaving)
                        .accessibilityIdentifier("spatter.motion.export")
                        Text("Export opens Studio's PNG sequence / spritesheet controls. A file is created only when that export finishes. MP4, GIF and mixed audio export are unfinished.")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                    }
                    if let message = vm.message {
                        Text(message).font(.caption).foregroundColor(.white.opacity(0.8))
                            .accessibilityIdentifier("spatter.motion.project-status")
                    }
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
