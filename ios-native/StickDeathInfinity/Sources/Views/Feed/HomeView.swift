// HomeView.swift
// Layer 1 ROOT — Home tab — matches web design
// Challenge banner → Continue creating → Community chat feed → Message input

import SwiftUI

// Seed messages (matches web app exactly)
private struct CommunityMsg: Identifiable {
    let id: String
    let username: String
    let avatar: String
    let isBot: Bool
    let text: String
    let time: String
    let likes: Int
    let replies: Int
    let isAnnouncement: Bool
}

private let seedMessages: [CommunityMsg] = [
    .init(id: "1", username: "Spatter", avatar: "🩸", isBot: true,
          text: "Welcome to StickDeath ∞! 🎨 Share your animations, get feedback, and connect with other creators. The bloodier the better. 💀",
          time: "2m ago", likes: 12, replies: 3, isAnnouncement: false),
    .init(id: "2", username: "StickMaster99", avatar: "💀", isBot: false,
          text: "Just finished my first fight scene! 6 frames of pure chaos. How do you guys do smooth walk cycles?",
          time: "5m ago", likes: 8, replies: 5, isAnnouncement: false),
    .init(id: "3", username: "Spatter", avatar: "🩸", isBot: true,
          text: "🔥 Weekly Challenge is LIVE: \"Epic Death Scene\" — Create the most creative death animation. Winner gets featured! Ends in 3 days.",
          time: "15m ago", likes: 24, replies: 11, isAnnouncement: true),
    .init(id: "4", username: "AnimateOrDie", avatar: "⚔️", isBot: false,
          text: "Pro tip: use onion skinning set to 2 frames before/after for fight scenes. Changes everything.",
          time: "22m ago", likes: 31, replies: 7, isAnnouncement: false),
    .init(id: "5", username: "BoneBreaker", avatar: "🦴", isBot: false,
          text: "Anyone else obsessed with the stick figure tool? I\'ve been posing for like an hour 😂",
          time: "45m ago", likes: 15, replies: 4, isAnnouncement: false),
]

struct HomeView: View {
    @EnvironmentObject var router: NavigationRouter
    @EnvironmentObject var offline: OfflineManager
    @State private var items: [FeedItem] = []
    @State private var loading = true
    @State private var newMessage = ""
    @State private var likedMessages: Set<String> = []

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header: STICKDEATH ∞ ──
                stickyHeader

