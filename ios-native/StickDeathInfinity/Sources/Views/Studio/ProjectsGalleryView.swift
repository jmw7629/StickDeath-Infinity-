// ProjectsGalleryView.swift
// Studio tab — user's animation projects

import SwiftUI

struct ProjectsGalleryView: View {
    @State private var projects: [StudioProject] = []
    @State private var loading = true
    @State private var showNewProject = false
    @State private var newTitle = ""
    @State private var navigateToStudio: StudioProject?

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                if loading {
                    ProgressView().tint(.orange)
                } else if projects.isEmpty {
                    // Empty state
                    VStack(spacing: 16) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: 48))
                            .foregroundStyle(.gray)
                        Text("No projects yet")
                            .font(.title3.bold())
                        Text("Create your first stick figure animation")
                            .font(.subheadline)
                            .foregroundStyle(.gray)
                        Button {
                            showNewProject = true
                        } label: {
                            Label("New Animation", systemImage: "plus")
                                .font(.headline)
                                .foregroundStyle(.black)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(.orange)
                                .clipShape(Capsule())
                        }
                    }
                } else {
                    // Project grid
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 160), spacing: 12)
                        ], spacing: 12) {
                            ForEach(projects) { project in
                                ProjectCard(project: project)
                                    .onTapGesture { navigateToStudio = project }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            Task { await deleteProject(project) }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("My Studio")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNewProject = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .alert("New Animation", isPresented: $showNewProject) {
                TextField("Project name", text: $newTitle)
                Button("Create") { Task { await createProject() } }
                Button("Cancel", role: .cancel) { newTitle = "" }
            }
            .navigationDestination(item: $navigateToStudio) { project in
                StudioView(vm: EditorViewModel(project: project))
            }
            .task { await loadProjects() }
        }
    }

    func loadProjects() async {
        loading = true
        projects = (try? await ProjectService.shared.fetchMyProjects()) ?? []
        loading = false
    }

    func createProject() async {
        let title = newTitle.isEmpty ? "Untitled" : newTitle
        newTitle = ""
        if let project = try? await ProjectService.shared.createProject(title: title) {
            projects.insert(project, at: 0)
            navigateToStudio = project
        }
    }

    func deleteProject(_ project: StudioProject) async {
        try? await ProjectService.shared.deleteProject(projectId: project.id)
        projects.removeAll { $0.id == project.id }
    }
}

struct ProjectCard: View {
    let project: StudioProject

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail placeholder
            RoundedRectangle(cornerRadius: 10)
                .fill(ThemeManager.surface)
                .frame(height: 120)
                .overlay(
                    Image(systemName: "figure.run")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange.opacity(0.3))
                )

            Text(project.title)
                .font(.subheadline.bold())
                .lineLimit(1)

            HStack {
                Text(project.status ?? "draft")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(project.status == "published" ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                    .foregroundStyle(project.status == "published" ? .green : .gray)
                    .clipShape(Capsule())

                Spacer()

                Text(project.fps.map { "\($0) fps" } ?? "24 fps")
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
        }
        .padding(10)
        .background(ThemeManager.surfaceLight)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

extension StudioProject: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: StudioProject, rhs: StudioProject) -> Bool { lhs.id == rhs.id }
}
