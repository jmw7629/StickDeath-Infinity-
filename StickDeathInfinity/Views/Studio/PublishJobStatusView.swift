// ═══════════════════════════════════════════════════════════════════
// PublishJobStatusView — Shows publish job state, progress, and result
// Displays real server status; never fabricates a published result.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct PublishJobStatusView: View {
    @ObservedObject var vm: StudioViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Color(hex: "#0A0A0F").ignoresSafeArea()

            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 36, height: 4)
                    .padding(.top, 8)

                // Header
                HStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(Color(hex: "#DC2626"))
                    Text("Publish Status")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if let job = vm.currentPublishJob {
                    ScrollView {
                        VStack(spacing: 16) {
                            // Status card
                            VStack(spacing: 12) {
                                HStack(spacing: 10) {
                                    Image(systemName: job.status.icon)
                                        .font(.system(size: 28))
                                        .foregroundColor(statusColor(for: job.status))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(job.status.displayName)
                                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                                            .foregroundColor(.white)
                                        if let error = job.errorMessage {
                                            Text(error)
                                                .font(.system(size: 11))
                                                .foregroundColor(.red)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer()
                                    if job.status.isTerminal {
                                        Button(action: { dismiss() }) {
                                            Text("DONE")
                                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                .foregroundColor(Color(hex: "#DC2626"))
                                        }
                                    }
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(hex: "#12121a"))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(statusColor(for: job.status).opacity(0.3), lineWidth: 1)
                                        )
                                )

                                // Job details
                                VStack(alignment: .leading, spacing: 8) {
                                    DetailRow(label: "Title", value: job.metadata.title)
                                    DetailRow(label: "Visibility", value: job.metadata.visibility.displayName)
                                    DetailRow(label: "Job ID", value: String(job.id.prefix(8)) + "...")
                                    if let serverID = job.serverJobID {
                                        DetailRow(label: "Server ID", value: String(serverID.prefix(12)) + "...")
                                    }
                                    DetailRow(label: "Created", value: formatDate(job.createdAt))
                                    DetailRow(label: "Retries", value: "\(job.retryCount)")
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(hex: "#12121a"))
                                )

                                // Published result
                                if job.status == .published {
                                    VStack(spacing: 10) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 36))
                                            .foregroundColor(.green)

                                        if let videoURL = job.publishedVideoURL {
                                            Text("Published!")
                                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                                .foregroundColor(.green)

                                            if let url = URL(string: videoURL) {
                                                Link(destination: url) {
                                                    HStack(spacing: 6) {
                                                        Image(systemName: "safari")
                                                        Text("Open on YouTube")
                                                    }
                                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                    .foregroundColor(.white)
                                                    .padding(.horizontal, 16)
                                                    .padding(.vertical, 10)
                                                    .background(Color(hex: "#DC2626"))
                                                    .cornerRadius(8)
                                                }
                                            }
                                        }

                                        if let videoID = job.publishedVideoID {
                                            DetailRow(label: "Video ID", value: videoID)
                                        }
                                    }
                                    .padding(16)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color(hex: "#12121a"))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(Color.green.opacity(0.3), lineWidth: 1)
                                            )
                                    )
                                }

                                // Action buttons for active jobs
                                if job.status.canCancel {
                                    HStack(spacing: 12) {
                                        Button(action: {
                                            Task { await vm.cancelPublish() }
                                        }) {
                                            Text("CANCEL")
                                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                .foregroundColor(.red)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 10)
                                                .background(Color(hex: "#12121a"))
                                                .cornerRadius(8)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(Color.red.opacity(0.3), lineWidth: 1)
                                                )
                                        }

                                        if job.status == .failed {
                                            Button(action: {
                                                Task { await vm.retryPublish() }
                                            }) {
                                                Text("RETRY")
                                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                    .foregroundColor(.white)
                                                    .frame(maxWidth: .infinity)
                                                    .padding(.vertical, 10)
                                                    .background(Color(hex: "#DC2626"))
                                                    .cornerRadius(8)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    }
                } else {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "arrow.up.circle")
                            .font(.system(size: 36))
                            .foregroundColor(.white.opacity(0.2))
                        Text("No active publish jobs")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                        Spacer()
                    }
                }
            }
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

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Detail Row
struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
        }
    }
}
