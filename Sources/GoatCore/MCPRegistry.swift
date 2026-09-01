import Foundation
import Observation
import FountainKit

/// Client for the official MCP registry (registry.modelcontextprotocol.io)
/// — the ecosystem-wide index the chooser browses. Not a Fountain API;
/// lives in GoatCore, but rides the same `HTTPTransport` seam so tests
/// inject a fake. Only `version=latest` entries are ever requested.
public struct MCPRegistryClient: Sendable {
    public let baseURL: URL
    let transport: any HTTPTransport

    public init(
        baseURL: URL = URL(string: "https://registry.modelcontextprotocol.io")!,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func servers(
        search: String? = nil, cursor: String? = nil, limit: Int = 30
    ) async throws -> MCPRegistryPage {
        var components = URLComponents(
            url: baseURL.appending(path: "/v0/servers"), resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "version", value: "latest"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let search, !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = query

        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw MCPRegistryError.status(response.statusCode)
        }
        let envelope = try JSONDecoder().decode(MCPRegistryEnvelope.self, from: data)
        return MCPRegistryPage(
            // The registry keeps deprecated/deleted entries listed; the
            // chooser should only offer live ones.
            servers: envelope.servers.filter { $0.official?.status ?? "active" == "active" }
                .map(\.server),
            nextCursor: envelope.metadata?.nextCursor
        )
    }
}

public enum MCPRegistryError: LocalizedError {
    case status(Int)

    public var errorDescription: String? {
        switch self {
        case .status(let code): "The MCP registry answered \(code)."
        }
    }
}

public struct MCPRegistryPage: Sendable {
    public var servers: [MCPRegistryServer]
    public var nextCursor: String?
}

// The registry's wire shape (camelCase keys, so no key strategy needed).
private struct MCPRegistryEnvelope: Decodable {
    struct Entry: Decodable {
        var server: MCPRegistryServer
        var _meta: [String: Meta]?

        var official: Meta? { _meta?["io.modelcontextprotocol.registry/official"] }
    }

    struct Meta: Decodable {
        var status: String?
        var isLatest: Bool?
    }

    struct Metadata: Decodable {
        var nextCursor: String?
        var count: Int?
    }

    var servers: [Entry]
    var metadata: Metadata?
}

/// One registry server: reverse-DNS `name`, human `title`, plus the ways
/// to run it — hosted `remotes` and installable `packages`.
public struct MCPRegistryServer: Sendable, Decodable, Hashable, Identifiable {
    public var name: String
    public var title: String?
    public var description: String?
    public var version: String?
    public var repository: Repository?
    public var remotes: [Remote]?
    public var packages: [Package]?

    public var id: String { name }

    public struct Repository: Sendable, Decodable, Hashable {
        public var url: String?
        public var source: String?
    }

    public struct Remote: Sendable, Decodable, Hashable {
        public var type: String?
        public var url: String
        public var headers: [Variable]?
    }

    public struct Package: Sendable, Decodable, Hashable {
        public var registryType: String?
        public var identifier: String
        public var version: String?
        public var runtimeHint: String?
        public var transport: Transport?
        public var runtimeArguments: [Argument]?
        public var packageArguments: [Argument]?
        public var environmentVariables: [Variable]?

        public struct Transport: Sendable, Decodable, Hashable {
            public var type: String?
        }

        public struct Argument: Sendable, Decodable, Hashable {
            public var type: String?
            public var value: String?
            public var name: String?
        }
    }

    /// A header or environment variable the server wants, possibly secret.
    public struct Variable: Sendable, Decodable, Hashable {
        public var name: String
        public var description: String?
        public var isRequired: Bool?
        public var isSecret: Bool?
        public var value: String?
        public var `default`: String?
    }
}

/// Searchable, cursor-paginated view over the registry for the chooser.
@Observable @MainActor
public final class MCPRegistryStore {
    public enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public var query = ""
    public private(set) var results: [MCPRegistryServer] = []
    public private(set) var phase: Phase = .idle
    public private(set) var nextCursor: String?
    public private(set) var isLoadingMore = false

    private let client: MCPRegistryClient

    public init(client: MCPRegistryClient = MCPRegistryClient()) {
        self.client = client
    }

    public func search() async {
        phase = .loading
        nextCursor = nil
        do {
            let page = try await client.servers(search: query)
            results = page.servers
            nextCursor = page.nextCursor
            phase = .loaded
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            results = []
            phase = .failed(describe(error))
        }
    }

    public func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.servers(search: query, cursor: cursor)
            results += page.servers
            nextCursor = page.nextCursor
        } catch {
            // Keep what we have; the footer button retries.
        }
    }
}
