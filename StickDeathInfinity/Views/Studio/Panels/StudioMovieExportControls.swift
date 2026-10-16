import SwiftUI
import AVFoundation
import UIKit

/// MP4 reuses the existing Export panel rail and destinations. This section has
/// an actual file receipt, not a canvas snapshot or simulated movie preview.
@MainActor
struct StudioMovieExportControls: View {
    @ObservedObject var vm: StudioViewModel
    @ObservedObject var movie: StudioMoviePanelState
    var directRequest: StudioMoviePanelState.DirectRequest? = nil
    var onDirectRequestConsumed: () -> Void = {}
    var onReady: () -> Void = {}
    @EnvironmentObject private var authVM: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var shareLifetime = StudioMovieShareLifetime.shared
    @StateObject private var presentationScope = StudioMoviePresentationScope()
    @StateObject private var preview = StudioMoviePreviewState()
    @State private var isVisible = false
    // H.264/HEVC MP4 has no alpha channel; the former "Transparent (unsupported)"
    // choice was removed (#185). White is the only truthful background.
    private let background: StudioMovieExportService.Background = .white
    @State private var codec: StudioMovieExportService.Codec = .h264
    @State private var preset: StudioMovieExportService.RenderPreset = .original
    @State private var normalizeAudio = false
    @State private var shareAccountID: String?
    @State private var shareRequest: StudioMovieExportSession.ShareRequest?
    @State private var saveRequest: StudioMovieExportSession.ShareRequest?
    @State private var reviewExport: SDIRenderUploadExport?

