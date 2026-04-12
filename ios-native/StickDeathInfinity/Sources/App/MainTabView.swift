// MainTabView.swift
// Bottom tab navigation

import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    @EnvironmentObject var auth: AuthManager

    var body: some View {
        TabView(selection: $selectedTab) {
            // Studio Tab
            ProjectsGalleryView()
                .tabItem {
                    Label("Studio", systemImage: "paintbrush.pointed")
                }
                .tag(0)

            // Feed Tab
            FeedView()
                .tabItem {
                    Label("Feed", systemImage: "play.rectangle.fill")
                }
                .tag(1)

            // Messages Tab
            MessagesListView()
                .tabItem {
                    Label("Messages", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(2)

            // Profile Tab
            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
                .tag(3)
        }
        .tint(.orange)
    }
}
