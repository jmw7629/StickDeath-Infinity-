import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct StudioProjectLibrary: View {
    @ObservedObject var vm: StudioViewModel
    @EnvironmentObject private var authVM: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var transferContext = StudioPortableTransferContext()
    @State private var importGeneration: UUID?
    @State private var backupGeneration: UUID?
    @State private var showingImport = false
    @State private var showingBackup = false
    @State private var backupDocument: StudioPortableProjectFile?
    @State private var backupName = "Animation.sdiproject"
    @State private var transferTask: Task<Void, Never>?
    @State private var transferID: UUID?
    @State private var transferNotice: String?
    @State private var removal: AnimationMetadata?
    @State private var showingRecovery = false
    @State private var showingStorage = false
    @State private var creating = false
    @State private var name = ""
    @State private var fps = 12
    @State private var projectWidth = 1080
    @State private var projectHeight = 1920
    @State private var backgroundID: String?
    @State private var creationNotice: String?
    @State private var creationTask: Task<Void, Never>?
    @State private var creationBusy = false
    @State private var libraryIsVisible = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var sort: ProjectSort = .modified
    private enum ProjectSort: String, CaseIterable, Identifiable {
        case modified = "Recently edited", title = "Name", frames = "Frame count"
        var id: String { rawValue }
    }
    private var matchingProjects: [AnimationMetadata] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return vm.savedProjects.filter { query.isEmpty || $0.title.localizedStandardContains(query) }.sorted { left, right in
            switch sort {
            case .modified:
                if left.modifiedAt != right.modifiedAt { return left.modifiedAt > right.modifiedAt }
            case .title:
                let order = left.title.localizedStandardCompare(right.title)
                if order != .orderedSame { return order == .orderedAscending }
            case .frames:
                if left.frameCount != right.frameCount { return left.frameCount > right.frameCount }
            }
            return left.id.uuidString < right.id.uuidString
        }
    }

    var body: some View {
        ZStack {
            Color(hex: "0D0D12").ignoresSafeArea()
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Text("SD").font(.specialElite(20)).foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(LinearGradient(colors: [.red, .orange], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 19))
                        .shadow(color: .red.opacity(0.25), radius: 14, y: 6)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("StickDeath Studio").font(.specialElite(25)).foregroundStyle(.white)
                            .accessibilityIdentifier("studio.library")
                        Text("Create. Animate. Destroy.").font(.specialElite(14)).foregroundStyle(.gray)
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    creationNotice = nil
                    creating.toggle()
                } label: {
                    Text(creating ? "− Close New Animation" : "+ New Animation")
                        .font(.specialElite(21)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 68)
                        .background(LinearGradient(colors: [Color(hex: "DC2626"), Color(hex: "FF5038")], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .red.opacity(0.22), radius: 16, y: 5)
                }.buttonStyle(.plain).accessibilityIdentifier("studio.new-project")
                    .disabled(creationBusy)
                if creating {
                    StudioProjectConfigurationCard(name: $name, width: $projectWidth, height: $projectHeight,
                        fps: $fps, backgroundID: $backgroundID, submitTitle: "Create Project →",
                        submitIdentifier: "studio.create-project", notice: creationNotice,
                        busy: creationBusy, onSubmit: createProject)
                    if creationBusy {
                        Button("Cancel preparation") { creationTask?.cancel() }
                            .font(.specialElite(14)).foregroundStyle(.red).frame(minHeight: 44)
                    }
                }
                HStack {
                    Text("YOUR PROJECTS").font(.specialElite(18)).foregroundStyle(.white)
                    Spacer()
                    Text("\(vm.savedProjects.count) projects").font(.specialElite(13)).foregroundStyle(.gray)
                }
                if let message = vm.message { Text(message).font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)).foregroundColor(.red).accessibilityIdentifier("studio.status") }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundColor(.gray)
                    TextField("Search projects", text: $search)
                        .font(.specialElite(14))
                        .foregroundColor(.white).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().accessibilityIdentifier("studio.library.search")
                        .focused($searchFocused).submitLabel(.search)
                        .onSubmit { searchFocused = false }
                    if !search.isEmpty {
                        Button { search = ""; searchFocused = false } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.gray) }
                            .accessibilityLabel("Clear project search")
                    }
                    Menu {
                        Picker("Sort projects", selection: $sort) {
                            ForEach(ProjectSort.allCases) { choice in Text(choice.rawValue).tag(choice) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down").foregroundColor(.red).frame(width: 44, height: 44)
                    }.accessibilityLabel("Sort projects: " + sort.rawValue)
                        .accessibilityIdentifier("studio.library.sort")
                }.padding(.horizontal, 12).background(Color(hex: "17171F")).cornerRadius(12)
                Text("\(matchingProjects.count) of \(vm.savedProjects.count) projects · \(sort.rawValue)")
                    .font(.specialElite(12)).foregroundColor(.gray).accessibilityIdentifier("studio.library.count")
                HStack {
                    Button { importGeneration = transferContext.generation; showingImport = true } label: {
                        Label { Text("Import project backup").font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)) } icon: { Image(systemName: "square.and.arrow.down") }.font(.caption).foregroundColor(.gray)
                    }.accessibilityIdentifier("studio.library.import-backup")
                    Spacer()
                    if let transferNotice { Text(transferNotice).font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)).foregroundColor(.gray) }
                }
                HStack {
                Button { vm.loadRecoverableProjects(); showingRecovery = true } label: {
                    Label { Text("Recently Deleted").font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)) } icon: { Image(systemName: "trash") }.font(.caption).foregroundColor(.gray)
                }.accessibilityIdentifier("studio.library.recently-deleted")
                Spacer()
                Button { showingStorage = true } label: {
                    Label { Text("Storage").font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)) } icon: { Image(systemName: "internaldrive") }.font(.caption).foregroundColor(.gray)
                }.accessibilityIdentifier("studio.library.storage")
                }
                VStack(spacing: 12) {
                    if vm.savedProjects.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "pencil.and.scribble").font(.system(size: 48)).foregroundColor(.red)
                            Text("Your next animation starts here.").font(.specialElite(18)).foregroundColor(.white)
                            Text("Create, draw and save offline. Your projects stay on this device.")
                                .font(.custom("SpecialElite-Regular", size: 16, relativeTo: .callout)).foregroundColor(.gray).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 70)
                    }
                    if !vm.savedProjects.isEmpty && matchingProjects.isEmpty {
                        Text("No projects match your search.").font(.custom("SpecialElite-Regular", size: 16, relativeTo: .callout)).foregroundColor(.gray)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(matchingProjects, id: \.id) { project in
                            ZStack(alignment: .topTrailing) {
                            Button { Task { await vm.openProject(project) } } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)).frame(height: 110)
                                        if let data = project.thumbnailData, let image = UIImage(data: data) {
                                            Image(uiImage: image).resizable().scaledToFit().frame(height: 110)
                                                .accessibilityLabel("Saved first-frame preview")
                                        } else {
                                            Image(systemName: "film.stack").font(.system(size: 30)).foregroundColor(.red)
                                        }
                                    }
                                    Text(project.title).font(.specialElite(14)).foregroundColor(.white).lineLimit(2)
                                    Text("\(project.frameCount) frames · \(project.fps) FPS")
                                        .font(.specialElite(10)).foregroundColor(.gray)
                                    Text(project.modifiedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                                        .font(.specialElite(10)).foregroundColor(.gray)
                                        .accessibilityLabel("Last edited " + project.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                                }.padding(12).background(Color(hex: "17171F")).cornerRadius(14)
                            }
                            .accessibilityIdentifier("studio.project.\(project.id.uuidString)")
                            .accessibilityLabel(project.title)
                            .contextMenu { projectActions(project) }
                            Menu { projectActions(project) } label: {
                                Image(systemName: "ellipsis.circle.fill")
                                    .font(.system(size: 22)).foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color(hex: "17171F").opacity(0.95), in: Circle())
                            }
                            .accessibilityLabel("Actions for " + project.title)
                            .accessibilityIdentifier("studio.project-actions.\(project.id.uuidString)")
                            .padding(12)
                            }
                        }
                    }
                }
            }.padding(20).padding(.bottom, 32).frame(maxWidth: 760).frame(maxWidth: .infinity)
                .disabled(vm.isManagingProjects)
            }.scrollDismissesKeyboard(.interactively)
                .refreshable { if !creationBusy { await vm.loadProjects() } }
                .accessibilityIdentifier("studio.library.scroll")
        }
        .overlay(alignment: .bottom) {
            if transferTask != nil {
                HStack {
                    ProgressView().tint(.red)
                    Text("Transferring project backup…").font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption))
                    Button("Cancel") { transferTask?.cancel() }
                        .accessibilityIdentifier("studio.library.transfer.cancel")
                }.padding().background(Color(hex: "17171F")).foregroundColor(.white).cornerRadius(12)
            }
        }
        .fileImporter(isPresented: $showingImport, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            guard importGeneration == transferContext.generation, transferContext.isActive else { return }
            importGeneration = nil
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                startTransfer { check in
                    let metadata = try await vm.importPortableProject(from: url, checkCancellation: check)
                    transferNotice = "Imported \(metadata.title) as a new project."
                }
            case .failure(let error):
                transferNotice = isPickerCancellation(error) ? "Import cancelled. Projects unchanged." : error.localizedDescription
            }
        }
        .fileExporter(isPresented: $showingBackup, document: backupDocument, contentType: .data, defaultFilename: backupName) { result in
            backupDocument = nil
            guard backupGeneration == transferContext.generation, transferContext.isActive else { return }
            backupGeneration = nil
            switch result {
            case .success: transferNotice = "Project backup saved to Files."
            case .failure(let error):
                transferNotice = isPickerCancellation(error) ? "Backup cancelled. Original preserved." : error.localizedDescription
            }
        }
        .onAppear { libraryIsVisible = true; transferContext.update(active: scenePhase == .active, accountID: authVM.userId) }
        .onDisappear { libraryIsVisible = false; if !vm.isEditing { creationTask?.cancel() }; invalidateTransfers() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { invalidateTransfers(); creationTask?.cancel() }
            transferContext.update(active: phase == .active, accountID: authVM.userId)
        }
        .onChange(of: authVM.userId) { _, _ in
            showingStorage = false
            creationTask?.cancel()
            invalidateTransfers()
            transferContext.update(active: scenePhase == .active, accountID: authVM.userId)
        }
        .confirmationDialog("Move this project to Recently Deleted?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            if let selected = removal {
                Button("Move \(selected.title) to Recently Deleted", role: .destructive) {
                    removal = nil; Task { await vm.moveProjectToRecovery(selected.id) }
                }
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: { Text("Your complete project stays on this device and can be restored. Nothing is permanently erased.") }
        .sheet(isPresented: $showingStorage) { StudioStorageSheet(vm: vm) }
        .sheet(isPresented: $showingRecovery) {
            NavigationStack {
                List {
                    Text("Projects remain on this device until restored. There is no automatic deletion.").font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption))
                    if let message = vm.message { Text(message).foregroundColor(.red) }
                    if vm.recoverableProjects.isEmpty { Text("No readable projects in Recently Deleted.") }
                    ForEach(vm.recoverableProjects, id: \.id) { project in
                        HStack {
                            Text(project.title)
                            Spacer()
                            Button("Restore") { Task { await vm.restoreProject(project.id) } }
                                .accessibilityIdentifier("studio.restore.\(project.id.uuidString)")
                        }
                    }
                }.navigationTitle("Recently Deleted")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingRecovery = false } } }
            }.preferredColorScheme(.dark)
        }

    }
    private func createProject() {
        guard !creationBusy, !vm.isManagingProjects, scenePhase == .active else { return }
        let requestedName = name, width = projectWidth, height = projectHeight, rate = fps
        let preset = backgroundID, account = authVM.userId
        creationBusy = true; creationNotice = nil
        creationTask = Task { @MainActor in
            defer { creationBusy = false; creationTask = nil }
            do {
                var background: StudioImageImportService.ImportedImage?
                if let preset {
                    background = try await StudioImageImportService.shared.prepareBackground(presetID: preset, width: width, height: height)
                }
                try Task.checkCancellation()
                guard libraryIsVisible, authVM.userId == account, scenePhase == .active, !vm.isEditing else { return }
                let saved = await vm.createProject(name: requestedName, width: width, height: height, fps: rate)
                guard saved else { creationNotice = vm.message ?? "The project could not be saved."; return }
                if let background {
                    guard authVM.userId == account, scenePhase == .active, !Task.isCancelled else {
                        vm.message = "Project created without the cancelled background. Add it from Background Library."; return
                    }
                    let document = vm.document
                    _ = try vm.attachImportedImage(background, expectedProjectID: document.id, expectedRevision: document.revision,
                        frameID: document.activeFrameID, layerID: document.activeLayerID)
                    _ = await vm.save()
                }
                creating = false
            } catch is CancellationError { creationNotice = "Preparation cancelled. No background was added." }
            catch {
                if vm.isEditing { vm.message = "Project created; background was not added: " + error.localizedDescription }
                else { creationNotice = error.localizedDescription }
            }
        }
    }
    private func isPickerCancellation(_ error: Error) -> Bool {
        (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSUserCancelledError
    }
    private func invalidateTransfers() {
        transferContext.invalidate()
        transferTask?.cancel()
        showingImport = false; showingBackup = false
        importGeneration = nil; backupGeneration = nil; backupDocument = nil
        if transferTask != nil { transferNotice = "Transfer cancelled because the active screen or account changed. Existing device projects are preserved." }
    }
    private func startTransfer(_ operation: @escaping @MainActor (@escaping @MainActor () throws -> Void) async throws -> Void) {
        guard transferTask == nil, transferContext.isActive else { return }
        let id = UUID(), generation = transferContext.generation
        let context = transferContext
        transferID = id; transferNotice = nil
        transferTask = Task { @MainActor in
            defer { if transferID == id { transferTask = nil; transferID = nil } }
            do {
                try await operation {
                    try Task.checkCancellation()
                    guard context.isActive, context.generation == generation else { throw CancellationError() }
                }
            }
            catch is CancellationError { transferNotice = "Transfer cancelled. Existing projects preserved." }
            catch { transferNotice = error.localizedDescription }
        }
    }
    @ViewBuilder private func projectActions(_ project: AnimationMetadata) -> some View {
        Button {
            searchFocused = false
            startTransfer { check in
                let data = try await vm.preparePortableBackup(project, checkCancellation: check)
                try check()
                backupGeneration = transferContext.generation
                backupDocument = StudioPortableProjectFile(data: data)
                backupName = "Animation-" + project.id.uuidString + ".sdiproject"
                showingBackup = true
            }
        } label: {
            Label("Save Project Backup to Files", systemImage: "square.and.arrow.up")
        }.disabled(vm.isManagingProjects).accessibilityIdentifier("studio.project.backup.\(project.id.uuidString)")
        Button { searchFocused = false; Task { await vm.duplicateProject(project) } } label: {
            Label("Duplicate Project", systemImage: "doc.on.doc")
        }.disabled(vm.isManagingProjects)
        Button(role: .destructive) { searchFocused = false; removal = project } label: {
            Label("Move to Recently Deleted", systemImage: "trash")
        }
    }
}

