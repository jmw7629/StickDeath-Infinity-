import SwiftUI
import AVFoundation
import UIKit

/// MP4 reuses the existing Export panel rail and destinations. This section has
/// an actual file receipt, not a canvas snapshot or simulated movie preview.
@MainActor
struct StudioMovieExportControls: View {
    @ObservedObject var vm: StudioViewModel
    @ObservedObject var movie: StudioMoviePanelState
    var onReady: () -> Void = {}
    @EnvironmentObject private var authVM: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var shareLifetime = StudioMovieShareLifetime.shared
    @StateObject private var presentationScope = StudioMoviePresentationScope()
    @StateObject private var preview = StudioMoviePreviewState()
    @State private var isVisible = false
    @State private var background: StudioMovieExportService.Background = .white
    @State private var shareAccountID: String?
    @State private var shareRequest: StudioMovieExportSession.ShareRequest?

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
            Text("VIDEO QUALITY").font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.4)).tracking(1)
            Text("Original canvas · \(vm.document.width) × \(vm.document.height)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
            Text("H.264 MP4 · \(vm.document.frames.count) frames · \(vm.document.fps) fps. White background only. Saved audio is mixed as stereo AAC. Trim audio within the animation duration; missing sources and overloaded mixes report an error. Editor grid and onion skin are not included.")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.6))
            Picker("MP4 background", selection: $background) {
                Text("White").tag(StudioMovieExportService.Background.white)
                Text("Transparent (unsupported)").tag(StudioMovieExportService.Background.transparent)
            }
            .pickerStyle(.segmented).disabled(movie.isBusy)
            .accessibilityIdentifier("studio.export.movie.background")
            if let pending = shareLifetime.pendingMessage {
                Text(pending).foregroundColor(.white.opacity(0.75))
                    .font(.system(size: 11, design: .monospaced))
                    .accessibilityIdentifier("studio.export.movie.share.pending")
            }
            if let error = session.errorMessage {
                Text(error).foregroundColor(Color(hex: "#FF8888"))
                    .font(.system(size: 11, design: .monospaced))
                    .accessibilityIdentifier("studio.export.status")
            } else if let notice = session.notice {
                Text(notice).foregroundColor(.white.opacity(0.75))
                    .font(.system(size: 11, design: .monospaced))
                    .accessibilityIdentifier("studio.export.status")
            }
            if session.isRunning {
                ProgressView(value: Double(session.completedFrames), total: Double(max(1, session.totalFrames)))
                    .tint(Color(hex: "#DC2626"))
                Text(progressText).font(.system(size: 11, design: .monospaced))
                    .accessibilityIdentifier("studio.export.movie.progress")
                Button("Cancel export") { session.cancel() }
                    .accessibilityIdentifier("studio.export.cancel")
            } else {
                Button {
                    _ = movie.start(from: vm, background: background, scope: scope)
                } label: {
                    Text("EXPORT MP4").font(.system(size: 14, weight: .bold, design: .monospaced))
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
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                    .accessibilityIdentifier("studio.export.movie.source")
            }
            if let output = session.output, !output.isCleaned {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.needsCleanup ? "MP4 needs recovery" : "MP4 ready on this device").font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.5)).tracking(1)
                    Text(output.movieURL.lastPathComponent).font(.system(size: 12, weight: .bold, design: .monospaced))
                        .accessibilityIdentifier("studio.export.movie.filename")
                    Text("\(output.manifest.width) × \(output.manifest.height) · \(output.manifest.frameIDs.count) frames · \(output.manifest.fps) fps · revision \(output.manifest.documentRevision)")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.7))
                        .accessibilityIdentifier("studio.export.movie.receipt")
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
                        Text(error).font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(hex: "#FF8888"))
                        Button("Retry movie preview") { refreshPreview() }
                            .accessibilityIdentifier("studio.export.movie.preview.retry")
                    } else {
                        HStack(spacing: 8) {
                            Button { preview.togglePlayback() } label: {
                                Image(systemName: preview.isPlaying || preview.isWaiting ? "pause.fill" : "play.fill")
                                    .frame(width: 44, height: 44)
                            }
                            .disabled(!preview.isReady)
                            .accessibilityLabel(preview.isPlaying || preview.isWaiting ? "Pause movie preview" : "Play movie preview")
                            .accessibilityIdentifier("studio.export.movie.preview.play")
                            Slider(value: Binding(get: { preview.currentTime }, set: { preview.seek(to: $0) }),
                                   in: 0...max(preview.duration, 0.001))
                                .tint(Color(hex: "#DC2626")).disabled(!preview.isReady)
                                .accessibilityLabel("Movie preview position")
                                .accessibilityIdentifier("studio.export.movie.preview.seek")
                            Text(String(format: "%.2f / %.2f s", preview.currentTime, preview.duration))
                                .font(.system(size: 9, design: .monospaced)).monospacedDigit()
                                .accessibilityIdentifier("studio.export.movie.preview.time")
                        }
                        Text(preview.didFinish ? "Playback finished" : preview.isPlaying ? "Playing rendered MP4" : preview.isWaiting ? "Preparing playback…" : preview.isReady ? "Preview ready" : "Loading rendered MP4…")
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.6))
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
                    Text("Share the rendered MP4 or save it to Files.")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                }
                .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#12121a")))
                .id("studio.export.movie.result")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        }
        .onAppear { isVisible = true; refreshScope(); refreshPreview() }
        .onDisappear {
            preview.stop()
            // A full-screen native activity may cover this section without
            // removing it. Actual removal invokes the presenter's dismantle,
            // which closes the owner but keeps files until the actual share callback.
            if !session.isSharing { isVisible = false; refreshScope(); session.close() }
        }
        .onChange(of: scenePhase) { _, _ in refreshScope(); refreshPreview() }
        .onChange(of: authVM.userId) {
            refreshScope(); session.close(); shareRequest = nil
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
