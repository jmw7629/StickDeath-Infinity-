// MainTabView.swift — Four-pillar navigation
// Create • Community • Messages • Profile
// Bold orange-on-dark, custom tab bar

import SwiftUI

enum AppTab: Int, CaseIterable {
    case create = 0
    case community = 1
    case messages = 2
    case profile = 3

    var label: String {
        switch self {
        case .create: "Create"
        case .community: "Community"
        case .messages: "Messages"
        case .profile: "Profile"
        }
    }

    var icon: String {
        switch self {
        case .create: "paintbrush.pointed.fill"
        case .community: "play.rectangle.fill"
        case .messages: "bubble.left.and.bubble.right.fill"
        case .profile: "person.crop.circle.fill"
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var selectedTab: AppTab = .create

    var body: some View {
        ZStack(alignment: .bottom) {
            // Tab content
            Group {
                switch selectedTab {
                case .create:
                    ProjectsGalleryView()
                case .community:
                    FeedView()
                case .messages:
                    MessagesListView()
                case .profile:
                    ProfileView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Custom tab bar
            tabBar
        }
        .ignoresSafeArea(.keyboard)
    }

    // MARK: - Custom Tab Bar
    var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.rawValue) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 20))
                            .symbolRenderingMode(.monochrome)

                        Text(tab.label.uppercased())
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(selectedTab == tab ? .orange : Color(white: 0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(.bottom, 16) // Safe area padding
        .background(
            Rectangle()
                .fill(Color(white: 0.04))
                .shadow(color: .black.opacity(0.5), radius: 8, y: -2)
                .ignoresSafeArea()
        )
    }
}
