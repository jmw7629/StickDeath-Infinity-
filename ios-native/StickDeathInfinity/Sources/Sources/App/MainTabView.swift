// MainTabView.swift
// Adaptive navigation — tabs on iPhone, sidebar on iPad/Mac
// Responds to size class changes (rotation, multitasking)

import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    @EnvironmentObject var auth: AuthManager
    @Environment(\.horizontalSizeClass) var hSize

    var body: some View {
        Group {
            if hSize == .regular {
                // iPad / Mac / landscape Plus — use sidebar navigation
                NavigationSplitView {
                    List(selection: $selectedTab) {
                        Label("Studio", systemImage: "paintbrush.pointed").tag(0)
                        Label("Feed", systemImage: "play.rectangle.fill").tag(1)
                        Label("Messages", systemImage: "bubble.left.and.bubble.right").tag(2)
                        Label("Profile", systemImage: "person.crop.circle").tag(3)
                    }
                    .listStyle(.sidebar)
                    .navigationTitle("StickDeath ∞")
                    .tint(.orange)
                } detail: {
                    detailView
                }
                .tint(.orange)
            } else {
                // iPhone compact — tabs
                TabView(selection: $selectedTab) {
                    ProjectsGalleryView()
                        .tabItem { Label("Studio", systemImage: "paintbrush.pointed") }
                        .tag(0)

                    FeedView()
                        .tabItem { Label("Feed", systemImage: "play.rectangle.fill") }
                        .tag(1)

                    MessagesListView()
                        .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right") }
                        .tag(2)

                    ProfileView()
                        .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                        .tag(3)
                }
                .tint(.orange)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: hSize)
    }

    @ViewBuilder
    var detailView: some View {
        switch selectedTab {
        case 0: ProjectsGalleryView()
        case 1: FeedView()
        case 2: MessagesListView()
        case 3: ProfileView()
        default: ProjectsGalleryView()
        }
    }
}
