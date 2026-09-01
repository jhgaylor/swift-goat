import Foundation
import Testing
import FountainKit
@testable import GoatCore

/// The account-wide permission watcher against the fake all-events stream.
@Suite("PermissionWatcher")
@MainActor
struct PermissionWatcherTests {
    private func makeClient(_ transport: RoutedTransport) -> FountainClient {
        FountainClient(
            config: FountainConfig(
                baseURL: URL(string: "https://fountain.test")!,
                apiKey: "ftn_live_test"
            ),
            transport: transport
        )
    }

    private let permissionEvent = #"""
    {"id": 10, "kind": "output", "stream": "acp", "conversation_id": "c1", "blocks": [{"kind": "permission_request", "request_id": "req_1", "summary": "Run ls?", "name": "bash", "options": [{"optionId": "opt_allow", "kind": "allow_once", "name": "Allow"}, {"optionId": "opt_reject", "kind": "reject_once", "name": "Reject"}]}]}
    """#

    private let turnDoneEvent = #"{"id": 11, "kind": "stage", "stage": "turn", "state": "done", "conversation_id": "c1"}"#

    private func awaitTrue(
        timeout: TimeInterval = 2, _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func permissionBlockOpensAnAlertOnce() async {
        let transport = RoutedTransport { _ in (200, "{}") }
        let watcher = PermissionWatcher()
        var announced: [String] = []
        watcher.onNew = { announced.append($0.id) }
        watcher.start(client: makeClient(transport))
        defer { watcher.stop() }

        let opened = await awaitTrue { transport.count(of: "/api/events/stream") == 1 }
        #expect(opened)
        transport.push("id: 10\ndata: \(permissionEvent)\n\n")

        let arrived = await awaitTrue { !watcher.pending.isEmpty }
        #expect(arrived)
        #expect(watcher.pending.map(\.id) == ["req_1"])
        #expect(watcher.pending.first?.conversationID == "c1")

        // A reconnect replay of the same event must not re-ring. (Short
        // timeout: we're waiting for something that must NOT happen.)
        transport.push("id: 10\ndata: \(permissionEvent)\n\n")
        _ = await awaitTrue(timeout: 0.3) { announced.count > 1 }
        #expect(announced == ["req_1"])
        #expect(watcher.pending.count == 1)
    }

    @Test func turnEndMootsTheConversationsAlerts() async {
        let transport = RoutedTransport { _ in (200, "{}") }
        let watcher = PermissionWatcher()
        var resolved: [String] = []
        watcher.onResolved = { resolved.append(contentsOf: $0) }
        watcher.start(client: makeClient(transport))
        defer { watcher.stop() }

        _ = await awaitTrue { transport.count(of: "/api/events/stream") == 1 }
        transport.push("id: 10\ndata: \(permissionEvent)\n\n")
        _ = await awaitTrue { !watcher.pending.isEmpty }

        transport.push("id: 11\ndata: \(turnDoneEvent)\n\n")
        let cleared = await awaitTrue { watcher.pending.isEmpty }
        #expect(cleared)
        #expect(resolved == ["req_1"])
    }

    @Test func answerPostsTheMatchingOfferedOption() async {
        let transport = RoutedTransport { request in
            if request.url?.path.hasSuffix("/requests/req_1") == true {
                return (200, "{}")
            }
            return (200, "{}")
        }
        let watcher = PermissionWatcher()
        watcher.start(client: makeClient(transport))
        defer { watcher.stop() }

        _ = await awaitTrue { transport.count(of: "/api/events/stream") == 1 }
        transport.push("id: 10\ndata: \(permissionEvent)\n\n")
        _ = await awaitTrue { !watcher.pending.isEmpty }

        await watcher.answer(requestID: "req_1", optionKindPrefix: "allow")
        #expect(transport.count(of: "/requests/req_1", method: "POST") == 1)
        let sent = transport.requests.last { $0.url?.path.hasSuffix("/requests/req_1") == true }
        let body = sent?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(body.contains("opt_allow"))
        #expect(watcher.pending.isEmpty)
    }

    @Test func answerConflictResolvesQuietly() async {
        let transport = RoutedTransport { request in
            if request.url?.path.hasSuffix("/requests/req_1") == true {
                return (409, #"{"error": "permission_request_resolved", "message": "answered"}"#)
            }
            return (200, "{}")
        }
        let watcher = PermissionWatcher()
        watcher.start(client: makeClient(transport))
        defer { watcher.stop() }

        _ = await awaitTrue { transport.count(of: "/api/events/stream") == 1 }
        transport.push("id: 10\ndata: \(permissionEvent)\n\n")
        _ = await awaitTrue { !watcher.pending.isEmpty }

        await watcher.answer(requestID: "req_1", optionKindPrefix: "reject")
        #expect(watcher.pending.isEmpty)
    }
}
