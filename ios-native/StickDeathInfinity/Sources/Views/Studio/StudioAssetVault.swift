// StudioAssetVault.swift
// Full-screen asset vault — category list with icons, Browse/Recent/Favorites tabs
// Matches StickDeath Infinity reference design

import SwiftUI

struct AssetCategory: Identifiable {
    let id: String
    let title: String
    let icon: String
    let count: Int
}

struct StudioAssetVault: View {
    @ObservedObject var vm: EditorViewModel
    @Binding var activePanel: StudioPanel
    @State private var search: String = ""
    @State private var selectedTab = 0

    let tabs = ["Browse", "Recent", "Favorites"]

    let categories: [AssetCategory] = [
        .init(id: "stickfigures", title: "Stick Figures", icon: "figure.walk", count: 24),
        .init(id: "weapons", title: "Weapons", icon: "bolt.fill", count: 36),
        .init(id: "effects", title: "Effects", icon: "sparkles", count: 18),
        .init(id: "backgrounds", title: "Backgrounds", icon: "photo", count: 12),
        .init(id: "props", title: "Props", icon: "cube", count: 42),
        .init(id: "vehicles", title: "Vehicles", icon: "car.fill", count: 8),
        .init(id: "text", title: "Text Bubbles", icon: "bubble.left.fill", count: 15),
        .init(id: "particles", title: "Particles", icon: "flame.fill", count: 20),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("🗃️")
                    .font(.system(size: 14))
                Text("Asset Vault")
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
            .padding(.bottom, 10)

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.3))
                TextField("Search assets...", text: $search)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            // Tabs
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { i, tab in
                    Button { selectedTab = i } label: {
                        Text(tab)
                            .font(.system(size: 13, weight: selectedTab == i ? .bold : .regular))
                            .foregroundStyle(selectedTab == i ? .white : .white.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) {
                                if selectedTab == i {
                                    Rectangle()
                                        .fill(Color(hex: "E03030"))
                                        .frame(height: 2)
                                }
                            }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
            }

            // Category list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(categories) { cat in
                        Button {} label: {
                            HStack(spacing: 14) {
                                Image(systemName: cat.icon)
                                    .font(.system(size: 18))
                                    .foregroundStyle(Color(hex: "E03030"))
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(Color(hex: "E03030").opacity(0.1)))

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(cat.title)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.white)
                                    Text("\(cat.count) assets")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.35))
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.2))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(.white.opacity(0.04)).frame(height: 1).padding(.leading, 66)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .background(Color(hex: "111111"))
        .ignoresSafeArea()
    }
}
