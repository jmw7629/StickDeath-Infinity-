import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Uses the original Add Picture surface with actual picker, decoding and
/// document commands. Provider transfer is distinct from applying an image.
@MainActor
struct StudioImageImportPanel: View {
    @ObservedObject var vm: StudioViewModel
    @EnvironmentObject private var authVM: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = StudioImageImportSession()
    @StateObject private var scopeHolder = StudioImagePanelScopeHolder()
    @State private var isVisible = false
    @State private var filesRequest: StudioImagePickerRequest?
    @State private var photosRequest: StudioImagePickerRequest?

    private var scope: StudioImageImportSession.Scope {
        .init(isStudioVisible: isVisible && vm.isEditing && vm.activePanel == .addImage,
              isForeground: scenePhase == .active, accountID: authVM.userId)
    }

    private func refreshScope() {
        scopeHolder.value = scope
        session.refreshScope(scopeHolder.value)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Add Picture", icon: "photo.fill") {
                session.close(); vm.activePanel = .none
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Add one picture to the current frame")
                        .font(.specialElite(18)).foregroundColor(.white)
                    Text("Choose a still JPEG, PNG or HEIF image up to 16 MB and 16 megapixels. Inspect the decoded picture, then add it on its own layer. Existing drawing stays above it; one Undo removes the import.")
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                    AddImageOption(icon: "photo.on.rectangle.angled", title: "Photo Library", subtitle: "Choose a picture using the system picker") {
                        guard let token = session.beginPicker(in: vm, scope: scope) else { return }
                        refreshScope(); photosRequest = .init(id: token)
                    }
                    .disabled(session.isClosed || session.isWorking || filesRequest != nil || photosRequest != nil)
                    .accessibilityIdentifier("studio.image.photos")
                    AddImageOption(icon: "folder.fill", title: "Files", subtitle: "Import an image from Files") {
                        guard let token = session.beginPicker(in: vm, scope: scope) else { return }
                        refreshScope(); filesRequest = .init(id: token)
                    }
                    .disabled(session.isClosed || session.isWorking || filesRequest != nil || photosRequest != nil)
                    .accessibilityIdentifier("studio.image.files")
                    if session.isWorking {
                        ProgressView(session.progressText ?? "Preparing the selected picture…")
                            .tint(.red).foregroundColor(.white)
                        Button("Cancel image import") { session.cancel() }
                            .foregroundColor(.red)
                            .accessibilityIdentifier("studio.image.cancel")
                    }
                    if let preview = session.preview {
                        if let image = session.previewImage {
                            Image(image, scale: 1, label: Text("Decoded image preview"))
                                .resizable().scaledToFit().frame(maxHeight: 220)
                                .frame(maxWidth: .infinity)
                                .background(Color.white.opacity(0.08)).cornerRadius(10)
                                .accessibilityLabel("Decoded image preview")
                                .accessibilityIdentifier("studio.image.preview")
                        }
                        Text(preview.name).font(.specialElite(15)).foregroundColor(.white)
                        Text("\(preview.width) × \(preview.height) pixels · orientation corrected")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                            .accessibilityIdentifier("studio.image.dimensions")
                        Text("Fits inside the canvas without cropping. Files preserves the selected file bytes. Photos preserves the still image provided by the picker, without paired Live Photo motion or audio. Studio uses an SDR PNG; animated images, depth and HDR effects are not included.")
                            .font(.caption).foregroundColor(.white.opacity(0.6))
                        Button("Add to current frame") { _ = session.apply(currentScope: scope) }
                            .buttonStyle(.borderedProminent).tint(.red)
                            .disabled(!session.canApply(currentScope: scope))
                            .accessibilityIdentifier("studio.image.apply")
                    }
                    if let notice = session.notice {
                        Text(notice).font(.subheadline).foregroundColor(.white)
                            .accessibilityIdentifier("studio.image.result")
                    }
                    Text(session.saveState(in: vm, currentScope: scope).text)
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                        .accessibilityIdentifier("studio.image.save-state")
                    Button("Save project") { Task { _ = await vm.save() } }
                        .disabled(!scope.isStudioVisible || !scope.isForeground || vm.isSaving || session.isWorking)
                        .foregroundColor(.red)
                        .accessibilityIdentifier("studio.image.save")
                    if let message = vm.message {
                        Text(message).font(.caption).foregroundColor(.white.opacity(0.7))
                    }
                    Divider().overlay(Color.white.opacity(0.2))
                    AddImageOption(icon: "camera.fill", title: "Take Photo", subtitle: "Camera capture is not available yet", action: {})
                        .disabled(true).opacity(0.45)
                    AddImageOption(icon: "doc.on.clipboard.fill", title: "Paste from Clipboard", subtitle: "Clipboard image import is not available yet", action: {})
                        .disabled(true).opacity(0.45)
                }
                .padding(24)
            }
            .accessibilityIdentifier("studio.image.scroll")
        }
        .background(Color(hex: "0A0A0F"))
        .background {
            if let request = filesRequest {
                StudioImageFilePicker(request: request) { token, result in
                    guard filesRequest?.id == token else { return }
                    filesRequest = nil
                    switch result {
                    case .success(let urls):
                        guard urls.count == 1, let url = urls.first else {
                            session.pickerCancelled(token: token); return
                        }
                        let holder = scopeHolder
                        _ = session.receiveFile(url, token: token, currentScope: { holder.value })
                    case .failure(let error): session.pickerFailed(error, token: token)
                    }
                } onCancellation: { token in
                    session.pickerCancelled(token: token)
                    if filesRequest?.id == token { filesRequest = nil }
                }
                .id(request.id)
            }
        }
        .sheet(item: $photosRequest) { request in
            StudioPhotoPicker { provider in
                guard photosRequest?.id == request.id else { return }
                photosRequest = nil
                let holder = scopeHolder
                if let provider {
                    _ = session.receivePhoto(provider, token: request.id, currentScope: { holder.value })
                } else { session.pickerCancelled(token: request.id) }
            }
            .id(request.id)
            .onDisappear {
                session.pickerCancelled(token: request.id)
                if photosRequest?.id == request.id { photosRequest = nil }
            }
        }
        .onAppear { isVisible = true; refreshScope() }
        .onDisappear {
            isVisible = false; refreshScope(); session.close()
            if vm.activePanel == .addImage { vm.activePanel = .none }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.cancel() }
            refreshScope()
        }
        .onChange(of: authVM.userId) {
            refreshScope(); session.close(); filesRequest = nil; photosRequest = nil
            if vm.activePanel == .addImage { vm.activePanel = .none }
        }
        .onChange(of: vm.document.id) { refreshScope() }
        .onChange(of: vm.document.revision) { refreshScope() }
        .onChange(of: vm.activePanel) { refreshScope() }
        .onChange(of: vm.isEditing) { refreshScope() }
    }
}

