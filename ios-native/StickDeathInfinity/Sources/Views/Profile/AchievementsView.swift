// AchievementsView.swift
// Layer 2 — CONTEXT (pushed from Profile)

import SwiftUI

struct AchievementsView: View {
    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    // Summary card
                    HStack {
                        VStack(alignment: .leading) {
                            Text("0 / \(Achievement.all.count)")
                                .font(.title.bold())
                            Text("Achievements Unlocked")
                                .font(.caption).foregroundStyle(.gray)
                        }
                        Spacer()
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.yellow.opacity(0.3))
                    }
                    .padding()
                    .background(ThemeManager.surfaceLight)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    // Achievement list
                    ForEach(Achievement.all) { badge in
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(badge.unlocked ? badge.color.opacity(0.2) : ThemeManager.surface)
                                    .frame(width: 50, height: 50)
                                Image(systemName: badge.icon)
                                    .font(.title3)
                                    .foregroundStyle(badge.unlocked ? badge.color : .gray.opacity(0.4))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(badge.title).font(.subheadline.bold())
                                    .foregroundStyle(badge.unlocked ? .white : .gray)
                                Text(badge.description).font(.caption).foregroundStyle(.gray)
                                ProgressView(value: badge.progress)
                                    .tint(badge.color)
                            }

                            Spacer()

                            if badge.unlocked {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding()
                        .background(ThemeManager.surfaceLight)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Achievements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
