// ═══════════════════════════════════════════════════════════════════
// MessagesView — WhatsApp-style messenger
// Matches: MessagesScreen.tsx exactly
// Header: 💬 Messages + Contacts + Invite buttons
// Search bar, Channels/Direct/Threads tabs
// Channels: FAVORITES section, ALL CHANNELS list with emoji/desc/members/unread/star
// Direct: Spatter AI pinned, contacts with status indicators
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct MessagesView: View {
    @StateObject private var vm = MessagesListViewModel()
    @State private var showContacts = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.sdBackground.ignoresSafeArea()

                if showContacts {
                    ContactsView(onClose: { showContacts = false })
                } else {
                    mainListView
                }
            }
        }
    }

    // MARK: - Main List
    private var mainListView: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("💬")
                        .font(.system(size: 20))
                    Text("Messages")
                        .font(.specialElite(18))
                        .fontWeight(.bold)
                        .foregroundColor(.sdTextPrimary)

                    Spacer()

                    // Contacts button
                    Button {
                        showContacts = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("👤")
                                .font(.system(size: 11))
                            Text("Contacts")
                                .font(.specialElite(11))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.sdSurface2)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.sdBorder, lineWidth: 1)
                        )
                    }

                    // Phone contacts
                    Button {} label: {
                        Text("📱")
                            .font(.system(size: 14))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.sdSurface2)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.sdBorder, lineWidth: 1)
                            )
                    }

                    // Invite button
                    Button {} label: {
                        HStack(spacing: 4) {
                            Text("Invite")
                                .font(.specialElite(11))
                                .fontWeight(.bold)
                            Text("💀")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.sdRed)
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                // Search bar
                HStack(spacing: 8) {
                    Text("🔍")
                        .font(.system(size: 14))
                        .foregroundColor(.sdTextSecondary)
                    TextField("Search channels, people, messages...", text: $vm.searchText)
                        .font(.specialElite(13))
                        .foregroundColor(.sdTextPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.sdSurface2)
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                // Tabs: Channels / Direct / Threads
                HStack(spacing: 0) {
                    ForEach(MsgTab.allCases, id: \.self) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                vm.activeTab = tab
                            }
                        } label: {
                            VStack(spacing: 0) {
                                HStack(spacing: 4) {
                                    Text(tab.icon)
                                        .font(.system(size: 12))
                                    Text(tab.label)
                                        .font(.specialElite(13))
                                }
                                .foregroundColor(vm.activeTab == tab ? .sdRed : .sdTextSecondary)
                                .fontWeight(vm.activeTab == tab ? .bold : .regular)
                                .padding(.vertical, 10)

                                Rectangle()
                                    .fill(vm.activeTab == tab ? Color.sdRed : Color.clear)
                                    .frame(height: 2)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .background(Color.sdSurface)

            // Tab content
            ScrollView {
                switch vm.activeTab {
                case .channels:
                    channelsListView
                case .direct:
                    directListView
                case .threads:
                    threadsListView
                }
            }
        }
    }

    // MARK: - Channels Tab
    private var channelsListView: some View {
        VStack(spacing: 0) {
            // Favorites section
            let favoriteChannels = vm.filteredChannels.filter { vm.favorites.contains($0.id) }
            if !favoriteChannels.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("⭐")
                            .font(.system(size: 12))
                        Text("FAVORITES")
                            .font(.specialElite(12))
                            .fontWeight(.bold)
                            .foregroundColor(.sdWarning)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                    ForEach(favoriteChannels) { ch in
                        NavigationLink {
                            ChatRoomView(room: ChatRoom(id: ch.id.hashValue, name: ch.name, type: "channel"))
                        } label: {
                            FavoriteChannelRow(channel: ch, onToggleFavorite: { vm.toggleFavorite(ch.id) })
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 12)
            }

            // All channels
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("📢")
                        .font(.system(size: 12))
                    Text("ALL CHANNELS")
                        .font(.specialElite(12))
                        .fontWeight(.bold)
                        .foregroundColor(.sdTextSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, favoriteChannels.isEmpty ? 16 : 0)

                if vm.filteredChannels.isEmpty {
                    Text("No channels found")
                        .font(.specialElite(14))
                        .foregroundColor(.sdTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    ForEach(vm.filteredChannels) { ch in
                        NavigationLink {
                            ChatRoomView(room: ChatRoom(id: ch.id.hashValue, name: ch.name, type: "channel"))
                        } label: {
                            ChannelRow(
                                channel: ch,
                                isFavorite: vm.favorites.contains(ch.id),
                                onToggleFavorite: { vm.toggleFavorite(ch.id) }
                            )
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.bottom, 100)
        }
    }

    // MARK: - Direct Messages Tab
    private var directListView: some View {
        VStack(spacing: 0) {
            // Spatter AI pinned
            NavigationLink {
                SpatterChatView()
            } label: {
                SpatterInboxRow()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)

            // Favorite DMs
            let favContacts = vm.contacts.filter { vm.favorites.contains($0.id) }
            if !favContacts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("⭐")
                            .font(.system(size: 12))
                        Text("FAVORITES")
                            .font(.specialElite(12))
                            .fontWeight(.bold)
                            .foregroundColor(.sdWarning)
                    }
                    .padding(.horizontal, 16)

                    ForEach(favContacts) { contact in
                        NavigationLink {
                            ChatRoomView(room: ChatRoom(id: contact.id.hashValue, name: contact.name, type: "dm"))
                        } label: {
                            ContactRow(contact: contact, isFavorite: true, onToggleFavorite: { vm.toggleFavorite(contact.id) })
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 12)
            }

            // All contacts
            ForEach(vm.contacts) { contact in
                NavigationLink {
                    ChatRoomView(room: ChatRoom(id: contact.id.hashValue, name: contact.name, type: "dm"))
                } label: {
                    ContactRow(
                        contact: contact,
                        isFavorite: vm.favorites.contains(contact.id),
                        onToggleFavorite: { vm.toggleFavorite(contact.id) }
                    )
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 100)
        }
    }

    // MARK: - Threads Tab
    private var threadsListView: some View {
        VStack(spacing: 12) {
            Text("🧵")
                .font(.system(size: 48))
            Text("No active threads")
                .font(.specialElite(14))
                .foregroundColor(.sdTextSecondary)
        }
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Spatter Inbox Row (pinned, gradient)
struct SpatterInboxRow: View {
    var body: some View {
        HStack(spacing: 12) {
            // Skull avatar with gradient
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#DC2626"), Color(hex: "#A855F7")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                    .shadow(color: Color(hex: "#DC2626").opacity(0.3), radius: 10)

                Text("💀")
                    .font(.system(size: 22))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Spatter")
                        .font(.specialElite(14))
                        .fontWeight(.bold)
                        .foregroundColor(.sdRed)

                    Text("AI")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.sdRed)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.sdRed.opacity(0.2))
                        .cornerRadius(8)
                }

                Text("Content reviews & AI assistant")
                    .font(.specialElite(11))
                    .foregroundColor(.sdTextSecondary)
            }

            Spacer()

            // Unread badge
            Circle()
                .fill(Color.sdRed)
                .frame(width: 22, height: 22)
                .overlay(
                    Text("3")
                        .font(.specialElite(11))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                )

            Text("›")
                .font(.system(size: 12))
                .foregroundColor(.sdTextMuted)
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [Color(hex: "#DC2626").opacity(0.12), Color(hex: "#A855F7").opacity(0.08)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(hex: "#DC2626").opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Channel Row
struct ChannelRow: View {
    let channel: SDChannel
    let isFavorite: Bool
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(channel.icon)
                .font(.system(size: 24))

            VStack(alignment: .leading, spacing: 2) {
                Text("#\(channel.name)")
                    .font(.specialElite(14))
                    .fontWeight(.bold)
                    .foregroundColor(.sdTextPrimary)

                HStack(spacing: 8) {
                    Text(channel.description)
                        .font(.specialElite(12))
                        .foregroundColor(.sdTextSecondary)
                        .lineLimit(1)
                    Text("• \(channel.members)")
                        .font(.specialElite(12))
                        .foregroundColor(.sdTextMuted)
                }
            }

            Spacer()

            if channel.unread > 0 {
                Circle()
                    .fill(Color.sdRed)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Text("\(channel.unread)")
                            .font(.specialElite(11))
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    )
            }

            Button {
                onToggleFavorite()
            } label: {
                Text(isFavorite ? "⭐" : "☆")
                    .font(.system(size: 14))
            }

            Text("›")
                .font(.system(size: 12))
                .foregroundColor(.sdTextMuted)
        }
        .padding(14)
        .background(Color.sdSurface)
        .cornerRadius(12)
    }
}

// MARK: - Favorite Channel Row (orange tint)
struct FavoriteChannelRow: View {
    let channel: SDChannel
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(channel.icon)
                .font(.system(size: 20))

            VStack(alignment: .leading, spacing: 2) {
                Text("#\(channel.name)")
                    .font(.specialElite(13))
                    .fontWeight(.bold)
                    .foregroundColor(.sdTextPrimary)
                Text(channel.description)
                    .font(.specialElite(11))
                    .foregroundColor(.sdTextSecondary)
            }

            Spacer()

            Button {
                onToggleFavorite()
            } label: {
                Text("⭐")
                    .font(.system(size: 16))
            }
        }
        .padding(12)
        .background(Color(hex: "#F97316").opacity(0.06))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: "#F97316").opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Contact Row
struct ContactRow: View {
    let contact: DMContact
    let isFavorite: Bool
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Avatar + status indicator
            ZStack(alignment: .bottomTrailing) {
                Text(contact.avatar)
                    .font(.system(size: 22))
                    .frame(width: 40, height: 40)

                Circle()
                    .fill(contact.statusColor)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle().stroke(Color.sdBackground, lineWidth: 2)
                    )
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                    .font(.specialElite(13))
                    .fontWeight(.bold)
                    .foregroundColor(.sdTextPrimary)
                Text(contact.status.rawValue)
                    .font(.specialElite(11))
                    .foregroundColor(contact.statusColor)
            }

            Spacer()

            Button {
                onToggleFavorite()
            } label: {
                Text(isFavorite ? "⭐" : "☆")
                    .font(.system(size: 14))
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Tab Enum
enum MsgTab: String, CaseIterable {
    case channels, direct, threads

    var label: String {
        switch self {
        case .channels: return "Channels"
        case .direct: return "Direct"
        case .threads: return "Threads"
        }
    }

    var icon: String {
        switch self {
        case .channels: return "📢"
        case .direct: return "💬"
        case .threads: return "🧵"
        }
    }
}

// MARK: - Data Models
struct SDChannel: Identifiable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let unread: Int
    let members: Int
}

struct DMContact: Identifiable {
    let id: String
    let name: String
    let status: DMContactStatus
    let avatar: String

    enum DMContactStatus: String {
        case online, away, busy, offline
    }

    var statusColor: Color {
        switch status {
        case .online: return Color(hex: "#22C55E")
        case .away: return Color(hex: "#F97316")
        case .busy: return Color(hex: "#DC2626")
        case .offline: return Color(hex: "#6B7280")
        }
    }
}

// MARK: - ViewModel
@MainActor
final class MessagesListViewModel: ObservableObject {
    @Published var activeTab: MsgTab = .channels
    @Published var searchText = ""
    @Published var favorites: Set<String> = ["general", "c1"]

    // Channels (matches MessagesScreen.tsx CHANNELS exactly)
    let channels: [SDChannel] = [
        SDChannel(id: "general", name: "general", icon: "💬", description: "Main community chat", unread: 3, members: 847),
        SDChannel(id: "help", name: "help", icon: "❓", description: "Get help from the community", unread: 0, members: 312),
        SDChannel(id: "showcase", name: "showcase", icon: "🎨", description: "Share your animations", unread: 5, members: 623),
        SDChannel(id: "challenges", name: "challenges", icon: "🏆", description: "Weekly challenges", unread: 1, members: 489),
        SDChannel(id: "war-room", name: "challenge-war-room", icon: "⚔️", description: "Battle announcements", unread: 2, members: 267),
        SDChannel(id: "announcements", name: "announcements", icon: "📢", description: "Official updates", unread: 0, members: 847),
        SDChannel(id: "collabs", name: "collabs", icon: "🤝", description: "Find collaborators", unread: 0, members: 198),
        SDChannel(id: "tutorials", name: "tutorials", icon: "📚", description: "Learn animation techniques", unread: 0, members: 534),
    ]

    // Contacts (matches CONTACTS exactly)
    let contacts: [DMContact] = [
        DMContact(id: "c_xblade", name: "x6ladeRunner", status: .online, avatar: "⚔️"),
        DMContact(id: "c_ninja", name: "StickNinja99", status: .online, avatar: "🥷"),
        DMContact(id: "c_pixel", name: "PixelDeath_X", status: .away, avatar: "💀"),
        DMContact(id: "c_maya", name: "MayaAnimate", status: .online, avatar: "🎨"),
        DMContact(id: "c_flame", name: "FlameBoi420", status: .busy, avatar: "🔥"),
        DMContact(id: "c_shadow", name: "ShadowFrame", status: .offline, avatar: "👤"),
        DMContact(id: "c_cleo", name: "CleoVFX", status: .online, avatar: "✨"),
        DMContact(id: "c_bones", name: "BonesTV", status: .away, avatar: "🦴"),
        DMContact(id: "c_zero", name: "Zer0_G", status: .online, avatar: "🚀"),
        DMContact(id: "c_art", name: "ArtOfWar_SD", status: .offline, avatar: "🗡"),
    ]

    var filteredChannels: [SDChannel] {
        if searchText.isEmpty { return channels }
        return channels.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) {
            favorites.remove(id)
        } else {
            favorites.insert(id)
        }
    }
}
