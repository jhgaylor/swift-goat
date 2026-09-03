import Foundation
import FountainKit

/// Reading and writing the agent's `mcp_servers` leaf. The wire shape is
/// name-keyed Claude-style config, three kinds in the wild:
/// `{type: "http", url, headers}`, `{command, args, env}`, and Fountain's
/// `{connection: "<uuid>"}`. `${NAME}` inside values interpolates a secret
/// from the conversation's environment at spawn time.
public enum MCPServers {
    /// One named entry, summarized for display. Unknown shapes pass
    /// through untouched — an editor must never eat config it doesn't
    /// understand.
    public struct Entry: Identifiable, Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case http(url: String)
            case stdio(command: String)
            case connection(id: String)
            case other
        }

        public var name: String
        public var kind: Kind
        public var config: JSONValue

        public var id: String { name }

        public var summary: String {
            switch kind {
            case .http(let url): url
            case .stdio(let command): command
            case .connection(let id): "connection \(id)"
            case .other: "custom config"
            }
        }
    }

    public static func parse(_ value: JSONValue?) -> [Entry] {
        guard let object = value?.objectValue else { return [] }
        return object.map { name, config in
            Entry(name: name, kind: kind(of: config), config: config)
        }
        .sorted { $0.name < $1.name }
    }

    private static func kind(of config: JSONValue) -> Entry.Kind {
        if let id = config["connection"]?.stringValue { return .connection(id: id) }
        if let url = config["url"]?.stringValue { return .http(url: url) }
        if let command = config["command"]?.stringValue {
            let args = config["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return .stdio(command: ([command] + args).joined(separator: " "))
        }
        return .other
    }

    public static func setting(_ value: JSONValue?, name: String, config: JSONValue) -> JSONValue {
        var object = value?.objectValue ?? [:]
        object[name] = config
        return .object(object)
    }

    /// Removing the last entry yields `{}`, not nil — a PATCH omitting the
    /// field wouldn't clear anything server-side.
    public static func removing(_ value: JSONValue?, name: String) -> JSONValue {
        var object = value?.objectValue ?? [:]
        object[name] = nil
        return .object(object)
    }

    // MARK: - Builders

    public static func httpConfig(url: String, headers: [String: String] = [:]) -> JSONValue {
        var config: [String: JSONValue] = [
            "type": .string("http"),
            "url": .string(url),
        ]
        if !headers.isEmpty {
            config["headers"] = .object(headers.mapValues(JSONValue.string))
        }
        return .object(config)
    }

    public static func stdioConfig(
        command: String, args: [String] = [], env: [String: String] = [:]
    ) -> JSONValue {
        var config: [String: JSONValue] = ["command": .string(command)]
        if !args.isEmpty { config["args"] = .array(args.map(JSONValue.string)) }
        if !env.isEmpty { config["env"] = .object(env.mapValues(JSONValue.string)) }
        return .object(config)
    }

    public static func connectionConfig(id: String) -> JSONValue {
        .object(["connection": .string(id)])
    }

    // MARK: - Registry conversion helpers

    /// A short config key out of a reverse-DNS registry name:
    /// `io.github.foo/bar-mcp-server` → `bar`. When the name part is just
    /// "mcp" (`ac.inference.sh/mcp`), fall back to the domain
    /// (`inference`).
    public static func suggestedKey(for registryName: String) -> String {
        let parts = registryName.lowercased().split(separator: "/")
        var key = String(parts.last ?? "server")
        for suffix in ["-mcp-server", "-mcp", "-server", "_mcp"] where key.hasSuffix(suffix) {
            key = String(key.dropLast(suffix.count))
        }
        for prefix in ["mcp-server-", "mcp-", "server-"] where key.hasPrefix(prefix) {
            key = String(key.dropFirst(prefix.count))
        }
        if key.isEmpty || key == "mcp", let namespace = parts.first {
            let domain = namespace.split(separator: ".")
            key = String(domain.count >= 2 ? domain[domain.count - 2] : domain.first ?? "server")
        }
        let allowed = key.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return allowed.isEmpty ? "server" : allowed
    }

    /// Registry templates write placeholders as `{api_key}`; Fountain
    /// interpolates secrets as `${API_KEY}`. Convert without touching
    /// values that are already in Fountain form.
    public static func fountainPlaceholders(_ template: String) -> String {
        // Match a possible leading `$` too: `${X}` is already Fountain
        // form and passes through (no lookbehind in Swift regex).
        template.replacing(/(\$?)\{([A-Za-z0-9_]+)\}/) { match in
            match.output.1.isEmpty
                ? "${\(match.output.2.uppercased())}"
                : String(match.output.0)
        }
    }
}
