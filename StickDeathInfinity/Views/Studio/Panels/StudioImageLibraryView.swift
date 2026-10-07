import SwiftUI

/// The existing Add Picture surface presents this local catalogue. Selection
/// returns to its real preview/import session; browsing never edits a project.
@MainActor
struct StudioImageLibraryView: View {
    let onSelect: (StudioImageCatalogue, StudioImageCatalogue.Image) -> Void
    let onClose: () -> Void
    @State private var catalogue: StudioImageCatalogue?
    @State private var optionalCatalogue: StudioImageCatalogue?
    @State private var pack: StudioImagePackCache.Descriptor?
    @State private var packTask: Task<Void, Never>?
    @State private var packBusy = false
    @State private var packNeedsRemoval = false
    @State private var packNotice: String?
    @State private var packRequest = UUID()
    @Environment(\.scenePhase) private var scenePhase
    private var sources: [StudioImageCatalogue] { [catalogue, optionalCatalogue].compactMap { $0 } }
    private func source(for image: StudioImageCatalogue.Image) -> StudioImageCatalogue? {
        sources.first { $0.images.contains(image) }
    }
    @State private var query = ""
    @State private var favorites = Set<String>()
    @State private var recent: [String] = []
    @State private var collection = "All"
    @State private var preferenceNotice: String?
    private func preferences(_ catalogue: StudioImageCatalogue) -> StudioImageLibraryPreferences {
        .init(allowedIDs: Set(catalogue.images.map(\.id) + (pack?.tiles.map { "kenney.1-bit-scenery.x\($0.x).y\($0.y)" } ?? [])))
    }
    @State private var category: StudioImageCatalogue.Category?
    @State private var includeCartoonWeapons = true
    @State private var failure: String?
    @State private var loadID = UUID()
    @FocusState private var searchFocused: Bool

    private var matches: [StudioImageCatalogue.Image] {
        let found = sources.flatMap { $0.search(query, category: category, includeCartoonWeapons: includeCartoonWeapons) }
        if collection == "Favorites" { return found.filter { favorites.contains($0.id) } }
        if collection == "Recent" {
            let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
            return recent.compactMap { byID[$0] }
        }
        return found
    }

