import SwiftUI

struct ExportPanel: View {
    @ObservedObject var vm: StudioViewModel
    @State private var showShareSheet = false
    @State private var showPublishSheet = false

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

                    // EXPORT button
                    Button(action: {
                        Task { await vm.performExport() }
                    }) {
                        HStack(spacing: 8) {
                            if vm.isExporting {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(vm.isExporting ? "EXPORTING..." : "EXPORT \(vm.exportFormat.rawValue)")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(vm.isExporting ? Color.gray : Color(hex: "#DC2626"))
                        )
                    }
                    .disabled(vm.isExporting)
                    .padding(.horizontal, 16)

                    // Post-export actions (only show when there's an export result)
                    if vm.lastExportResult != nil {
                        VStack(spacing: 8) {
                            Text("ACTIONS")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                                .tracking(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            // Share button — opens iOS Share Sheet
                            Button(action: { showShareSheet = true }) {
                                HStack(spacing: 10) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 16))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("Share")
                                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        Text("Share to any app or platform")
                                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.35))
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.2))
                                }
                                .foregroundColor(.white)
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

                            // Publish button — submits to official SDI YouTube channel
                            Button(action: { showPublishSheet = true }) {
                                HStack(spacing: 10) {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(Color(hex: "#DC2626"))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("Publish to SDI YouTube")
                                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        Text("Submit to the official channel")
                                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.35))
                                    }
                                    Spacer()
                                    if vm.currentPublishJob != nil && !vm.currentPublishJob!.status.isTerminal {
                                        ProgressView()
                                            .tint(Color(hex: "#DC2626"))
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.2))
                                    }
                                }
                                .foregroundColor(.white)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(hex: "#12121a"))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color(hex: "#DC2626").opacity(0.3), lineWidth: 1)
                                        )
                                )
                            }

                            // View publish status (if there's a job)
                            if let job = vm.currentPublishJob {
                                Button(action: {
                                    vm.activePanel = .none
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        NotificationCenter.default.post(
                                            name: .showPublishStatus,
                                            object: nil
                                        )
                                    }
                                }) {
                                    HStack(spacing: 10) {
                                        Image(systemName: job.status.icon)
                                            .font(.system(size: 16))
                                            .foregroundColor(statusColor(for: job.status))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text("Publish Status")
                                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                            Text(job.status.displayName)
                                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                                .foregroundColor(.white.opacity(0.35))
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.2))
                                    }
                                    .foregroundColor(.white)
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
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 20)
            }
            .frame(maxHeight: UIScreen.main.bounds.height * 0.65)
        }
        .background(Color(hex: "#1a1a24"))
        .cornerRadius(16, corners: [.topLeft, .topRight])
        .sheet(isPresented: $showShareSheet) {
            if let result = vm.lastExportResult {
                ShareSheet(
                    items: [result.fileURL],
                    completion: { _ in }
                )
            }
        }
        .sheet(isPresented: $showPublishSheet) {
            PublishSheet(vm: vm)
        }
    }

    private func statusColor(for status: PublishJobStatus) -> Color {
        switch status {
        case .preparing, .uploading: return Color(hex: "#DC2626")
        case .queued, .processing: return .orange
        case .published: return .green
        case .failed: return .red
        case .cancelled: return .gray
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

// MARK: - Notification for publish status
extension Notification.Name {
    static let showPublishStatus = Notification.Name("showPublishStatus")
}
