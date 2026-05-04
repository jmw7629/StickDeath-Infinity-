// StudioImportVideo.swift
// Full-screen import video — dashed upload area, format info
// Matches StickDeath Infinity reference design

import SwiftUI
import PhotosUI

struct StudioImportVideo: View {
    @ObservedObject var vm: EditorViewModel
    @Binding var activePanel: StudioPanel
    @State private var selectedItem: PhotosPickerItem?
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("🎬")
                    .font(.system(size: 14))
                Text("Import Video")
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
            .padding(.bottom, 20)

            Spacer()

            // Upload area
            VStack(spacing: 16) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 36))
                    .foregroundStyle(Color(hex: "E03030"))

                VStack(spacing: 4) {
                    Text("Drop a video file here")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("or tap to browse")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                }

                PhotosPicker(selection: $selectedItem, matching: .videos) {
                    Text("Choose Video")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: "E03030")))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [10, 6]))
                    .foregroundStyle(.white.opacity(isDragging ? 0.4 : 0.1))
            )
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isDragging ? Color(hex: "E03030").opacity(0.05) : .clear)
            )
            .padding(.horizontal, 24)

            Spacer()

            // Format info
            VStack(spacing: 8) {
                Text("SUPPORTED FORMATS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.3))

                HStack(spacing: 12) {
                    ForEach(["MP4", "MOV", "AVI", "WebM"], id: \.self) { fmt in
                        Text(fmt)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.04)))
                    }
                }

                Text("Max 500MB · Video will be split into frames automatically")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.25))
                    .padding(.top, 4)
            }
            .padding(.bottom, 30)
        }
        .background(Color(hex: "111111"))
        .ignoresSafeArea()
    }
}
