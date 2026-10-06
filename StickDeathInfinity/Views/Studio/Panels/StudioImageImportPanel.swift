import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// Uses the original Add Picture surface with actual picker, decoding and
/// document commands. Provider transfer is distinct from applying an image.
@MainActor
struct StudioImageImportPanel: View {
    @ObservedObject var vm: StudioViewModel
    var videoFrameMode = false
    @EnvironmentObject private var authVM: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = StudioImageImportSession()
    @StateObject private var scopeHolder = StudioImagePanelScopeHolder()
    @State private var isVisible = false
    @State private var filesRequest: StudioImagePickerRequest?
    @State private var photosRequest: StudioImagePickerRequest?
    @State private var libraryRequest: StudioImagePickerRequest?
    @State private var cameraRequest: StudioImagePickerRequest?
    @State private var cameraPermissionToken: UUID?
    @State private var cameraAuthorized = false
    @FocusState private var timingFieldFocused: Bool
    @State private var sourceStart = 0.0
    @State private var sourceEnd = 1.0
    @State private var projectStart = 0.0
    @State private var playbackRate = 1.0
    @State private var usesSourceEnd = false

    private var videoMapping: StudioVideoFrameImportService.Mapping {
        .init(sourceStartSeconds: sourceStart, sourceEndSeconds: usesSourceEnd ? sourceEnd : nil,
              projectStartSeconds: projectStart, speed: playbackRate)
    }
    private var mappedTime: Double? {
        try? videoMapping.sourceTime(projectSeconds: Double(vm.document.startTick(ofFrame: vm.currentFrameIndex)) / Double(vm.fps))
    }
    private var timingIsLocked: Bool {
        session.isWorking || session.status == .picking || session.preview != nil
    }
    private var videoTiming: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reference timing").font(.specialElite(16))
            timingField("Source in (seconds)", value: $sourceStart, identifier: "studio.video.source-in")
            Toggle("Trim source end", isOn: $usesSourceEnd).tint(.red)
                .accessibilityIdentifier("studio.video.use-end")
            if usesSourceEnd {
                timingField("Source out (seconds)", value: $sourceEnd, identifier: "studio.video.source-out")
            }
            timingField("Starts in Studio (seconds)", value: $projectStart, identifier: "studio.video.project-start")
            if timingFieldFocused {
                Button("Done editing timing") { timingFieldFocused = false }
                    .foregroundColor(.red)
            }
            Picker("Speed", selection: $playbackRate) {
                ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { rate in
                    Text(String(format: "%g×", rate)).tag(rate)
                }
            }.pickerStyle(.segmented).accessibilityIdentifier("studio.video.speed")
            if let mappedTime {
                Text(String(format: "Current Studio frame → source %.3fs", mappedTime))
                    .font(.caption).accessibilityIdentifier("studio.video.mapped-time")
            } else {
                Text("Adjust the trim or Studio start so the current frame maps inside the source range.")
                    .font(.caption).foregroundColor(.red)
            }
        }
        .foregroundColor(.white).disabled(timingIsLocked)
    }
    private func timingField(_ title: String, value: Binding<Double>, identifier: String) -> some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
                .keyboardType(.decimalPad).focused($timingFieldFocused).multilineTextAlignment(.trailing)
                .frame(width: 110).textFieldStyle(.roundedBorder)
                .foregroundColor(.black).accessibilityIdentifier(identifier)
        }
    }

    private var scope: StudioImageImportSession.Scope {
        .init(isStudioVisible: isVisible && vm.isEditing && vm.activePanel == (videoFrameMode ? .rotoscope : .addImage),
              isForeground: scenePhase == .active, accountID: authVM.userId)
    }

    private func refreshScope() {
        scopeHolder.value = scope
        session.refreshScope(scopeHolder.value)
    }

    private func cancelPendingCamera() {
        guard cameraRequest != nil || cameraPermissionToken != nil else { return }
        cameraRequest = nil; cameraPermissionToken = nil; cameraAuthorized = false
        session.cancel()
    }
    private func beginCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            vm.message = "This device has no available camera. Use Photos, Files or the Image Library."
            return
        }
        guard let token = session.beginPicker(in: vm, scope: scope) else { return }
        refreshScope(); cameraPermissionToken = token; cameraAuthorized = false
        Task { @MainActor in
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
            default: granted = false
            }
            guard cameraPermissionToken == token, !session.isClosed else { return }
            guard granted else {
                cameraPermissionToken = nil
                session.pickerFailed(StudioCameraFailure.permission, token: token)
                return
            }
            cameraAuthorized = true
            presentAuthorizedCamera()
        }
    }
    private func presentAuthorizedCamera() {
        guard cameraAuthorized, let token = cameraPermissionToken else { return }
        guard session.status == .picking, scope.isStudioVisible else {
            cameraPermissionToken = nil; cameraAuthorized = false; return
        }
        guard scope.isForeground else { return }
        cameraPermissionToken = nil; cameraAuthorized = false
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            session.pickerFailed(StudioCameraFailure.unavailable, token: token); return
        }
        cameraRequest = .init(id: token)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: videoFrameMode ? "Rotoscope / Video" : "Add Picture", icon: videoFrameMode ? "film.fill" : "photo.fill") {
                session.close(); vm.activePanel = .none
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(videoFrameMode ? "Trace a video frame" : "Add one picture to the current frame")
                        .font(.specialElite(18)).foregroundColor(.white)
                    Text(videoFrameMode ? "Choose a self-contained MP4 or MOV from Photos or Files, up to 16 MB and 4 megapixels. Extract one frame at the current Studio playhead using the timing below, inspect it, then add it on a separate reference layer. One Undo removes the import." : "Choose a still JPEG, PNG or HEIF image up to 16 MB and 16 megapixels. Inspect the decoded picture, then add it on its own layer. Existing drawing stays above it; one Undo removes the import.")
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                    if videoFrameMode { videoTiming }
                    AddImageOption(icon: "photo.on.rectangle.angled", title: "Photo Library", subtitle: videoFrameMode ? "Choose a video using the system picker" : "Choose a picture using the system picker") {
                        guard let token = session.beginPicker(in: vm, scope: scope, videoMapping: videoFrameMode ? videoMapping : .init()) else { return }
                        refreshScope(); photosRequest = .init(id: token)
                    }
                    .disabled(session.isClosed || session.isWorking || filesRequest != nil || photosRequest != nil || (videoFrameMode && mappedTime == nil))
                    .accessibilityIdentifier("studio.image.photos")
                    AddImageOption(icon: "folder.fill", title: "Files", subtitle: videoFrameMode ? "Choose a video to extract the current frame" : "Import an image from Files") {
                        guard let token = session.beginPicker(in: vm, scope: scope, videoMapping: videoFrameMode ? videoMapping : .init()) else { return }
                        refreshScope(); filesRequest = .init(id: token)
                    }
                    .disabled(session.isClosed || session.isWorking || filesRequest != nil || photosRequest != nil || (videoFrameMode && mappedTime == nil))
                    .accessibilityIdentifier("studio.image.files")
                    if !videoFrameMode {
                    AddImageOption(icon: "square.grid.2x2.fill", title: "Image Library", subtitle: "Free offline scenery, props and effects") {
                        guard let token = session.beginPicker(in: vm, scope: scope, videoMapping: videoFrameMode ? videoMapping : .init()) else { return }
                        refreshScope(); libraryRequest = .init(id: token)
                    }
                    .disabled(session.isClosed || session.isWorking || filesRequest != nil || photosRequest != nil || libraryRequest != nil)
                    .accessibilityIdentifier("studio.image.library")
                    }
                    if session.isWorking {
                        ProgressView(session.progressText ?? "Preparing the selected picture…")
                            .tint(.red).foregroundColor(.white)
                        Button(videoFrameMode ? "Cancel video frame import" : "Cancel image import") { session.cancel() }
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
                        if let attribution = preview.catalogueAttribution {
                            Text("\(attribution["author"] ?? "") · \(attribution["license"] ?? "")")
                                .font(.caption).foregroundColor(.white.opacity(0.7))
                                .accessibilityIdentifier("studio.image.attribution")
                        }
                        Text("\(preview.width) × \(preview.height) pixels · orientation corrected")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                            .accessibilityIdentifier("studio.image.dimensions")
                        Text(videoFrameMode ? "The orientation-corrected SDR reference PNG is saved inside this project. The source movie stays in Photos or Files; the selected trim and speed choose this snapshot, but no movie track or audio is attached. Keep the source movie for future frames." : "Fits inside the canvas without cropping. Files preserves the selected file bytes. Photos preserves the still image provided by the picker, without paired Live Photo motion or audio. Studio uses an SDR PNG; animated images, depth and HDR effects are not included.")
                            .font(.caption).foregroundColor(.white.opacity(0.6))
                        Button("Add to current frame") { _ = session.apply(currentScope: scope) }
                            .buttonStyle(.borderedProminent).tint(.red)
                            .disabled(!session.canApply(currentScope: scope))
                            .accessibilityIdentifier("studio.image.apply")
                    }
                    if videoFrameMode && session.preview != nil {
                        Button("Change reference timing") { session.cancel() }
                            .foregroundColor(.red).accessibilityIdentifier("studio.video.change-timing")
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
                    if videoFrameMode {
                        Text("Camera recording and whole-video timeline import are not available yet.")
                            .font(.caption).foregroundColor(.white.opacity(0.6))
                    } else {
                    AddImageOption(icon: "camera.fill", title: "Take Photo", subtitle: "Capture a still photo, preview it, then add it") { beginCamera() }
                        .disabled(session.isClosed || session.isWorking || session.status == .picking)
                        .accessibilityIdentifier("studio.image.camera")
                    Text("Camera photos are encoded as a still JPEG for preview. They are not saved to Photos or uploaded. Captures above 16 megapixels or 16 MB are rejected.")
                        .font(.caption).foregroundColor(.white.opacity(0.6))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paste an image").font(.specialElite(16)).foregroundColor(.white)
                        Text("Tap Paste to preview one copied JPEG, PNG or HEIF image. Nothing is added until you choose Add to current frame.")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                        StudioClipboardImageControl { providers in
                            guard let token = session.beginPicker(in: vm, scope: scope) else { return }
                            refreshScope()
                            guard providers.count == 1, let provider = providers.first else {
                                session.pickerFailed(NSError(domain: "SDIImagePaste", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "Copy one supported image and tap Paste again."]), token: token)
                                return
                            }
                            let holder = scopeHolder
                            _ = session.receivePhoto(provider, token: token, currentScope: { holder.value })
                        }
                        .frame(width: 150, height: 44)
                        .disabled(session.isClosed || session.isWorking || session.status == .picking)
                    }
                    }
                }
                .padding(24)
            }
            .accessibilityIdentifier("studio.image.scroll")
        }
        .background(Color(hex: "0A0A0F"))
        .background {
            if let request = filesRequest {
                StudioImageFilePicker(request: request, videoFrameMode: videoFrameMode) { token, result in
                    guard filesRequest?.id == token else { return }
                    filesRequest = nil
                    switch result {
                    case .success(let urls):
                        guard urls.count == 1, let url = urls.first else {
                            session.pickerCancelled(token: token); return
                        }
                        let holder = scopeHolder
                        if videoFrameMode {
                            _ = session.receiveVideoFrame(url, token: token, currentScope: { holder.value })
                        } else {
                            _ = session.receiveFile(url, token: token, currentScope: { holder.value })
                        }
                    case .failure(let error): session.pickerFailed(error, token: token)
                    }
                } onCancellation: { token in
                    session.pickerCancelled(token: token)
                    if filesRequest?.id == token { filesRequest = nil }
                }
                .id(request.id)
            }
        }
        .sheet(item: $cameraRequest) { request in
            StudioCameraPicker { result in
                guard cameraRequest?.id == request.id else { return }
                cameraRequest = nil
                switch result {
                case .success(let provider):
                    if let provider {
                        let holder = scopeHolder
                        _ = session.receivePhoto(provider, token: request.id, currentScope: { holder.value })
                    } else { session.pickerCancelled(token: request.id) }
                case .failure(let error): session.pickerFailed(error, token: request.id)
                }
            }
            .id(request.id)
            .presentationDetents([.large])
            .onDisappear {
                session.pickerCancelled(token: request.id)
                if cameraRequest?.id == request.id { cameraRequest = nil }
            }
        }
        .sheet(item: $photosRequest) { request in
            StudioPhotoPicker(videoFrameMode: videoFrameMode) { provider in
                guard photosRequest?.id == request.id else { return }
                photosRequest = nil
                let holder = scopeHolder
                if let provider {
                    if videoFrameMode {
                        _ = session.receiveVideoPhoto(provider, token: request.id, currentScope: { holder.value })
                    } else {
                        _ = session.receivePhoto(provider, token: request.id, currentScope: { holder.value })
                    }
                } else { session.pickerCancelled(token: request.id) }
            }
            .id(request.id)
            .onDisappear {
                session.pickerCancelled(token: request.id)
                if photosRequest?.id == request.id { photosRequest = nil }
            }
        }
        .sheet(item: $libraryRequest) { request in
            StudioImageLibraryView { catalogue, image in
                guard libraryRequest?.id == request.id else { return }
                libraryRequest = nil
                let holder = scopeHolder
                _ = session.receiveLibraryImage(image, from: catalogue, token: request.id, currentScope: { holder.value })
            } onClose: {
                session.pickerCancelled(token: request.id)
                if libraryRequest?.id == request.id { libraryRequest = nil }
            }
            .id(request.id)
            .onDisappear {
                session.pickerCancelled(token: request.id)
                if libraryRequest?.id == request.id { libraryRequest = nil }
            }
        }
        .onAppear { isVisible = true; refreshScope() }
        .onDisappear {
            cameraPermissionToken = nil; cameraAuthorized = false; cameraRequest = nil
            isVisible = false; refreshScope(); session.close()
            if vm.activePanel == (videoFrameMode ? .rotoscope : .addImage) { vm.activePanel = .none }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.cancel(); cameraPermissionToken = nil; cameraAuthorized = false; cameraRequest = nil }
            refreshScope()
            if phase == .active { presentAuthorizedCamera() }
        }
        .onChange(of: authVM.userId) {
            refreshScope(); session.close(); filesRequest = nil; photosRequest = nil; libraryRequest = nil; cameraRequest = nil; cameraPermissionToken = nil; cameraAuthorized = false
            if vm.activePanel == (videoFrameMode ? .rotoscope : .addImage) { vm.activePanel = .none }
        }
        .onChange(of: vm.document.id) { cancelPendingCamera(); refreshScope() }
        .onChange(of: vm.document.revision) { cancelPendingCamera(); refreshScope() }
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
    let videoFrameMode: Bool
    let completion: (UUID, Result<[URL], Error>) -> Void
    let onCancellation: (UUID) -> Void
    @State private var isPresented = true
    var body: some View {
        Color.clear
            .fileImporter(isPresented: $isPresented, allowedContentTypes: videoFrameMode ? [.mpeg4Movie, .quickTimeMovie] : [.jpeg, .png, .heic, .heif],
                          allowsMultipleSelection: false) { result in
                completion(request.id, result)
            } onCancellation: {
                onCancellation(request.id)
            }
    }
}