/// Pending provider callbacks retain only this scalar context, never the panel
/// or its observed editor. The session owns a weak editor reference.
@MainActor
private final class StudioImagePanelScopeHolder: ObservableObject {
    var value = StudioImageImportSession.Scope(isStudioVisible: false, isForeground: false, accountID: nil)
}

private struct StudioImagePickerRequest: Identifiable {
    let id: UUID
}

/// A new child has its own immutable request and native presentation binding.
/// Old completion/cancellation closures can only deliver their original token.
private struct StudioImageFilePicker: View {
    let request: StudioImagePickerRequest
    let completion: (UUID, Result<[URL], Error>) -> Void
    let onCancellation: (UUID) -> Void
    @State private var isPresented = true
    var body: some View {
        Color.clear
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.jpeg, .png, .heic, .heif],
                          allowsMultipleSelection: false) { result in
                completion(request.id, result)
            } onCancellation: {
                onCancellation(request.id)
            }
    }
}

private struct StudioPhotoPicker: UIViewControllerRepresentable {
    let completion: (NSItemProvider?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let completion: (NSItemProvider?) -> Void
        private var finished = false
        init(completion: @escaping (NSItemProvider?) -> Void) { self.completion = completion }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !finished else { return }
            finished = true
            completion(results.count == 1 ? results.first?.itemProvider : nil)
        }
    }
}