/// Opaque, bounded native project data. No ZIP paths or executable content.
private struct StudioPortableProjectFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents,
              bytes.count <= DeviceStorageManager.maximumPortableBundleBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard data.count <= DeviceStorageManager.maximumPortableBundleBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        return FileWrapper(regularFileWithContents: data)
    }
}

/// Device projects are not reassigned on login. Only a pending transfer loses
/// authority when its initiating visible foreground/account context changes.
@MainActor private final class StudioPortableTransferContext: ObservableObject {
    private(set) var generation = UUID()
    private(set) var isActive = false
    private var accountID: String?
    func invalidate() { generation = UUID(); isActive = false }
    func update(active: Bool, accountID: String?) {
        if self.accountID != accountID || !active { invalidate() }
        self.accountID = accountID; isActive = active
    }
}

private struct StudioStorageSheet: View {
    @ObservedObject var vm: StudioViewModel
    @EnvironmentObject private var authVM: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var cleanup = StudioRevisionCleanupController()
    @State private var usage: StudioStorageUsage?
    @State private var error: String?
    @State private var notice: String?
    @State private var scanning = false
    @State private var confirmingClear = false
    @State private var cleanupProject: UUID?
    @State private var confirmingCleanup = false
    @State private var refresh = UUID()
    @State private var cacheBytes = DeviceStorageManager.snapshotEncodingCacheFootprint.bytes