                ScrollView {
                    VStack(spacing: 12) {
                        // ── Featured Challenge Banner ──
                        challengeBanner
                            .padding(.horizontal, 16)

                        // ── Continue Creating ──
                        continueCard
                            .padding(.horizontal, 16)

                        // ── COMMUNITY header ──
                        HStack {
                            Text("COMMUNITY")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .tracking(1)
                            Spacer()
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 6, height: 6)
                                Text("142 online")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)

                        // ── Messages ──
                        ForEach(seedMessages) { msg in
                            communityMessageCard(msg)
                                .padding(.horizontal, 16)
                        }

                        // Spacer for input bar
                        Color.clear.frame(height: 60)
                    }
                    .padding(.top, 12)
                }

                // ── Message Input ──
                messageInput
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: - Header
    var stickyHeader: some View {
        HStack {
            HStack(spacing: 0) {
                Text("STICK")
                    .foregroundStyle(ThemeManager.brand)
                Text("DEATH")
                    .foregroundStyle(.white)
                Text(" ∞")
                    .foregroundStyle(Color(hex: "#ef4444"))
                    .font(.system(size: 12))
            }
            .font(.custom("SpecialElite-Regular", size: 18, relativeTo: .headline))
            .fontWeight(.black)

            Spacer()

            Button {
                router.selectedTab = .profile
            } label: {
                Circle()
                    .fill(ThemeManager.surface)
                    .frame(width: 32, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(ThemeManager.border, lineWidth: 1)
                    )
                    .overlay(
                        Image(systemName: "person")
                            .font(.system(size: 13))
                            .foregroundStyle(ThemeManager.textMuted)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(ThemeManager.background.opacity(0.9))
        .overlay(
            Rectangle().fill(ThemeManager.border).frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Challenge Banner
    var challengeBanner: some View {
        Button {
            router.selectedTab = .challenges
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(ThemeManager.brand.opacity(0.2))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(ThemeManager.brand)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Epic Death Scene")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text("47 entries · 3 days left · Prize: Featured Creator")
                        .font(.system(size: 10))
                        .foregroundStyle(ThemeManager.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(ThemeManager.textDim)
            }
            .padding(12)
            .background(
                LinearGradient(
                    colors: [ThemeManager.brand.opacity(0.15), Color(hex: "#7f1d1d").opacity(0.08)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(ThemeManager.brand.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Continue Creating Card
    var continueCard: some View {
        Button {
            router.selectedTab = .studio
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(ThemeManager.surface)
                    .frame(width: 40, height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(ThemeManager.border, lineWidth: 1)
                    )
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(ThemeManager.textMuted)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue creating")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Jump back into the studio")
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
    }

    // MARK: - Community Message Card
    private func communityMessageCard(_ msg: CommunityMsg) -> some View {
        let isLiked = likedMessages.contains(msg.id)

        return VStack(alignment: .leading, spacing: 6) {
            // User row
            HStack(spacing: 8) {
                Circle()
                    .fill(msg.isBot ? ThemeManager.brand.opacity(0.2) : ThemeManager.surface)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Group {
                            if !msg.isBot {
                                Circle().strokeBorder(ThemeManager.border, lineWidth: 1)
                            }
                        }
                    )
                    .overlay(Text(msg.avatar).font(.system(size: 13)))

                HStack(spacing: 6) {
                    Text(msg.username)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(msg.isBot ? Color(hex: "#f87171") : .white)

                    if msg.isBot {
                        Text("AI")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color(hex: "#f87171"))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ThemeManager.brand.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }

                Spacer()

                Text(msg.time)
                    .font(.system(size: 10))
                    .foregroundStyle(ThemeManager.textDim)
            }

            // Text
            Text(msg.text)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "#c0c0d0"))
                .lineSpacing(3)
                .padding(.leading, 36)

            // Actions
            HStack(spacing: 16) {
                Button {
                    if likedMessages.contains(msg.id) { likedMessages.remove(msg.id) }
                    else { likedMessages.insert(msg.id) }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isLiked ? "heart.fill" : "heart")
                            .font(.system(size: 11))
                        Text("\(msg.likes + (isLiked ? 1 : 0))")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(isLiked ? ThemeManager.brand : ThemeManager.textDim)
                }

                HStack(spacing: 3) {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 11))
                    Text("\(msg.replies)")
                        .font(.system(size: 10))
                }
                .foregroundStyle(ThemeManager.textDim)

                if msg.isAnnouncement {
                    Spacer()
                    Button {
                        router.selectedTab = .challenges
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 11))
                            Text("Join Challenge")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(ThemeManager.brand)
                    }
                }
            }
            .padding(.leading, 36)
            .padding(.top, 2)
        }
        .padding(12)
        .background(msg.isAnnouncement ? ThemeManager.brand.opacity(0.06) : ThemeManager.card.opacity(1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    msg.isAnnouncement ? ThemeManager.brand.opacity(0.2) : ThemeManager.surface,
                    lineWidth: 1
                )
        )
    }

    // MARK: - Message Input
    var messageInput: some View {
        HStack(spacing: 8) {
            TextField("Message the community...", text: $newMessage)
                .font(.system(size: 13))
                .foregroundStyle(.white)

            Button {} label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(newMessage.isEmpty ? ThemeManager.border : ThemeManager.brand)
            }
            .disabled(newMessage.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ThemeManager.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(ThemeManager.border, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(ThemeManager.background.opacity(0.95))
    }

    // MARK: - Data loading
    func loadFeed() async {
        loading = true
        items = (try? await ProjectService.shared.fetchFeed(page: 1)) ?? []
        loading = false
    }
}
