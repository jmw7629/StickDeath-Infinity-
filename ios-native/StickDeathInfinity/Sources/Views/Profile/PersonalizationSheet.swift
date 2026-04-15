// PersonalizationSheet.swift
// Customize animation defaults & app appearance

import SwiftUI

struct PersonalizationSheet: View {
    @EnvironmentObject var auth: AuthManager
    @State private var skillLevel = "beginner"
    @State private var preferredFPS = 24
    @State private var preferredCanvas = "portrait"
    @State private var interests: Set<String> = []

    let allInterests = ["Action", "Comedy", "Sci-Fi", "Horror", "Drama", "Music", "Tutorial", "Experimental"]
    let fpsOptions = [12, 15, 24, 30, 60]
    let canvasOptions = ["portrait", "landscape", "square"]

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Make STICKDEATH ∞ yours")
                        .font(.headline).padding(.horizontal)

                    // Skill Level
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Skill Level").font(.subheadline.bold())
                        Picker("Skill", selection: $skillLevel) {
                            Text("Beginner").tag("beginner")
                            Text("Intermediate").tag("intermediate")
                            Text("Advanced").tag("advanced")
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.horizontal)

                    // Default FPS
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Default Frame Rate").font(.subheadline.bold())
                        HStack(spacing: 8) {
                            ForEach(fpsOptions, id: \.self) { fps in
                                Button {
                                    preferredFPS = fps
                                    HapticManager.shared.buttonTap()
                                } label: {
                                    Text("\(fps)")
                                        .font(.caption.bold())
                                        .foregroundStyle(preferredFPS == fps ? .black : .white)
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .background(preferredFPS == fps ? Color.red : ThemeManager.surface)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Canvas Orientation
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Default Canvas").font(.subheadline.bold())
                        Picker("Canvas", selection: $preferredCanvas) {
                            Text("Portrait").tag("portrait")
                            Text("Landscape").tag("landscape")
                            Text("Square").tag("square")
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.horizontal)

                    // Interests
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Interests").font(.subheadline.bold())
                        Text("Helps us personalize your feed").font(.caption).foregroundStyle(.gray)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 8) {
                            ForEach(allInterests, id: \.self) { interest in
                                Button {
                                    if interests.contains(interest) {
                                        interests.remove(interest)
                                    } else {
                                        interests.insert(interest)
                                    }
                                } label: {
                                    Text(interest)
                                        .font(.caption.bold())
                                        .foregroundStyle(interests.contains(interest) ? .black : .white)
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .frame(maxWidth: .infinity)
                                        .background(interests.contains(interest) ? Color.red : ThemeManager.surface)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 20)
            }
        }
        .navigationTitle("Personalization")
        .navigationBarTitleDisplayMode(.inline)
    }
}