    var body: some View {
        NavigationStack {
            List {
                Section("On this device") {
                    Text("Measures Documents and disk caches, including every saved revision. Downloaded image packs and preferences in Application Support, and exported backups outside the app, are excluded. This is not total app or device usage.")
                        .font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)).foregroundStyle(.secondary)
                    if scanning { ProgressView("Measuring files…").accessibilityIdentifier("studio.storage.scanning") }
                    if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("studio.storage.error") }
                    if let usage {
                        row("Projects and revisions", usage.projects)
                        row("Recently Deleted", usage.recentlyDeleted)
                        row("Media", usage.media)
                        row("Other documents and historical files", usage.otherDocuments)
                        row("Preserved disk caches", usage.preservedCaches)
                        LabeledContent("Documents and cache bytes", value: bytes(usage.totalFileBytes))
                            .accessibilityIdentifier("studio.storage.total")
                        if usage.skippedLinksAndSpecialFiles > 0 {
                            Text("\(usage.skippedLinksAndSpecialFiles) links or special files excluded; their targets were not followed.").font(.specialElite(12))
                        }
                    }
                    Button("Refresh usage") { refresh = UUID() }
                        .disabled(scanning).accessibilityIdentifier("studio.storage.refresh")
                }
                Section("Older successful saves") {
                    Text("Remove obsolete full-document snapshots only when their successful save history can be verified. Keeps the current and previous version, original media, legacy files, and failed-save recovery data. Permanent removal is optional; back up projects first. This does not clear Undo or delete your project.")
                        .font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)).foregroundStyle(.secondary)
                    Picker("Project", selection: $cleanupProject) {
                        Text("Choose a project").tag(UUID?.none)
                        ForEach(vm.savedProjects, id: \.id) { project in
                            Text(project.title).tag(Optional(project.id))
                                .accessibilityIdentifier("studio.storage.project-option." + project.id.uuidString)
                        }
                    }.disabled(cleanup.isBusy)
                    .accessibilityIdentifier("studio.storage.project-picker")
                    .onChange(of: cleanupProject) { _, _ in cleanup.cancel(); confirmingCleanup = false }
                    Button("Review older saved versions") { previewCleanup() }
                        .disabled(cleanupProject == nil || cleanup.isBusy)
                        .accessibilityIdentifier("studio.storage.review-revisions")
                    if cleanup.isBusy {
                        ProgressView(cleanup.isRemoving ? "Removing reviewed versions…" : "Checked \(cleanup.scannedRevisions) saved versions…")
                            .accessibilityIdentifier("studio.storage.revision-scanning")
                    }
                    if cleanup.hasReview {
                        Button(cleanup.isRemoving ? "Stop after current removal" : "Cancel review") {
                            cleanup.cancelByUser(); confirmingCleanup = false
                        }.accessibilityIdentifier("studio.storage.cancel-review")
                    }
                    if let preview = cleanup.preview {
                        Text("\(preview.candidates) verified obsolete versions · \(bytes(preview.removableFileBytes)) of file contents. Current and previous saved versions stay on this device.")
                            .font(.specialElite(12)).accessibilityIdentifier("studio.storage.revision-preview")
                        if preview.candidates > 0 {
                            Button("Remove reviewed old versions", role: .destructive) { confirmingCleanup = true }
                                .disabled(cleanup.isBusy).accessibilityIdentifier("studio.storage.remove-revisions")
                        } else {
                            Text("No eligible old versions. Historical and unverified recovery files are preserved.").font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption))
                        }
                        if preview.moreBatchesAvailable {
                            Text("More versions remain. Review another bounded batch after this one finishes.").font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption))
                        }
                    }
                    if let cleanupNotice = cleanup.notice { Text(cleanupNotice).font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)).accessibilityIdentifier("studio.storage.revision-result") }
                }
                Section("Regenerable working memory") {
                    LabeledContent("Estimated frame cache memory", value: bytes(Int64(cacheBytes)))
                    Text("Clear releases cached frame encodings from memory. It does not free disk space. Existing projects, history, media, backups and exports are preserved. Unclassified disk cache files remain untouched.")
                        .font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)).foregroundStyle(.secondary)
                    Button("Clear working cache") { confirmingClear = true }
                        .accessibilityIdentifier("studio.storage.clear-cache")
                    if let notice { Text(notice).font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)).accessibilityIdentifier("studio.storage.notice") }
                }
            }
            .accessibilityIdentifier("studio.storage.list")
            .navigationTitle("Device Storage")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { cleanup.cancel(); dismiss() } } }
            .confirmationDialog(confirmingCleanup ? "Permanently remove these older saved versions?" : "Clear regenerable working cache?",
                                isPresented: Binding(get: { confirmingClear || confirmingCleanup },
                                    set: { if !$0 { confirmingClear = false; confirmingCleanup = false } }),
                                titleVisibility: .visible) {
                if confirmingCleanup {
                    Button("Remove reviewed old versions", role: .destructive) { performCleanup() }
                        .accessibilityIdentifier("studio.storage.confirm-remove-revisions")
                } else {
                    Button("Clear working cache") {
                        do {
                            let result = try vm.clearRegenerableStorageCache()
                            cacheBytes = DeviceStorageManager.snapshotEncodingCacheFootprint.bytes
                            notice = "Cleared \(result.entries) cached frames (estimated \(bytes(Int64(result.releasedMemoryBytes)))). No files were deleted."
                        } catch { self.error = error.localizedDescription }
                    }
                }
                Button("Cancel", role: .cancel) { }
                    .accessibilityIdentifier("studio.storage.cancel-confirmation")
            } message: {
                if confirmingCleanup {
                    Text("The current and previous versions stay. Removed older versions cannot be recovered unless you exported a backup. Physical free space may differ from removed file bytes.")
                } else {
                    Text("Only regenerable frame encodings in memory are cleared. No files are removed.")
                }
            }
            .task(id: refresh) {
                guard scenePhase == .active else { return }
                scanning = true; usage = nil; error = nil
                cacheBytes = DeviceStorageManager.snapshotEncodingCacheFootprint.bytes
                let request = vm.storageScanRequest
                let worker = Task.detached(priority: .utility) { try request.scan() }
                do {
                    let result = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    usage = result
                } catch is CancellationError { }
                catch { self.error = error.localizedDescription }
                scanning = false
            }
        }.preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in if phase != .active { cleanup.cancel(); dismiss() } }
        .onChange(of: authVM.userId) { _, _ in cleanup.cancel(); dismiss() }
        .onChange(of: vm.isEditing) { _, editing in if editing { cleanup.cancel(); dismiss() } }
        .onChange(of: cleanup.refreshID) { _, _ in refresh = UUID() }
        .onChange(of: cleanup.preview?.confirmationToken) { _, token in if token == nil { confirmingCleanup = false } }
        .onDisappear { cleanup.cancel() }
    }
    private func previewCleanup() {
        guard let id = cleanupProject, !cleanup.isBusy else { return }
        do { cleanup.review(try vm.obsoleteRevisionCleanupRequest(id: id)) }
        catch { cleanup.fail(error) }
    }
    private func performCleanup() {
        guard let id = cleanup.preview?.projectID else { return }
        // Revalidate the visible library context before granting removal authority.
        do { _ = try vm.obsoleteRevisionCleanupRequest(id: id); cleanup.remove() }
        catch { cleanup.fail(error) }
    }
    private func bytes(_ amount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: amount, countStyle: .file)
    }
    private func row(_ title: String, _ bucket: StudioStorageUsage.Bucket) -> some View {
        LabeledContent(title, value: "\(bytes(bucket.bytes)) · \(bucket.files) files")
    }
}

