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
    @State private var previewPlaying = false
    @State private var previewFrame = 0
    private struct PreviewPlaybackKey: Equatable {
        let url: URL?
        let playing: Bool
        let foreground: Bool
    }
    @State private var previewError: String?
    @State private var shareAccountID: String?
    @State private var shareRequest: StudioGIFExportSession.ShareRequest?

    private var session: StudioGIFExportSession { gif.session }
    private var scope: StudioGIFExportSession.Scope {
        .init(isStudioVisible: isVisible && vm.isEditing && vm.activePanel == .export && vm.exportFormat == .gif,
              isForeground: scenePhase == .active, accountID: authVM.userId)
    }
    private func refreshScope() { presentationScope.value = scope; session.refreshScope(scope) }

    private var frameCapacity: Int {
        (try? StudioGIFEncoder.frameCapacity(document: vm.document,
            maximumDimension: gif.maximumDimension == 0 ? nil : gif.maximumDimension)) ?? 0
    }
    private var fitsFrameBudget: Bool { (1...50).contains(vm.document.fps) && vm.document.frames.count <= frameCapacity }
    private var suggestedSize: Int? {
        guard (1...50).contains(vm.document.fps) else { return nil }
        return [0, 960, 640, 320].first { dimension in
            let capacity = (try? StudioGIFEncoder.frameCapacity(document: vm.document,
                maximumDimension: dimension == 0 ? nil : dimension)) ?? 0
            return vm.document.frames.count <= capacity
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ANIMATED GIF").font(.specialElite(9))
                .foregroundColor(.white.opacity(0.4)).tracking(1)
            Picker("GIF longest edge", selection: $gif.maximumDimension) {
                Text("Original").tag(0)
                Text("320 px").tag(320)
                Text("640 px").tag(640)
                Text("960 px").tag(960)
            }.disabled(gif.isBusy || session.needsCleanup)
                .accessibilityIdentifier("studio.export.gif.size")
            if let size = try? StudioGIFEncoder.outputSize(document: vm.document,
                maximumDimension: gif.maximumDimension == 0 ? nil : gif.maximumDimension) {
                Text("Output: \(size.width) × \(size.height) · project canvas unchanged")
                    .font(.specialElite(11))
            }
            Text("This size supports up to \(frameCapacity) frames; this project has \(vm.document.frames.count). Source-asset and encoded-file limits also apply.")
                .font(.specialElite(10))
                .accessibilityIdentifier("studio.export.gif.capacity")
            if !fitsFrameBudget {
                if let suggestedSize {
                    Button("Use \(suggestedSize == 0 ? "original size" : "\(suggestedSize) px") to fit every frame") { gif.maximumDimension = suggestedSize }
                        .disabled(gif.isBusy || session.needsCleanup)
                } else {
                    Text("This animation exceeds the available GIF frame or frame-rate limits. Use MP4; no frames will be omitted.")
                        .font(.specialElite(11)).foregroundStyle(.secondary)
                }
            }
            Text("Original canvas · \(vm.document.width) × \(vm.document.height)")
                .font(.specialElite(12))
            Text("\(vm.document.frames.count) frames · \(vm.document.fps) fps · \(String(format: "%.2f", vm.document.durationSeconds))s with frame exposures. Loops continuously, with a white background and no audio. GIF reduces colors; use MP4 for sound or longer animations. Grid and onion skin are not exported.")
                .font(.specialElite(10)).foregroundColor(.white.opacity(0.6))
            Text("Up to 240 frames at 1–50 fps, within 8.4 million total frame pixels. Original 1080 × 1920 fits four frames; 320 px output fits up to 145. Choose a smaller output for longer sequences. Limits never drop frames.")
                .font(.specialElite(10)).foregroundColor(.white.opacity(0.6))
            if let pending = shareLifetime.pendingMessage {
                Text(pending).font(.specialElite(11))
                    .foregroundColor(.white.opacity(0.75)).accessibilityIdentifier("studio.export.gif.share.pending")
            }
            if let error = session.errorMessage {
                Text(error).foregroundColor(Color(hex: "#FF8888"))
                    .font(.specialElite(11)).accessibilityIdentifier("studio.export.status")
            } else if let notice = session.notice {
                Text(notice).foregroundColor(.white.opacity(0.75))
                    .font(.specialElite(11)).accessibilityIdentifier("studio.export.status")
            }
            if session.isRunning {
                ProgressView(value: Double(session.completedFrames), total: Double(max(1, session.totalFrames)))
                    .tint(Color(hex: "#DC2626"))
                Text(progressText).font(.specialElite(11))
                    .accessibilityIdentifier("studio.export.gif.progress")
                Button("Cancel export") { session.cancel() }.accessibilityIdentifier("studio.export.cancel")
            } else {
                Button { _ = gif.start(from: vm, scope: scope) } label: {
                    Text("EXPORT GIF").font(.specialElite(14))
                        .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#DC2626")))
                }
                .disabled(!scope.isStudioVisible || !scope.isForeground || session.isSharing || session.needsCleanup || !fitsFrameBudget)
                .accessibilityIdentifier("studio.export.start")
            }
            if session.needsCleanup {
                Button("Retry safe cleanup") { _ = session.retryCleanup() }
                    .disabled(gif.isBusy).accessibilityIdentifier("studio.export.gif.cleanup")
            }
            if let source = session.source {
                Text("Captured \(source.name) · revision \(source.revision)")
                    .font(.specialElite(10)).foregroundColor(.white.opacity(0.6))
            }
            if let output = session.output, !output.isCleaned {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.needsCleanup ? "GIF needs recovery" : "GIF ready on this device")
                        .font(.specialElite(9)).foregroundColor(.white.opacity(0.5)).tracking(1)
                    Text(output.gifURL.lastPathComponent).font(.system(size: 12, weight: .bold, design: .monospaced))
                        .accessibilityIdentifier("studio.export.gif.filename")
                    Text("\(output.receipt.width) × \(output.receipt.height) · \(output.receipt.frameIDs.count) frames · \(output.receipt.sourceFPS) fps · revision \(output.receipt.revision)")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.7))
                        .accessibilityIdentifier("studio.export.gif.receipt")
                    if let credits = output.receipt.imageCredits, !credits.isEmpty {
                        Text("\(credits.count) image \(credits.count == 1 ? "credit" : "credits") included in manifest")
                            .font(.specialElite(10))
                            .foregroundColor(.white.opacity(0.6))
                            .accessibilityIdentifier("studio.export.gif.image-credits")
                    }
                    Text("\(output.receipt.encodedBytes) encoded bytes · \(output.receipt.delaysCentiseconds.reduce(0, +)) centiseconds · white · no audio")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                        .accessibilityIdentifier("studio.export.gif.media")
                    if let image = previewImage {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                            .frame(maxWidth: .infinity).frame(height: 180)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Frame \(previewFrame + 1) decoded from exported GIF")
                            .accessibilityIdentifier("studio.export.gif.preview")
                        Button(previewPlaying ? "Pause GIF preview" : "Play exported GIF") { previewPlaying.toggle() }
                            .disabled(gif.isBusy || session.needsCleanup)
                            .accessibilityIdentifier("studio.export.gif.preview-playback")
                        Text("Actual exported file · frame \(previewFrame + 1) of \(output.receipt.frameIDs.count) · silent")
                            .font(.specialElite(10)).foregroundColor(.white.opacity(0.6))
                    }
                    if let error = previewError {
                        Text(error).font(.specialElite(10)).foregroundColor(Color(hex: "#FF8888"))
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
                        .font(.specialElite(10)).foregroundColor(.white.opacity(0.6))
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
        .task(id: PreviewPlaybackKey(url: session.output?.gifURL, playing: previewPlaying,
                                    foreground: scope.isForeground && scope.isStudioVisible)) {
            await playPreview()
        }
        .onAppear { isVisible = true; refreshScope(); loadPreview() }
        .onDisappear {
            previewPlaying = false
            previewImage = nil
            if !session.isSharing { isVisible = false; refreshScope(); session.close() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { previewPlaying = false }
            refreshScope()
        }
        .onChange(of: authVM.userId) { previewPlaying = false; refreshScope(); session.close(); shareRequest = nil }
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
        previewPlaying = false; previewFrame = 0
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
    private func playPreview() async {
        guard previewPlaying, scope.isForeground, scope.isStudioVisible,
              let output = session.output, !output.isCleaned, !session.needsCleanup else { return }
        do {
            _ = try output.checkedURLs()
            guard let source = CGImageSourceCreateWithURL(output.gifURL as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                  !output.receipt.frameIDs.isEmpty,
                  output.receipt.delaysCentiseconds.count == output.receipt.frameIDs.count,
                  CGImageSourceGetCount(source) == output.receipt.frameIDs.count else {
                throw StudioGIFExportService.Failure.unavailable
            }
            var index = min(previewFrame, output.receipt.frameIDs.count - 1)
            var deadline = ProcessInfo.processInfo.systemUptime
            while previewPlaying {
                try Task.checkCancellation()
                guard scope.isForeground, scope.isStudioVisible, session.output === output,
                      !output.isCleaned, !session.needsCleanup else { return }
                let delay = try autoreleasepool { () throws -> Double in
                    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                          let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
                          let duration = gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber,
                          duration.doubleValue.isFinite, duration.doubleValue > 0, duration.doubleValue <= 600,
                          abs(duration.doubleValue - Double(output.receipt.delaysCentiseconds[index]) / 100) < 0.0001,
                          let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 640,
                            kCGImageSourceShouldCacheImmediately: true
                          ] as CFDictionary), image.width <= 640, image.height <= 640 else {
                        throw StudioGIFExportService.Failure.unavailable
                    }
                    previewImage = image; previewFrame = index
                    return duration.doubleValue
                }
                deadline += delay
                let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                index = (index + 1) % output.receipt.frameIDs.count
            }
        } catch is CancellationError { }
        catch {
            previewPlaying = false
            previewError = "The exported GIF could not be played. Retry its preview before sharing."
        }
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