    private var scope: StudioMovieExportSession.Scope {
        .init(isStudioVisible: isVisible && vm.isEditing && vm.activePanel == .export,
              isForeground: scenePhase == .active, accountID: authVM.userId)
    }
    private var session: StudioMovieExportSession { movie.session }
    private func refreshScope() {
        presentationScope.value = scope
        session.refreshScope(scope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VIDEO QUALITY").font(.specialElite(9)).foregroundColor(.white.opacity(0.4)).tracking(1)
            Text("Original canvas · \(vm.document.width) × \(vm.document.height)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
            Picker("MP4 resolution", selection: $preset) {
                if presetAllowed(.original) {
                    Text("Original").tag(StudioMovieExportService.RenderPreset.original)
                }
                ForEach(ExportQuality.allCases.filter { presetAllowed(.init(quality: $0)) }, id: \.rawValue) { quality in
                    Text(quality.resolution).tag(StudioMovieExportService.RenderPreset(quality: quality))
                }
            }
            .pickerStyle(.segmented).disabled(movie.isBusy)
            .accessibilityIdentifier("studio.export.movie.resolution")
            if let limit = vm.planLimits.maxExportLongEdge {
                Label("Up to \(limit) px on the longest edge" + (vm.planLimits.exportWatermark ? ", with the SDI mark" : "") + ". " + vm.planLimits.upgradeNote,
                      systemImage: "lock.fill")
                    .font(.specialElite(10)).foregroundColor(.white.opacity(0.6))
            } else if vm.planLimits.exportWatermark {
                Label("Exports carry the SDI mark. " + vm.planLimits.upgradeNote, systemImage: "lock.fill")
                    .font(.specialElite(10)).foregroundColor(.white.opacity(0.6))
            }
            if let plan = try? StudioMovieExportService.RenderPlan.make(canvasWidth: vm.document.width, canvasHeight: vm.document.height, preset: preset) {
                Text("Output \(plan.outputWidth) × \(plan.outputHeight)" + (plan.paddingRight + plan.paddingBottom > 0 ? " · 1 white pixel added on the \(plan.paddingRight > 0 ? "right" : "")\(plan.paddingRight > 0 && plan.paddingBottom > 0 ? " and " : "")\(plan.paddingBottom > 0 ? "bottom" : "") so the encoder gets even dimensions" : "") + (plan.scale != 1 ? String(format: " · scaled ×%.3f", plan.scale) : ""))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.7))
                    .accessibilityIdentifier("studio.export.movie.output-size")
            }
            Picker("MP4 codec", selection: $codec) {
                ForEach(StudioMovieExportService.Codec.allCases, id: \.rawValue) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).disabled(movie.isBusy)
            .accessibilityIdentifier("studio.export.movie.codec")
            Text("\(codec.label) MP4 · \(vm.document.frames.count) frames · \(vm.document.fps) fps · \(String(format: "%.2f", vm.document.durationSeconds))s with frame exposures. White background (MP4 cannot store transparency). Saved audio is mixed as stereo AAC within one 120-second mix; audio that ends after the animation holds the last frame until it finishes. Up to 1,440 frames stream through the encoder. Missing sources report an error. HEVC is refused with a message if this device's encoder cannot apply it. Editor grid, onion skin and video reference layers are not included.")
                .font(.specialElite(10)).foregroundColor(.white.opacity(0.6))
                .accessibilityIdentifier("studio.export.movie.background")
            if !vm.document.audioClips.isEmpty {
                Toggle(isOn: $normalizeAudio) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Normalize audio to −1 dBFS").font(.specialElite(12))
                        Text(normalizeAudio
                             ? "The whole mix is scaled by one gain so its loudest sample sits at −1 dBFS; the gain is written to the manifest. Clip volumes are unchanged."
                             : "Off: levels are exported exactly as mixed. A mix that exceeds full scale is refused with a message instead of being changed.")
                            .font(.specialElite(9)).foregroundColor(.white.opacity(0.6))
                    }
                }
                .tint(Color(hex: "#DC2626")).disabled(movie.isBusy)
                .accessibilityIdentifier("studio.export.movie.normalize")
            }
            if let pending = shareLifetime.pendingMessage {
                Text(pending).foregroundColor(.white.opacity(0.75))
                    .font(.specialElite(11))
                    .accessibilityIdentifier("studio.export.movie.share.pending")
            }
            if let error = movie.directError {
                Text(error).foregroundColor(Color(hex: "#FF8888"))
                    .accessibilityIdentifier("studio.export.movie.direct-error")
            }
            if let provenance = movie.directArtifactDescription {
                Text(provenance).font(.specialElite(10))
                    .accessibilityIdentifier("studio.export.movie.spatter-receipt")
            }
            if let error = session.errorMessage {
                Text(error).foregroundColor(Color(hex: "#FF8888"))
                    .font(.specialElite(11))
                    .accessibilityIdentifier("studio.export.status")
            } else if let notice = session.notice {
                Text(notice).foregroundColor(.white.opacity(0.75))
                    .font(.specialElite(11))
                    .accessibilityIdentifier("studio.export.status")
            }
            if session.isRunning {
                ProgressView(value: Double(session.completedFrames), total: Double(max(1, session.totalFrames)))
                    .tint(Color(hex: "#DC2626"))
                Text(progressText).font(.specialElite(11))
                    .accessibilityIdentifier("studio.export.movie.progress")
                Button("Cancel export") { session.cancel() }
                    .accessibilityIdentifier("studio.export.cancel")
            } else {
                Button {
                    _ = movie.start(from: vm, background: background, scope: scope,
                                    options: .init(render: .init(codec: codec, preset: preset), normalizeAudio: normalizeAudio))
                } label: {
                    Text("EXPORT MP4").font(.specialElite(14))
                        .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#DC2626")))
                }
                .disabled(!scope.isStudioVisible || !scope.isForeground || session.isSharing || session.needsCleanup)
                .accessibilityIdentifier("studio.export.start")
            }
            if session.needsCleanup {
                Button("Retry safe cleanup") { _ = session.retryCleanup() }
                    .disabled(movie.isBusy).accessibilityIdentifier("studio.export.movie.cleanup")
            }
            if let source = session.source {
                Text("Captured \(source.name) · revision \(source.revision)")
                    .font(.specialElite(10)).foregroundColor(.white.opacity(0.6))
                    .accessibilityIdentifier("studio.export.movie.source")
            }
            if let output = session.output, !output.isCleaned {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.needsCleanup ? "MP4 needs recovery" : "MP4 ready on this device").font(.specialElite(9)).foregroundColor(.white.opacity(0.5)).tracking(1)
                    Text(output.movieURL.lastPathComponent).font(.system(size: 12, weight: .bold, design: .monospaced))
                        .accessibilityIdentifier("studio.export.movie.filename")
                    Text("\(output.manifest.width) × \(output.manifest.height) · \(output.manifest.frameIDs.count) frames · \(output.manifest.fps) fps · revision \(output.manifest.documentRevision)")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.7))
                        .accessibilityIdentifier("studio.export.movie.receipt")
                    if let rule = output.manifest.renderRule, output.manifest.renderPlan.map({ $0.scale != 1 || $0.paddingRight + $0.paddingBottom > 0 }) == true {
                        Text(rule).font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                            .accessibilityIdentifier("studio.export.movie.render-rule")
                    }
                    if let gain = output.audioAppliedGain {
                        Text(String(format: "Audio normalized to −1 dBFS · gain ×%.3f recorded in manifest", gain))
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                            .accessibilityIdentifier("studio.export.movie.normalized")
                    }
                    if let credits = output.manifest.imageCredits, !credits.isEmpty {
                        Text("\(credits.count) image \(credits.count == 1 ? "credit" : "credits") included in manifest")
                            .font(.specialElite(10))
                            .foregroundColor(.white.opacity(0.6))
                            .accessibilityIdentifier("studio.export.movie.image-credits")
                    }
                    if let credits = output.manifest.soundCredits, !credits.isEmpty {
                        // Library attribution travels with the mixed movie (#191).
                        Text("\(credits.count) sound \(credits.count == 1 ? "credit" : "credits") included in manifest: " + credits.map(\.summary).joined(separator: "; "))
                            .font(.specialElite(10)).lineLimit(4)
                            .foregroundColor(.white.opacity(0.6))
                            .accessibilityIdentifier("studio.export.movie.sound-credits")
                    }
                    if let notice = session.soundCreditNotice {
                        Text(notice).font(.specialElite(10)).foregroundColor(.white.opacity(0.6))
                            .accessibilityIdentifier("studio.export.movie.sound-credits.notice")
                    }
                    Text("\(output.manifest.encodedBytes) encoded bytes · \(output.manifest.codec) · white · \(output.manifest.audioIncluded ? "stereo audio" : "no audio")")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                        .accessibilityIdentifier("studio.export.movie.media")
                    if let player = preview.player {
                        StudioMoviePreviewSurface(player: player)
                            .frame(height: 180).background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Rendered MP4 picture")
                            .accessibilityIdentifier("studio.export.movie.preview")
                    }
                    if let error = preview.errorMessage {
                        Text(error).font(.specialElite(10))
                            .foregroundColor(Color(hex: "#FF8888"))
                        Button("Retry movie preview") { refreshPreview() }
                            .accessibilityIdentifier("studio.export.movie.preview.retry")
                    } else {
                        HStack(spacing: 8) {
                            Button { preview.togglePlayback() } label: {
                                Image(systemName: preview.isPlaying || preview.isWaiting ? "pause.fill" : "play.fill")
                                    .frame(width: 44, height: 44)
                            }
                            .disabled(!preview.isReady || preview.isScrubbing || preview.isSeeking)
                            .accessibilityLabel(preview.isPlaying || preview.isWaiting ? "Pause movie preview" : "Play movie preview")
                            .accessibilityIdentifier("studio.export.movie.preview.play")
                            Slider(value: Binding(get: { preview.sliderPosition }, set: { preview.updateSliderPosition($0) }),
                                   in: 0...max(preview.duration, 0.001),
                                   onEditingChanged: { preview.setScrubbing($0) })
                                .tint(Color(hex: "#DC2626")).disabled(!preview.isReady)
                                .accessibilityLabel("Movie preview position")
                                .accessibilityIdentifier("studio.export.movie.preview.seek")
                            Text(String(format: "%.2f / %.2f s", preview.currentTime, preview.duration))
                                .font(.system(size: 9, design: .monospaced)).monospacedDigit()
                                .accessibilityIdentifier("studio.export.movie.preview.time")
                        }
                        Text(preview.didFinish ? "Playback finished" : preview.isPlaying ? "Playing rendered MP4" : preview.isWaiting ? "Preparing playback…" : preview.isReady ? "Preview ready" : "Loading rendered MP4…")
                            .font(.specialElite(10)).foregroundColor(.white.opacity(0.6))
                            .accessibilityIdentifier("studio.export.movie.preview.status")
                    }
                    Button {
                        shareAccountID = scope.accountID
                        shareRequest = session.beginSharing(scope: scope)
                    } label: {
                        Label("Share MP4 / Save to Files", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity).padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                    }
                    .disabled(movie.isBusy || session.isClosed || session.needsCleanup || shareLifetime.isReserved)
                    .accessibilityIdentifier("studio.export.share")
                    Button {
                        saveRequest = session.beginSharing(scope: scope)
                    } label: {
                        Label("Save to Files", systemImage: "folder")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity).padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                    }
                    .disabled(movie.isBusy || session.isClosed || session.needsCleanup || shareLifetime.isReserved)
                    .accessibilityIdentifier("studio.export.movie.save-files")
                    Button {
                        guard let account = scope.accountID,
                              let request = session.beginSharing(scope: scope) else { return }
                        reviewExport = SDIRenderUploadExport(request: request, account: account,
                            title: String(vm.document.name.prefix(100)),
                            revision: "Studio project \(output.manifest.projectID.uuidString), revision \(output.manifest.documentRevision)",
                            manifest: output.manifest)
                    } label: {
                        Label("Submit this MP4 for review", systemImage: "checkmark.shield")
                            .font(.specialElite(12))
                            .frame(maxWidth: .infinity).padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#DC2626")))
                    }
                    .disabled(movie.isBusy || session.isClosed || session.needsCleanup || shareLifetime.isReserved || scope.accountID == nil)
                    .accessibilityIdentifier("studio.export.movie.submit-review")
                    if scope.accountID == nil {
                        Text("Sign in before submitting an export for private review.").font(.specialElite(10))
                    }
                    Text("Share hands the rendered MP4 to the share sheet; Save to Files copies it into a folder you choose. Neither uploads or publishes anything.")
                        .font(.specialElite(10)).foregroundColor(.white.opacity(0.6))
                }
                .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#12121a")))
                .id("studio.export.movie.result")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $reviewExport) { exported in
            NavigationStack {
                SDIRenderUploadView(exportedMovie: exported)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { exported.close(); reviewExport = nil }
                        }
                    }
            }
            .onDisappear { exported.close() }
        }
        .background {
            if let request = shareRequest {
                let binding = $shareRequest
                let holder = presentationScope
                let projectID = session.source?.projectID
                let accountID = shareAccountID
                let capturedSession = session
                StudioMovieSharePresenter(request: request, session: capturedSession, isAllowed: { [weak vm, weak authVM, weak capturedSession] in
                    guard let vm, let authVM, let capturedSession else { return false }
                    return !capturedSession.isClosed && holder.value.isStudioVisible && holder.value.isForeground
                        && vm.isEditing && vm.activePanel == .export && vm.document.id == projectID
                        && authVM.userId == accountID
                }) { id in
                    if binding.wrappedValue?.id == id { binding.wrappedValue = nil }
                }
                .id(request.id)
            }
            if let request = saveRequest {
                let binding = $saveRequest
                let holder = presentationScope
                let projectID = session.source?.projectID
                let capturedSession = session
                StudioFilesSavePresenter(request: request, isAllowed: { [weak vm, weak capturedSession] in
                    guard let vm, let capturedSession else { return false }
                    return !capturedSession.isClosed && holder.value.isStudioVisible && holder.value.isForeground
                        && vm.isEditing && vm.activePanel == .export && vm.document.id == projectID
                }) { id in
                    if binding.wrappedValue?.id == id { binding.wrappedValue = nil }
                }
                .id(request.id)
            }
        }
        .onAppear {
            isVisible = true; refreshScope()
            clampPresetToPlan()
            if let request = directRequest {
                _ = movie.start(request, from: vm, scope: scope)
                onDirectRequestConsumed()
            }
            refreshPreview()
        }
        .onDisappear {
            preview.stop()
            // A full-screen native activity may cover this section without
            // removing it. Actual removal invokes the presenter's dismantle,
            // which closes the owner but keeps files until the actual share callback.
            if !session.isSharing { isVisible = false; refreshScope(); session.close() }
        }
        .onChange(of: scenePhase) { _, _ in refreshScope(); refreshPreview() }
        .onChange(of: authVM.userId) {
            reviewExport?.close(); reviewExport = nil
            refreshScope(); session.close(); shareRequest = nil; saveRequest = nil
        }
        .onChange(of: vm.document.id) { refreshScope() }
        .onChange(of: vm.isEditing) { refreshScope() }
        .onChange(of: vm.activePanel) { refreshScope() }
        .onChange(of: session.output?.movieURL) { _, output in
            if output != nil { onReady() }
            refreshPreview()
        }
        .onChange(of: session.isRunning) { _, _ in refreshPreview() }
        .onChange(of: session.isSharing) { _, _ in refreshPreview() }
    }
    /// A size the plan allows (always true without a size cap).
    private func presetAllowed(_ candidate: StudioMovieExportService.RenderPreset) -> Bool {
        guard vm.planLimits.maxExportLongEdge != nil else { return true }
        guard let plan = try? StudioMovieExportService.RenderPlan.make(canvasWidth: vm.document.width,
            canvasHeight: vm.document.height, preset: candidate) else { return false }
        return vm.planLimits.allowsExport(width: plan.contentWidth, height: plan.contentHeight)
    }
    private func clampPresetToPlan() {
        guard !presetAllowed(preset) else { return }
        if let allowed = [StudioMovieExportService.RenderPreset.p1080, .p720, .p480].first(where: presetAllowed) { preset = allowed }
    }
    private func refreshPreview() {
        guard scope.isStudioVisible, scope.isForeground, !session.isClosed,
              !session.isRunning, !session.isSharing, !session.isRecovering,
              !session.needsCleanup, session.output != nil else { preview.stop(); return }
        if preview.player == nil { _ = preview.load(session: session, scope: scope) }
    }
    private var progressText: String {
        if let audio = session.audioProgressText { return audio }
        switch session.phase {
        case .rendering: return "Rendering \(session.completedFrames) of \(session.totalFrames) frames"
        case .finalizing: return "Finalizing the encoded movie…"
        case .verifying: return "Decoding and checking the actual movie…"
        case .publishing: return "Finishing the file on this device…"
        case nil: return "Preparing the captured project…"
        }
    }
}

@MainActor
private final class StudioMoviePresentationScope: ObservableObject {
    var value = StudioMovieExportSession.Scope(isStudioVisible: false, isForeground: false, accountID: nil)
}

/// The native AVPlayerLayer displays decoded file pixels; controls above drive
/// the same player. Dismantling releases only this view's layer reference.
private struct StudioMoviePreviewSurface: UIViewRepresentable {
    let player: AVPlayer
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
    }
    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        if let layer = view.layer as? AVPlayerLayer { layer.videoGravity = .resizeAspect; layer.player = player }
        return view
    }
    func updateUIView(_ view: Surface, context: Context) { (view.layer as? AVPlayerLayer)?.player = player }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { (view.layer as? AVPlayerLayer)?.player = nil }
}