/// Owns one explicit storage review, including its utility worker and project
/// lease. A new view/account/project generation cannot adopt an old result.
@MainActor private final class StudioRevisionCleanupController: ObservableObject {
    @Published private(set) var preview: DeviceStorageManager.RevisionCleanupPreview?
    @Published private(set) var notice: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isRemoving = false
    @Published private(set) var scannedRevisions = 0
    @Published private(set) var refreshID = UUID()
    var hasReview: Bool { isBusy || preview != nil }
    private var generation = UUID()
    private var request: StudioRevisionCleanupRequest?
    private var scan: DeviceStorageManager.RevisionCleanupScan?
    private var task: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil
        expiryTask?.cancel(); expiryTask = nil
        scan?.cancel(); scan = nil; request = nil
        preview = nil; notice = nil; scannedRevisions = 0
        isBusy = false; isRemoving = false
    }
    func cancelByUser() {
        if isRemoving {
            // Keep the worker and its factual partial receipt until the current
            // atomic removal completes. Cancellation is not a zero-byte result.
            task?.cancel()
        } else {
            cancel(); notice = "Review cancelled. No saved versions were removed."
        }
    }
    func fail(_ error: Error) { cancel(); notice = error.localizedDescription }

    func review(_ request: StudioRevisionCleanupRequest) {
        cancel()
        let generation = self.generation
        isBusy = true
        task = Task { [weak self] in
            guard let self else { return }
            var opened: DeviceStorageManager.RevisionCleanupScan?
            var retained = false
            defer {
                if !retained { opened?.cancel() }
                if self.generation == generation { self.isBusy = false; self.task = nil }
            }
            do {
                let starter = Task.detached(priority: .utility) { try request.beginScan() }
                let scan = try await withTaskCancellationHandler { try await starter.value } onCancel: { starter.cancel() }
                opened = scan
                try Task.checkCancellation()
                guard self.generation == generation else { throw CancellationError() }
                self.scan = scan
                while true {
                    let worker = Task.detached(priority: .utility) { try request.advance(scan) }
                    let page = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    guard self.generation == generation else { throw CancellationError() }
                    self.scannedRevisions = page.scannedRevisions
                    if let preview = page.preview {
                        self.preview = preview
                        if preview.candidates > 0 {
                            retained = true; self.request = request
                            self.watchExpiry(scan, generation: generation)
                        } else { self.scan = nil }
                        break
                    }
                    await Task.yield()
                }
            } catch {
                guard self.generation == generation else { return }
                self.scan = nil; self.request = nil; self.preview = nil
                if !(error is CancellationError) { self.notice = error.localizedDescription }
            }
        }
    }
    private func watchExpiry(_ scan: DeviceStorageManager.RevisionCleanupScan, generation: UUID) {
        expiryTask = Task { [weak self, weak scan] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.generation == generation else { return }
                guard let scan, scan.isActive() else {
                    self.cancel(); self.notice = "Storage review expired. Review the saved versions again before removing any."
                    return
                }
            }
        }
    }
    func remove() {
        guard !isBusy, let preview, let request, let scan else { return }
        guard scan.isActive() else {
            cancel(); notice = "Storage review expired. Review the saved versions again before removing any."
            return
        }
        let generation = self.generation
        expiryTask?.cancel(); expiryTask = nil
        isBusy = true; isRemoving = true; notice = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                scan.cancel()
                if self.generation == generation {
                    self.scan = nil; self.request = nil; self.preview = nil
                    self.isBusy = false; self.isRemoving = false; self.task = nil; self.refreshID = UUID()
                }
            }
            do {
                let worker = Task.detached(priority: .utility) { try request.remove(scan: scan, confirmationToken: preview.confirmationToken) }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard self.generation == generation else { return }
                let bytes = ByteCountFormatter.string(fromByteCount: result.removedFileBytes, countStyle: .file)
                self.notice = "Removed \(result.removedRevisions) obsolete versions (\(bytes) of file contents). Current, previous, original and unverified recovery files remain." + (result.stoppedReason.map { " " + $0 } ?? "")
            } catch {
                guard self.generation == generation else { return }
                self.notice = error is CancellationError ? "Cancelled before any versions were removed." : error.localizedDescription
            }
        }
    }
}


