// ProjectsGalleryView.swift
// Studio tab root — matches web StudioHubPage design
// Header: "Studio" + red "New Project" button
// Empty state: clapperboard + "No projects yet" + Create button
// Templates grid: skull icons, 2-col layout

import SwiftUI

private struct Template: Identifiable {
    let id: String
    let name: String
    let frames: Int
    let desc: String
}

private let templates: [Template] = [
    .init(id: "walk", name: "Walk Cycle", frames: 8, desc: "Basic walking animation"),
    .init(id: "fight", name: "Fight Combo", frames: 12, desc: "3-hit attack sequence"),
    .init(id: "death", name: "Death Scene", frames: 6, desc: "Classic stick death"),
    .init(id: "dance", name: "Dance Loop", frames: 16, desc: "Looping dance moves"),
    .init(id: "run", name: "Run Cycle", frames: 6, desc: "Smooth running loop"),
    .init(id: "jump", name: "Jump Arc", frames: 8, desc: "Jump with squash & stretch"),
]

struct ProjectsGalleryView: View {
    @EnvironmentObject var router: NavigationRouter
    @State private var projects: [StudioProject] = []
    @State private var loading = true
    @State private var showNewProject = false
    @State private var newTitle = ""
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    if loading && projects.isEmpty {
                        ProgressView().tint(.red).padding(.top, 80)
                    } else if projects.isEmpty {
                        emptyState
                        templatesSection
                    } else {
                        projectsGrid
                        templatesSection
                    }
                }
            }
            .refreshable { await loadProjects() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text("Studio")
                    .font(.custom("SpecialElite-Regular", size: 20, relativeTo: .headline))
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewProject = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                        Text("New Project")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(ThemeManager.brand)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .alert("New Animation", isPresented: $showNewProject) {
            TextField("Project name", text: $newTitle)
            Button("Create") { Task { await createProject() } }
            Button("Cancel", role: .cancel) { newTitle = "" }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Something went wrong")
        }
        .task { await loadProjects() }
    }

    // MARK: - Empty State (matches web design)
    var emptyState: some View {
        VStack(spacing: 12) {
            // Clapperboard icon
            RoundedRectangle(cornerRadius: 16)
                .fill(ThemeManager.card)
                .frame(width: 80, height: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(ThemeManager.border, lineWidth: 1)
                )
                .overlay(
                    Text("🎬").font(.system(size: 40))
                )

            Text("No projects yet")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)

            Text("Create your first stick figure animation.\nStart from scratch or pick a template below.")
                .font(.system(size: 12))
                .foregroundStyle(ThemeManager.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Button { showNewProject = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                    Text("Create Animation")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(ThemeManager.brand)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.top, 40)
        .padding(.bottom, 20)
    }

    // MARK: - Projects Grid
    var projectsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(projects) { project in
                Button {
                    router.studioPath.append(StudioDestination.editor(project))
                } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(ThemeManager.background)
                            .frame(width: 64, height: 48)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(ThemeManager.border, lineWidth: 1)
                            )
                            .overlay(
                                Image(systemName: "play.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(ThemeManager.brand.opacity(0.5))
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.title)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                            Text("\(project.fps ?? 24) fps · \(project.status ?? "draft")")
                                .font(.system(size: 10))
                                .foregroundStyle(ThemeManager.textMuted)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13))
                            .foregroundStyle(ThemeManager.textDim)
                    }
                    .padding(12)
                    .background(ThemeManager.card)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(ThemeManager.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        router.studioPath.append(StudioDestination.editor(project))
                    } label: { Label("Open", systemImage: "play.fill") }
                    Button(role: .destructive) {
                        Task { await deleteProject(project) }
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: - Templates Section (matches web design — skull icons)
    var templatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(ThemeManager.textMuted)
                Text("TEMPLATES")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .tracking(1)
            }
            .padding(.horizontal, 16)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], spacing: 8) {
                ForEach(templates) { tpl in
                    Button { showNewProject = true } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            // Skull preview area
                            RoundedRectangle(cornerRadius: 10)
                                .fill(ThemeManager.background)
                                .aspectRatio(16/10, contentMode: .fit)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(ThemeManager.surface, lineWidth: 1)
                                )
                                .overlay(
                                    Text("💀")
                                        .font(.system(size: 28))
                                        .opacity(0.4)
                                )

                            Text(tpl.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)

                            Text("\(tpl.frames) frames · \(tpl.desc)")
                                .font(.system(size: 10))
                                .foregroundStyle(ThemeManager.textDim)
                                .lineLimit(2)
                        }
                        .padding(10)
                        .background(ThemeManager.card)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(ThemeManager.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 20)
        .padding(.bottom, 24)
    }

    // MARK: - Data
    func loadProjects() async {
        loading = true
        projects = (try? await ProjectService.shared.fetchMyProjects()) ?? []
        loading = false
    }

    func createProject() async {
        let title = newTitle.isEmpty ? "Untitled" : newTitle
        newTitle = ""

        do {
            let project = try await ProjectService.shared.createProject(title: title)
            projects.insert(project, at: 0)
            router.studioPath.append(StudioDestination.editor(project))
        } catch {
            // Create local-only project so user can draw immediately
            let localProject = StudioProject(
                id: -Int.random(in: 1...999_999),
                user_id: await AuthManager.shared.session?.user.id.uuidString ?? "local",
                title: title,
                description: nil,
                canvas_width: 1920,
                canvas_height: 1080,
                fps: 24,
                status: "draft",
                created_at: nil,
                updated_at: nil,
                thumbnail_url: nil,
                background_type: nil,
                background_value: nil
            )
            projects.insert(localProject, at: 0)
            router.studioPath.append(StudioDestination.editor(localProject))
            print("⚠️ Created local project (server error: \(error.localizedDescription))")
        }
    }

    func deleteProject(_ project: StudioProject) async {
        _ = try? await ProjectService.shared.deleteProject(projectId: project.id)
        projects.removeAll { $0.id == project.id }
    }
}

extension StudioProject: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: StudioProject, rhs: StudioProject) -> Bool { lhs.id == rhs.id }
}
