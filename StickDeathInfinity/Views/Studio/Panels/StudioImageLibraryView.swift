import SwiftUI

/// The existing Add Picture surface presents this local catalogue. Selection
/// returns to its real preview/import session; browsing never edits a project.
@MainActor
struct StudioImageLibraryView: View {
    let onSelect: (StudioImageCatalogue, StudioImageCatalogue.Image) -> Void
    let onClose: () -> Void
    @State private var catalogue: StudioImageCatalogue?
    @State private var query = ""
    @State private var category: StudioImageCatalogue.Category?
    @State private var includeCartoonWeapons = true
    @State private var failure: String?
    @State private var loadID = UUID()
    @FocusState private var searchFocused: Bool

    private var matches: [StudioImageCatalogue.Image] {
        catalogue?.search(query, category: category, includeCartoonWeapons: includeCartoonWeapons) ?? []
    }

    var body: some View {
        VStack(spacing: 12) {
            PanelHeader(title: "Image Library", icon: "square.grid.2x2.fill", onClose: onClose)
            if let catalogue {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(catalogue.images.count) free pictures · available offline")
                        .font(.specialElite(16)).foregroundColor(.white)
                        .accessibilityIdentifier("studio.image-library.count")
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
                    Toggle("Include cartoon weapons", isOn: $includeCartoonWeapons)
                        .font(.caption).tint(.red).foregroundColor(.white.opacity(0.8))
                        .accessibilityIdentifier("studio.image-library.weapons")
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
                                Button { onSelect(catalogue, item) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        StudioLibraryThumbnail(item: item, catalogue: catalogue)
                                            .frame(height: 106).frame(maxWidth: .infinity)
                                            .background(Color.white.opacity(0.9)).cornerRadius(8)
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
            } catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
        .onChange(of: query) { if query.count > 256 { query = String(query.prefix(256)) } }
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
