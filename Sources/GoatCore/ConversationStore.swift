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
    public private(set) var queuedPrompts: [QueuedPrompt] = []
    /// Unanswered permission requests from the current turn. A turn-end
    /// stage event moots whatever is still here.
    public private(set) var pendingPermissions: [PermissionRequest] = []
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

    /// Send now, or queue when the conversation is mid-turn. Attachments
    /// queue alongside their prompt so a busy flush loses nothing.
    public func send(_ prompt: String, images: [ImageInput] = []) async {
        do {
            try await client.conversations.prompt(id, prompt, images: images.isEmpty ? nil : images)
        } catch FountainError.conversationBusy {
            queuedPrompts.append(QueuedPrompt(prompt: prompt, images: images))
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

    /// Answer a pending permission request. A `permission_request_resolved`
    /// conflict means someone else answered first — drop it quietly.
    public func answer(_ request: PermissionRequest, optionID: String) async {
        do {
            try await client.conversations.answer(id, requestID: request.requestID, optionID: optionID)
            pendingPermissions.removeAll { $0.requestID == request.requestID }
        } catch let error as FountainError where error.code == "permission_request_resolved" {
            pendingPermissions.removeAll { $0.requestID == request.requestID }
        } catch {
            self.error = describe(error)
        }
    }

    public func terminate() async {
        do {
            try await client.conversations.terminate(id)
            if let record = try? await client.conversations.get(id) {
                conversation = record
            }
        } catch {
            self.error = describe(error)
        }
    }

    /// Delete the conversation server-side. True on success — the caller
    /// owns navigating away and refreshing lists.
    public func delete() async -> Bool {
        do {
            try await client.conversations.delete(id)
            stop()
            return true
        } catch {
            self.error = describe(error)
            return false
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
            track(event)
        }
        if appended {
            events.sort { ($0.id ?? 0) < ($1.id ?? 0) }
        }
    }

    /// Keep `pendingPermissions` honest as events flow past (history arrives
    /// oldest-first, so replaying a transcript settles to the right answer):
    /// a permission_request block opens a question, a turn ending moots all
    /// of them.
    private func track(_ event: LogEvent) {
        if event.stage == "turn", event.state != .started {
            pendingPermissions.removeAll()
            return
        }
        guard event.kind == .output else { return }
        for block in event.blocks ?? [] {
            guard let request = PermissionRequest(block: block),
                  !pendingPermissions.contains(where: { $0.requestID == request.requestID })
            else { continue }
            pendingPermissions.append(request)
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
            await send(next.prompt, images: next.images)
        }
    }
}

/// A prompt (plus its image attachments) parked while the agent is mid-turn.
public struct QueuedPrompt: Sendable {
    public var prompt: String
    public var images: [ImageInput]

    public init(prompt: String, images: [ImageInput] = []) {
        self.prompt = prompt
        self.images = images
    }
}
