import Foundation
import Testing
import FountainKit
@testable import GoatCore

@Suite("MCPServers config")
struct MCPServersTests {
    @Test func parsesTheThreeWildShapes() throws {
        let wire = #"""
        {
          "github": {"type": "http", "url": "https://api.githubcopilot.com/mcp/",
                     "headers": {"Authorization": "Bearer ${GITHUB_TOKEN}"}},
          "slack": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-slack"],
                    "env": {"SLACK_TEAM_ID": "T1"}},
          "gmail": {"connection": "592671c2"}
        }
        """#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(wire.utf8))
        let entries = MCPServers.parse(value)
        #expect(entries.map(\.name) == ["github", "gmail", "slack"])
        #expect(entries[0].kind == .http(url: "https://api.githubcopilot.com/mcp/"))
        #expect(entries[1].kind == .connection(id: "592671c2"))
        #expect(entries[2].kind == .stdio(command: "npx -y @modelcontextprotocol/server-slack"))
    }

    @Test func unknownShapesSurviveUntouched() throws {
        let value = JSONValue.object(["weird": .object(["future_key": .bool(true)])])
        let entries = MCPServers.parse(value)
        #expect(entries.first?.kind == .other)
        // Round-trip through set-another-key keeps the unknown entry whole.
        let updated = MCPServers.setting(value, name: "new", config: MCPServers.connectionConfig(id: "c1"))
        #expect(updated["weird"] == .object(["future_key": .bool(true)]))
    }

    @Test func removingLastEntryYieldsEmptyObjectNotNil() {
        let one = MCPServers.setting(nil, name: "a", config: MCPServers.connectionConfig(id: "c1"))
        let none = MCPServers.removing(one, name: "a")
        #expect(none == .object([:]))
    }

    @Test func buildersMatchTheWireShape() {
        let http = MCPServers.httpConfig(
            url: "https://mcp.example.com/mcp",
            headers: ["Authorization": "Bearer ${TOKEN}"])
        #expect(http["type"]?.stringValue == "http")
        #expect(http["url"]?.stringValue == "https://mcp.example.com/mcp")
        #expect(http["headers"]?["Authorization"]?.stringValue == "Bearer ${TOKEN}")

        let stdio = MCPServers.stdioConfig(command: "npx", args: ["-y", "pkg"], env: ["K": "v"])
        #expect(stdio["command"]?.stringValue == "npx")
        #expect(stdio["args"]?.arrayValue?.compactMap(\.stringValue) == ["-y", "pkg"])

        // Empty collections are omitted, not encoded as empty.
        let bare = MCPServers.stdioConfig(command: "npx")
        #expect(bare["args"] == nil)
        #expect(bare["env"] == nil)
    }

    @Test func suggestedKeyStripsRegistryNoise() {
        #expect(MCPServers.suggestedKey(for: "io.github.foo/bar-mcp-server") == "bar")
        #expect(MCPServers.suggestedKey(for: "com.pulsemcp/remote-filesystem") == "remote-filesystem")
        #expect(MCPServers.suggestedKey(for: "ai.smithery/mcp-obsidian") == "obsidian")
        #expect(MCPServers.suggestedKey(for: "ac.inference.sh/mcp") == "inference")
    }

    @Test func fountainPlaceholdersConvertWithoutDoubleConverting() {
        #expect(MCPServers.fountainPlaceholders("Bearer {smithery_api_key}") == "Bearer ${SMITHERY_API_KEY}")
        #expect(MCPServers.fountainPlaceholders("Bearer ${ALREADY}") == "Bearer ${ALREADY}")
        #expect(MCPServers.fountainPlaceholders("plain") == "plain")
    }
}

@Suite("MCPRegistryClient")
struct MCPRegistryClientTests {
    /// Fixture captured from the live registry (shape, not content).
    private let pageJSON = #"""
    {"servers": [
      {"server": {"name": "io.github.foo/bar-mcp", "description": "Bar things.", "version": "1.2.0",
        "remotes": [{"type": "streamable-http", "url": "https://bar.example/mcp",
          "headers": [{"name": "Authorization", "value": "Bearer {bar_key}", "isRequired": true, "isSecret": true}]}]},
       "_meta": {"io.modelcontextprotocol.registry/official": {"status": "active", "isLatest": true}}},
      {"server": {"name": "io.github.gone/dead-mcp", "version": "0.1.0"},
       "_meta": {"io.modelcontextprotocol.registry/official": {"status": "deleted", "isLatest": true}}},
      {"server": {"name": "com.example/pkg", "version": "2.0.0",
        "packages": [{"registryType": "npm", "identifier": "@example/pkg", "version": "2.0.0",
          "runtimeHint": "npx", "transport": {"type": "stdio"},
          "runtimeArguments": [{"value": "-y", "type": "positional"}],
          "environmentVariables": [{"name": "API_KEY", "isRequired": true, "isSecret": true}]}]},
       "_meta": {"io.modelcontextprotocol.registry/official": {"status": "active", "isLatest": true}}}
    ],
    "metadata": {"nextCursor": "com.example/pkg:2.0.0", "count": 3}}
    """#

    @Test func decodesAndFiltersDeletedServers() async throws {
        let json = pageJSON
        let transport = RoutedTransport { request in
            let query = request.url?.query ?? ""
            #expect(query.contains("version=latest"))
            return (200, json)
        }
        let client = MCPRegistryClient(transport: transport)
        let page = try await client.servers(search: "bar")

        #expect(page.servers.map(\.name) == ["io.github.foo/bar-mcp", "com.example/pkg"])
        #expect(page.nextCursor == "com.example/pkg:2.0.0")

        let remote = try #require(page.servers.first?.remotes?.first)
        #expect(remote.url == "https://bar.example/mcp")
        #expect(remote.headers?.first?.isSecret == true)

        let package = try #require(page.servers.last?.packages?.first)
        #expect(package.runtimeHint == "npx")
        #expect(package.environmentVariables?.first?.name == "API_KEY")
    }

    @Test func non2xxThrows() async {
        let transport = RoutedTransport { _ in (503, "{}") }
        let client = MCPRegistryClient(transport: transport)
        await #expect(throws: MCPRegistryError.self) {
            _ = try await client.servers()
        }
    }
}
