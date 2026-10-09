import SwiftUI

struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var authVM: AuthViewModel
    @State private var username = ""
    @State private var bio = ""
    @State private var capture: AuthService.ProfileEditCapture?
    @State private var saveTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Username").font(.specialElite(14))
                    TextField("Your username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("profile.edit.username")
                    Text("Bio").font(.specialElite(14))
                    TextEditor(text: $bio).frame(minHeight: 120)
                        .accessibilityIdentifier("profile.edit.bio")
                    Text("Name: 1–80 characters. Bio: up to 500 characters. Avatar and portfolio editing are not available here.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let notice { Text(notice).foregroundStyle(.red).accessibilityIdentifier("profile.edit.notice") }
                    Button {
                        guard let captured = capture, !isSaving else { return }
                        let name = username, biography = bio
                        isSaving = true; notice = nil
                        saveTask = Task { @MainActor in
                            defer { isSaving = false; saveTask = nil }
                            do {
                                _ = try await authVM.saveProfile(username: name, bio: biography, capture: captured)
                                guard !Task.isCancelled, capture == captured, scenePhase == .active else { return }
                                dismiss()
                            } catch {
                                guard !Task.isCancelled, capture == captured else { return }
                                notice = error.localizedDescription
                            }
                        }
                    } label: {
                        HStack { if isSaving { ProgressView() }; Text("Save Profile") }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.disabled(capture == nil || isSaving)
                        .accessibilityIdentifier("profile.edit.save")
                }.padding(20).disabled(isSaving)
            }
            .background(Color.sdBackground).foregroundStyle(.white)
            .navigationTitle("Edit Profile").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { invalidate(); dismiss() }
            } }
        }
        .onAppear {
            capture = authVM.captureProfileEdit()
            username = capture?.username ?? ""; bio = capture?.bio ?? ""
            if capture == nil { notice = "Sign in with an available profile before editing." }
        }
        .onChange(of: authVM.userId) { _ in invalidate(); dismiss() }
        .onChange(of: authVM.state) { _ in
            if !authVM.isAuthenticated { invalidate(); dismiss() }
        }
        .onChange(of: scenePhase) { phase in if phase != .active {
            invalidate(); notice = "Editing paused. Reopen this form before saving. An already submitted update may have reached the server."
        } }
        .onDisappear { invalidate() }
    }
    private func invalidate() { capture = nil; saveTask?.cancel() }
}
