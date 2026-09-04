import SwiftUI
import PhotosUI

struct ExportPanel: View {
    @ObservedObject var vm: StudioViewModel
    @State private var shareTargets: [ShareTarget] = [
        ShareTarget(id: "camera", name: "Camera Roll", icon: "📱", isPro: false, isEnabled: true),
        ShareTarget(id: "tiktok", name: "TikTok", icon: "🎵", isPro: true, isEnabled: false),
        ShareTarget(id: "youtube", name: "YouTube", icon: "▶️", isPro: true, isEnabled: false),
        ShareTarget(id: "instagram", name: "Instagram", icon: "📷", isPro: true, isEnabled: false),
    ]
    @State private var showShareSheet = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            PanelHeader(title: "Export", icon: "📤", onClose: { vm.activePanel = .none })

            ScrollView {
                VStack(spacing: 16) {
                    // Format grid (2x2)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(ExportFormat.allCases, id: \.rawValue) { format in
                            ExportFormatCard(
                                format: format,
                                isSelected: vm.exportFormat == format,
                                onTap: { vm.exportFormat = format }
                            )
                        }
                    }
                    .padding(.horizontal, 16)

                    // Quality
                    VStack(alignment: .leading, spacing: 8) {
                        Text("QUALITY")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .tracking(1)

                        HStack(spacing: 8) {
                            ForEach(ExportQuality.allCases, id: \.rawValue) { quality in
                                Button(action: { vm.exportQuality = quality }) {
                                    VStack(spacing: 2) {
                                        Text(quality.rawValue)
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        Text(quality.resolution)
                                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.4))
                                    }
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color(hex: "#12121a"))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(
                                                        vm.exportQuality == quality ? Color(hex: "#DC2626") : Color.white.opacity(0.08),
                                                        lineWidth: vm.exportQuality == quality ? 2 : 1
                                                    )
                                            )
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)

                    // Watermark
                    HStack(spacing: 10) {
                        Text("💀")
                            .font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("StickDeath ∞ watermark")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                            Text("Powered by StickDeath Infinity")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.35))
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(hex: "#12121a"))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 16)

                    // Export Progress
                    if case .exporting(let progress) = vm.exportProgress {
                        VStack(spacing: 8) {
                            ProgressView(value: progress)
                                .tint(.red)
                            Text("Exporting... \(Int(progress * 100))%")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 16)
                    }

                    // Export Complete
                    if case .complete(let result) = vm.exportProgress {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.green)
                            Text("Export Complete!")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                            Text("File size: \(ByteCountFormatter.string(fromByteCount: result.fileSize, countStyle: .file))")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white.opacity(0.5))

                            Button(action: { showShareSheet = true }) {
                                Text("Share Export")
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.green)
                                    .cornerRadius(14)
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // Export Failed
                    if case .failed(let error) = vm.exportProgress {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.red)
                            Text("Export Failed")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                            Text(error)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .padding(.horizontal, 16)
                    }

                    // Share To
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SHARE TO")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .tracking(1)

                        ForEach(shareTargets) { target in
                            ShareTargetRow(target: target)
                        }
                    }
                    .padding(.horizontal, 16)

                    // Export button / Cancel button
                    if case .exporting = vm.exportProgress {
                        Button(action: {
                            ExportService.shared.cancelExport()
                            vm.exportProgress = .idle
                        }) {
                            Text("CANCEL EXPORT")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.gray)
                                )
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                    } else {
                        Button(action: {
                            Task {
                                await startExport()
                            }
                        }) {
                            Text("EXPORT \(vm.exportFormat.rawValue)")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(hex: "#DC2626"))
                                )
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                    }
                }
            }
            .frame(maxHeight: UIScreen.main.bounds.height * 0.6)
        }
        .background(Color(hex: "#1a1a24"))
        .cornerRadius(16, corners: [.topLeft, .topRight])
        .sheet(isPresented: $showShareSheet) {
            if let result = vm.lastExportResult {
                ShareSheet(items: [result.url])
            }
        }
    }

    // MARK: - Start Export
    private func startExport() async {
        let exportService = ExportService.shared

        do {
            let result: ExportResult

            switch vm.exportFormat {
            case .mp4:
                result = try await exportService.exportMP4(
                    frames: vm.frames,
                    canvasWidth: vm.canvasWidth,
                    canvasHeight: vm.canvasHeight,
                    fps: vm.fps,
                    quality: vm.exportQuality,
                    layers: vm.layers,
                    audioClips: vm.audioClips,
                    rotoscopeReference: vm.rotoscopeReference,
                    rotoscopeVideoAsset: vm.rotoscopeVideoAsset
                )

            case .gif:
                result = try await exportService.exportGIF(
                    frames: vm.frames,
                    canvasWidth: vm.canvasWidth,
                    canvasHeight: vm.canvasHeight,
                    fps: vm.fps,
                    quality: vm.exportQuality,
                    layers: vm.layers,
                    rotoscopeReference: vm.rotoscopeReference,
                    rotoscopeVideoAsset: vm.rotoscopeVideoAsset
                )

            case .png:
                result = try await exportService.exportPNGSequence(
                    frames: vm.frames,
                    canvasWidth: vm.canvasWidth,
                    canvasHeight: vm.canvasHeight,
                    quality: vm.exportQuality,
                    layers: vm.layers,
                    rotoscopeReference: vm.rotoscopeReference,
                    rotoscopeVideoAsset: vm.rotoscopeVideoAsset
                )

            case .spritesheet:
                // Spritesheet export - combine all frames into one image
                result = try await exportService.exportPNGSequence(
                    frames: vm.frames,
                    canvasWidth: vm.canvasWidth,
                    canvasHeight: vm.canvasHeight,
                    quality: vm.exportQuality,
                    layers: vm.layers,
                    rotoscopeReference: vm.rotoscopeReference,
                    rotoscopeVideoAsset: vm.rotoscopeVideoAsset
                )
            }

            vm.lastExportResult = result
            vm.exportProgress = .complete(result: result)

        } catch {
            vm.exportProgress = .failed(error: error.localizedDescription)
        }
    }
}

// MARK: - Export Format Card
struct ExportFormatCard: View {
    let format: ExportFormat
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text(format.icon)
                    .font(.system(size: 24))
                Text(format.rawValue)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text(format.subtitle)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(hex: "#12121a"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? Color(hex: "#DC2626") : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
                    )
            )
        }
    }
}

// MARK: - Share Target Row
struct ShareTargetRow: View {
    let target: ShareTarget

    var body: some View {
        HStack(spacing: 10) {
            Text(target.icon)
                .font(.system(size: 18))

            Text(target.name)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(target.isPro ? .white.opacity(0.35) : .white)

            Spacer()

            if target.isPro {
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                    Text("PRO")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                }
                .foregroundColor(Color(hex: "#B8860B"))
            } else if target.isEnabled {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.green)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(hex: "#12121a"))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

// MARK: - Share Sheet
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
