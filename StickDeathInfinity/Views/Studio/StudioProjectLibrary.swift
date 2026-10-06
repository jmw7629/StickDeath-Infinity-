import SwiftUI
import UIKit

struct StudioProjectLibrary: View {
    @ObservedObject var vm: StudioViewModel
    @State private var removal: AnimationMetadata?
    @State private var showingRecovery = false
    @State private var creating = false
    @State private var name = "Untitled Animation"
    @State private var format = 0
    @State private var fps = 12
    @State private var customWidth = 1080
    @State private var customHeight = 1920
    @State private var search = ""
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
    private let formats = [("Portrait", 1080, 1920), ("Square", 1080, 1080), ("Landscape", 1920, 1080)]

    var body: some View {
        ZStack {
            Color(hex: "0D0D12").ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Studio").font(.specialElite(28)).foregroundColor(.white)
                            .accessibilityIdentifier("studio.library")
                        Text("YOUR ANIMATIONS · ON THIS DEVICE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.gray)
                    }
                    Spacer()
                    Button { creating = true } label: {
                        Label("New Project", systemImage: "plus").font(.specialElite(13))
                            .foregroundColor(.white).padding(12).background(Color.red).cornerRadius(12)
                    }.accessibilityIdentifier("studio.new-project")
                }
                if let message = vm.message { Text(message).font(.caption).foregroundColor(.red).accessibilityIdentifier("studio.status") }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundColor(.gray)
                    TextField("Search projects", text: $search)
                        .foregroundColor(.white).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().accessibilityIdentifier("studio.library.search")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.gray) }
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
                    .font(.caption).foregroundColor(.gray).accessibilityIdentifier("studio.library.count")
                Button { vm.loadRecoverableProjects(); showingRecovery = true } label: {
                    Label("Recently Deleted", systemImage: "trash").font(.caption).foregroundColor(.gray)
                }.accessibilityIdentifier("studio.library.recently-deleted")
                ScrollView {
                    if vm.savedProjects.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "pencil.and.scribble").font(.system(size: 48)).foregroundColor(.red)
                            Text("Your next animation starts here.").font(.specialElite(18)).foregroundColor(.white)
                            Text("Create, draw and save offline. Your projects stay on this device.")
                                .font(.callout).foregroundColor(.gray).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 70)
                    }
                    if !vm.savedProjects.isEmpty && matchingProjects.isEmpty {
                        Text("No projects match your search.").font(.callout).foregroundColor(.gray)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(matchingProjects, id: \.id) { project in
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
                                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                                    Text(project.modifiedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                                        .accessibilityLabel("Last edited " + project.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                                }.padding(12).background(Color(hex: "17171F")).cornerRadius(14)
                            }
                            .accessibilityIdentifier("studio.project.\(project.id.uuidString)")
                            .accessibilityLabel(project.title)
                            .contextMenu {
                                Button { Task { await vm.duplicateProject(project) } } label: {
                                    Label("Duplicate Project", systemImage: "doc.on.doc")
                                }.disabled(vm.isManagingProjects)
                                Button(role: .destructive) { removal = project } label: {
                                    Label("Move to Recently Deleted", systemImage: "trash")
                                }
                            }
                        }
                    }
                }.refreshable { await vm.loadProjects() }
            }.padding(16).disabled(vm.isManagingProjects)
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
        .sheet(isPresented: $showingRecovery) {
            NavigationStack {
                List {
                    Text("Projects remain on this device until restored. There is no automatic deletion.").font(.caption)
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
        .sheet(isPresented: $creating) {
            NavigationStack {
                Form {
                    TextField("Project name", text: $name).accessibilityIdentifier("studio.project-name")
                    Picker("Canvas", selection: $format) {
                        ForEach(formats.indices, id: \.self) { i in Text(formats[i].0).tag(i) }
                        Text("Custom").tag(formats.count)
                    }
                    if format == formats.count {
                        HStack {
                            Text("Width")
                            TextField("Width", value: $customWidth, format: .number).keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing).accessibilityIdentifier("studio.project-width")
                        }
                        HStack {
                            Text("Height")
                            TextField("Height", value: $customHeight, format: .number).keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing).accessibilityIdentifier("studio.project-height")
                        }
                        Button("Swap width and height") {
                            let previous = customWidth; customWidth = customHeight; customHeight = previous
                        }
                        Text("16–4096 pixels per side. Large canvases and effects require more memory; individual export formats have their own limits.").font(.caption)
                    }
                    Picker("Frames per second", selection: $fps) {
                        ForEach([1, 6, 8, 10, 12, 15, 18, 24, 25, 30, 48, 50, 60], id: \.self) { Text("\($0) FPS").tag($0) }
                    }
                    if let message = vm.message { Text(message).foregroundColor(.red) }
                    Text("Projects stay on this device. Use Export to create files for sharing. Cloud publishing is unavailable.").font(.caption)
                }
                .navigationTitle("New Animation")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { creating = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            let selected = format == formats.count ? ("Custom", customWidth, customHeight) : formats[format]
                            Task {
                                _ = await vm.createProject(name: name, width: selected.1, height: selected.2, fps: fps)
                                if vm.isEditing { creating = false }
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120 || (format == formats.count && (!(16...4096).contains(customWidth) || !(16...4096).contains(customHeight))))
                        .accessibilityIdentifier("studio.create-project")
                    }
                }
            }.preferredColorScheme(.dark)
        }
    }
}
