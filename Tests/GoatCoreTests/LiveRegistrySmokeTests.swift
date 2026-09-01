import Foundation
import Testing
import FountainKit
@testable import GoatCore

/// Read-only smoke against the real MCP registry (and the Fountain
/// connections endpoint the chooser also reads). Off by default so
/// `swift test` is hermetic; run with:
///
///     FOUNTAIN_SMOKE=1 swift test --filter LiveRegistrySmokeTests
///
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FOUNTAIN_SMOKE"] != nil))
struct LiveRegistrySmokeTests {
    @Test func registrySearchPaginatesAndDecodes() async throws {
        let client = MCPRegistryClient()
        let page = try await client.servers(search: "github", limit: 5)
        #expect(!page.servers.isEmpty)
        // Every result must offer at least one way to run it that the
        // configurator can render.
        for server in page.servers {
            #expect(!(server.remotes ?? []).isEmpty || !(server.packages ?? []).isEmpty)
            #expect(!MCPServers.suggestedKey(for: server.name).isEmpty)
        }
        if let cursor = page.nextCursor {
            let next = try await client.servers(search: "github", cursor: cursor, limit: 5)
            #expect(next.servers.map(\.name) != page.servers.map(\.name))
        }
    }

    @Test func connectionsEndpointDecodes() async throws {
        let client = FountainClient(config: .fromEnvironment())
        let connections = try await client.connections.list()
        for connection in connections {
            #expect(!connection.provider.isEmpty)
        }
    }
}
