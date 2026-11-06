import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// A shortcut authorizes sharing this exact already-rendered output once. It
/// never survives a new session/export or authorizes rendering something later.
struct StudioQuickShareHandoff: Equatable {
    let id = UUID()
    let file: StudioQuickShareFile
    let accountID: String?
    let projectID: UUID
    let revision: Int
    let sessionID: ObjectIdentifier
    let outputURL: URL

    func accepts(_ format: ExportFormat) -> Bool {
        (file == .mp4 && format == .mp4) || (file == .gif && format == .gif)
    }
}

struct ExportPanel: View {
    @ObservedObject var vm: StudioViewModel
    @EnvironmentObject private var authVM: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase
    /// The movie and GIF states are owned by StudioView so a completed direct
    /// export's receipt stays observable from the Spatter panel while this panel
    /// is open (#215). Closing this panel still closes both sessions.
    @ObservedObject var movie: StudioMoviePanelState
    @ObservedObject var gif: StudioGIFPanelState
    var directRequest: StudioMoviePanelState.DirectRequest? = nil
    var directGIFRequest: StudioGIFPanelState.DirectRequest? = nil
    var onDirectRequestConsumed: () -> Void = {}
    @StateObject private var session = StudioExportSession()
    @State private var background: StudioExportService.Background = .white
    @State private var frameScope = "All"
    @State private var firstFrame = 1
    @State private var lastFrame = 1
    @State private var sheetColumns = 0
    @State private var cellPadding = 0
    @State private var scale: StudioExportService.Scale = .original
    @State private var separateLayers = false
    @State private var shareRequest: StudioExportShareRequest?
    @State private var saveRequest: StudioImageExportFileRequest?
    /// Six configurable quick-share shortcuts (#242); persisted per device.
    @State private var quickShare = StudioQuickShareConfiguration.load()
    @State private var quickShareNote: String?
    @State private var customizingQuickShare = false
    @State private var quickShareHandoff: StudioQuickShareHandoff?
    @State private var quickShareDeliveryReady = false

    private var supportedFormat: StudioExportService.Format? {
        switch vm.exportFormat {
        case .png: return .pngSequence
        case .spritesheet: return .spritesheet
        case .mp4, .gif: return nil
        }
    }

    /// Free-plan notes, kept out of `body` so it type-checks in reasonable time.
    @ViewBuilder private var pngSequenceLockNote: some View {
        if supportedFormat == .pngSequence, !vm.planLimits.pngSequenceExport {
            Label("Transparent PNG sequences: " + vm.planLimits.upgradeNote, systemImage: "lock.fill")
                .font(.specialElite(10)).foregroundColor(.white.opacity(0.6))
        }
    }

    private var watermarkSummary: String {
        vm.planLimits.exportWatermark
            ? "A small SDI mark is added at the bottom right of exported images and videos; your project is unchanged. "
            : "No watermark is added. "
    }

