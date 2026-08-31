import Foundation
import Observation
import FountainKit

/// One open conversation: the record, its merged transcript, and a live
/// tail. Owns the two hard-won rules of Fountain feeds:
/// - merge history and live events **by event id** (the stream only follows
///   unfinished conversations, so gaps are normal; a status change triggers
///   a history backfill from the last seen id);
/// - `conversation_busy` is a queue, not an error toast — queued prompts
///   flush when the running turn ends.
@Observable @MainActor
public final class ConversationStore {
    public let id: String
    public private(set) var conversation: Conversation?
    /// Transcript, ordered by event id, deduplicated.
    public private(set) var events: [LogEvent] = []
    public private(set) var queuedPrompts: [String] = []
    public private(set) var error: String?
    public private(set) var isLoading = false

    private let client: FountainClient
    private var seenIDs: Set<Int> = []
    private var lastID = 0
    private var tail: Task<Void, Never>?

    public init(client: FountainClient, id: String) {
        self.client = client
        self.id = id
    }

    public func start() async {
        isLoading = true
        error = nil
        do {
            async let record = client.conversations.get(id)
            async let history = client.conversations.history(id)
            conversation = try await record
            merge(try await history)
            isLoading = false
            startTail()
        } catch {
            isLoading = false
            self.error = describe(error)
        }
    }

    public func stop() {
        tail?.cancel()
        tail = nil
    }

    /// Send now, or queue when the conversation is mid-turn.
    public func send(_ prompt: String) async {
        do {
            try await client.conversations.prompt(id, prompt)
        } catch FountainError.conversationBusy {
            queuedPrompts.append(prompt)
        } catch {
            self.error = describe(error)
        }
    }

    public func interrupt() async {
        do {
            try await client.conversations.interrupt(id)
        } catch {
            self.error = describe(error)
        }
    }

    private func startTail() {
        tail?.cancel()
        tail = Task { [weak self] in
            guard let self else { return }
            let stream = client.conversations.stream(id, StreamRequest(after: lastID))
            do {
                for try await item in stream {
                    guard !Task.isCancelled else { return }
                    if case .log(let event) = item {
                        merge([event])
                        await react(to: event)
                    }
                }
            } catch {
                if !Task.isCancelled { self.error = describe(error) }
            }
        }
    }

    private func merge(_ incoming: [LogEvent]) {
        var appended = false
        for event in incoming {
            guard let eventID = event.id else { continue }
            guard seenIDs.insert(eventID).inserted else { continue }
            events.append(event)
            lastID = max(lastID, eventID)
            appended = true
        }
        if appended {
            events.sort { ($0.id ?? 0) < ($1.id ?? 0) }
        }
    }

    /// Turn/lifecycle changes: refresh the record, backfill any gap, and
    /// flush the queue when the turn ended.
    private func react(to event: LogEvent) async {
        guard event.kind == .stage else { return }
        if let record = try? await client.conversations.get(id) {
            conversation = record
        }
        if let backfill = try? await client.conversations.history(id, after: lastID) {
            merge(backfill)
        }
        if event.stage == "turn", event.state != .started, !queuedPrompts.isEmpty {
            let next = queuedPrompts.removeFirst()
            await send(next)
        }
    }
}
