import Foundation
import Observation
import FountainKit

/// The admin users table: server-side search/filter state plus page-number
/// pagination (`/api/admin/users` is the one endpoint that pages this way).
@Observable @MainActor
public final class AdminUsersStore {
    public enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Server-side query state; call `refresh` after changing any of these.
    public var query = ""
    public var roleFilter: UserRole?
    public var compedFilter: Bool?

    public private(set) var users: [AdminUser] = []
    public private(set) var total = 0
    public private(set) var phase: Phase = .idle
    public private(set) var isLoadingMore = false

    private var page = 1
    private let perPage: Int

    public init(perPage: Int = 50) {
        self.perPage = perPage
    }

    public var hasMore: Bool { users.count < total }

    /// Reload from page 1 with the current query state.
    public func refresh(_ client: FountainClient) async {
        phase = .loading
        page = 1
        do {
            let result = try await fetch(client, page: 1)
            users = result.users
            total = result.total
            phase = .loaded
        } catch {
            phase = .failed(describe(error))
        }
    }

    /// Append the next page (no-op while loading or when everything is in).
    public func loadMore(_ client: FountainClient) async {
        guard hasMore, !isLoadingMore, phase == .loaded else { return }
        isLoadingMore = true
        do {
            let result = try await fetch(client, page: page + 1)
            page = result.page
            total = result.total
            let known = Set(users.map(\.id))
            users.append(contentsOf: result.users.filter { !known.contains($0.id) })
        } catch {
            phase = .failed(describe(error))
        }
        isLoadingMore = false
    }

    /// Swap one user in place after a mutation returned the fresh record.
    public func replace(_ user: AdminUser) {
        if let index = users.firstIndex(where: { $0.id == user.id }) {
            users[index] = user
        }
    }

    private func fetch(_ client: FountainClient, page: Int) async throws -> AdminUserPage {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return try await client.admin.users(
            query: trimmed.isEmpty ? nil : trimmed,
            role: roleFilter,
            comped: compedFilter,
            page: page,
            perPage: perPage
        )
    }
}
