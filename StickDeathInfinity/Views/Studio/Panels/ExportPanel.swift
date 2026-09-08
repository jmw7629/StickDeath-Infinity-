import SwiftUI
import UIKit

struct ExportPanel: View {
    @ObservedObject var vm: StudioViewModel
    @StateObject private var session = StudioExportSession()
    @State private var background: StudioExportService.Background = .white
    @State private var shareRequest: StudioExportShareRequest?

    private var supportedFormat: StudioExportService.Format? {
        switch vm.exportFormat {
        case .png: return .pngSequence
        case .spritesheet: return .spritesheet
        case .mp4, .gif: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.2)).frame(width: 36, height: 4).padding(.top, 8)
            PanelHeader(title: "Export", icon: "📤", onClose: {
                session.close()
                vm.activePanel = .none
            })
            ScrollView {
                VStack(spacing: 16) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(ExportFormat.allCases, id: \.rawValue) { format in
                            ExportFormatCard(format: format, isSelected: vm.exportFormat == format,
                                onTap: { vm.exportFormat = format })
                                .disabled(session.isRunning || session.isSharing)
                                .accessibilityIdentifier("studio.export.format.\(format.rawValue.lowercased())")
                        }
                    }
                    if vm.isEditing {
                        let document = vm.document
                        VStack(alignment: .leading, spacing: 8) {
                            sectionLabel("IMAGE QUALITY")
                            Text("Original canvas · \(document.width) × \(document.height)")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                            Text("Lossless PNG · \(document.frames.count) frames · \(document.fps) fps in the timing manifest. Audio, editor grid and onion skin are not included.")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.6))
                            sectionLabel("BACKGROUND")
                            Picker("Export background", selection: $background) {
                                Text("White").tag(StudioExportService.Background.white)
                                Text("Transparent").tag(StudioExportService.Background.transparent)
                            }
                            .pickerStyle(.segmented)
                            .disabled(session.isRunning || session.isSharing)
                            .accessibilityIdentifier("studio.export.background")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if supportedFormat == nil {
                        Text("\(vm.exportFormat.rawValue) export is not available yet. Choose PNG or Spritesheet to render actual image files.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    statusView
                    if session.isRunning {
                        VStack(spacing: 10) {
                            ProgressView(value: Double(session.completedFrames), total: Double(max(1, session.totalFrames)))
                                .tint(Color(hex: "#DC2626"))
                            Text("Rendering \(session.completedFrames) of \(session.totalFrames) frames")
                                .font(.system(size: 11, design: .monospaced))
                            Button("Cancel export") { session.cancel() }
                                .accessibilityIdentifier("studio.export.cancel")
                        }
                    } else {
                        Button(action: startExport) {
                            Text(supportedFormat == nil ? "\(vm.exportFormat.rawValue) UNAVAILABLE" : "EXPORT \(vm.exportFormat.rawValue)")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
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
                            sectionLabel("READY ON THIS DEVICE")
                            Text("\(output.imageURLs.count) PNG \(output.imageURLs.count == 1 ? "file" : "files") + timing manifest")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                            Text("\(output.manifest.imageWidth) × \(output.manifest.imageHeight) · revision \(output.manifest.documentRevision)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.6))
                            Button(action: shareExport) {
                                Label("Share files / Save to Files", systemImage: "square.and.arrow.up")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .frame(maxWidth: .infinity).padding(12)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                            }
                            .disabled(session.isSharing || session.isRunning)
                            .accessibilityIdentifier("studio.export.share")
                            Text("Choose a destination in the iOS share sheet. Files stay available until you close this panel or create another export.")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#12121a")))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("SHARE TO")
                        exportDestination("📱", "Camera Roll", "Use the iOS share sheet when supported")
                        exportDestination("🎵", "TikTok", "Direct publishing unavailable")
                        exportDestination("▶️", "YouTube", "Official channel publishing unavailable")
                        exportDestination("📷", "Instagram", "Direct publishing unavailable")
                    }
                    Text("No watermark is added. PNG exports do not include sound. Video, GIF and official channel publishing remain unfinished.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 16).padding(.bottom, 20)
            }
            .frame(maxHeight: UIScreen.main.bounds.height * 0.6)
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
        .onDisappear {
            if vm.activePanel != .export || !vm.isEditing { session.close() }
        }
    }

    @ViewBuilder private var statusView: some View {
        if let error = session.errorMessage {
            Text(error).foregroundColor(Color(hex: "#FF8888"))
                .font(.system(size: 11, design: .monospaced))
                .accessibilityIdentifier("studio.export.status")
        } else if let notice = session.notice {
            Text(notice).foregroundColor(.white.opacity(0.75))
                .font(.system(size: 11, design: .monospaced))
                .accessibilityIdentifier("studio.export.status")
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(.white.opacity(0.4)).tracking(1)
    }

    private func exportDestination(_ icon: String, _ name: String, _ status: String) -> some View {
        HStack(spacing: 10) {
            Text(icon).font(.system(size: 18))
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 12, weight: .medium, design: .monospaced))
                Text(status).font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#12121a")))
    }

    private func startExport() {
        guard vm.isEditing, let format = supportedFormat else { return }
        let document = vm.document
        // Capture value-type document and immutable original bytes together on
        // MainActor before export yields. Later edits cannot change this export.
        var rasters: [String: Data] = [:]
        for id in Set(document.frames.compactMap(\.rasterAssetID)) {
            if let data = vm.rasterData(id) { rasters[id] = data }
        }
        session.start(document: document, format: format, background: background, rasters: rasters)
    }

    private func shareExport() {
        guard let urls = session.beginSharing() else { return }
        shareRequest = StudioExportShareRequest(urls: urls)
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
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    private var task: Task<Void, Never>?
    private var isClosed = false

    func start(document: StudioDocument, format: StudioExportService.Format,
               background: StudioExportService.Background, rasters: [String: Data]) {
        guard !isRunning, !isSharing, !isClosed else { return }
        errorMessage = nil; notice = nil
        guard removeOutput() else { return }
        isRunning = true; completedFrames = 0; totalFrames = document.frames.count
        task = Task { [self] in
            do {
                let result = try await StudioExportService().export(document: document, format: format,
                    outputParent: FileManager.default.temporaryDirectory, background: background,
                    rasterData: { rasters[$0] }, progress: { [self] completed, total in
                        completedFrames = completed; totalFrames = total
                    })
                output = result
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
            errorMessage = "An export file is no longer available. Create the export again."
            return nil
        }
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

    private func removeOutput() -> Bool {
        guard let output else { return true }
        do {
            if FileManager.default.fileExists(atPath: output.directory.path) {
                try FileManager.default.removeItem(at: output.directory)
            }
            self.output = nil
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
    private var isAvailable: Bool { format == .png || format == .spritesheet }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text(format.icon).font(.system(size: 24))
                Text(format.rawValue).font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text(isAvailable ? format.subtitle : "Not available yet")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5)).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#12121a"))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color(hex: "#DC2626") : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)))
        }
    }
}
