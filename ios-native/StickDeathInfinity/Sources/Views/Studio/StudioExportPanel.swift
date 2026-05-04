// StudioExportPanel.swift
// Full-screen export panel — FORMAT grid, QUALITY, Watermark, SHARE TO
// PRO badges on premium formats. Red border on selected format.
// Matches StickDeath Infinity reference design

import SwiftUI

enum ExportFormat: String, CaseIterable {
    case mp4 = "MP4"
    case gif = "GIF"
    case webm = "WebM"
    case mov = "MOV"

    var subtitle: String {
        switch self {
        case .mp4: return "Best quality"
        case .gif: return "Animated image"
        case .webm: return "Web playback"
        case .mov: return "Apple ProRes"
        }
    }

    var isPro: Bool {
        switch self {
        case .mp4: return false
        case .gif, .webm, .mov: return true
        }
    }
}

enum ExportQuality: String, CaseIterable {
    case sd = "SD"
    case hd = "HD"
    case fhd = "Full HD"

    var resolution: String {
        switch self {
        case .sd: return "480p"
        case .hd: return "720p"
        case .fhd: return "1080p"
        }
    }
}

struct StudioExportPanel: View {
    @ObservedObject var vm: EditorViewModel
    @Binding var activePanel: StudioPanel
    @State private var selectedFormat: ExportFormat = .mp4
    @State private var selectedQuality: ExportQuality = .hd
    @State private var watermarkEnabled = true
    @State private var isExporting = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("📤")
                    .font(.system(size: 14))
                Text("Export")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button { activePanel = .none } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // FORMAT section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("FORMAT")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.3))

                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)
                        ], spacing: 10) {
                            ForEach(ExportFormat.allCases, id: \.self) { fmt in
                                Button { selectedFormat = fmt } label: {
                                    VStack(spacing: 4) {
                                        HStack {
                                            Spacer()
                                            if fmt.isPro {
                                                Text("PRO")
                                                    .font(.system(size: 8, weight: .bold))
                                                    .foregroundStyle(Color(hex: "E03030"))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color(hex: "E03030").opacity(0.15))
                                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                            }
                                        }
                                        Text(fmt.rawValue)
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundStyle(selectedFormat == fmt ? Color(hex: "E03030") : .white)
                                        Text(fmt.subtitle)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.white.opacity(0.4))
                                    }
                                    .padding(.vertical, 14)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(selectedFormat == fmt ? Color(hex: "E03030").opacity(0.08) : .white.opacity(0.03))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(selectedFormat == fmt ? Color(hex: "E03030") : .white.opacity(0.06), lineWidth: 2)
                                    )
                                }
                            }
                        }
                    }

                    // QUALITY section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("QUALITY")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.3))

                        HStack(spacing: 8) {
                            ForEach(ExportQuality.allCases, id: \.self) { q in
                                Button { selectedQuality = q } label: {
                                    VStack(spacing: 2) {
                                        Text(q.rawValue)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(selectedQuality == q ? .white : .white.opacity(0.5))
                                        Text(q.resolution)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.3))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(selectedQuality == q ? Color(hex: "E03030") : .white.opacity(0.04))
                                    )
                                }
                            }
                        }
                    }

                    // WATERMARK
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WATERMARK")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.3))

                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Color(hex: "E03030"))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("StickDeath Infinity Watermark")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white)
                                Text("Small watermark in bottom corner")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            Spacer()
                            Toggle("", isOn: $watermarkEnabled)
                                .tint(Color(hex: "E03030"))
                                .scaleEffect(0.85)
                                .labelsHidden()
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.03)))
                    }

                    // SHARE TO
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SHARE TO")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.3))

                        HStack(spacing: 12) {
                            shareTarget("YouTube", icon: "play.rectangle.fill", color: .red)
                            shareTarget("TikTok", icon: "music.note", color: .white)
                            shareTarget("Instagram", icon: "camera", color: Color(hex: "8B5CF6"))
                            shareTarget("Save", icon: "square.and.arrow.down", color: Color(hex: "4A90D9"))
                        }
                    }

                    // Export button
                    Button {
                        isExporting = true
                    } label: {
                        HStack {
                            if isExporting {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            Text(isExporting ? "Exporting..." : "Export \(selectedFormat.rawValue)")
                                .font(.system(size: 16, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "E03030")))
                    }
                    .disabled(isExporting)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
        }
        .background(Color(hex: "111111"))
        .ignoresSafeArea()
    }

    func shareTarget(_ name: String, icon: String, color: Color) -> some View {
        Button {} label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white.opacity(0.06)))
                Text(name)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}