private struct StudioPhotoPicker: UIViewControllerRepresentable {
    let videoFrameMode: Bool
    let completion: (NSItemProvider?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = videoFrameMode ? .videos : .images
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


/// The system control grants clipboard access only for an explicit paste action.
/// https://developer.apple.com/documentation/uikit/uipastecontrol
private struct StudioClipboardImageControl: UIViewRepresentable {
    var onPaste: ([NSItemProvider]) -> Void
    func makeUIView(context: Context) -> StudioClipboardImageTarget {
        StudioClipboardImageTarget(onPaste: onPaste)
    }
    func updateUIView(_ view: StudioClipboardImageTarget, context: Context) {
        view.onPaste = onPaste
        view.isUserInteractionEnabled = context.environment.isEnabled
        view.alpha = context.environment.isEnabled ? 1 : 0.45
    }
}

private final class StudioClipboardImageTarget: UIView {
    var onPaste: ([NSItemProvider]) -> Void
    private let control: UIPasteControl
    init(onPaste: @escaping ([NSItemProvider]) -> Void) {
        self.onPaste = onPaste
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.baseBackgroundColor = .systemRed
        configuration.baseForegroundColor = .white
        control = UIPasteControl(configuration: configuration)
        super.init(frame: .zero)
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
            UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier
        ])
        control.target = self
        control.accessibilityIdentifier = "studio.image.clipboard"
        addSubview(control)
    }
    required init?(coder: NSCoder) { return nil }
    override func layoutSubviews() { super.layoutSubviews(); control.frame = bounds }
    override func paste(itemProviders: [NSItemProvider]) {
        guard isUserInteractionEnabled else { return }
        onPaste(itemProviders)
    }
}

