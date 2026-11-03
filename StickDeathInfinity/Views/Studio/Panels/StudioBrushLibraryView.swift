import SwiftUI

extension StudioBrushFamily {
    var title: String {
        switch self {
        case .round: return "Round"
        case .stipple: return "Stipple"
        case .grain: return "Grain"
        case .roughPen: return "Rough Pen"
        case .calligraphy: return "Calligraphy"
        case .dipPen: return "Dip Pen"
        case .halftone: return "Halftone"
        case .hatchRight: return "Hatch /"
        case .hatchLeft: return "Hatch \\"
        case .gradient: return "Gradient"
        case .airbrush: return "Airbrush"
        case .watercolor: return "Watercolor"
        case .neon: return "Neon"
        }
    }
}

/// A contextual library inside the existing floating settings panel. Samples
/// are rendered by the same native brush engine as editable strokes.
struct StudioBrushLibraryView: View {
    @ObservedObject var vm: StudioViewModel
    let didSelect: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var savedBrushes: [StudioSavedBrush] = []
    @State private var storageReadable = true
    @State private var feedback: String?
    @State private var namingBrush = false
    @State private var draftName = ""
    @State private var capturedSettings: StudioBrushSettings?
    @State private var renamingBrush: StudioSavedBrush?
    @State private var deletingBrush: StudioSavedBrush?
    @State private var confirmingDeletion = false
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            savedLibrary
            Divider().background(Color.white.opacity(0.12))
            Text("Built-in brushes").font(.specialElite(11)).foregroundColor(.sdStudioSecondaryText)
            builtInLibrary
        }
        .onAppear(perform: reloadSavedBrushes)
        .onChange(of: vm.selectedTool) { _, _ in dismissDrafts() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { dismissDrafts() }
        }
        .onDisappear(perform: dismissDrafts)
        .alert(renamingBrush == nil ? "Save brush" : "Rename brush", isPresented: $namingBrush) {
            TextField("Brush name", text: $draftName)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("studio.saved-brush.name")
            Button("Cancel", role: .cancel) { capturedSettings = nil; renamingBrush = nil }
            Button("Save", action: finishNaming)
                .disabled(nameProblem != nil)
                .accessibilityIdentifier("studio.saved-brush.name.save")
        } message: {
            Text(nameProblem ?? "Use this name to find the brush on this device.")
        }
        .confirmationDialog("Delete saved brush?", isPresented: $confirmingDeletion,
            titleVisibility: .visible, presenting: deletingBrush) { brush in
            Button("Delete saved brush", role: .destructive) { delete(brush) }
            Button("Cancel", role: .cancel) { deletingBrush = nil }
        } message: { brush in
            Text("Remove \"\(brush.name)\" from this device? Existing drawings and the current brush stay as they are.")
        }
        .confirmationDialog("Reset saved brushes?", isPresented: $confirmingReset,
            titleVisibility: .visible) {
            Button("Reset saved brushes", role: .destructive) {
                do {
                    try StudioSavedBrushStore.resetUnreadable()
                    reloadSavedBrushes()
                } catch { handleFailure(error) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Remove the unreadable saved-brush list from this device so you can save brushes again? Existing drawings and tool settings stay as they are.")
        }
    }

    private var savedLibrary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Saved brushes").font(.specialElite(11))
                Spacer()
                Text("\(savedBrushes.count)/\(StudioSavedBrushStore.maximumBrushes)")
                    .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
            }.foregroundColor(.white)
            Button(action: beginSaving) {
                Label("Save current brush", systemImage: "plus")
                    .font(.specialElite(11))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundColor(.white)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .disabled(!canChangeBrush || !storageReadable || savedBrushes.count >= StudioSavedBrushStore.maximumBrushes)
            .accessibilityIdentifier("studio.saved-brush.add")
            Text("Save size, opacity and brush effects. Applying a saved brush keeps your drawing color, mirror and ruler settings.")
                .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
            if savedBrushes.isEmpty && storageReadable {
                Text("Tune a brush below, then save it here to use again with any drawing tool.")
                    .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
            }
            ForEach(savedBrushes) { brush in savedBrushRow(brush) }
            if let feedback {
                Text(feedback).font(.specialElite(10)).foregroundColor(.orange)
                    .accessibilityIdentifier("studio.saved-brush.feedback")
            }
            if !storageReadable {
                Button("Reset saved brushes") { confirmingReset = true }
                    .font(.specialElite(10)).foregroundColor(.sdStudioActionText)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("studio.saved-brush.reset")
            }
        }
    }

    private func savedBrushRow(_ brush: StudioSavedBrush) -> some View {
        HStack(spacing: 0) {
            Button { apply(brush) } label: {
                HStack(spacing: 6) {
                    StudioSavedBrushSwatch(settings: brush.settings)
                        .equatable()
                        .frame(width: 64, height: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(brush.name).font(.specialElite(11)).lineLimit(2)
                        Text(brush.settings.family.title + " · " + brush.settings.size.formatted(.number.precision(.fractionLength(0...1))) + "px")
                            .font(.specialElite(9)).foregroundColor(.sdStudioSecondaryText)
                    }
                    Spacer(minLength: 0)
                    if !vm.planAllowsBrush(brush.settings.family) {
                        Image(systemName: "lock.fill").font(.system(size: 10)).accessibilityHidden(true)
                    } else if currentSettings == brush.settings {
                        Image(systemName: "checkmark").font(.system(size: 10)).accessibilityHidden(true)
                    }
                }
                .padding(.leading, 6).frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundColor(.white)
            .disabled(!canChangeBrush)
            .accessibilityLabel("Apply saved brush " + brush.name)
            .accessibilityValue(brush.settings.family.title + ", " + brush.settings.size.formatted() + " pixels, " + (brush.settings.opacity * 100).formatted() + " percent opacity")
            .accessibilityIdentifier("studio.saved-brush.apply." + brush.id.uuidString)
            Menu {
                Button("Rename") { beginRenaming(brush) }
                Button("Delete", role: .destructive) {
                    deletingBrush = brush; confirmingDeletion = true
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .foregroundColor(.white)
            .accessibilityLabel("Manage saved brush " + brush.name)
            .accessibilityIdentifier("studio.saved-brush.manage." + brush.id.uuidString)
        }
        .background(Color.white.opacity(currentSettings == brush.settings ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    // Settings are preferences, never document commands. Capture the brush's
    // actual native descriptor, but keep opacity independent of paint alpha.
    // A saved brush can therefore be reused with the creator's current color.
    private var currentSettings: StudioBrushSettings? { try? captureCurrentSettings() }
    private func captureCurrentSettings() throws -> StudioBrushSettings {
        try vm.brushDescriptor(elementID: "studio.saved-brush", seed: 71)
            .settings(width: vm.strokeWidth, opacity: vm.strokeOpacity)
    }
    private var canChangeBrush: Bool {
        scenePhase == .active && vm.isEditing && !vm.isPlaying && !vm.isSaving &&
        vm.activeStrokeID == nil && vm.pendingBrushStroke == nil && vm.textDraft == nil &&
        [.pencil, .pen, .brush, .marker, .crayon].contains(vm.selectedTool)
    }
    private var nameProblem: String? {
        StudioSavedBrushStore.nameProblem(draftName, brushes: savedBrushes, excluding: renamingBrush?.id)
    }
    private func reloadSavedBrushes() {
        do {
            savedBrushes = try StudioSavedBrushStore.load()
            storageReadable = true; feedback = nil
        } catch {
            savedBrushes = []; storageReadable = false; feedback = error.localizedDescription
        }
    }
    private func beginSaving() {
        guard canChangeBrush, storageReadable else { return }
        do {
            // Re-read before showing the dialog; another Studio window may
            // have changed this device's list since this popup was opened.
            savedBrushes = try StudioSavedBrushStore.load()
            guard savedBrushes.count < StudioSavedBrushStore.maximumBrushes else {
                throw StudioSavedBrushStore.Failure.full
            }
            capturedSettings = try captureCurrentSettings()
            renamingBrush = nil
            draftName = StudioSavedBrushStore.suggestedName(vm.brushFamily.title, brushes: savedBrushes)
            feedback = nil; namingBrush = true
        } catch { handleFailure(error) }
    }
    private func beginRenaming(_ brush: StudioSavedBrush) {
        renamingBrush = brush; capturedSettings = nil
        draftName = brush.name; feedback = nil; namingBrush = true
    }
    private func finishNaming() {
        defer { capturedSettings = nil; renamingBrush = nil }
        do {
            let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let expected = renamingBrush {
                savedBrushes = try StudioSavedBrushStore.update { values in
                    guard let index = values.firstIndex(of: expected) else { throw StudioSavedBrushStore.Failure.changed }
                    if let problem = StudioSavedBrushStore.nameProblem(name, brushes: values, excluding: expected.id) {
                        throw StudioSavedBrushStore.Failure.invalid(problem)
                    }
                    values[index].name = name
                }
            } else if let settings = capturedSettings {
                savedBrushes = try StudioSavedBrushStore.update { values in
                    guard values.count < StudioSavedBrushStore.maximumBrushes else { throw StudioSavedBrushStore.Failure.full }
                    if let problem = StudioSavedBrushStore.nameProblem(name, brushes: values) {
                        throw StudioSavedBrushStore.Failure.invalid(problem)
                    }
                    values.append(StudioSavedBrush(id: UUID(), name: name, settings: settings))
                }
            }
            feedback = nil
        } catch { handleFailure(error) }
    }
    private func apply(_ brush: StudioSavedBrush) {
        guard canChangeBrush else { return }
        do {
            savedBrushes = try StudioSavedBrushStore.load()
            guard savedBrushes.contains(brush) else { throw StudioSavedBrushStore.Failure.changed }
            try brush.settings.validate()
            // Saved preferences do not bypass the built-in family's plan gate.
            guard vm.requirePlan(vm.planAllowsBrush(brush.settings.family)) else { return }
            let value = brush.settings
            vm.brushFamily = value.family; vm.strokeWidth = value.size; vm.strokeOpacity = value.opacity
            vm.smoothing = value.smoothing; vm.pressureSensitivity = value.pressureEnabled
            vm.pencilTiltEnabled = value.tiltEnabled; vm.brushTipAngle = value.tipAngleDegrees
            vm.brushTexture = value.texture; vm.brushGrain = value.grain
            vm.brushBuildup = value.buildup; vm.brushBleed = value.bleed; vm.brushAdditiveGlow = value.additiveGlow
            if let color = value.gradientEndColor {
                vm.brushGradientEndColor = Color(red: color.red, green: color.green, blue: color.blue)
            }
            feedback = nil; didSelect()
        } catch { handleFailure(error) }
    }
    private func delete(_ expected: StudioSavedBrush) {
        defer { deletingBrush = nil }
        do {
            savedBrushes = try StudioSavedBrushStore.update { values in
                guard let index = values.firstIndex(of: expected) else { throw StudioSavedBrushStore.Failure.changed }
                values.remove(at: index)
            }
            feedback = nil
        } catch { handleFailure(error) }
    }
    private func handleFailure(_ error: Error) {
        reloadSavedBrushes()
        feedback = error.localizedDescription
    }
    private func dismissDrafts() {
        namingBrush = false; capturedSettings = nil; renamingBrush = nil
        confirmingDeletion = false; deletingBrush = nil; confirmingReset = false
    }

    private var builtInLibrary: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(StudioBrushFamily.allCases, id: \.self) { family in
                Button {
                    // Extra brushes on a limited plan show the upgrade note.
                    guard vm.requirePlan(vm.planAllowsBrush(family)) else { return }
                    vm.brushFamily = family
                    didSelect()
                } label: {
                    VStack(spacing: 3) {
                        StudioBrushSwatch(family: family).frame(height: 25)
                        HStack(spacing: 3) {
                            if !vm.planAllowsBrush(family) {
                                Image(systemName: "lock.fill").font(.system(size: 8)).accessibilityHidden(true)
                            }
                            Text(family.title).font(.specialElite(10))
                        }
                        .foregroundColor(vm.brushFamily == family ? .red : .white.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity).padding(6)
                    .background(Color.white.opacity(vm.brushFamily == family ? 0.12 : 0.04))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(vm.brushFamily == family ? Color.red : .white.opacity(0.12)))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(family.title + " brush")
                .accessibilityIdentifier("studio.brush-family." + family.rawValue)
            }
        }
    }
}

/// Device preferences only: these records never enter a project, its undo
/// history, collaboration payloads or exported artwork.
private struct StudioSavedBrush: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let settings: StudioBrushSettings
}

private enum StudioSavedBrushStore {
    static let maximumBrushes = 24
    private static let maximumBytes = 64 * 1024
    private static let key = "studio.saved-brushes.v1"
    private struct Archive: Codable {
        let version: Int
        let brushes: [StudioSavedBrush]
    }
    enum Failure: Error, LocalizedError {
        case unreadable, full, changed, invalid(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Saved brushes could not be read. Their stored data has been kept. Reset the saved list to start again."
            case .full: return "You can keep up to 24 saved brushes. Delete one before saving another."
            case .changed: return "This saved brush changed in another window. Check the refreshed list and try again."
            case .invalid(let message): return message
            }
        }
    }
    static func nameProblem(_ input: String, brushes: [StudioSavedBrush], excluding id: UUID? = nil) -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Enter a brush name." }
        guard name.count <= 40, name.utf8.count <= 160,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else {
            return "Use a single-line name of 40 characters or fewer."
        }
        guard !brushes.contains(where: { $0.id != id && folded($0.name) == folded(name) }) else {
            return "A saved brush already uses that name."
        }
        return nil
    }
    private static func folded(_ name: String) -> String {
        name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func suggestedName(_ family: String, brushes: [StudioSavedBrush]) -> String {
        let base = "My " + family
        if nameProblem(base, brushes: brushes) == nil { return base }
        for suffix in 2...(maximumBrushes + 1) {
            let candidate = base + " " + String(suffix)
            if nameProblem(candidate, brushes: brushes) == nil { return candidate }
        }
        return "New brush"
    }
    static func load(defaults: UserDefaults = .standard) throws -> [StudioSavedBrush] {
        guard let object = defaults.object(forKey: key) else { return [] }
        guard let data = object as? Data, data.count <= maximumBytes else { throw Failure.unreadable }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1 else { throw Failure.unreadable }
            try validate(archive.brushes)
            return archive.brushes
        } catch { throw Failure.unreadable }
    }
    // Every mutation starts with the current stored list. A stale menu cannot
    // rename/delete a different revision, or overwrite another window's save.
    static func update(defaults: UserDefaults = .standard,
                       mutation: (inout [StudioSavedBrush]) throws -> Void) throws -> [StudioSavedBrush] {
        var brushes = try load(defaults: defaults)
        try mutation(&brushes)
        try validate(brushes)
        let data = try JSONEncoder().encode(Archive(version: 1, brushes: brushes))
        guard data.count <= maximumBytes else { throw Failure.full }
        defaults.set(data, forKey: key)
        return brushes
    }
    static func resetUnreadable(defaults: UserDefaults = .standard) throws {
        // A repair in another window must not be erased by this stale dialog.
        do { _ = try load(defaults: defaults) }
        catch { defaults.removeObject(forKey: key); return }
        throw Failure.changed
    }
    private static func validate(_ brushes: [StudioSavedBrush]) throws {
        guard brushes.count <= maximumBrushes, Set(brushes.map(\.id)).count == brushes.count else { throw Failure.unreadable }
        for brush in brushes {
            guard brush.name == brush.name.trimmingCharacters(in: .whitespacesAndNewlines),
                  nameProblem(brush.name, brushes: brushes, excluding: brush.id) == nil else { throw Failure.unreadable }
            let value = brush.settings
            try value.validate()
            // Match the native descriptor's effective per-family settings;
            // unsupported stored combinations are never applied silently.
            guard (value.buildup == 0 || value.family == .airbrush),
                  (value.bleed == 0 || value.family == .watercolor),
                  (!value.additiveGlow || value.family == .neon),
                  (value.gradientEndColor == nil || value.family == .gradient),
                  (value.gradientEndColor?.alpha ?? 1) == 1 else { throw Failure.unreadable }
        }
    }
}

/// A normalized preview of the saved native geometry, including opacity,
/// texture, pressure and the gradient endpoint. Painting still uses its saved
/// document-pixel size; the swatch alone scales to fit the library row.
private struct StudioSavedBrushSwatch: View, Equatable {
    let settings: StudioBrushSettings
    var body: some View {
        let result = Result {
            try StudioBrushRenderer.geometry(points: [
                StrokePoint(x: 8, y: 18, pressure: 0.4, timestamp: 0),
                StrokePoint(x: 30, y: 8, pressure: 0.7, timestamp: 0.08),
                StrokePoint(x: 65, y: 18, pressure: 1, timestamp: 0.2),
                StrokePoint(x: 90, y: 8, pressure: 0.6, timestamp: 0.24)],
                settings: settings, seed: 71, checkCancellation: {})
        }
        Canvas { context, size in
            switch result {
            case .success(let geometry):
                let bounds = geometry.bounds
                if !bounds.isNull, bounds.width > 0, bounds.height > 0 {
                    let scale = min(max(1, size.width - 4) / bounds.width, max(1, size.height - 4) / bounds.height)
                    context.translateBy(x: size.width / 2 - bounds.midX * scale, y: size.height / 2 - bounds.midY * scale)
                    context.scaleBy(x: scale, y: scale)
                    do { try StudioBrushRenderer.draw(geometry, color: StudioBrushColor(red: 1, green: 1, blue: 1), context: &context) }
                    catch { StudioFrameRenderer.drawFailure(error, context: &context, size: size) }
                }
            case .failure(let error): StudioFrameRenderer.drawFailure(error, context: &context, size: size)
            }
        }.accessibilityHidden(true)
    }
}

private struct StudioBrushSwatch: View {
    let family: StudioBrushFamily
    var body: some View {
        let result = Result {
            try StudioBrushRenderer.geometry(points: [StrokePoint(x: 8, y: 18, timestamp: 0),
                StrokePoint(x: 30, y: 8, timestamp: 0.08), StrokePoint(x: 65, y: 18, timestamp: 0.2),
                StrokePoint(x: 90, y: 8, timestamp: 0.24)],
                settings: StudioBrushSettings(family: family, size: 7, smoothing: 2,
                    gradientEndColor: family == .gradient ? StudioBrushColor(red: 1, green: 0, blue: 0) : nil),
                seed: 71, checkCancellation: {})
        }
        Canvas { context, size in
            switch result {
            case .success(let geometry):
                context.scaleBy(x: size.width / 100, y: size.height / 26)
                do { try StudioBrushRenderer.draw(geometry, color: StudioBrushColor(red: 1, green: 1, blue: 1), context: &context) }
                catch { StudioFrameRenderer.drawFailure(error, context: &context, size: size) }
            case .failure(let error): StudioFrameRenderer.drawFailure(error, context: &context, size: size)
            }
        }.accessibilityHidden(true)
    }
}