/// Shared reference-style form for creation and editing an existing project.
struct StudioProjectConfigurationCard: View {
    @Binding var name: String
    @Binding var width: Int
    @Binding var height: Int
    @Binding var fps: Int
    @Binding var backgroundID: String?
    var submitTitle: String
    var submitIdentifier: String
    var nameIdentifier = "studio.project-name"
    var notice: String?
    var busy = false
    var canSubmit = true
    var chooseExistingBackground: (() -> Void)? = nil
    let onSubmit: () -> Void
    @State private var showingCustom = false
    @State private var showingCustomFPS = false
    @State private var preferredPreset: String?
    private let presets: [(String, Int, Int)] = [
        ("Portrait",1080,1920), ("Landscape",1920,1080), ("Square",1080,1080),
        ("TikTok",1080,1920), ("YouTube",1920,1080), ("Instagram",1080,1350),
        ("SD",640,480), ("HD",1280,720)
    ]
    // Aliases share dimensions, but the card must expose a single selection.
    // Saved projects only store dimensions, so use the first matching preset
    // unless the user has explicitly selected a matching alias in this card.
    private var selectedPreset: String? {
        let matches = presets.filter { $0.1 == width && $0.2 == height }
        return matches.first(where: { $0.0 == preferredPreset })?.0 ?? matches.first?.0
    }
    private var validationNotice: String? {
        guard (16...4096).contains(width), (16...4096).contains(height) else {
            return "Enter a whole-number width and height from 16 to 4096 pixels."
        }
        guard (1...60).contains(fps) else { return "Enter a whole-number frame rate from 1 to 60 FPS." }
        do { _ = try StudioDocument.validatedProjectName(name) }
        catch { return error.localizedDescription }
        return nil
    }
    private var valid: Bool { validationNotice == nil }
    private var backgroundName: String {
        StudioImageImportService.BackgroundPreset.all.first(where: { $0.id == backgroundID })?.name ?? "Choose background…"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TextField("Project name…", text: $name).font(.specialElite(18)).foregroundStyle(.white)
                .padding(.trailing, 44)
                .padding(16).background(Color(hex: "101017"), in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.08)))
                .accessibilityIdentifier(nameIdentifier)
                .overlay(alignment: .trailing) {
                    if !name.isEmpty {
                        Button { name = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18)).foregroundStyle(.gray)
                                .frame(width: 44, height: 44)
                        }.buttonStyle(.plain).padding(.trailing, 8)
                            .accessibilityLabel("Clear project name")
                            .accessibilityIdentifier(nameIdentifier + ".clear")
                    }
                }
            heading("CANVAS SIZE")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(presets.indices, id: \.self) { index in
                    let preset = presets[index]
                    choice("\(preset.0) (\(preset.1)×\(preset.2))", selected: selectedPreset == preset.0) {
                        preferredPreset = preset.0; width = preset.1; height = preset.2
                    }.accessibilityIdentifier("studio.project.preset." + preset.0.lowercased())
                }
            }
            DisclosureGroup("Custom size · \(width) × \(height)", isExpanded: $showingCustom) {
                HStack {
                    dimension("Width", value: $width, identifier: "studio.project-width")
                    Text("×").foregroundStyle(.gray)
                    dimension("Height", value: $height, identifier: "studio.project-height")
                    Button { let previous = width; width = height; height = previous } label: { Image(systemName: "arrow.left.arrow.right").frame(width: 44, height: 44) }
                        .accessibilityLabel("Swap width and height")
                }.padding(.top, 10)
                Text("16–4096 pixels per side").font(.specialElite(11)).foregroundStyle(.gray)
            }.font(.specialElite(12)).tint(.red).foregroundStyle(.gray)
            heading("FRAME RATE")
            ViewThatFits(in: .horizontal) {
                rateRow
                ScrollView(.horizontal, showsIndicators: true) { rateRow }
            }
            Menu("More frame rates · \(fps) FPS") {
                ForEach([1,6,8,10,12,15,18,24,25,30,48,50,60], id: \.self) { rate in
                    Button("\(rate) FPS") { fps = rate }
                }
            }.font(.specialElite(11)).foregroundStyle(.gray).frame(minHeight: 44)
            DisclosureGroup("Custom frame rate · \(fps) FPS", isExpanded: $showingCustomFPS) {
                dimension("Frames per second", value: $fps, identifier: "studio.project-fps-custom")
                    .padding(.top, 10)
                Text("Whole numbers from 1 to 60 FPS").font(.specialElite(11)).foregroundStyle(.gray)
            }.font(.specialElite(12)).tint(.red).foregroundStyle(.gray)
            heading("BACKGROUND")
            Group {
                if let action = chooseExistingBackground {
                    Button(action: action) { backgroundLabel }
                } else {
                    Menu {
                        Button("White canvas (no image)") { backgroundID = nil }
                        ForEach(StudioImageImportService.BackgroundPreset.all) { preset in
                            Button(preset.name) { backgroundID = preset.id }
                        }
                    } label: { backgroundLabel }
                }
            }.buttonStyle(.plain).accessibilityIdentifier("studio.project.background")
            if let validationNotice, !name.isEmpty || width < 16 || height < 16 || !(1...60).contains(fps) {
                Text(validationNotice).font(.specialElite(12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("studio.project.validation")
            }
            if let notice { Text(notice).font(.specialElite(12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Button(action: onSubmit) {
                HStack {
                    if busy { ProgressView().tint(.white) }
                    Text(busy ? "Preparing…" : submitTitle).font(.specialElite(21))
                }.foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 58)
                    .background(LinearGradient(colors: [Color(hex: "FF303B"), Color(hex: "FF6B00")], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 19))
            }.buttonStyle(.plain).disabled(!valid || busy || !canSubmit)
                .opacity(valid && canSubmit ? 1 : 0.5).accessibilityIdentifier(submitIdentifier)
        }.padding(20).background(Color(hex: "1A1A24"), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.08)))
            .disabled(busy)
    }
    private var backgroundLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo").foregroundStyle(.yellow)
            Text(backgroundName).font(.specialElite(15)).foregroundStyle(.gray)
            Spacer(); Image(systemName: "chevron.down").font(.caption).foregroundStyle(.gray)
        }.padding(16).frame(maxWidth: .infinity, minHeight: 50)
            .background(Color(hex: "101017"), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.08)))
    }
    private var rateRow: some View {
        HStack(spacing: 8) {
            ForEach([6,8,10,12,15,24,30], id: \.self) { rate in
                choice("\(rate)", selected: fps == rate) { fps = rate }
                    .frame(minWidth: 36).accessibilityIdentifier("studio.project.fps.\(rate)")
            }
        }
    }
    private func heading(_ title: String) -> some View {
        Text(title).font(.specialElite(12)).tracking(1.5).foregroundStyle(Color.white.opacity(0.7))
    }
    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.specialElite(12)).multilineTextAlignment(.center)
                .foregroundStyle(selected ? Color(hex: "FF555D") : Color.gray)
                .frame(maxWidth: .infinity, minHeight: 38).padding(.horizontal, 4)
                .background(selected ? Color.red.opacity(0.13) : Color(hex: "101017"), in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(selected ? Color.red : Color.white.opacity(0.08)))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func dimension(_ title: String, value: Binding<Int>, identifier: String) -> some View {
        StudioProjectIntegerField(title: title, value: value, identifier: identifier)
    }
}

/// Keep the displayed draft and submitted integer in sync, including empty/invalid input.
/// Zero is an invalid sentinel rejected by the configuration card; it is never submitted.
private struct StudioProjectIntegerField: View {
    let title: String
    @Binding var value: Int
    let identifier: String
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.specialElite(11)).foregroundStyle(.gray)
            TextField(title, text: Binding(get: { draft }, set: { text in
                draft = String(text.prefix(12))
                value = !draft.isEmpty && draft.utf8.allSatisfy({ (48...57).contains($0) }) ? (Int(draft) ?? 0) : 0
            })).keyboardType(.numberPad)
                .font(.specialElite(16)).foregroundStyle(.white).padding(10)
                .background(Color(hex: "101017"), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier(identifier)
        }
        .onAppear { draft = String(value) }
        .onChange(of: value) { _, updated in
            // Presets, swapping dimensions and reloading settings update the field.
            if (Int(draft) ?? 0) != updated { draft = String(updated) }
        }
    }
}
