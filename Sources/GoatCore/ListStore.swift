import Foundation
import Observation
import FountainKit

/// One observable list per feature section: items + loading phase + error
/// copy, refreshed through an injected fetch. Views watch this; they never
/// call FountainKit themselves.
@Observable @MainActor
public final class ListStore<Item: Identifiable & Sendable> {
    public enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var items: [Item] = []
    public private(set) var phase: Phase = .idle

    private let fetch: @Sendable (FountainClient) async throws -> [Item]

    public init(fetch: @escaping @Sendable (FountainClient) async throws -> [Item]) {
        self.fetch = fetch
    }

    public func refresh(_ client: FountainClient) async {
        phase = .loading
        do {
            items = try await fetch(client)
            phase = .loaded
        } catch {
            phase = .failed(describe(error))
        }
    }
}

/// The stores the app shell holds, one per sidebar section.
@Observable @MainActor
public final class AppStores {
    public let agents = ListStore<Agent> { try await $0.agents.list() }
    public let environments = ListStore<Environment> { try await $0.environments.list() }
    public let vaults = ListStore<Vault> { try await $0.vaults.list() }
    public let conversations = ListStore<Conversation> { try await $0.conversations.list() }
    public let team = ListStore<Teammate> { try await $0.team.list() }
    public let runners = ListStore<Runner> { try await $0.runners.list() }
    public let sandboxes = ListStore<Sandbox> { try await $0.sandboxes.list() }

    public init() {}
}
