import Foundation
import SwiftUI
import Darwin

private struct Failure: Error { let message: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
}
private func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }; throw Failure(message: "Unexpected acceptance")
}

@main @MainActor struct SpatterPersonalMemoryTests {
    static func idle(_ vm: SpatterAIViewModel) async throws {
        for _ in 0..<1000 {
            if !vm.isThinking { return }
            await Task.yield()
        }
        throw Failure(message: "Actual coordinator never completed")
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-memory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpatterPersonalMemoryStore(directory: root.appendingPathComponent("preferences"))
        let accountA = UUID(), accountB = UUID()
        var calls = 0, sent: [SpatterChatMessage] = []
        var delayed: CheckedContinuation<String, Error>?
        let vm = SpatterAIViewModel(responder: { history, _ in
            calls += 1; sent = history
            if history.last?.content == "Delayed response" { return try await withCheckedThrowingContinuation { delayed = $0 } }
            return "Actual injected transport response"
        }, memoryStore: store)
        vm.configurePersonalMemory(accountID: accountA.uuidString)
        try require(!vm.personalPreferences.enabled, "Default must be disabled")
        try require(!FileManager.default.fileExists(atPath: store.directory.path), "Reading absent memory must not persist inferred data")
        var selected = SpatterPersonalPreferences(); selected.enabled = true; selected.guidance = .beginner; selected.focus = .audio
        try require(vm.savePersonalPreferences(selected), "Explicit save failed")
        try require(try store.load(.account(accountA)) == selected, "Actual cold store read differs")
        try require(try !store.load(.account(accountB)).enabled && !store.load(.guest).enabled, "Account/guest isolation")
        print("PASS disabled default, explicit persistence, independent account and guest records")

        try require(vm.submit("How do I export MP4?", context: .general), "Local actual submit")
        try await idle(vm)
        try require(vm.messages.last?.content.contains("For your audio focus") == true && calls == 0, "Opt-in local help must use selected choices without cloud")
        vm.useCloud = true
        try require(vm.submit("Export help", context: .general), "Cloud actual submit")
        try await idle(vm)
        try require(calls == 1 && sent.count == 1 && sent[0].content == "Export help", "Memory or local reply leaked into actual cloud boundary")
        try require(!sent.contains { $0.content.contains("audio focus") || $0.content.contains("saved local preferences") }, "No memory injection")
        print("PASS actual local advice personalization and unchanged cloud request boundary")

        try require(vm.submit("Delayed response", context: .general), "Delayed production request")
        for _ in 0..<1000 { if delayed != nil { break }; await Task.yield() }
        try require(delayed != nil, "Actual injected transport did not start")
        vm.configurePersonalMemory(accountID: accountB.uuidString)
        delayed?.resume(returning: "Late response for previous account"); delayed = nil
        for _ in 0..<20 { await Task.yield() }
        try require(vm.messages.isEmpty && !vm.personalPreferences.enabled && !vm.useCloud, "Account change leaked transient state")
        vm.configurePersonalMemory(accountID: nil)
        var guest = SpatterPersonalPreferences(); guest.enabled = true; guest.focus = .drawing
        try require(vm.savePersonalPreferences(guest), "Guest explicit save")
        vm.configurePersonalMemory(accountID: accountA.uuidString)
        try require(vm.personalPreferences == selected, "Returning account did not reload own choices")
        var disabled = selected; disabled.enabled = false
        try require(vm.savePersonalPreferences(disabled), "Disable failed")
        try require(vm.submit("layers", context: .general), "Disabled local request")
        try await idle(vm)
        try require(vm.messages.last?.content.contains("saved local preferences") == false, "Disabled choices used")
        try require(vm.resetPersonalMemory(), "Actual reset failed")
        try require(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("account-" + accountA.uuidString + ".json").path), "Reset did not delete actual record")
        try require(try store.load(.guest) == guest && !store.load(.account(accountA)).enabled, "Reset touched guest or retained account consent")
        vm.configurePersonalMemory(accountID: "../../guest")
        try require(!vm.savePersonalPreferences(selected) && !vm.personalPreferences.enabled, "Invalid account became guest")
        print("PASS account transitions, disabled behavior, actual reset and invalid-identity fencing")

        let transfer = root.appendingPathComponent("export.json"), bytes = try selected.encoded()
        try bytes.write(to: transfer)
        try require(try SpatterPersonalMemoryStore.readImport(transfer) == selected, "Real bounded file import roundtrip")
        let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        try require(Set(object.keys) == ["version", "enabled", "guidance", "focus"], "Export includes unrelated identity or transcript fields")
        for invalid in [Data(repeating: 65, count: 2049), Data("{}".utf8), Data("{\"version\":2,\"enabled\":true,\"guidance\":\"standard\",\"focus\":\"general\"}".utf8), Data("{\"version\":1,\"enabled\":true,\"guidance\":\"standard\",\"focus\":\"general\",\"secret\":\"do not store\"}".utf8)] {
            try rejects { _ = try SpatterPersonalPreferences.decode(invalid) }
        }
        let linked = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: transfer)
        try rejects { _ = try SpatterPersonalMemoryStore.readImport(linked) }
        let before = try Data(contentsOf: transfer)
        try FileManager.default.createSymbolicLink(at: store.directory.appendingPathComponent("account-" + accountB.uuidString + ".json"), withDestinationURL: transfer)
        try rejects { try store.save(selected, scope: .account(accountB)) }
        try require(try Data(contentsOf: transfer) == before, "Unsafe store write changed linked original")
        // No writer is ever opened. O_NONBLOCK must let regular-file validation
        // reject each FIFO rather than waiting forever inside open on the UI actor.
        let importFIFO = root.appendingPathComponent("import-fifo.json")
        let fifoAccount = UUID()
        let accountFIFO = store.directory.appendingPathComponent("account-" + fifoAccount.uuidString + ".json")
        try require(mkfifo(importFIFO.path, 0o600) == 0 && mkfifo(accountFIFO.path, 0o600) == 0, "Create real FIFO fixtures")
        let began = Date()
        try rejects { _ = try SpatterPersonalMemoryStore.readImport(importFIFO) }
        try rejects { _ = try store.load(.account(fifoAccount)) }
        try require(Date().timeIntervalSince(began) < 2, "FIFO rejection must be prompt with no writer")
        print("PASS real import/export schema, bounds, symlink rejection and original preservation")
    }
}
