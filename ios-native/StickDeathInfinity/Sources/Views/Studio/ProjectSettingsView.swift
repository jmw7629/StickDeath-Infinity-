// ProjectSettingsView.swift
// Full project settings: FPS, canvas size presets, project name
// v9: Matches web app ProjectSettingsDialog

import SwiftUI

struct ProjectSettingsView: View {
    @ObservedObject var vm: EditorViewModel
    @Environment(\.dismiss) var dismiss

    @State private var projectName: String = ""
    @State private var selectedFPS: Int = 12
    @State private var canvasWidth: Int = 1080
    @State private var canvasHeight: Int = 1920

    private let fpsOptions: [(Int, String)] = [
        (6, "Slow — good for beginners"),
        (8, "Casual animation"),
        (10, "Smooth casual"),
        (12, "Standard — FlipaClip default"),
        (15, "Smooth"),
        (24, "Film standard"),
        (30, "Ultra smooth"),
    ]

    private let canvasPresets: [(String, String, Int, Int)] = [
        ("TikTok / Reels", "9:16", 1080, 1920),
        ("YouTube", "16:9", 1920, 1080),
        ("Instagram Square", "1:1", 1080, 1080),
        ("HD Portrait", "3:4", 1080, 1440),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        // Project Name
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Project Name")
                                .font(.headline)
                                .foregroundStyle(.white)
                            TextField("My Animation", text: $projectName)
                                .textFieldStyle(.roundedBorder)
                                .font(.body)
                        }
                        .padding(.horizontal)

                        // FPS
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Frames Per Second")
                                .font(.headline)
                                .foregroundStyle(.white)

                            ForEach(fpsOptions, id: \.0) { fps, desc in
                                Button {
                                    selectedFPS = fps
                                    HapticManager.shared.buttonTap()
                                } label: {
                                    HStack {
                                        Text("\(fps) FPS")
                                            .font(.subheadline.bold())
                                            .foregroundStyle(.white)
                                            .frame(width: 60, alignment: .leading)
                                        Text(desc)
                                            .font(.caption)
                                            .foregroundStyle(.gray)
                                        Spacer()
                                        if selectedFPS == fps {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.red)
                                        }
                                    }
                                    .padding(12)
                                    .background(selectedFPS == fps ? Color.red.opacity(0.15) : ThemeManager.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                        .padding(.horizontal)

                        // Canvas Size
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Canvas Size")
                                .font(.headline)
                                .foregroundStyle(.white)

                            ForEach(canvasPresets, id: \.0) { name, ratio, w, h in
                                Button {
                                    canvasWidth = w
                                    canvasHeight = h
                                    HapticManager.shared.buttonTap()
                                } label: {
                                    HStack {
                                        // Preview rectangle
                                        let aspect = CGFloat(w) / CGFloat(h)
                                        let previewH: CGFloat = 32
                                        let previewW = previewH * aspect
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color.white.opacity(0.1))
                                            .frame(width: min(previewW, 48), height: min(previewH, 48))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 3)
                                                    .stroke(canvasWidth == w && canvasHeight == h ? Color.red : Color.gray.opacity(0.3), lineWidth: 1)
                                            )

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(name)
                                                .font(.subheadline.bold())
                                                .foregroundStyle(.white)
                                            Text("\(w)×\(h) (\(ratio))")
                                                .font(.caption)
                                                .foregroundStyle(.gray)
                                        }
                                        Spacer()
                                        if canvasWidth == w && canvasHeight == h {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.red)
                                        }
                                    }
                                    .padding(12)
                                    .background(canvasWidth == w && canvasHeight == h ? Color.red.opacity(0.15) : ThemeManager.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                        .padding(.horizontal)

                        // Save button
                        Button {
                            vm.updateProjectSettings(
                                title: projectName.isEmpty ? vm.project.title : projectName,
                                fps: selectedFPS,
                                canvasWidth: canvasWidth,
                                canvasHeight: canvasHeight
                            )
                            dismiss()
                        } label: {
                            Text("Save Settings")
                                .font(.headline)
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(.red)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .padding(.horizontal, 40)
                        .padding(.top, 8)
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("Project Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.red)
                }
            }
            .onAppear {
                projectName = vm.project.title
                selectedFPS = vm.project.fps ?? 12
                canvasWidth = vm.project.canvas_width ?? 1080
                canvasHeight = vm.project.canvas_height ?? 1920
            }
        }
    }
}
