import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Uses the existing Export panel. The still thumbnail is decoded from the
/// completed GIF, while sharing receives its actual animated file.
@MainActor
struct StudioGIFExportControls: View {
    @ObservedObject var vm: StudioViewModel
    @ObservedObject var gif: StudioGIFPanelState
    var onReady: () -> Void = {}
    @EnvironmentObject private var authVM: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var shareLifetime = StudioGIFShareLifetime.shared
    @StateObject private var presentationScope = StudioGIFPresentationScope()
    @State private var isVisible = false
    @State private var previewImage: CGImage?
    @State private var previewError: String?
    @State private var shareAccountID: String?
    @State private var shareRequest: StudioGIFExportSession.ShareRequest?

    private var session: StudioGIFExportSession { gif.session }
    private var scope: StudioGIFExportSession.Scope {
        .init(isStudioVisible: isVisible && vm.isEditing && vm.activePanel == .export && vm.exportFormat == .gif,
              isForeground: scenePhase == .active, accountID: authVM.userId)
    }
    private func refreshScope() { presentationScope.value = scope; session.refreshScope(scope) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ANIMATED GIF").font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.4)).tracking(1)
            Text("Original canvas · \(vm.document.width) × \(vm.document.height)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
            Text("\(vm.document.frames.count) frames · \(vm.document.fps) fps. Loops continuously, with a white background and no audio. GIF reduces colors; use MP4 for sound or longer animations. Grid and onion skin are not exported.")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.6))
            Text("Up to 240 frames at 1–50 fps, within 8.4 million total frame pixels. A 1080 × 1920 project fits up to four frames. Larger exports report a limit error.")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.6))
            if let pending = shareLifetime.pendingMessage {
                Text(pending).font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75)).accessibilityIdentifier("studio.export.gif.share.pending")
            }
            if let error = session.errorMessage {
                Text(error).foregroundColor(Color(hex: "#FF8888"))
                    .font(.system(size: 11, design: .monospaced)).accessibilityIdentifier("studio.export.status")
            } else if let notice = session.notice {
                Text(notice).foregroundColor(.white.opacity(0.75))
                    .font(.system(size: 11, design: .monospaced)).accessibilityIdentifier("studio.export.status")
            }
            if session.isRunning {
                ProgressView(value: Double(session.completedFrames), total: Double(max(1, session.totalFrames)))
                    .tint(Color(hex: "#DC2626"))
                Text(progressText).font(.system(size: 11, design: .monospaced))
                    .accessibilityIdentifier("studio.export.gif.progress")
                Button("Cancel export") { session.cancel() }.accessibilityIdentifier("studio.export.cancel")
            } else {
                Button { _ = gif.start(from: vm, scope: scope) } label: {
                    Text("EXPORT GIF").font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#DC2626")))
                }
                .disabled(!scope.isStudioVisible || !scope.isForeground || session.isSharing || session.needsCleanup)
                .accessibilityIdentifier("studio.export.start")
            }
            if session.needsCleanup {
                Button("Retry safe cleanup") { _ = session.retryCleanup() }
                    .disabled(gif.isBusy).accessibilityIdentifier("studio.export.gif.cleanup")
            }
            if let source = session.source {
                Text("Captured \(source.name) · revision \(source.revision)")
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.6))
            }
            if let output = session.output, !output.isCleaned {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.needsCleanup ? "GIF needs recovery" : "GIF ready on this device")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.5)).tracking(1)
                    Text(output.gifURL.lastPathComponent).font(.system(size: 12, weight: .bold, design: .monospaced))
                        .accessibilityIdentifier("studio.export.gif.filename")
                    Text("\(output.receipt.width) × \(output.receipt.height) · \(output.receipt.frameIDs.count) frames · \(output.receipt.sourceFPS) fps · revision \(output.receipt.revision)")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.7))
                        .accessibilityIdentifier("studio.export.gif.receipt")
                    Text("\(output.receipt.encodedBytes) encoded bytes · \(output.receipt.delaysCentiseconds.reduce(0, +)) centiseconds · white · no audio")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                        .accessibilityIdentifier("studio.export.gif.media")
                    if let image = previewImage {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                            .frame(maxWidth: .infinity).frame(height: 180)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("First frame decoded from exported GIF")
                            .accessibilityIdentifier("studio.export.gif.preview")
                        Text("First frame of the actual GIF file")
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                    }
                    if let error = previewError {
                        Text(error).font(.system(size: 10, design: .monospaced)).foregroundColor(Color(hex: "#FF8888"))
                        Button("Retry GIF preview") { loadPreview() }
                    }
                    Button {
                        shareAccountID = scope.accountID
                        shareRequest = session.beginSharing(scope: scope)
                    } label: {
                        Label("Share GIF / Save to Files", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity).padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                    }
                    .disabled(gif.isBusy || session.isClosed || session.needsCleanup || shareLifetime.isReserved || previewImage == nil)
                    .accessibilityIdentifier("studio.export.share")
                    Text("Share the animated GIF or save it to Files.")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                }
                .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#12121a")))
                .id("studio.export.gif.result")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if let request = shareRequest {
                let binding = $shareRequest, holder = presentationScope
                let projectID = session.source?.projectID, accountID = shareAccountID
                let capturedSession = session
                StudioGIFSharePresenter(request: request, session: capturedSession, isAllowed: { [weak vm, weak authVM, weak capturedSession] in
                    guard let vm, let authVM, let capturedSession else { return false }
                    return !capturedSession.isClosed && holder.value.isStudioVisible && holder.value.isForeground
                        && vm.isEditing && vm.activePanel == .export && vm.exportFormat == .gif
                        && vm.document.id == projectID && authVM.userId == accountID
                }) { id in if binding.wrappedValue?.id == id { binding.wrappedValue = nil } }
                    .id(request.id)
            }
        }
        .onAppear { isVisible = true; refreshScope(); loadPreview() }
        .onDisappear {
            previewImage = nil
            if !session.isSharing { isVisible = false; refreshScope(); session.close() }
        }
        .onChange(of: scenePhase) { _, _ in refreshScope() }
        .onChange(of: authVM.userId) { refreshScope(); session.close(); shareRequest = nil }
        .onChange(of: vm.document.id) { refreshScope() }
        .onChange(of: vm.isEditing) { refreshScope() }
        .onChange(of: vm.activePanel) { refreshScope() }
        .onChange(of: vm.exportFormat) { refreshScope() }
        .onChange(of: session.output?.gifURL) { _, value in
            loadPreview()
            if value != nil { onReady() }
        }
    }
    private func loadPreview() {
        previewImage = nil; previewError = nil
        guard let output = session.output, !output.isCleaned, !session.needsCleanup else { return }
        do {
            _ = try output.checkedURLs()
            guard let source = CGImageSourceCreateWithURL(output.gifURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(source) as String? == UTType.gif.identifier,
                  CGImageSourceGetCount(source) == output.receipt.frameIDs.count,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 640,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary), image.width <= 640, image.height <= 640,
                  CGImageSourceGetStatus(source) == .statusComplete else { throw StudioGIFExportService.Failure.unavailable }
            previewImage = image
        } catch { previewError = "The GIF thumbnail could not be loaded. Retry before sharing." }
    }
    private var progressText: String {
        switch session.phase {
        case .rendering: return "Rendering \(session.completedFrames) of \(session.totalFrames) frames"
        case .finalizing: return "Finalizing GIF colors and timing…"
        case .verifying: return "Checking \(session.completedFrames) of \(session.totalFrames) encoded frames"
        case nil: return "Preparing the captured project…"
        }
    }
}

@MainActor private final class StudioGIFPresentationScope: ObservableObject {
    var value = StudioGIFExportSession.Scope(isStudioVisible: false, isForeground: false, accountID: nil)
}
