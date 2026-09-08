import Foundation
import SwiftUI

private struct Failure: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(message: message) }
}
private final class NetworkTrap: URLProtocol {
    private static let lock = NSLock()
    private static var attempts = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    override class func canInit(with request: URLRequest) -> Bool {
        guard ["http", "https"].contains(request.url?.scheme ?? "") else { return false }
        lock.lock(); attempts += 1; lock.unlock(); return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
@MainActor private final class Gate {
    var pending: CheckedContinuation<String, Error>?
    func response() async throws -> String { try await withCheckedThrowingContinuation { pending = $0 } }
    func finish(_ value: String) { let waiting = pending; pending = nil; waiting?.resume(returning: value) }
}

@main @MainActor struct SpatterConversationTests {
    static func idle(_ vm: SpatterAIViewModel) async throws {
        for _ in 0..<400 {
            if !vm.isThinking { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw Failure(message: "Conversation did not reach a terminal state")
    }
    private static func started(_ gate: Gate) async throws {
        for _ in 0..<400 {
            if gate.pending != nil { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw Failure(message: "Injected response gate did not start")
    }
    static func settle() async { for _ in 0..<10 { await Task.yield() } }
    static func main() async {
        URLProtocol.registerClass(NetworkTrap.self)
        defer { URLProtocol.unregisterClass(NetworkTrap.self) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-spatter-conversation-\(UUID().uuidString)")
        var passed = 0
        func test(_ name: String, _ body: () async throws -> Void) async throws {
            try await body(); passed += 1; print("PASS \(name)")
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let storage = DeviceStorageManager(documentsDirectory: root, cachesDirectory: root)
            let studio = StudioViewModel(storage: storage)
            try require(await studio.createProject(name: "Private project marker", width: 64, height: 64, fps: 12), "Actual production project creation failed")
            try await test("local lookup uses actual preserved knowledge and captures a cleared draft without cloud calls") {
                var calls = 0
                let vm = SpatterAIViewModel(responder: { _, _ in calls += 1; return "Must not be called" })
                var draft = "How do I export my animation?"
                let accepted = vm.submit(draft, context: .messages)
                if accepted { draft = "" }
                try await idle(vm)
                try require(accepted && draft.isEmpty && vm.messages[0].content == "How do I export my animation?", "Submitted prompt was lost")
                try require(vm.status == .localGuide && vm.messages.last?.origin == .local && calls == 0, "Local lookup used cloud or false state")
                try require(SpatterKnowledgeBase.allModules.count == 120, "Preserved brain modules changed")
                let first = vm.messages.last!.content
                try require(vm.submit("How does onion skin work?", context: .messages), "Second guide request rejected")
                try await idle(vm)
                try require(vm.messages.last!.content != first, "Distinct supported topics returned invariant canned text")
            }
            try await test("empty and oversized UTF-8 drafts fail before message or request creation") {
                var calls = 0
                let vm = SpatterAIViewModel(responder: { _, _ in calls += 1; return "Unused" })
                for prompt in ["", " \n\t", String(repeating: "💀", count: 1501)] {
                    try require(!vm.submit(prompt, context: .messages), "Invalid draft accepted")
                    try require(vm.messages.isEmpty && !vm.isThinking && vm.status == .invalidInput, "Invalid draft changed conversation")
                }
                try require(calls == 0, "Invalid draft requested cloud")
            }
            try await test("explicit cloud mode retains actual error-word advice and sends generic Messages context") {
                var received: [SpatterChatMessage] = []
                var context: SpatterContext?
                let vm = SpatterAIViewModel(responder: { messages, value in received = messages; context = value; return "To diagnose this error, check the project settings." })
                try require(!vm.useCloud, "Cloud was enabled without choosing it")
                vm.useCloud = true
                try require(vm.submit("Help diagnose an export error", context: .messages), "Cloud draft rejected")
                try await idle(vm)
                try require(received.count == 1 && received[0].content == "Help diagnose an export error", "Wrong cloud request")
                try require(context == .messages && context?.studio == nil, "Messages inherited an open Studio project")
                try require(vm.status == .cloudAdvice && vm.messages.last!.content.contains("this error"), "Legitimate response filtered by literal word")
                try require(vm.messages.last?.origin == .cloud && !vm.statusText.contains("Online"), "Response claimed persistent online status")
            }
            try await test("config auth rate limit and network errors retain classified state plus real local help") {
                for expected in [SpatterClientError.notConfigured, .notAuthenticated, .httpStatus(429), .networkUnavailable] {
                    let vm = SpatterAIViewModel(responder: { _, _ in throw expected })
                    vm.useCloud = true
                    try require(vm.submit("Tell me about layers", context: .messages), "Failure-path draft rejected")
                    try await idle(vm)
                    try require(vm.status == .unavailable(expected) && vm.notice == expected.localizedDescription, "Failure classification was hidden")
                    try require(vm.messages.last?.origin == .local && vm.messages.last!.content != "I'm Spatter, your creative AI assistant! 🎨", "Failure emitted canned/cloud success")
                }
            }
            try await test("missing public auth configuration is reported as configuration rather than transport failure") {
                let vm = SpatterAIViewModel(responder: { _, _ in throw AppConfigurationError.supabaseUnavailable })
                vm.useCloud = true
                try require(vm.submit("Layers", context: .messages), "Request rejected")
                try await idle(vm)
                try require(vm.status == .unavailable(.notConfigured) && vm.messages.last?.origin == .local, "Public auth configuration failure was misclassified")
            }
            try await test("owned cancellation rejects an uncancellable late reply and permits retry") {
                let gate = Gate()
                let vm = SpatterAIViewModel(responder: { _, _ in try await gate.response() })
                vm.useCloud = true
                try require(vm.submit("First request", context: .messages), "Request rejected")
                try await started(gate)
                try require(!vm.submit("Duplicate request", context: .messages), "Concurrent request accepted")
                vm.cancel()
                try require(vm.status == .cancelled && !vm.isThinking, "Cancellation did not restore UI state")
                gate.finish("Late response that must not appear")
                await settle()
                try require(vm.messages.count == 1 && vm.status == .cancelled, "Late cancellation reply was published")
                try require(vm.submit("Retry request", context: .messages), "Cancelled conversation could not retry")
                try await started(gate); gate.finish("Real injected retry advice")
                try await idle(vm)
                try require(vm.status == .cloudAdvice && vm.messages.last!.content == "Real injected retry advice", "Retry did not complete")
            }
            try await test("Studio context comes from actual canonical document and contains no asset bytes or paths") {
                let context = try unwrap(SpatterContext.studio(studio.commandScreenContext))
                let snapshot = try unwrap(context.studio)
                try require(snapshot.projectID == studio.document.id && snapshot.revision == studio.document.revision, "Wrong canonical identity/revision")
                try require(snapshot.activeFrameID == studio.document.activeFrameID && snapshot.activeLayerID == studio.document.activeLayerID, "Wrong selection context")
                try require(snapshot.width == 64 && snapshot.height == 64 && snapshot.fps == 12 && snapshot.frameCount == 1, "Wrong actual project shape")
                let summary = try context.promptSummary()
                try require(summary.utf8.count < 8192 && !summary.contains(root.path) && !summary.contains("audioData") && !summary.contains("imageData"), "Snapshot exposed raw assets or private path")
                try require(SpatterContext.studio(StudioViewModel(storage: storage).commandScreenContext) == nil, "Library invented editable project context")
            }
            try await test("changed project revision discards stale cloud reply without altering actual document") {
                let gate = Gate(), vm = SpatterAIViewModel(responder: { _, _ in try await gate.response() })
                let context = try unwrap(SpatterContext.studio(studio.commandScreenContext))
                let revision = studio.document.revision, projectID = studio.document.id
                vm.useCloud = true
                try require(vm.submit("Advise on this frame", context: context, stillCurrent: { studio.document.id == projectID && studio.document.revision == revision }), "Studio draft rejected")
                try await started(gate)
                studio.addFrame()
                let changed = studio.document
                gate.finish("Advice for the old frame")
                try await idle(vm)
                try require(vm.status == .stale && vm.messages.count == 1 && studio.document == changed, "Stale reply implied a current result or changed document")
            }
            try await test("per-entry-point instances cannot inherit Studio cloud history") {
                var studioRequests: [[SpatterChatMessage]] = [], messagesRequests: [[SpatterChatMessage]] = []
                let studioChat = SpatterAIViewModel(responder: { messages, _ in studioRequests.append(messages); return "Studio-specific advice" })
                let messagesChat = SpatterAIViewModel(responder: { messages, context in
                    try require(context.studio == nil, "Generic context shared Studio")
                    messagesRequests.append(messages); return "Generic advice"
                })
                studioChat.useCloud = true; messagesChat.useCloud = true
                let context = try unwrap(SpatterContext.studio(studio.commandScreenContext))
                try require(studioChat.submit("Private Studio conversation marker", context: context), "Studio request rejected")
                try await idle(studioChat)
                try require(messagesChat.submit("Generic Messages question", context: .messages), "Messages request rejected")
                try await idle(messagesChat)
                try require(messagesRequests.count == 1 && messagesRequests[0].count == 1 && !messagesRequests[0][0].content.contains("Private"), "Cross-entry history leaked")
                try require(studioRequests.count == 1, "Unexpected Studio request")
            }
            try await test("ending session clears history choice and ignores in-flight replies") {
                let gate = Gate(), vm = SpatterAIViewModel(responder: { _, _ in try await gate.response() })
                vm.useCloud = true
                try require(vm.submit("Old account or sheet", context: .messages), "Request rejected")
                try await started(gate); vm.endSession(); gate.finish("Reply for dismissed sheet")
                await settle()
                try require(vm.messages.isEmpty && !vm.useCloud && vm.status == .localGuide && !vm.isThinking, "Dismissal retained private state or accepted stale reply")
                try require(vm.submit("Layers", context: .messages), "New local request rejected")
                try await idle(vm)
                try require(vm.messages.count == 2 && vm.messages.last?.origin == .local, "New session inherited old messages")
            }
            try await test("cloud response validation is explicit and hides raw transport diagnostics") {
                for answer in [" \n", String(repeating: "x", count: 32_769)] {
                    let vm = SpatterAIViewModel(responder: { _, _ in answer }); vm.useCloud = true
                    try require(vm.submit("Timing help", context: .messages), "Request rejected"); try await idle(vm)
                    try require(vm.status == .unavailable(answer.utf8.count > 32_768 ? .responseTooLarge : .emptyResponse), "Invalid response claimed success")
                }
                let vm = SpatterAIViewModel(responder: { _, _ in throw Failure(message: "private-provider-diagnostic") }); vm.useCloud = true
                try require(vm.submit("Timing help", context: .messages), "Request rejected"); try await idle(vm)
                try require(vm.status == .unavailable(.networkUnavailable) && !(vm.notice ?? "").contains("private-provider"), "Private diagnostic leaked")
            }
            try await test("bounded history remains user-led and natural-language advice never executes Studio commands") {
                var requests: [[SpatterChatMessage]] = []
                let vm = SpatterAIViewModel(responder: { messages, _ in requests.append(messages); return String(repeating: "Advice. ", count: 1000) })
                let before = studio.document
                let context = try unwrap(SpatterContext.studio(studio.commandScreenContext))
                vm.useCloud = true
                for index in 0..<10 {
                    try require(vm.submit("Create an editable animation and export it \(index)", context: context), "Request rejected")
                    try await idle(vm)
                }
                try require(requests.allSatisfy { $0.count <= 13 && $0.first?.role == .user && $0.reduce(0) { $0 + $1.content.utf8.count } <= 40_000 }, "Unbounded or assistant-led cloud history")
                try require(studio.document == before && vm.messages.count <= 40, "Advice executed project changes or retained unbounded messages")
            }
            _ = await studio.flush()
            try require(NetworkTrap.count == 0, "Tests attempted actual URLSession HTTP traffic")
            passed += 1; print("PASS no real URLSession HTTP requests across conversation tests")
            try FileManager.default.removeItem(at: root)
            print("\(passed) Spatter conversation tests passed")
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
    }
    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure(message: "Expected actual context") }
        return value
    }
}
