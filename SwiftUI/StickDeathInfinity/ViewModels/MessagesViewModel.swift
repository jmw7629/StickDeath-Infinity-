// ═══════════════════════════════════════════════════════════════════
// MessagesViewModel — Drives MessagesView conversation list
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import Supabase

@MainActor
final class MessagesViewModel: ObservableObject {
    @Published var rooms: [ChatRoom] = []
    @Published var searchText = ""
    @Published var showNewMessage = false
    @Published var isLoading = false

    var filteredRooms: [ChatRoom] {
        if searchText.isEmpty { return rooms }
        return rooms.filter { room in
            (room.name ?? "").localizedCaseInsensitiveContains(searchText)
            || (room.lastMessage ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    func loadRooms() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id.uuidString else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            rooms = try await MessageService.shared.fetchRooms(userID: userID)
        } catch {
            print("[MessagesVM] loadRooms error: \(error)")
        }
    }
}
