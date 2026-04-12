// PublishSheet.swift
// Share/publish animation to StickDeath channels + user's own

import SwiftUI

struct PublishSheet: View {
    @ObservedObject var vm: EditorViewModel
    @Environment(\.dismiss) var dismiss
    @State private var title = ""
    @State private var publishToStickDeath = true
    @State private var publishToOwn = false
    @State private var selectedPlatforms: Set<String> = ["youtube", "tiktok", "instagram", "facebook"]
    @State private var isPublishing = false
    @State private var published = false

    let platforms = [
        ("youtube", "YouTube", "play.rectangle.fill"),
        ("tiktok", "TikTok", "music.note"),
        ("instagram", "Instagram", "camera.fill"),
        ("facebook", "Facebook", "person.2.fill"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                if published {
                    // Success state
                    VStack(spacing: 20) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.green)
                        Text("Published! 🎉")
                            .font(.title.bold())
                        Text("Your animation is being uploaded to all selected platforms.")
                            .font(.subheadline)
                            .foregroundStyle(.gray)
                            .multilineTextAlignment(.center)
                        Button("Done") { dismiss() }
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.green)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 40)
                    }
                    .padding()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            // Title
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Title").font(.subheadline.bold())
                                TextField("My Awesome Animation", text: $title)
                                    .padding()
                                    .background(ThemeManager.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }

                            // Upload agreement
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: $publishToStickDeath) {
                                    VStack(alignment: .leading) {
                                        Text("Upload to StickDeath channels")
                                            .font(.subheadline.bold())
                                        Text("Required — helps build the community and earn ad revenue")
                                            .font(.caption)
                                            .foregroundStyle(.gray)
                                    }
                                }
                                .tint(.orange)
                                .disabled(true) // Always required

                                Toggle(isOn: $publishToOwn) {
                                    VStack(alignment: .leading) {
                                        Text("Also upload to my channels")
                                            .font(.subheadline.bold())
                                        Text("Share on your connected social accounts too")
                                            .font(.caption)
                                            .foregroundStyle(.gray)
                                    }
                                }
                                .tint(.orange)
                            }

                            // Platform selection
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Platforms").font(.subheadline.bold())
                                ForEach(platforms, id: \.0) { id, name, icon in
                                    HStack {
                                        Image(systemName: icon)
                                            .frame(width: 24)
                                        Text(name).font(.subheadline)
                                        Spacer()
                                        Image(systemName: selectedPlatforms.contains(id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedPlatforms.contains(id) ? .orange : .gray)
                                    }
                                    .padding(12)
                                    .background(ThemeManager.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .onTapGesture {
                                        if selectedPlatforms.contains(id) { selectedPlatforms.remove(id) }
                                        else { selectedPlatforms.insert(id) }
                                    }
                                }
                            }

                            // Publish button
                            Button {
                                Task { await publish() }
                            } label: {
                                if isPublishing {
                                    ProgressView().tint(.black)
                                } else {
                                    Label("Publish Animation", systemImage: "paperplane.fill")
                                        .font(.headline)
                                        .foregroundStyle(.black)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .disabled(title.isEmpty || isPublishing)
                        }
                        .padding(24)
                    }
                }
            }
            .navigationTitle("Publish")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    func publish() async {
        isPublishing = true
        do {
            // 1. Save project
            await vm.saveProject()
            // 2. Publish status
            try await ProjectService.shared.publishProject(projectId: vm.project.id)
            // 3. Trigger server-side publish to social platforms
            try await PublishService.shared.publishToSocial(
                projectId: vm.project.id,
                platforms: Array(selectedPlatforms)
            )
            published = true
        } catch {
            print("Publish error: \(error)")
        }
        isPublishing = false
    }
}
