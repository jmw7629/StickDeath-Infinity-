// StudioSoundLibrary.swift
// Full-screen sound library — 2-column grid with colored-border category cards
// Matches StickDeath Infinity reference design

import SwiftUI

struct SoundCategory: Identifiable {
    let id: String
    let title: String
    let icon: String
    let count: Int
    let borderColor: Color
}

struct StudioSoundLibrary: View {
    @ObservedObject var vm: EditorViewModel
    @Binding var activePanel: StudioPanel
    @State private var search: String = ""

    let categories: [SoundCategory] = [
        .init(id: "punch", title: "Punches", icon: "🥊", count: 18, borderColor: Color(hex: "E03030")),
        .init(id: "kick", title: "Kicks", icon: "🦵", count: 12, borderColor: Color(hex: "F2A033")),
        .init(id: "sword", title: "Swords", icon: "⚔️", count: 15, borderColor: Color(hex: "4A90D9")),
        .init(id: "gun", title: "Gunshots", icon: "💥", count: 22, borderColor: Color(hex: "E03030")),
        .init(id: "explosion", title: "Explosions", icon: "🔥", count: 10, borderColor: Color(hex: "F2A033")),
        .init(id: "whoosh", title: "Whooshes", icon: "💨", count: 20, borderColor: Color(hex: "34C77B")),
        .init(id: "impact", title: "Impacts", icon: "💢", count: 16, borderColor: Color(hex: "8B5CF6")),
        .init(id: "voice", title: "Voice FX", icon: "🗣️", count: 8, borderColor: Color(hex: "4A90D9")),
        .init(id: "ambient", title: "Ambience", icon: "🌳", count: 14, borderColor: Color(hex: "34C77B")),
        .init(id: "music", title: "Music BG", icon: "🎵", count: 6, borderColor: Color(hex: "8B5CF6")),
        .init(id: "comedy", title: "Comedy", icon: "😂", count: 11, borderColor: Color(hex: "F2A033")),
        .init(id: "horror", title: "Horror", icon: "👻", count: 9, borderColor: Color(hex: "E03030")),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("🔊")
                    .font(.system(size: 14))
                Text("Sound Library")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button { activePanel = .audio } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.3))
                TextField("Search sounds...", text: $search)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            // Category grid
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ], spacing: 12) {
                    ForEach(categories) { cat in
                        Button {} label: {
                            HStack(spacing: 10) {
                                Text(cat.icon)
                                    .font(.system(size: 20))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cat.title)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                    Text("\(cat.count) sounds")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.2))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(hex: "1a1a1a"))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(cat.borderColor.opacity(0.5), lineWidth: 2)
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .background(Color(hex: "111111"))
        .ignoresSafeArea()
    }
}
