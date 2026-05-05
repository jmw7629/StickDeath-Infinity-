// ProfileView.swift
// Matches reference exactly:
// Avatar with red ring, username, Creator badge $7.99/mo
// Stats grid: Projects, Published, Followers, Likes
// Menu items: Messages, Notifications, Settings, Theme
// Subscription tiers: Free $0, Pro $4.99, Creator $7.99

import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var router: NavigationRouter

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // ── Avatar & Name ──
                    profileHeader
                        .padding(.top, 24)
                        .padding(.bottom, 20)

                    // ── Stats Grid ──
                    statsGrid
                        .padding(.bottom, 24)

                    // ── Menu Items ──
                    menuSection
                        .padding(.bottom, 24)

                    // ── Subscription Plans ──
                    subscriptionSection
                        .padding(.bottom, 24)

                    // ── Sign Out ──
                    Button {
                        Task { try? await auth.signOut() }
                    } label: {
                        Text("Sign Out")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(ThemeManager.card)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(ThemeManager.border, lineWidth: 1)
                            )
                    }
                    .padding(.horizontal, 16)

                    Spacer().frame(height: 100)
                }
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: - Profile Header
    var profileHeader: some View {
        VStack(spacing: 10) {
            // Avatar with red ring
            ZStack {
                Circle()
                    .stroke(ThemeManager.brand, lineWidth: 3)
                    .frame(width: 88, height: 88)
                Circle()
                    .fill(ThemeManager.surface)
                    .frame(width: 80, height: 80)
                Text("JW")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
            }

            // Username
            Text(auth.currentUser?.username ?? "joe_willis")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)

            // Creator badge
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.yellow)
                Text("Creator")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("$7.99/mo")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "#9090a8"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(ThemeManager.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Stats Grid
    var statsGrid: some View {
        HStack(spacing: 0) {
            statItem("12", "Projects")
            statDivider
            statItem("5", "Published")
            statDivider
            statItem("234", "Followers")
            statDivider
            statItem("1.2k", "Likes")
        }
        .padding(.vertical, 16)
        .background(ThemeManager.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(ThemeManager.border, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    func statItem(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "#9090a8"))
        }
        .frame(maxWidth: .infinity)
    }

    var statDivider: some View {
        Rectangle()
            .fill(ThemeManager.border)
            .frame(width: 1, height: 36)
    }

    // MARK: - Menu Items
    var menuSection: some View {
        VStack(spacing: 2) {
            menuItem(icon: "envelope.fill", title: "Messages", color: .blue) {
                router.push(ProfileDestination.messages)
            }
            menuItem(icon: "bell.fill", title: "Notifications", color: .orange, badge: 3) {
                router.push(ProfileDestination.notifications)
            }
            menuItem(icon: "gearshape.fill", title: "Settings", color: Color(hex: "#9090a8")) {
                router.push(ProfileDestination.settings)
            }
            menuItem(icon: "paintpalette.fill", title: "Theme", color: .purple) {
                router.push(ProfileDestination.personalization)
            }
            menuItem(icon: "trophy.fill", title: "Achievements", color: .yellow) {
                router.push(ProfileDestination.achievements)
            }
            menuItem(icon: "link", title: "Connected Accounts", color: .green) {
                router.push(ProfileDestination.connectedAccounts)
            }
            menuItem(icon: "questionmark.circle.fill", title: "Help Center", color: .teal) {
                router.push(ProfileDestination.help)
            }
        }
        .padding(.horizontal, 16)
    }

    func menuItem(icon: String, title: String, color: Color, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(color)
                    .frame(width: 32, height: 32)

                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)

                Spacer()

                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(ThemeManager.brand)
                        .clipShape(Circle())
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(hex: "#5a5a6e"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(ThemeManager.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Subscription Plans
    var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subscription")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)

            HStack(spacing: 10) {
                planCard(tier: "Free", price: "$0", features: ["5 Projects", "720p Export", "Watermark"], isActive: false)
                planCard(tier: "Pro", price: "$4.99", features: ["Unlimited", "1080p Export", "No Watermark"], isActive: false)
                planCard(tier: "Creator", price: "$7.99", features: ["Everything", "4K Export", "Analytics"], isActive: true)
            }
            .padding(.horizontal, 16)
        }
    }

    func planCard(tier: String, price: String, features: [String], isActive: Bool) -> some View {
        VStack(spacing: 8) {
            Text(tier)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isActive ? ThemeManager.brand : .white)

            Text(price)
                .font(.system(size: 22, weight: .black))
                .foregroundStyle(.white)

            Text("/mo")
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: "#9090a8"))
                .offset(y: -4)

            VStack(spacing: 4) {
                ForEach(features, id: \.self) { feat in
                    Text(feat)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: "#9090a8"))
                }
            }

            if isActive {
                Text("CURRENT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(ThemeManager.brand)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(ThemeManager.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isActive ? ThemeManager.brand : ThemeManager.border, lineWidth: isActive ? 2 : 1)
        )
    }
}
