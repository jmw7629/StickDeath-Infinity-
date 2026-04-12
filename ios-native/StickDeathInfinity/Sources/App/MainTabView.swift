// MainTabView.swift
// Adaptive navigation — tabs on iPhone, sidebar on iPad/Mac
// Responds to size class changes (rotation, multitasking)
// v4.3: Uses Tab type (iOS 18+ required API, .tabItem is removed)

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
                // iPhone compact — Tab type (iOS 18+)
                TabView(selection: $selectedTab) {
                    Tab("Studio", systemImage: "paintbrush.pointed", value: 0) {
                        ProjectsGalleryView()
                    }
                    Tab("Feed", systemImage: "play.rectangle.fill", value: 1) {
                        FeedView()
                    }
                    Tab("Messages", systemImage: "bubble.left.and.bubble.right", value: 2) {
                        MessagesListView()
                    }
                    Tab("Profile", systemImage: "person.crop.circle", value: 3) {
                        ProfileView()
                    }
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
