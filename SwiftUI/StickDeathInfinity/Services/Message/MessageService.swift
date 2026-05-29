// ═══════════════════════════════════════════════════════════════════
// MessageService — Chat messaging via Supabase
// Matches: src/services/MessageService.ts
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase

@MainActor
final class MessageService {
    static let shared = MessageService()
    private let supabase = SupabaseManager.shared.client

    /// Fetch all chat rooms for the current user
    func fetchRooms(userID: String) async throws -> [ChatRoom] {
        let rooms: [ChatRoom] = try await supabase
            .from("chat_rooms")
            .select("*, room_members!inner(user_id)")
            .eq("room_members.user_id", value: userID)
            .order("last_message_at", ascending: false)
            .execute()
            .value
        return rooms
    }

    /// Fetch messages for a room
    func fetchMessages(roomID: Int, limit: Int = 50) async throws -> [ChatMessage] {
        let messages: [ChatMessage] = try await supabase
            .from("chat_messages")
            .select()
            .eq("room_id", value: roomID)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
        return messages.reversed()
    }

    /// Send a message
    func sendMessage(roomID: Int, senderID: String, content: String, type: String = "text", replyToID: Int? = nil) async throws -> ChatMessage {
        var payload: [String: String] = [
            "room_id": "\(roomID)",
            "sender_id": senderID,
            "content": content,
            "message_type": type
        ]
        if let replyID = replyToID {
            payload["reply_to_id"] = "\(replyID)"
        }
        let message: ChatMessage = try await supabase
            .from("chat_messages")
            .insert(payload)
            .select()
            .single()
            .execute()
            .value
        return message
    }

    /// Toggle reaction on a message
    func toggleReaction(messageID: Int, emoji: String) async throws {
        // TODO: Implement via Supabase RPC or message_reactions table
    }

    /// Create a new DM room
    func createDMRoom(userID: String, otherUserID: String) async throws -> ChatRoom {
        let room: ChatRoom = try await supabase
            .from("chat_rooms")
            .insert(["type": "dm"])
            .select()
            .single()
            .execute()
            .value

        // Add both members
        try await supabase
            .from("room_members")
            .insert([
                ["room_id": "\(room.id)", "user_id": userID],
                ["room_id": "\(room.id)", "user_id": otherUserID]
            ])
            .execute()

        return room
    }

    /// Subscribe to new messages in a room (Supabase Realtime)
    func subscribeToRoom(roomID: Int, onMessage: @escaping (ChatMessage) -> Void) {
        // TODO: Implement Supabase Realtime subscription
        // supabase.channel("room:\(roomID)")
        //     .on("postgres_changes", table: "chat_messages", filter: "room_id=eq.\(roomID)") { payload in
        //         // Decode and call onMessage
        //     }
        //     .subscribe()
    }
}
