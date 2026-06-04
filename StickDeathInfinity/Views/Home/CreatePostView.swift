// ═══════════════════════════════════════════════════════════════════
// CreatePostView — Share to social feed
// Matches: src/pages/CreatePost.tsx exactly
// - Cancel / "New Post" / Post header
// - Text area with "What are you working on?" placeholder
// - Character count (0/500)
// - Attach animation from Studio toggle
// - Tags section with add/remove (max 5)
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct CreatePostView: View {
    let onBack: () -> Void
    let onPublish: (String, [String], Bool) -> Void

    @State private var content = ""
    @State private var tagInput = ""
    @State private var tags: [String] = []
    @State private var attachAnimation = false

    private var canPublish: Bool { !content.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ZStack {
            Color.sdBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button { onBack() } label: {
                        Text("Cancel")
                            .font(.specialElite(14))
                            .foregroundColor(.sdTextSecondary)
                    }
                    Spacer()
                    Text("New Post")
                        .font(.specialElite(16))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        if canPublish {
                            onPublish(content.trimmingCharacters(in: .whitespaces), tags, attachAnimation)
                        }
                    } label: {
                        Text("Post")
                            .font(.specialElite(13))
                            .fontWeight(.bold)
                            .foregroundColor(canPublish ? .white : .sdTextMuted)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(canPublish ? Color.sdRed : Color.sdSurfaceLight)
                            .cornerRadius(8)
                    }
                    .disabled(!canPublish)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.sdSurface)
                .overlay(
                    Rectangle().fill(Color.sdBorder).frame(height: 1),
                    alignment: .bottom
                )

                ScrollView {
                    VStack(spacing: 0) {
                        // Text area
                        ZStack(alignment: .topLeading) {
                            if content.isEmpty {
                                Text("What are you working on?")
                                    .font(.specialElite(14))
                                    .foregroundColor(.sdTextMuted)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 14)
                            }
                            TextEditor(text: $content)
                                .font(.specialElite(14))
                                .foregroundColor(.white)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 120)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 10)
                        }
                        .background(Color.sdSurface)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.sdBorder, lineWidth: 1)
                        )
                        .padding(16)

                        // Character count
                        HStack {
                            Spacer()
                            Text("\(content.count)/500")
                                .font(.specialElite(11))
                                .foregroundColor(.sdTextMuted)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, -8)

                        // Animation attachment
                        Button { attachAnimation.toggle() } label: {
                            VStack(spacing: 8) {
                                if attachAnimation {
                                    Text("🎬").font(.system(size: 32))
                                    Text("Animation attached")
                                        .font(.specialElite(13))
                                        .foregroundColor(.sdRed)
                                    Text("Tap to remove")
                                        .font(.specialElite(11))
                                        .foregroundColor(.sdTextSecondary)
                                } else {
                                    Text("📎").font(.system(size: 28))
                                    Text("Attach animation from Studio")
                                        .font(.specialElite(13))
                                        .foregroundColor(.sdTextSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .background(Color.sdSurface)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(
                                        attachAnimation
                                            ? Color.sdRed
                                            : Color.sdBorder,
                                        style: attachAnimation
                                            ? StrokeStyle(lineWidth: 2)
                                            : StrokeStyle(lineWidth: 1, dash: [6, 4])
                                    )
                            )
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                        // Tags
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Tags (max 5)")
                                .font(.specialElite(13))
                                .foregroundColor(.sdTextSecondary)

                            HStack(spacing: 8) {
                                TextField("Add a tag...", text: $tagInput)
                                    .font(.specialElite(13))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Color.sdSurface)
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.sdBorder, lineWidth: 1)
                                    )
                                    .onSubmit { addTag() }

                                Button { addTag() } label: {
                                    Text("+")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .background(tags.count >= 5 ? Color.sdSurfaceLight : Color.sdRed)
                                        .cornerRadius(8)
                                }
                                .disabled(tags.count >= 5)
                            }

                            // Tag pills
                            FlowLayout(spacing: 6) {
                                ForEach(tags, id: \.self) { tag in
                                    Button { removeTag(tag) } label: {
                                        HStack(spacing: 4) {
                                            Text("#\(tag)")
                                            Text("✕")
                                        }
                                        .font(.specialElite(12))
                                        .foregroundColor(.sdRed)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.sdRed.opacity(0.15))
                                        .cornerRadius(8)
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .onChange(of: content) { _ in
            if content.count > 500 {
                content = String(content.prefix(500))
            }
        }
    }

    private func addTag() {
        let tag = tagInput.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        if !tag.isEmpty && !tags.contains(tag) && tags.count < 5 {
            tags.append(tag)
            tagInput = ""
        }
    }

    private func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
    }
}
