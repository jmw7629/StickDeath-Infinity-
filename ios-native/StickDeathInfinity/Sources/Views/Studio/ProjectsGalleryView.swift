// ProjectsGalleryView.swift — "My Studio" project grid
// Pulls from studio_projects table
// Bold orange-on-dark theme with grid cards

import SwiftUI

struct ProjectsGalleryView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var projects: [StudioProject] = []
    @State private var isLoading = true
    @State private var openEditorForProject: StudioProject?
    @State private var showNewProject = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header
                    header

                    if isLoading {
                        Spacer()
                        ProgressView().tint(.orange).scaleEffect(1.2)
                        Spacer()
                    } else if projects.isEmpty {
                        emptyState
                    } else {
                        projectGrid
                    }
                }
            }
            .navigationBarHidden(true)
            .fullScreenCover(item: $openEditorForProject) { project in
                StudioView(vm: EditorViewModel(project: project))
                    .environmentObject(auth)
            }
            .task { await loadProjects() }
        }
    }

    // MARK: - Header
    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("MY STUDIO")
                    .font(ThemeManager.headlineBold(size: 28))
                    .foregroundStyle(.white)
                Text("Create. Animate. Annihilate.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Project Grid
    var projectGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                // New project card
                newProjectCard

                // Existing projects
                ForEach(projects) { project in
                    projectCard(project)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .padding(.bottom, 80) // Tab bar clearance
        }
        .refreshable { await loadProjects() }
    }

    // MARK: - New Project Card
    var newProjectCard: some View {
        Button { createNewProject() } label: {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.orange.opacity(0.08))
                        .aspectRatio(4/3, contentMode: .fit)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.orange.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                        )

                    VStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.orange)
                        Text("NEW PROJECT")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // MARK: - Project Card
    func projectCard(_ project: StudioProject) -> some View {
        Button { openEditorForProject = project } label: {
            VStack(alignment: .leading, spacing: 6) {
                // Thumbnail
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(white: 0.08))
                        .aspectRatio(4/3, contentMode: .fit)

                    if let url = project.thumbnail_url, let imageURL = URL(string: url) {
                        AsyncImage(url: imageURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            projectPlaceholder(project)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        projectPlaceholder(project)
                    }

                    // Status badge
                    VStack {
                        HStack {
                            Spacer()
                            Text(project.status?.uppercased() ?? "DRAFT")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(statusColor(project.status).opacity(0.85))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(6)
                        }
                        Spacer()
                    }
                }

                // Title + info
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.title)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text("\(project.fps ?? 12) FPS")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(white: 0.4))
                        Text("•")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(white: 0.3))
                        Text("\(project.canvas_width ?? 1280)×\(project.canvas_height ?? 720)")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(white: 0.4))
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    func projectPlaceholder(_ project: StudioProject) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "figure.run")
                .font(.system(size: 24))
                .foregroundStyle(.orange.opacity(0.25))
            Text(project.title)
                .font(.system(size: 9))
                .foregroundStyle(Color(white: 0.3))
                .lineLimit(1)
        }
    }

    func statusColor(_ status: String?) -> Color {
        switch status {
        case "published": .green
        case "rendering": .blue
        default: Color(white: 0.3)
        }
    }

    // MARK: - Empty State
    var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "paintbrush.pointed.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange.opacity(0.3))
            Text("YOUR STUDIO IS EMPTY")
                .font(ThemeManager.headlineBold(size: 20))
                .foregroundStyle(.white)
            Text("Create your first animation!")
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.5))
            Button { createNewProject() } label: {
                Label("New Project", systemImage: "plus")
                    .font(.subheadline.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.orange)
                    .clipShape(Capsule())
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - Data
    func loadProjects() async {
        guard let userId = auth.session?.user.id.uuidString else {
            isLoading = false
            return
        }
        isLoading = true
        do {
            projects = try await supabase
                .from("studio_projects")
                .select()
                .eq("user_id", value: userId)
                .order("updated_at", ascending: false)
                .execute()
                .value
        } catch {
            print("⚠️ Projects load error: \(error)")
        }
        isLoading = false
    }

    func createNewProject() {
        Task {
            guard let userId = auth.session?.user.id.uuidString else { return }
            do {
                let newProject: StudioProject = try await supabase
                    .from("studio_projects")
                    .insert([
                        "user_id": userId,
                        "name": "Untitled Animation",
                        "status": "draft"
                    ])
                    .select()
                    .single()
                    .execute()
                    .value
                openEditorForProject = newProject
                await loadProjects()
            } catch {
                print("⚠️ Create project error: \(error)")
            }
        }
    }
}
