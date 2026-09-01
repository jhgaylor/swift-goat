import Foundation
import Observation
import FountainKit

/// Account-wide watch for permission requests, independent of any open
/// transcript: tails `/api/events/stream`, opens an alert per
/// `permission_request` block, and moots a conversation's alerts when its
/// turn ends or its sandbox goes away. The UI layer decides how alerts
/// surface (notifications, dock badge) through the callbacks; answering
/// goes back through here so a notification button needs no store.
@Observable @MainActor
public final class PermissionWatcher {
    public struct Alert: Sendable, Hashable, Identifiable {
        public let conversationID: String
        public let request: PermissionRequest

        public var id: String { request.requestID }
    }

    public private(set) var pending: [Alert] = []
    /// Fired once per newly seen request.
    public var onNew: (@MainActor (Alert) -> Void)?
    /// Fired with the request ids that just stopped being answerable.
    public var onResolved: (@MainActor ([String]) -> Void)?

    private var tail: Task<Void, Never>?
    private var client: FountainClient?
    /// Requests alerted this session — a reconnect replay must not re-ring.
    private var seenRequestIDs: Set<String> = []

    public init() {}

    public func start(client: FountainClient) {
        stop()
        self.client = client
        tail = Task { [weak self] in
            // The SSE loop gives up after its retries; a background watcher
            // should outlive server restarts, so keep coming back.
            while !Task.isCancelled {
                guard let self, let client = self.client else { return }
                do {
                    for try await item in client.events.stream() {
                        guard !Task.isCancelled else { return }
                        if case .log(let event) = item {
                            self.track(event)
                        }
                    }
                } catch {}
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    public func stop() {
        tail?.cancel()
        tail = nil
        client = nil
        pending = []
        seenRequestIDs = []
    }

    /// Answer from a notification action: the first offered option whose
    /// kind starts with the prefix (`allow` / `reject`) — mirroring the
    /// transcript card, only server-offered options are ever sent.
    public func answer(requestID: String, optionKindPrefix: String) async {
        guard let client,
              let alert = pending.first(where: { $0.id == requestID }),
              let optionID = alert.request.options.first(where: {
                  $0.optionID != nil && $0.kind?.hasPrefix(optionKindPrefix) == true
              })?.optionID
        else { return }
        do {
            try await client.conversations.answer(
                alert.conversationID, requestID: requestID, optionID: optionID)
        } catch let error as FountainError where error.code == "permission_request_resolved" {
            // Someone answered elsewhere first — same outcome.
        } catch {
            // Leave the alert standing; the transcript card is the retry path.
            return
        }
        pending.removeAll { $0.id == requestID }
        onResolved?([requestID])
    }

    private func track(_ event: LogEvent) {
        guard let conversationID = event.conversationID else { return }
        if event.kind == .stage {
            // Same mooting rule as ConversationStore, plus teardown stages —
            // a dead conversation can't take an answer.
            let ended = (event.stage == "turn" && event.state != .started)
                || event.stage == "terminate" || event.stage == "server"
            if ended { resolveAll(for: conversationID) }
            return
        }
        guard event.kind == .output else { return }
        for block in event.blocks ?? [] {
            guard let request = PermissionRequest(block: block),
                  seenRequestIDs.insert(request.requestID).inserted
            else { continue }
            let alert = Alert(conversationID: conversationID, request: request)
            pending.append(alert)
            onNew?(alert)
        }
    }

    private func resolveAll(for conversationID: String) {
        let resolved = pending.filter { $0.conversationID == conversationID }.map(\.id)
        guard !resolved.isEmpty else { return }
        pending.removeAll { $0.conversationID == conversationID }
        onResolved?(resolved)
    }
}