private enum StudioCameraFailure: LocalizedError {
    case permission, unavailable, image
    var errorDescription: String? {
        switch self {
        case .permission: return "Camera access is denied or restricted. Enable camera access for SDI in Settings, or use Photos or Files. Nothing was added."
        case .unavailable: return "The camera is unavailable on this device. Use Photos or Files. Nothing was added."
        case .image: return "The camera photo could not be prepared within the 16-megapixel and 16-MB limits. Capture a smaller still image or use Photos. Nothing was added."
        }
    }
}

/// Explicit still capture only; no microphone, photo-library write or upload.
/// https://developer.apple.com/documentation/uikit/uiimagepickercontroller
private struct StudioCameraPicker: UIViewControllerRepresentable {
    let completion: (Result<NSItemProvider?, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIViewController {
        guard UIImagePickerController.isSourceTypeAvailable(.camera),
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            DispatchQueue.main.async { context.coordinator.finish(.failure(StudioCameraFailure.unavailable)) }
            return UIViewController()
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (Result<NSItemProvider?, Error>) -> Void
        private var finished = false
        init(completion: @escaping (Result<NSItemProvider?, Error>) -> Void) { self.completion = completion }
        func finish(_ result: Result<NSItemProvider?, Error>) {
            guard !finished else { return }; finished = true; completion(result)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(.success(nil)) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard !finished, let image = info[.originalImage] as? UIImage, let pixels = image.cgImage,
                  pixels.width > 0, pixels.height > 0, pixels.width <= 16_000_000 / pixels.height,
                  let data = image.jpegData(compressionQuality: 0.95), data.count <= 16 * 1024 * 1024 else {
                finish(.failure(StudioCameraFailure.image)); return
            }
            let provider = NSItemProvider()
            provider.suggestedName = "Camera photo.jpg"
            provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .ownProcess) { complete in
                complete(data, nil); return nil
            }
            finish(.success(provider))
        }
    }
}