    /// Four fixed cards: an eager two-column grid keeps every format button in
    /// the hierarchy after the panel scrolls, where a lazy grid drops the
    /// off-screen row. Kept out of `body` so the compiler checks it separately.
    private var formatGrid: some View {
        let formats = ExportFormat.allCases
        let rows = Array(stride(from: 0, to: formats.count, by: 2))
        let busy = session.isRunning || session.isSharing || movie.isBusy || gif.isBusy
        return VStack(spacing: 10) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(Array(formats[row..<min(row + 2, formats.count)]), id: \.rawValue) { (format: ExportFormat) in
                        formatCard(format, busy: busy)
                    }
                }
            }
        }
    }

    private func formatCard(_ format: ExportFormat, busy: Bool) -> some View {
        ExportFormatCard(format: format, isSelected: vm.exportFormat == format,
            onTap: { vm.exportFormat = format })
            .frame(maxWidth: .infinity)
            .disabled(busy)
            .accessibilityIdentifier("studio.export.format.\(format.rawValue.lowercased())")
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.2)).frame(width: 36, height: 4).padding(.top, 8)
            PanelHeader(title: "Export", icon: "📤", onClose: {
                session.close()
                movie.session.close()
                gif.session.close()
                vm.activePanel = .none
            })
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    formatGrid
                    if vm.exportFormat == .mp4 {
                        StudioMovieExportControls(vm: vm, movie: movie, directRequest: directRequest, onDirectRequestConsumed: onDirectRequestConsumed, onReady: {
                            proxy.scrollTo("studio.export.movie.result", anchor: .top)
                        }, quickShareRequest: quickShareDeliveryReady ? quickShareHandoff : nil, onQuickShareHandled: finishQuickShare)
                    } else if vm.exportFormat == .gif {
                        StudioGIFExportControls(vm: vm, gif: gif, directRequest: directGIFRequest, onDirectRequestConsumed: onDirectRequestConsumed, onReady: {
                            proxy.scrollTo("studio.export.gif.result", anchor: .top)
                        }, quickShareRequest: quickShareDeliveryReady ? quickShareHandoff : nil, onQuickShareHandled: finishQuickShare)
                    } else {
                    if vm.isEditing {
                        let document = vm.document
                        VStack(alignment: .leading, spacing: 8) {
                            sectionLabel("IMAGE QUALITY")
                            Text("Original canvas · \(document.width) × \(document.height)")
                                .font(.specialElite(12))
                            Text("Lossless PNG · \(document.frames.count) project frames · \(document.fps) fps; frame exposures are included in the timing manifest. Audio, editor grid, onion skin and video reference layers are not included.")
                                .font(.specialElite(10))
                                .foregroundColor(.white.opacity(0.6))
                            // Output scale (#184): the compositor draws at the output size.
                            Picker("Export scale", selection: $scale) {
                                ForEach(StudioExportService.Scale.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .disabled(session.isRunning || session.isSharing)
                            .accessibilityIdentifier("studio.export.scale")
                            Text("Output \(max(1, Int((Double(document.width) * scale.factor).rounded(.down)))) × \(max(1, Int((Double(document.height) * scale.factor).rounded(.down)))) per frame · vectors and placed images are drawn at this size, not resampled.")
                                .font(.specialElite(10)).foregroundColor(.white.opacity(0.6))
                                .accessibilityIdentifier("studio.export.scale.output")
                            if supportedFormat == .pngSequence {
                                Toggle(isOn: $separateLayers) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("One PNG per visible layer").font(.specialElite(12))
                                        Text("Writes every frame once per visible layer (\(document.layers.filter { $0.visible && $0.opacity > 0 && !$0.isReference }.count) now) with the layer recorded in the manifest.")
                                            .font(.specialElite(9)).foregroundColor(.white.opacity(0.6))
                                    }
                                }
                                .tint(Color(hex: "#DC2626"))
                                .disabled(session.isRunning || session.isSharing)
                                .accessibilityIdentifier("studio.export.separate-layers")
                            }
                            sectionLabel("BACKGROUND")
                            Picker("Export background", selection: $background) {
                                Text("White").tag(StudioExportService.Background.white)
                                Text("Transparent").tag(StudioExportService.Background.transparent)
                            }
                            .pickerStyle(.segmented)
                            .disabled(session.isRunning || session.isSharing)
                            .accessibilityIdentifier("studio.export.background")
                            pngSequenceLockNote
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("FRAMES")
                        Picker("Export frames", selection: $frameScope) {
                            ForEach(["All", "Current", "Range"], id: \.self) { Text($0).tag($0) }
                        }.pickerStyle(.segmented)
                            .accessibilityIdentifier("studio.export.frame-scope")
                        if frameScope == "Range" {
                            Stepper("First frame: \(firstFrame)", value: $firstFrame, in: 1...max(1, vm.document.frames.count))
                            Stepper("Last frame: \(lastFrame)", value: $lastFrame, in: firstFrame...max(firstFrame, vm.document.frames.count))
                                .onChange(of: firstFrame) { value in lastFrame = max(lastFrame, value) }
                        }
                        Text("Frames keep their exposure durations. Export playback begins at zero; the manifest retains original frame indices.")
                            .font(.specialElite(10)).foregroundColor(.white.opacity(0.6))
                    }.font(.specialElite(12)).disabled(session.isRunning || session.isSharing)
                    if supportedFormat == .spritesheet {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionLabel("ATLAS LAYOUT")
                            Stepper(sheetColumns == 0 ? "Columns: Automatic" : "Columns: \(sheetColumns)",
                                value: $sheetColumns, in: 0...max(1, vm.document.frames.count))
                                .accessibilityIdentifier("studio.export.sheet-columns")
                            Stepper("Padding per frame edge: \(cellPadding) px", value: $cellPadding, in: 0...32)
                                .accessibilityIdentifier("studio.export.sheet-padding")
                            Text("Padding uses the export background. Manifest rectangles exclude padding; frame size and timing stay unchanged. Sheet limits still apply.")
                                .font(.specialElite(10)).foregroundColor(.white.opacity(0.6))
                        }
                        .font(.specialElite(12))
                        .disabled(session.isRunning || session.isSharing)
                    }
                    if supportedFormat == nil {
                        Text("\(vm.exportFormat.rawValue) export is not available yet. Choose PNG or Spritesheet to render actual image files.")
                            .font(.specialElite(11))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    statusView
                    if session.isRunning {
                        VStack(spacing: 10) {
                            ProgressView(value: Double(session.completedFrames), total: Double(max(1, session.totalFrames)))
                                .tint(Color(hex: "#DC2626"))
                            Text("Rendering \(session.completedFrames) of \(session.totalFrames) frames")
                                .font(.specialElite(11))
                            Button("Cancel export") { session.cancel() }
                                .accessibilityIdentifier("studio.export.cancel")
                        }
                    } else {
                        Button(action: startExport) {
                            Text(supportedFormat == nil ? "\(vm.exportFormat.rawValue) UNAVAILABLE" : "EXPORT \(vm.exportFormat.rawValue)")
                                .font(.specialElite(14))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#DC2626")))
                        }
                        .disabled(supportedFormat == nil || !vm.isEditing || session.isSharing)
                        .opacity(supportedFormat == nil ? 0.45 : 1)
                        .accessibilityIdentifier("studio.export.start")
                    }
                    if let output = session.output {
                        VStack(alignment: .leading, spacing: 10) {
                            sectionLabel(session.previewImage == nil ? "EXPORT FILES UNAVAILABLE" : "READY ON THIS DEVICE")
                            Text("\(output.imageURLs.count) PNG \(output.imageURLs.count == 1 ? "file" : "files") + timing manifest")
                                .font(.specialElite(12))
                            Text("\(output.manifest.imageWidth) × \(output.manifest.imageHeight) · revision \(output.manifest.documentRevision)"
                                 + (output.manifest.scale.map { " · \($0.label) scale" } ?? "")
                                 + (output.manifest.layerCount.map { " · \($0) layers separately" } ?? ""))
                                .font(.specialElite(10))
                                .foregroundColor(.white.opacity(0.6))
                                .accessibilityIdentifier("studio.export.receipt")
                            if let credits = output.manifest.imageCredits, !credits.isEmpty {
                                Text("\(credits.count) image \(credits.count == 1 ? "credit" : "credits") included in manifest")
                                    .font(.specialElite(10))
                                    .foregroundColor(.white.opacity(0.6))
                                    .accessibilityIdentifier("studio.export.image-credits")
                            }
                            if let preview = session.previewImage {
                                Image(decorative: preview, scale: 1)
                                    .resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 180)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("Exported PNG preview")
                                    .accessibilityIdentifier("studio.export.preview")
                                Text(output.imageURLs.first?.lastPathComponent ?? "")
                                    .font(.specialElite(9))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            Button(action: shareExport) {
                                Label {
                                    Text("Share files / Save to Files").font(.specialElite(12))
                                } icon: {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.specialElite(12))
                                }
                                    .frame(maxWidth: .infinity).padding(12)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                            }
                            .disabled(session.isSharing || session.isRunning || session.previewImage == nil)
                            .accessibilityIdentifier("studio.export.share")
                            Button(action: saveToFiles) {
                                Label {
                                    Text("Save to Files").font(.specialElite(12))
                                } icon: {
                                    Image(systemName: "folder").font(.specialElite(12))
                                }
                                    .frame(maxWidth: .infinity).padding(12)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                            }
                            .disabled(session.isSharing || session.isRunning || session.previewImage == nil)
                            .accessibilityIdentifier("studio.export.save-files")
                            Text("Share opens the iOS share sheet; Save to Files copies every PNG and the manifest into a folder you choose. Files stay available until you close this panel or create another export.")
                                .font(.specialElite(10))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#12121a")))
                    }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("SHARING")
                        // One truthful destination: the iOS share sheet. Studio has no
                        // direct TikTok/YouTube/Instagram publishing (#185).
                        exportDestination("📤", "Share via system sheet",
                            "After an export is ready, Share hands the files to the iOS share sheet. Save to Files, Photos (for MP4/GIF) or any installed app that accepts them. Studio does not post to TikTok, YouTube or Instagram itself.")
                            .accessibilityIdentifier("studio.export.share-explanation")
                        quickShareSection(proxy: proxy)
                    }
                    Text(watermarkSummary + "Files are named after the project (ASCII letters, digits, '-' and '_'; otherwise \"animation\"). PNG exports do not include sound. MP4 uses a white background and includes saved project audio as stereo AAC with library sound credits in its manifest. GIF uses reduced colors, a white background and no audio. Video reference layers are never exported.")
                        .font(.specialElite(10))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 20)
            }
            .frame(maxHeight: UIScreen.main.bounds.height * 0.6)
            }
        }
        .foregroundColor(.white)
        .background(Color(hex: "#1a1a24"))
        .cornerRadius(16, corners: [.topLeft, .topRight])
        .sheet(item: $shareRequest, onDismiss: { session.finishSharing(completed: false, error: nil) }) { request in
            StudioExportShareSheet(urls: request.urls) { completed, error in
                session.finishSharing(completed: completed, error: error)
                shareRequest = nil
            }
        }
        .background {
            if let request = saveRequest {
                let binding = $saveRequest
                StudioFilesSavePresenter(request: request, isAllowed: { [weak vm] in
                    guard let vm else { return false }
                    return vm.isEditing && vm.activePanel == .export
                }) { id in if binding.wrappedValue?.id == id { binding.wrappedValue = nil } }
                .id(request.id)
            }
        }
        .onDisappear {
            cancelPendingQuickShare()
            // An active UIKit consumer can temporarily cover this panel. Its
            // presenter closes the movie owner on actual representable removal.
            if !movie.session.isSharing { movie.session.close() }
            if !gif.session.isSharing { gif.session.close() }
            if vm.activePanel != .export || !vm.isEditing { session.close() }
        }
        .onChange(of: authVM.userId) { _, value in
            if let pending = quickShareHandoff, pending.accountID != value { cancelPendingQuickShare() }
        }
        .onChange(of: vm.document.id) { _, value in
            if let pending = quickShareHandoff, pending.projectID != value { cancelPendingQuickShare() }
        }
        .onChange(of: vm.document.revision) { _, value in
            if let pending = quickShareHandoff, pending.revision != value { cancelPendingQuickShare() }
        }
        .onChange(of: vm.isEditing) { _, value in
            if !value { cancelPendingQuickShare() }
        }
        .onChange(of: vm.exportFormat) { _, value in
            if let pending = quickShareHandoff, !pending.accepts(value) { cancelPendingQuickShare() }
        }
        .onChange(of: vm.activePanel) { _, value in
            if value != .export { cancelPendingQuickShare() }
        }
        .onChange(of: scenePhase) { _, value in
            if value != .active { cancelPendingQuickShare() }
        }
    }

    @ViewBuilder private var statusView: some View {
        if let error = session.errorMessage {
            Text(error).foregroundColor(Color(hex: "#FF8888"))
                .font(.specialElite(11))
                .accessibilityIdentifier("studio.export.status")
        } else if let notice = session.notice {
            Text(notice).foregroundColor(.white.opacity(0.75))
                .font(.specialElite(11))
                .accessibilityIdentifier("studio.export.status")
        }
    }

    /// Six shortcuts that prepare the right rendered file and hand it to the iOS
    /// share sheet (#242). They never post, upload or claim delivery.
    @ViewBuilder private func quickShareSection(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("QUICK SHARE")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(quickShare.slots) { destination in
                    Button { runQuickShare(destination, proxy: proxy) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: destination.symbol).font(.system(size: 16))
                            Text(destination.title).font(.specialElite(10)).lineLimit(1).minimumScaleFactor(0.7)
                            Text(quickShare.file(for: destination).label).font(.specialElite(8)).foregroundColor(.white.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                    }
                    .accessibilityLabel("Quick share to \(destination.title)")
                    .accessibilityIdentifier("studio.export.quick-share.\(destination.rawValue)")
                }
            }
            if let quickShareNote {
                Text(quickShareNote)
                    .font(.specialElite(10)).foregroundColor(.white.opacity(0.75))
                    .accessibilityIdentifier("studio.export.quick-share.note")
            }
            DisclosureGroup(isExpanded: $customizingQuickShare) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<StudioQuickShareConfiguration.slotCount, id: \.self) { slot in
                        let destination = quickShare.slots[slot]
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("Shortcut \(slot + 1)", selection: Binding(
                                get: { quickShare.slots[slot] },
                                set: { quickShare.assign($0, toSlot: slot); quickShare.save() })) {
                                ForEach(StudioQuickShareDestination.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.menu)
                            if destination.acceptedFiles.count > 1 {
                                Picker("File for \(destination.title)", selection: Binding(
                                    get: { quickShare.file(for: destination) },
                                    set: { quickShare.setPreferredFile($0, for: destination); quickShare.save() })) {
                                    ForEach(destination.acceptedFiles, id: \.self) { Text($0.label).tag($0) }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                    }
                    Button("Restore default shortcuts") { quickShare.reset(); quickShare.save(); quickShareNote = nil }
                        .font(.specialElite(11))
                        .accessibilityIdentifier("studio.export.quick-share.reset")
                    Text("Choices stay on this device. A shortcut prepares the rendered file and opens the iOS share sheet; the app you pick there does the posting. Direct posting from Studio is not available.")
                        .font(.specialElite(9)).foregroundColor(.white.opacity(0.5))
                }
                .padding(.top, 6)
            } label: {
                Text("Customize shortcuts").font(.specialElite(11))
            }
            .tint(.white)
            .accessibilityIdentifier("studio.export.quick-share.customize")
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#12121a")))
    }

    private func runQuickShare(_ destination: StudioQuickShareDestination, proxy: ScrollViewProxy) {
        var ready: Set<StudioQuickShareFile> = []
        if let output = movie.session.output, movie.session.hasCurrentPlanAuthorization,
           !movie.session.isClosed, !movie.session.needsCleanup, !output.isCleaned,
           output.manifest.projectID == vm.document.id, output.manifest.documentRevision == vm.document.revision {
            ready.insert(.mp4)
        }
        if let output = gif.session.output, !gif.session.isClosed, !gif.session.needsCleanup, !output.isCleaned,
           output.receipt.projectID == vm.document.id, output.receipt.revision == vm.document.revision {
            ready.insert(.gif)
        }
        if session.output != nil && session.previewImage != nil { ready.insert(.png) }
        let plan = StudioQuickSharePlan.plan(for: destination, configuration: quickShare, ready: ready)
        guard quickShareHandoff == nil, !(session.isRunning || session.isSharing || movie.isBusy || gif.isBusy) else {
            quickShareNote = "Wait for the current export or share to finish, then use \(destination.title) again."
            return
        }
        guard vm.isEditing, vm.activePanel == .export, scenePhase == .active else {
            quickShareNote = "Return to the active Studio export panel before sharing. Nothing was shared."
            return
        }
        quickShareNote = plan.instruction
        let anchor: String?
        switch plan.file {
        case .mp4: vm.exportFormat = .mp4; anchor = "studio.export.movie.result"
        case .gif: vm.exportFormat = .gif; anchor = "studio.export.gif.result"
        case .png:
            if vm.exportFormat != .spritesheet { vm.exportFormat = .png }
            anchor = nil
        }
        guard case .share(let file, _) = plan else { return }
        if file == .png {
            // The PNG files are owned by this panel's session: hand them over now.
            shareExport()
        } else if let anchor {
            // The result view owns its native presenter. Its one-shot request
            // uses the same beginSharing action and owned file lease as Share.
            let owner: ObjectIdentifier
            let url: URL
            if file == .mp4, let output = movie.session.output {
                owner = ObjectIdentifier(movie.session); url = output.movieURL
            } else if file == .gif, let output = gif.session.output {
                owner = ObjectIdentifier(gif.session); url = output.gifURL
            } else {
                quickShareNote = "The rendered file is no longer ready. Export it again before sharing."
                return
            }
            let request = StudioQuickShareHandoff(file: file, accountID: authVM.userId,
                projectID: vm.document.id, revision: vm.document.revision, sessionID: owner, outputURL: url)
            quickShareDeliveryReady = false
            quickShareHandoff = request
            // The presenter's existing visibility check must see its real
            // result view, not a scrolled-offscreen host. Scroll without an
            // animation, then deliver on the next UI turn. Both turns retain
            // the exact request fences; neither queues sharing a later render.
            DispatchQueue.main.async {
                guard quickShareHandoff?.id == request.id else { return }
                guard canDeliverQuickShare(request) else { cancelPendingQuickShare(); return }
                proxy.scrollTo(anchor, anchor: .top)
                DispatchQueue.main.async {
                    guard quickShareHandoff?.id == request.id else { return }
                    guard canDeliverQuickShare(request) else { cancelPendingQuickShare(); return }
                    quickShareDeliveryReady = true
                }
            }
        }
    }

    private func finishQuickShare(_ id: UUID, _ failure: String?) {
        guard quickShareHandoff?.id == id else { return }
        quickShareHandoff = nil
        quickShareDeliveryReady = false
        if let failure { quickShareNote = failure }
    }

    private func cancelPendingQuickShare() {
        guard quickShareHandoff != nil else { return }
        quickShareHandoff = nil
        quickShareDeliveryReady = false
        quickShareNote = "Studio changed before sharing could start. Use the shortcut again when the current export is ready."
    }

    private func canDeliverQuickShare(_ request: StudioQuickShareHandoff) -> Bool {
        vm.isEditing && vm.activePanel == .export && scenePhase == .active
            && authVM.userId == request.accountID && vm.document.id == request.projectID
            && vm.document.revision == request.revision && request.accepts(vm.exportFormat)
            && (request.file != .mp4 || movie.session.hasCurrentPlanAuthorization)
            && !(session.isRunning || session.isSharing || movie.isBusy || gif.isBusy)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.specialElite(9))
            .foregroundColor(.white.opacity(0.4)).tracking(1)
    }

    private func exportDestination(_ icon: String, _ name: String, _ status: String) -> some View {
        HStack(spacing: 10) {
            Text(icon).font(.system(size: 18))
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.specialElite(12))
                Text(status).font(.specialElite(9)).foregroundColor(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#12121a")))
    }

    private func startExport() {
        guard vm.isEditing, let format = supportedFormat else { return }
        // Transparent PNG image sequences are a paid-plan export.
        if format == .pngSequence, background == .transparent, !vm.planLimits.pngSequenceExport {
            session.preparationFailed(StudioDocumentError.unavailable("Transparent PNG sequences: " + vm.planLimits.upgradeNote))
            return
        }
        let document = vm.document
        // Capture value-type document and immutable original bytes together on
        // MainActor before export yields. Later edits cannot change this export.
        let frameIDs: Set<String>?
        switch frameScope {
        case "Current": frameIDs = [document.activeFrameID]
        case "Range":
            let lower = min(max(1, firstFrame), document.frames.count) - 1
            let upper = min(max(firstFrame, lastFrame), document.frames.count) - 1
            frameIDs = Set(document.frames[lower...upper].map(\.id))
        default: frameIDs = nil
        }
        let selectedFrames = document.frames.filter { frameIDs?.contains($0.id) ?? true }
        var rasters: [String: Data] = [:]
        var imageCredits: [String: StudioExportService.ImageCredit] = [:]
        let visibleIDs = Set(selectedFrames.flatMap { frame in
            frame.visibleRasterInstances(in: document.layers).compactMap { frame.rasterAssetID(on: $0.layerID) }
        })
        do {
            for id in visibleIDs {
                if let data = vm.rasterData(id) { rasters[id] = data }
                if let source = vm.originalImageSource(id), let origin = source.catalogueAttribution {
                    try source.validate()
                    imageCredits[id] = try StudioExportService.ImageCredit(attribution: origin)
                }
            }
        } catch {
            session.preparationFailed(error)
            return
        }
        session.start(document: document, format: format, background: background, rasters: rasters, imageCredits: imageCredits,
            sheetColumns: format == .spritesheet && sheetColumns > 0 ? min(sheetColumns, selectedFrames.count) : nil,
            cellPadding: format == .spritesheet ? cellPadding : 0, frameIDs: frameIDs,
            scale: scale, separateLayers: format == .pngSequence && separateLayers,
            watermark: vm.planLimits.exportWatermark)
    }

    private func shareExport() {
        guard let urls = session.beginSharing() else { return }
        shareRequest = StudioExportShareRequest(urls: urls)
    }
    private func saveToFiles() {
        guard let urls = session.beginSharing() else { return }
        saveRequest = StudioImageExportFileRequest(urls: urls, session: session)
    }
}

