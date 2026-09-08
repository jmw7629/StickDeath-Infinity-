import Foundation

// Compile this harness with the complete production Models.swift, AppConfig.swift,
// and SpatterBackendClient.swift on macOS. No copied model definitions are used.
private struct TestFailure: Error { let message: String }

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message: message) }
}

@main
struct NativeModelTests {
    static func main() {
        var passed = 0
        do {
            let minimal = ChatMessage(id: 41, roomID: 7, senderID: "fixture-user", content: "Draft")
            try require(minimal.id == 41 && minimal.roomID == 7 && minimal.senderID == "fixture-user" && minimal.content == "Draft", "constructor changed message identity or content")
            try require(minimal.senderUsername == nil && minimal.createdAt == nil && minimal.mediaURL == nil && minimal.type == nil && minimal.reactions.isEmpty && minimal.replyTo == nil && minimal.readStatus == nil && minimal.edited == nil && minimal.voiceDuration == nil && minimal.threadCount == nil, "constructor changed optional defaults")
            passed += 1
            print("PASS explicit ChatMessage construction preserves identity and optional defaults")

            let full = ChatMessage(
                id: 99, roomID: 3, senderID: "sender", senderUsername: "fixture-name",
                content: "Reply", createdAt: "2026-09-08T12:00:00.000Z",
                mediaURL: "https://media.example/fixture", type: .voice,
                reactions: ["heart": ReactionData(count: 2, reacted: true)],
                replyTo: ReplyRef(sender: "prior", content: "First"), readStatus: .delivered,
                edited: true, voiceDuration: 12, threadCount: 3
            )
            let data = try JSONEncoder().encode(full)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TestFailure(message: "encoded message is not an object")
            }
            let expected: [String: Any] = [
                "id": 99, "room_id": 3, "sender_id": "sender", "sender_username": "fixture-name",
                "content": "Reply", "created_at": "2026-09-08T12:00:00.000Z",
                "media_url": "https://media.example/fixture", "type": "voice",
                "reactions": ["heart": ["count": 2, "reacted": true]],
                "reply_to": ["sender": "prior", "content": "First"], "read_status": "delivered",
                "edited": true, "voice_duration": 12, "thread_count": 3
            ]
            try require(NSDictionary(dictionary: object).isEqual(to: expected), "encoder changed fields or backend wire keys")
            let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
            try require(decoded.id == full.id && decoded.roomID == full.roomID && decoded.senderID == full.senderID && decoded.senderUsername == full.senderUsername && decoded.content == full.content && decoded.createdAt == full.createdAt && decoded.mediaURL == full.mediaURL && decoded.type == .voice && decoded.readStatus == .delivered && decoded.edited == true && decoded.voiceDuration == 12 && decoded.threadCount == 3, "roundtrip lost scalar fields")
            try require(decoded.reactions["heart"]?.count == 2 && decoded.reactions["heart"]?.reacted == true && decoded.replyTo?.sender == "prior" && decoded.replyTo?.content == "First", "roundtrip lost reaction or reply fields")
            passed += 1
            print("PASS complete ChatMessage roundtrip preserves fields and backend wire keys")

            // Older rows omit optional keys; explicit database nulls must behave the same.
            for payload in [
                #"{"id":4,"room_id":2,"sender_id":"sender","content":"Historical message"}"#,
                #"{"id":4,"room_id":2,"sender_id":"sender","content":"Historical message","sender_username":null,"created_at":null,"media_url":null,"type":null,"reactions":null,"reply_to":null,"read_status":null,"edited":null,"voice_duration":null,"thread_count":null}"#
            ] {
                let historical = try JSONDecoder().decode(ChatMessage.self, from: Data(payload.utf8))
                try require(historical.id == 4 && historical.roomID == 2 && historical.senderID == "sender" && historical.content == "Historical message", "historical identity or content changed")
                try require(historical.senderUsername == nil && historical.createdAt == nil && historical.mediaURL == nil && historical.type == nil && historical.reactions.isEmpty && historical.replyTo == nil && historical.readStatus == nil && historical.edited == nil && historical.voiceDuration == nil && historical.threadCount == nil, "historical decoder defaults changed")
            }
            passed += 1
            print("PASS sparse and null historical message payloads preserve decoder defaults")
            print("NATIVE_MODEL_TESTS=PASS \(passed)/3")
        } catch {
            print("NATIVE_MODEL_TESTS=FAIL after \(passed) tests: \(error)")
            exit(1)
        }
    }
}
