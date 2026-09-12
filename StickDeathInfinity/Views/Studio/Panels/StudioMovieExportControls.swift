import SwiftUI

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
                    Text("Video preview unavailable.")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.6))
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
        .onAppear { isVisible = true; refreshScope() }
        .onDisappear {
            // A full-screen native activity may cover this section without
            // removing it. Actual removal invokes the presenter's dismantle,
            // which closes the owner but keeps files until the actual share callback.
            if !session.isSharing { isVisible = false; refreshScope(); session.close() }
        }
        .onChange(of: scenePhase) { _, _ in refreshScope() }
        .onChange(of: authVM.userId) {
            refreshScope(); session.close(); shareRequest = nil
        }
        .onChange(of: vm.document.id) { refreshScope() }
        .onChange(of: vm.isEditing) { refreshScope() }
        .onChange(of: vm.activePanel) { refreshScope() }
        .onChange(of: session.output?.movieURL) { _, output in
            if output != nil { onReady() }
        }
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