/// Adapts the PNG session's share lease to the shared Files-save presenter (#185).
@MainActor
final class StudioImageExportFileRequest: StudioExportFileRequest {
    let id = UUID()
    private let urls: [URL]
    private let session: StudioExportSession
    private var finished = false
    init(urls: [URL], session: StudioExportSession) { self.urls = urls; self.session = session }
    func checkedURLs() throws -> [URL] {
        guard !finished, !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw StudioExportService.ExportError.unsafeDestination
        }
        return urls
    }
    func finish(completed: Bool, error: Error?) {
        guard !finished else { return }
        finished = true
        session.finishSharing(completed: completed, error: error)
    }
}

// Holds the task and successful output for exactly this panel. The share-sheet
// completion retains this session so panel dismissal cannot delete active files.
@MainActor
final class StudioExportSession: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isSharing = false
    @Published private(set) var completedFrames = 0
    @Published private(set) var totalFrames = 0
    @Published private(set) var output: StudioExportService.Output?
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    private var task: Task<Void, Never>?
    private var isClosed = false

    func preparationFailed(_ error: Error) {
        guard !isRunning, !isSharing, !isClosed else { return }
        errorMessage = error.localizedDescription; notice = nil
    }

    func start(document: StudioDocument, format: StudioExportService.Format,
               background: StudioExportService.Background, rasters: [String: Data],
               imageCredits: [String: StudioExportService.ImageCredit] = [:],
               sheetColumns: Int? = nil, cellPadding: Int = 0, frameIDs: Set<String>? = nil,
               scale: StudioExportService.Scale = .original, separateLayers: Bool = false,
               watermark: Bool = false) {
        guard !isRunning, !isSharing, !isClosed else { return }
        errorMessage = nil; notice = nil
        guard removeOutput() else { return }
        // Preflight (#202) before any rendering: free space for twice the
        // estimated PNG output (at the output scale, once per layer pass) and a
        // non-critical thermal state.
        let frameCount = frameIDs?.count ?? document.frames.count
        let passes = separateLayers ? max(1, document.layers.filter { $0.visible && $0.opacity > 0 && !$0.isReference }.count) : 1
        let outputParent = FileManager.default.temporaryDirectory
        do {
            try StudioExportPreflight.check(estimatedOutputBytes: StudioExportPreflight.estimatedPNGBytes(
                width: max(1, Int((Double(document.width) * scale.factor).rounded(.down))),
                height: max(1, Int((Double(document.height) * scale.factor).rounded(.down))),
                frames: frameCount * passes), destination: outputParent)
        } catch { errorMessage = error.localizedDescription; return }
        let filenameBase = StudioExportFilename.base(for: document.name)
        isRunning = true; completedFrames = 0; totalFrames = frameCount * passes
        task = Task { [self] in
            do {
                let result = try await StudioExportService().export(document: document, format: format,
                    outputParent: outputParent, background: background,
                    sheetColumns: sheetColumns, cellPadding: cellPadding, frameIDs: frameIDs, imageCredits: imageCredits,
                    filenameBase: filenameBase, scale: scale, separateLayers: separateLayers,
                    watermark: watermark,
                    rasterData: { rasters[$0] }, progress: { [self] completed, total in
                        completedFrames = completed; totalFrames = total
                    })
                output = result
                try loadPreview(result)
                notice = "Export ready. Files were created on this device."
            } catch is CancellationError {
                notice = "Export cancelled."
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunning = false; task = nil
            if isClosed { _ = removeOutput() }
        }
    }

    func cancel() {
        guard isRunning else { return }
        notice = "Cancelling export…"
        task?.cancel()
    }

    func beginSharing() -> [URL]? {
        guard !isRunning, !isSharing, !isClosed, let output else { return nil }
        let urls = output.imageURLs + [output.manifestURL]
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            previewImage = nil
            errorMessage = "An export file is no longer available. Create the export again."
            return nil
        }
        do { try loadPreview(output) }
        catch { errorMessage = error.localizedDescription; return nil }
        errorMessage = nil; notice = nil; isSharing = true
        return urls
    }

    func finishSharing(completed: Bool, error: Error?) {
        guard isSharing else { return }
        isSharing = false
        if let error { errorMessage = error.localizedDescription }
        else { notice = completed ? "Share sheet completed." : "Sharing cancelled. Your export is still available." }
        if isClosed { _ = removeOutput() }
    }

    func close() {
        isClosed = true
        cancel()
        if !isSharing { _ = removeOutput() }
    }

    // Decode a bounded thumbnail from the returned PNG file, never from the
    // canvas or editor. The source's compressed bytes and image dimensions are
    // checked before thumbnail decoding; full-size bitmaps are not retained.
    private func loadPreview(_ output: StudioExportService.Output) throws {
        previewImage = nil
        guard let url = output.imageURLs.first, url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let byteCount = values.fileSize, byteCount > 0,
              byteCount <= StudioExportService.maximumOutputBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == output.manifest.imageWidth, height == output.manifest.imageHeight,
              width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= StudioExportService.maximumSheetPixels,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              image.width <= 640, image.height <= 640,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw PreviewError.unavailable
        }
        previewImage = image
    }

    private enum PreviewError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "The exported PNG is missing or cannot be previewed. Create the export again before sharing."
        }
    }

    private func removeOutput() -> Bool {
        guard let output else { return true }
        do {
            if FileManager.default.fileExists(atPath: output.directory.path) {
                try FileManager.default.removeItem(at: output.directory)
            }
            self.output = nil; previewImage = nil
            return true
        } catch {
            errorMessage = "The previous export could not be removed. Its files were kept; try again before exporting another copy."
            return false
        }
    }
}

private struct StudioExportShareRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct StudioExportShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let completion: (Bool, Error?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            Task { @MainActor in completion(completed, error) }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ExportFormatCard: View {
    let format: ExportFormat
    let isSelected: Bool
    let onTap: () -> Void
    private var isAvailable: Bool { format == .mp4 || format == .gif || format == .png || format == .spritesheet }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text(format.icon).font(.system(size: 24))
                Text(format.rawValue).font(.specialElite(12))
                    .foregroundColor(.white)
                Text(format == .mp4 ? "H.264 · project audio" : format == .gif ? "Animated · no audio" : (isAvailable ? format.subtitle : "Not available yet"))
                    .font(.specialElite(8))
                    .foregroundColor(.white.opacity(0.5)).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#12121a"))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color(hex: "#DC2626") : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)))
        }
    }
}
