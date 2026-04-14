// MainTabView.swift
// 4-tab navigation: Studio, Feed, Messages, Profile
// Black & red theme

import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    @EnvironmentObject var auth: AuthManager

    var body: some View {
        TabView(selection: $selectedTab) {
            ProjectsGalleryView()
                .tabItem {
                    Label("Studio", systemImage: "paintbrush.pointed")
                }
                .tag(0)

            FeedView()
                .tabItem {
                    Label("Feed", systemImage: "play.rectangle.fill")
                }
                .tag(1)

            MessagesListView()
                .tabItem {
                    Label("Messages", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(2)

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
                .tag(3)
        }
        .tint(.red)
    }
}
