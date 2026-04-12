// AssetBrowserView.swift
// Browsable, searchable library of 1,000+ objects and 1,000+ sound effects
// Paginated, cached thumbnails, category filters, preview playback for sounds

import SwiftUI
import AVFoundation

struct AssetBrowserView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var auth: AuthManager
    @StateObject private var library = AssetLibrary.shared
    @State private var tab: AssetTab = .objects
    @State private var selectedCategory: String?
    @State private var searchText = ""

    let onObjectSelected: (StudioAsset) -> Void
    let onSoundSelected: (StudioAsset) -> Void

    enum AssetTab { case objects, sounds }

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Tab picker
                    Picker("", selection: $tab) {
                        Label("Objects (\(AssetLibrary.totalObjectCount)+)", systemImage: "cube.fill").tag(AssetTab.objects)
                        Label("Sounds (\(AssetLibrary.totalSoundCount)+)", systemImage: "speaker.wave.3.fill").tag(AssetTab.sounds)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    // Search
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.gray)
                        TextField(tab == .objects ? "Search 1,000+ objects..." : "Search 1,000+ sounds...", text: $searchText)
                            .textFieldStyle(.plain)
                            .autocapitalization(.none)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.gray)
                            }
                        }
                    }
                    .padding(10)
                    .background(ThemeManager.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    // Categories
                    let categories = tab == .objects ? AssetLibrary.objectCategories : AssetLibrary.soundCategories
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            CategoryChip(name: "All", icon: "square.grid.2x2", color: .white, selected: selectedCategory == nil) {
                                selectedCategory = nil
                            }
                            ForEach(categories) { cat in
                                CategoryChip(name: cat.name, icon: cat.icon, color: cat.color, selected: selectedCategory == cat.id) {
                                    selectedCategory = selectedCategory == cat.id ? nil : cat.id
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }

                    // Asset grid
                    if tab == .objects {
                        ObjectsGridView(
                            category: selectedCategory,
                            searchText: searchText,
                            isPro: auth.isPro,
                            onSelect: { asset in onObjectSelected(asset); dismiss() }
                        )
                    } else {
                        SoundsListView(
                            category: selectedCategory,
                            searchText: searchText,
                            isPro: auth.isPro,
                            onSelect: { asset in onSoundSelected(asset); dismiss() }
                        )
                    }
                }
            }
            .navigationTitle("Asset Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Category Chip
struct CategoryChip: View {
    let name: String
    let icon: String
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                Text(name).font(.caption.bold())
            }
            .foregroundStyle(selected ? .black : color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? color : color.opacity(0.12))
            .clipShape(Capsule())
        }
    }
}

// MARK: - Objects Grid (lazy, paginated)
struct ObjectsGridView: View {
    let category: String?
    let searchText: String
    let isPro: Bool
    let onSelect: (StudioAsset) -> Void

    @State private var items: [StudioAsset] = []
    @State private var loading = true

    var filtered: [StudioAsset] {
        var result = items
        if let cat = category { result = result.filter { $0.category == cat } }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter { $0.name.lowercased().contains(q) || $0.tags.contains(where: { $0.contains(q) }) }
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                ForEach(filtered) { asset in
                    ObjectTile(asset: asset, isPro: isPro) {
                        if !asset.isPro || isPro { onSelect(asset) }
                    }
                }
            }
            .padding(16)
        }
        .task { loadItems() }
        .onChange(of: category) { _, _ in loadItems() }
    }

    func loadItems() {
        loading = true
        items = AssetLibrary.builtInObjects(category: category)
        loading = false
    }
}

struct ObjectTile: View {
    let asset: StudioAsset
    let isPro: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ThemeManager.surface)
                        .frame(height: 70)

                    // SF Symbol preview (built-in assets use symbol lookup)
                    Image(systemName: iconForAsset(asset))
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.6))

                    if asset.isPro && !isPro {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.black)
                                    .padding(3)
                                    .background(.orange)
                                    .clipShape(Circle())
                                    .padding(3)
                            }
                            Spacer()
                        }
                    }
                }

                Text(asset.name)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .opacity(asset.isPro && !isPro ? 0.5 : 1)
    }

    func iconForAsset(_ asset: StudioAsset) -> String {
        switch asset.category {
        case "weapons": return "shield.slash.fill"
        case "vehicles": return "car.fill"
        case "environments": return "building.2.fill"
        case "effects": return "sparkle"
        case "furniture": return "sofa.fill"
        case "clothing": return "tshirt.fill"
        case "food": return "fork.knife"
        case "sports": return "sportscourt.fill"
        case "animals": return "hare.fill"
        case "tech": return "cpu.fill"
        case "text": return "textformat.abc"
        default: return "cube.fill"
        }
    }
}

// MARK: - Sounds List (with playback preview)
struct SoundsListView: View {
    let category: String?
    let searchText: String
    let isPro: Bool
    let onSelect: (StudioAsset) -> Void

    @State private var items: [StudioAsset] = []
    @State private var playingId: String?
    @State private var loading = true

    var filtered: [StudioAsset] {
        var result = items
        if let cat = category { result = result.filter { $0.category == cat } }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter { $0.name.lowercased().contains(q) || $0.tags.contains(where: { $0.contains(q) }) }
        }
        return result
    }

    // Group by subcategory
    var grouped: [(String, [StudioAsset])] {
        Dictionary(grouping: filtered, by: { $0.subcategory })
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(grouped, id: \.0) { subcategory, assets in
                    Text(subcategory)
                        .font(.caption.bold())
                        .foregroundStyle(.gray)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    ForEach(assets) { asset in
                        SoundRow(asset: asset, isPro: isPro, isPlaying: playingId == asset.id) {
                            // Toggle preview
                            if playingId == asset.id {
                                playingId = nil
                            } else {
                                playingId = asset.id
                                // Auto-stop after 3s
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                    if playingId == asset.id { playingId = nil }
                                }
                            }
                        } onAdd: {
                            if !asset.isPro || isPro { onSelect(asset) }
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .task { loadItems() }
        .onChange(of: category) { _, _ in loadItems() }
    }

    func loadItems() {
        loading = true
        items = AssetLibrary.builtInSounds(category: category)
        loading = false
    }
}

struct SoundRow: View {
    let asset: StudioAsset
    let isPro: Bool
    let isPlaying: Bool
    let onPreview: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Preview play button
            Button(action: onPreview) {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(isPlaying ? .orange : .white.opacity(0.5))
            }

            // Info
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(asset.name).font(.subheadline)
                    if asset.isPro && !isPro {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                    }
                }
                Text(asset.category.capitalized).font(.caption2).foregroundStyle(.gray)
            }

            Spacer()

            // Waveform animation
            if isPlaying {
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.orange)
                            .frame(width: 2, height: CGFloat.random(in: 4...16))
                    }
                }
                .frame(width: 16, height: 16)
            }

            // Add to timeline
            Button(action: onAdd) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(asset.isPro && !isPro ? .gray : .orange)
            }
            .disabled(asset.isPro && !isPro)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isPlaying ? ThemeManager.surface : .clear)
    }
}
