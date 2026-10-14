import SwiftUI
import PhotosUI

/// Genuine profile editing: username (public handle rules checked before the
/// save), bio and an avatar chosen from Photos, downscaled on device and
/// uploaded to the account's own storage path. The server confirms every
/// change; nothing is shown as saved until it does.
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
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarPreview: Image?
    @State private var avatarUploading = false
    @State private var avatarNotice: String?
    private var handleProblem: String? { CreatorHandle.validate(username) }
    private var canSave: Bool { capture != nil && !isSaving && !avatarUploading && handleProblem == nil && bio.count <= 500 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Avatar").communitySubheading()
                    HStack(spacing: 14) {
                        Group {
                            if let avatarPreview {
                                avatarPreview.resizable().scaledToFill()
                            } else {
                                AsyncImage(url: currentAvatarURL) { image in image.resizable().scaledToFill() } placeholder: {
                                    Text(String(username.prefix(2)).uppercased()).font(.specialElite(22, relativeTo: .title2))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(StudioCraftTheme.field)
                                }
                            }
                        }
                        .frame(width: 72, height: 72).clipShape(Circle())
                        .overlay(Circle().stroke(StudioCraftTheme.accent, lineWidth: 2))
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            PhotosPicker(selection: $avatarItem, matching: .images, photoLibrary: .shared()) {
                                Label(avatarUploading ? "Uploading…" : "Choose from Photos", systemImage: "photo").frame(minHeight: 44)
                            }
                            .buttonStyle(CommunitySecondaryButtonStyle())
                            .disabled(avatarUploading || isSaving || capture == nil)
                            .accessibilityIdentifier("profile.edit.avatar-picker")
                            if currentAvatarURL != nil || avatarPreview != nil {
                                Button(role: .destructive) { Task { await removeAvatar() } } label: {
                                    Label("Remove avatar", systemImage: "trash").frame(minHeight: 44)
                                }
                                .disabled(avatarUploading || isSaving || capture == nil)
                                .accessibilityIdentifier("profile.edit.avatar-remove")
                            }
                            Text("Square JPEG up to \(AvatarImagePolicy.maximumSide) px and \(AvatarImagePolicy.maximumBytes / 1024) KB, stored under your account only. The original photo stays on this device.")
                                .communityCaption()
                        }
                    }
                    if let avatarNotice { CommunityMessage(text: avatarNotice, kind: avatarNotice.hasPrefix("Avatar updated") ? .success : .error).accessibilityIdentifier("profile.edit.avatar-notice") }
                    Text("Username").communitySubheading()
                    TextField("Your username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .communityField()
                        .accessibilityIdentifier("profile.edit.username")
                    if let handleProblem, !username.isEmpty { CommunityMessage(text: handleProblem, kind: .error).accessibilityIdentifier("profile.edit.username-problem") }
                    Text("3–30 letters, digits or underscores, starting with a letter or digit. Reserved names are not allowed.").communityCaption()
                    Text("Bio").communitySubheading()
                    TextEditor(text: $bio).frame(minHeight: 120).scrollContentBackground(.hidden)
                        .padding(8).background(StudioCraftTheme.field)
                        .clipShape(RoundedRectangle(cornerRadius: StudioCraftTheme.radius))
                        .accessibilityIdentifier("profile.edit.bio")
                    Text("\(bio.count)/500 characters").communityCaption()
                    if let notice { CommunityMessage(text: notice, kind: .error).accessibilityIdentifier("profile.edit.notice") }
                    Button {
                        guard let captured = capture, canSave else { return }
                        let name = username.trimmingCharacters(in: .whitespacesAndNewlines), biography = bio
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
                        HStack { if isSaving { ProgressView().tint(.white) }; Text("Save Profile") }
                    }
                    .buttonStyle(CommunityPrimaryButtonStyle()).disabled(!canSave)
                    .accessibilityIdentifier("profile.edit.save")
                }.padding(20).disabled(isSaving)
            }
            .communityScreen()
            .navigationTitle("Edit Profile").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { invalidate(); dismiss() }
            } }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            capture = authVM.captureProfileEdit()
            username = capture?.username ?? ""; bio = capture?.bio ?? ""
            if capture == nil { notice = "Sign in with an available profile before editing." }
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task { await uploadAvatar(item) }
        }
        .onChange(of: authVM.userId) { _, _ in invalidate(); dismiss() }
        .onChange(of: authVM.state) { _, _ in
            if !authVM.isAuthenticated { invalidate(); dismiss() }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active {
            invalidate(); notice = "Editing paused. Reopen this form before saving. An already submitted update may have reached the server."
        } }
        .onDisappear { invalidate() }
    }
    private var currentAvatarURL: URL? { CommunityMediaURL.checked(authVM.user?.avatarURL) }
    private func invalidate() { capture = nil; saveTask?.cancel() }

    @MainActor private func removeAvatar() async {
        guard !avatarUploading, let captured = capture else { return }
        avatarUploading = true; avatarNotice = nil
        defer { avatarUploading = false }
        do {
            let result = try await AvatarUploadService.remove(account: captured.userID)
            guard capture == captured else { return }
            avatarPreview = nil
            switch result {
            case .removed: avatarNotice = "Avatar updated: removed from your profile and storage."
            case .profileClearedFileRetained: avatarNotice = "Avatar updated: removed from your profile. The stored file could not be deleted; your next avatar upload replaces it."
            }
        } catch {
            guard capture == captured else { return }
            avatarNotice = (error as? LocalizedError)?.errorDescription ?? "The avatar was not changed."
        }
    }

    @MainActor private func uploadAvatar(_ item: PhotosPickerItem) async {
        guard !avatarUploading, let captured = capture else { return }
        avatarUploading = true; avatarNotice = nil
        defer { avatarUploading = false; avatarItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw AvatarUploadService.Failure.unreadable }
            let prepared = try AvatarUploadService.prepare(imageData: data)
            guard capture == captured else { return }
            let url = try await AvatarUploadService.upload(prepared, account: captured.userID)
            guard capture == captured else { return }
            if let image = UIImage(data: prepared.jpeg) { avatarPreview = Image(uiImage: image) }
            avatarNotice = "Avatar updated (\(prepared.width)×\(prepared.height), \(prepared.jpeg.count / 1024) KB) at \(url.host ?? "storage")."
        } catch {
            guard capture == captured else { return }
            avatarPreview = nil
            avatarNotice = (error as? LocalizedError)?.errorDescription ?? "The avatar was not changed."
        }
    }
}
