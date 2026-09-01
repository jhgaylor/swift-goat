import Foundation
import Testing
import FountainKit
@testable import GoatCore

/// Path-routed fake transport. JSON endpoints answer via `respond`; the SSE
/// endpoint yields nothing and stays open (the real stream idles too) until
/// the test pushes events through it.
final class RoutedTransport: HTTPTransport, @unchecked Sendable {
    typealias Responder = @Sendable (URLRequest) -> (status: Int, json: String)

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var continuations: [AsyncThrowingStream<Data, Error>.Continuation] = []
    private let respond: Responder

    init(respond: @escaping Responder) {
        self.respond = respond
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func count(of pathSuffix: String, method: String? = nil) -> Int {
        requests.filter {
            $0.url?.path.hasSuffix(pathSuffix) == true
                && (method == nil || $0.httpMethod == method)
        }.count
    }

    /// Deliver raw SSE text on every open stream.
    func push(_ sse: String) {
        lock.lock()
        let open = continuations
        lock.unlock()
        for continuation in open {
            continuation.yield(Data(sse.utf8))
        }
    }

    private func response(_ status: Int, _ url: URL?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url ?? URL(string: "https://fountain.test")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    private func hold(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        lock.lock()
        continuations.append(continuation)
        lock.unlock()
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let (status, json) = respond(request)
        return (Data(json.utf8), response(status, request.url))
    }

    func bytes(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        record(request)
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            self.hold(continuation)
        }
        return (response(200, request.url), stream)
    }
}

private func client(_ transport: RoutedTransport) -> FountainClient {
    FountainClient(
        config: FountainConfig(
            baseURL: URL(string: "https://fountain.test")!,
            apiKey: "ftn_live_test"
        ),
        transport: transport
    )
}

private let conversationJSON = #"{"data": {"id": "c1", "runtime": "claude", "status": "running"}}"#

private let permissionEventJSON = #"""
{"id": 2, "kind": "output", "stream": "acp", "blocks": [{"kind": "permission_request", "request_id": "req_1", "summary": "Run ls?", "name": "bash", "options": [{"optionId": "opt_allow", "kind": "allow_once", "name": "Allow"}, {"optionId": "opt_reject", "kind": "reject_once", "name": "Reject"}]}]}
"""#

private func historyJSON(_ events: [String]) -> String {
    #"{"data": [\#(events.joined(separator: ","))], "meta": {"has_more": false}}"#
}

private let turnStartedJSON = #"{"id": 1, "kind": "stage", "stage": "turn", "state": "started"}"#
private let turnDoneJSON = #"{"id": 3, "kind": "stage", "stage": "turn", "state": "done"}"#

@MainActor
private func eventually(
    timeout: TimeInterval = 2,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite("ConversationStore permission requests")
@MainActor
struct ConversationStorePermissionTests {
    @Test("A permission_request block in an open turn becomes pending")
    func pendingFromHistory() async throws {
        let transport = RoutedTransport { request in
            switch request.url!.path {
            case "/api/conversations/c1/events":
                (200, historyJSON([turnStartedJSON, permissionEventJSON]))
            default:
                (200, conversationJSON)
            }
        }
        let store = ConversationStore(client: client(transport), id: "c1")
        await store.start()
        defer { store.stop() }

        #expect(store.pendingPermissions.count == 1)
        #expect(store.pendingPermissions.first?.requestID == "req_1")
        #expect(store.pendingPermissions.first?.options.count == 2)
    }

    @Test("A turn ending moots pending requests")
    func turnEndClears() async throws {
        let transport = RoutedTransport { request in
            switch request.url!.path {
            case "/api/conversations/c1/events":
                (200, historyJSON([turnStartedJSON, permissionEventJSON, turnDoneJSON]))
            default:
                (200, conversationJSON)
            }
        }
        let store = ConversationStore(client: client(transport), id: "c1")
        await store.start()
        defer { store.stop() }

        #expect(store.pendingPermissions.isEmpty)
    }

    @Test("Answering removes the request; a resolved conflict is not an error")
    func answering() async throws {
        let transport = RoutedTransport { request in
            switch request.url!.path {
            case "/api/conversations/c1/events":
                (200, historyJSON([turnStartedJSON, permissionEventJSON]))
            case "/api/conversations/c1/requests/req_1":
                (409, #"{"error": "permission_request_resolved", "message": "already answered"}"#)
            default:
                (200, conversationJSON)
            }
        }
        let store = ConversationStore(client: client(transport), id: "c1")
        await store.start()
        defer { store.stop() }

        let request = try #require(store.pendingPermissions.first)
        await store.answer(request, optionID: "opt_allow")

        #expect(store.pendingPermissions.isEmpty)
        #expect(store.error == nil)
        #expect(transport.count(of: "/requests/req_1", method: "POST") == 1)
    }
}

@Suite("ConversationStore prompt queue")
@MainActor
struct ConversationStoreQueueTests {
    @Test("conversation_busy queues; a live turn end flushes the queue")
    func busyThenFlush() async throws {
        let promptCalls = Mutex(0)
        let transport = RoutedTransport { request in
            switch request.url!.path {
            case "/api/conversations/c1/events":
                return (200, historyJSON([]))
            case "/api/conversations/c1/prompts":
                let call = promptCalls.increment()
                if call == 1 {
                    return (409, #"{"error": "conversation_busy", "message": "mid-turn"}"#)
                }
                return (200, "{}")
            default:
                return (200, conversationJSON)
            }
        }
        let store = ConversationStore(client: client(transport), id: "c1")
        await store.start()
        defer { store.stop() }

        await store.send("hello")
        #expect(store.queuedPrompts.map(\.prompt) == ["hello"])

        // The running turn ends on the live stream: queue should flush.
        transport.push("id: 3\ndata: \(turnDoneJSON)\n\n")
        let flushed = await eventually { store.queuedPrompts.isEmpty }
        #expect(flushed)
        #expect(transport.count(of: "/prompts", method: "POST") == 2)
        #expect(store.error == nil)
    }
}

/// Tiny lock-guarded counter (the responder closure is Sendable).
private final class Mutex: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(_ value: Int) { self.value = value }

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