    var body: some View {
        VStack(spacing: 12) {
            PanelHeader(title: "Image Library", icon: "square.grid.2x2.fill", onClose: onClose)
            if let catalogue {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(sources.reduce(0) { $0 + $1.images.count }) free pictures · available offline")
                        .font(.specialElite(16)).foregroundColor(.white)
                        .accessibilityIdentifier("studio.image-library.count")
                    if let pack {
                        HStack {
                            Text("\(pack.title) · \(pack.tiles.count) additional pictures").font(.caption)
                            Spacer()
                            if packBusy {
                                Button("Cancel") { cancelPack() }
                            } else if optionalCatalogue != nil || packNeedsRemoval {
                                Button("Remove download") { changePack(remove: true) }
                            } else {
                                Button("Download 643 KB") { changePack(remove: false) }
                            }
                        }.foregroundColor(.white.opacity(0.8))
                            .accessibilityIdentifier("studio.image-library.pack")
                        if packBusy { ProgressView("Downloading and verifying pictures…").tint(.red) }
                        if let packNotice { Text(packNotice).font(.caption).foregroundColor(.white.opacity(0.7)) }
                    }
                    TextField("Search pictures, tags…", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($searchFocused).submitLabel(.search)
                        .onSubmit { searchFocused = false }
                        .padding(12).background(Color.white.opacity(0.08)).cornerRadius(12)
                        .foregroundColor(.white)
                        .accessibilityIdentifier("studio.image-library.search")
                    Picker("Category", selection: $category) {
                        Text("All").tag(StudioImageCatalogue.Category?.none)
                        Text("Props").tag(StudioImageCatalogue.Category?.some(.props))
                        Text("Scenery").tag(StudioImageCatalogue.Category?.some(.scenery))
                        Text("Effects").tag(StudioImageCatalogue.Category?.some(.effects))
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("studio.image-library.category")
                    Picker("Collection", selection: $collection) {
                        Text("All").tag("All"); Text("Favorites").tag("Favorites"); Text("Recent").tag("Recent")
                    }.pickerStyle(.segmented).accessibilityIdentifier("studio.image-library.collection")
                    if collection == "Recent" {
                        Button("Clear recent previews") {
                            preferences(catalogue).clearRecent(); recent = []
                        }.font(.caption).foregroundColor(.red)
                    }
                    if let preferenceNotice { Text(preferenceNotice).font(.caption).foregroundColor(.red) }
                    Toggle("Include cartoon weapons", isOn: $includeCartoonWeapons)
                        .font(.caption).tint(.red).foregroundColor(.white.opacity(0.8))
                        .accessibilityIdentifier("studio.image-library.weapons")
                    HStack {
                        Text("\(matches.count) matching pictures").font(.caption)
                            .accessibilityIdentifier("studio.image-library.matches")
                        Spacer()
                        Button("Clear filters") {
                            query = ""; category = nil; collection = "All"; includeCartoonWeapons = true; searchFocused = false
                        }.font(.caption).foregroundColor(.red)
                    }.foregroundColor(.white.opacity(0.7))
                    Text("Choose a picture to preview it. Add attaches it to a new image layer. This build supports one imported picture per frame.")
                        .font(.caption).foregroundColor(.white.opacity(0.6))
                }
                .padding(.horizontal, 20)
                if matches.isEmpty {
                    Text("No matching pictures").foregroundColor(.white.opacity(0.7))
                        .accessibilityIdentifier("studio.image-library.empty")
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                            ForEach(matches) { item in
                                VStack(spacing: 4) {
                                Button {
                                    let store = preferences(catalogue); store.recordPreview(item.id); recent = store.recent
                                    if let selectedSource = source(for: item) { onSelect(selectedSource, item) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        if let selectedSource = source(for: item) {
                                            StudioLibraryThumbnail(item: item, catalogue: selectedSource)
                                                .frame(height: 106).frame(maxWidth: .infinity)
                                                .background(Color.white.opacity(0.9)).cornerRadius(8)
                                        }
                                        Text(item.title).font(.specialElite(14)).lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text("Kenney · CC0").font(.caption2).foregroundColor(.white.opacity(0.65))
                                    }
                                    .foregroundColor(.white).padding(10)
                                    .background(Color.white.opacity(0.06)).cornerRadius(12)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Preview \(item.title), free CC0 picture by Kenney")
                                .accessibilityIdentifier("studio.image-library.item." + item.id)
                                Button {
                                    let store = preferences(catalogue)
                                    preferenceNotice = store.toggleFavorite(item.id) ? nil : "You can keep up to 256 favorites. Remove one before adding another."
                                    favorites = Set(store.favorites)
                                } label: {
                                    Label(favorites.contains(item.id) ? "Favorited" : "Favorite",
                                          systemImage: favorites.contains(item.id) ? "star.fill" : "star")
                                        .font(.caption).foregroundColor(.red).frame(maxWidth: .infinity, minHeight: 32)
                                }.accessibilityIdentifier("studio.image-library.favorite." + item.id)
                                }
                            }
                        }
                        .padding(20)
                    }
                    .accessibilityIdentifier("studio.image-library.grid")
                }
            } else if let failure {
                Text(failure).foregroundColor(.white).padding()
                    .accessibilityIdentifier("studio.image-library.error")
                Button("Try again") { self.failure = nil; loadID = UUID() }.tint(.red)
                Spacer()
            } else {
                ProgressView("Loading pictures…").tint(.red).foregroundColor(.white)
                Spacer()
            }
        }
        .background(Color(hex: "0A0A0F"))
        .task(id: loadID) {
            do {
                let loaded = try await StudioImageCatalogue.loadBundled()
                try Task.checkCancellation(); catalogue = loaded; failure = nil
                pack = try? StudioImagePackCache.descriptor()
                if let pack {
                    do { optionalCatalogue = try await StudioImagePackCache.shared.installed(pack) }
                    catch is CancellationError { throw CancellationError() }
                    catch { packNeedsRemoval = true; packNotice = "Downloaded pictures could not be verified. Remove the downloaded copy and try again." }
                }
                let store = preferences(loaded); favorites = Set(store.favorites); recent = store.recent
            } catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
        .onChange(of: query) { if query.count > 256 { query = String(query.prefix(256)) } }
        .onDisappear { cancelPack() }
        .onChange(of: scenePhase) {
            if scenePhase != .active { cancelPack() }
            else { loadID = UUID() }
        }
    }
    private func cancelPack() {
        packRequest = UUID(); packTask?.cancel(); packTask = nil; packBusy = false
    }
    private func changePack(remove: Bool) {
        guard let pack, !packBusy else { return }
        let request = UUID(); packRequest = request; packBusy = true; packNotice = nil
        packTask = Task {
            do {
                if remove { try await StudioImagePackCache.shared.remove(pack) }
                else { _ = try await StudioImagePackCache.shared.download(pack) }
                let installed = try await StudioImagePackCache.shared.installed(pack)
                try Task.checkCancellation()
                guard packRequest == request else { return }
                optionalCatalogue = installed; packNeedsRemoval = false; packBusy = false; packTask = nil
                packNotice = remove ? "Downloaded library copy removed. Pictures already added to your projects are kept." : "Pictures verified and available offline."
            } catch is CancellationError { }
            catch {
                guard packRequest == request else { return }
                packBusy = false; packTask = nil; packNotice = error.localizedDescription
            }
        }
    }
}

@MainActor
private struct StudioLibraryThumbnail: View {
    let item: StudioImageCatalogue.Image
    let catalogue: StudioImageCatalogue
    @State private var image: CGImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image {
                Image(image, scale: 1, label: Text(item.title)).resizable().scaledToFit().padding(8)
            } else if failed {
                Text("Preview unavailable").font(.caption).foregroundColor(.black)
            } else { ProgressView().tint(.red) }
        }
        .task(id: item.id) {
            do {
                let decoded = try await StudioImageLibraryThumbnails.shared.image(item, catalogue: catalogue)
                try Task.checkCancellation(); image = decoded; failed = false
            } catch is CancellationError { }
            catch { failed = true }
        }
    }
}
