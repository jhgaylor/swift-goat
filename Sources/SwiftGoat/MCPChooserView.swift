import SwiftUI
import FountainKit
import GoatCore

/// The MCP chooser: browse the official registry, mount one of the
/// account's OAuth connections, or type a custom config. Returns one
/// named entry for the agent's `mcp_servers`; the caller owns saving.
struct MCPChooserSheet: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let existingNames: [String]
    let onAdd: (String, JSONValue) -> Void

    enum Source: String, CaseIterable, Identifiable {
        case registry = "Registry"
        case connections = "Connections"
        case custom = "Custom"

        var id: String { rawValue }
    }

    @State private var source: Source = .registry

    var body: some View {
        VStack(spacing: 0) {
            Picker("Source", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            Group {
                switch source {
                case .registry:
                    RegistryBrowser(existingNames: existingNames, onAdd: add)
                case .connections:
                    ConnectionPicker(existingNames: existingNames, onAdd: add)
                case .custom:
                    CustomServerForm(existingNames: existingNames, onAdd: add)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Text("`${NAME}` in a value interpolates a secret from the conversation's environment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 860, minHeight: 560)
        .navigationTitle("Add MCP Server")
    }

    private func add(_ name: String, _ config: JSONValue) {
        onAdd(name, config)
        dismiss()
    }
}

// MARK: - Registry

/// Search-as-you-type over registry.modelcontextprotocol.io: results on
/// the left, the selected server's configurator on the right.
private struct RegistryBrowser: View {
    let existingNames: [String]
    let onAdd: (String, JSONValue) -> Void

    @State private var registry = MCPRegistryStore()
    @State private var selectedID: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Search the MCP registry…", text: $registry.query)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                Divider()
                resultsList
            }
            .frame(minWidth: 340, idealWidth: 380)

            Group {
                if let server = registry.results.first(where: { $0.id == selectedID }) {
                    RegistryServerConfigurator(
                        server: server, existingNames: existingNames, onAdd: onAdd
                    )
                    .id(server.id)
                } else {
                    ContentUnavailableView(
                        "Pick a server",
                        systemImage: "square.and.arrow.down.on.square",
                        description: Text("Search the registry, then choose how to run the server.")
                    )
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        // Debounced live search; also runs the initial browse.
        .task(id: registry.query) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await registry.search()
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        switch registry.phase {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView(
                "Registry unreachable",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .loaded:
            if registry.results.isEmpty {
                ContentUnavailableView.search(text: registry.query)
            } else {
                List(selection: $selectedID) {
                    ForEach(registry.results) { server in
                        RegistryRow(server: server).tag(server.id)
                    }
                    if registry.nextCursor != nil {
                        HStack {
                            Spacer()
                            if registry.isLoadingMore {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Load More") {
                                    Task { await registry.loadMore() }
                                }
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
    }
}

private struct RegistryRow: View {
    let server: MCPRegistryServer

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(server.title ?? MCPServers.suggestedKey(for: server.name))
                .fontWeight(.medium)
            Text(server.name)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let description = server.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 4) {
                if !(server.remotes ?? []).isEmpty {
                    Badge(text: "remote", color: .blue)
                }
                ForEach(Array(Set((server.packages ?? []).compactMap(\.registryType))).sorted(), id: \.self) {
                    Badge(text: $0, color: .purple)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// How to run one registry server: pick a hosted remote or an installable
/// package, name the entry, fill the values it asks for, add.
private struct RegistryServerConfigurator: View {
    /// One way to run the server, flattened for the picker.
    enum Runway: Hashable {
        case remote(MCPRegistryServer.Remote)
        case package(MCPRegistryServer.Package)

        var label: String {
            switch self {
            case .remote(let remote): "Remote — \(remote.url)"
            case .package(let package):
                "\(package.registryType ?? "package") — \(package.identifier)"
            }
        }

        /// Hosted remotes need nothing installed in the sandbox; prefer them.
        var isSupported: Bool {
            switch self {
            case .remote: true
            case .package(let package):
                package.runtimeHint != nil || ["npm", "pypi"].contains(package.registryType ?? "")
            }
        }
    }

    let server: MCPRegistryServer
    let existingNames: [String]
    let onAdd: (String, JSONValue) -> Void

    @State private var name = ""
    @State private var runway: Runway?
    @State private var variables: [VariableField] = []

    struct VariableField: Identifiable {
        let id = UUID()
        var name: String
        var value: String
        var description: String?
        var isRequired: Bool
        var isSecret: Bool
    }

    private var runways: [Runway] {
        (server.remotes ?? []).map(Runway.remote)
            + (server.packages ?? []).map(Runway.package)
    }

    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent("Server", value: server.title ?? server.name)
                if let repository = server.repository?.url, let url = URL(string: repository) {
                    Link(repository, destination: url).font(.caption)
                }
                Picker("Run via", selection: $runway) {
                    ForEach(runways, id: \.self) { candidate in
                        Text(candidate.label).tag(Optional(candidate))
                            .disabled(!candidate.isSupported)
                    }
                }
                TextField("Name in config", text: $name)
                    .font(.body.monospaced())
                if existingNames.contains(name) {
                    Text("Replaces the existing “\(name)” entry.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if !variables.isEmpty {
                SwiftUI.Section(variablesTitle) {
                    ForEach($variables) { $variable in
                        VStack(alignment: .leading, spacing: 2) {
                            LabeledContent {
                                TextField("", text: $variable.value, prompt: Text("value"))
                                    .font(.body.monospaced())
                            } label: {
                                HStack(spacing: 4) {
                                    Text(variable.name)
                                    if variable.isSecret {
                                        Image(systemName: "key.fill").foregroundStyle(.orange)
                                    }
                                    if variable.isRequired { Text("*").foregroundStyle(.red) }
                                }
                            }
                            if let description = variable.description {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Add Server") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd)
            }
            .padding(12)
            .background(.bar)
        }
        .onAppear { seed() }
        .onChange(of: runway) { seedVariables() }
    }

    private var variablesTitle: String {
        if case .remote = runway { return "Headers" }
        return "Environment variables"
    }

    private var canAdd: Bool {
        guard runway != nil, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return variables.allSatisfy { !$0.isRequired || !$0.value.isEmpty }
    }

    private func seed() {
        name = MCPServers.suggestedKey(for: server.name)
        runway = runways.first { $0.isSupported }
        seedVariables()
    }

    /// Prefill what the registry entry declares: templates converted to
    /// Fountain's `${NAME}` form, secrets defaulting to a placeholder so
    /// the actual value lives in environment secrets, never the manifest.
    private func seedVariables() {
        guard let runway else {
            variables = []
            return
        }
        let declared: [MCPRegistryServer.Variable] =
            switch runway {
            case .remote(let remote): remote.headers ?? []
            case .package(let package): package.environmentVariables ?? []
            }
        variables = declared.map { variable in
            let template = variable.value ?? variable.default
                ?? (variable.isSecret == true ? "${\(variable.name.uppercased())}" : "")
            return VariableField(
                name: variable.name,
                value: MCPServers.fountainPlaceholders(template),
                description: variable.description,
                isRequired: variable.isRequired ?? false,
                isSecret: variable.isSecret ?? false
            )
        }
    }

    private func add() {
        guard let runway else { return }
        let values = variables.filter { !$0.value.isEmpty }
        let config: JSONValue =
            switch runway {
            case .remote(let remote):
                MCPServers.httpConfig(
                    url: remote.url,
                    headers: Dictionary(
                        values.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
                )
            case .package(let package):
                MCPServers.stdioConfig(
                    command: package.runtimeHint
                        ?? (package.registryType == "pypi" ? "uvx" : "npx"),
                    args: (package.runtimeArguments ?? []).compactMap(\.value)
                        + [package.identifier]
                        + (package.packageArguments ?? []).compactMap(\.value),
                    env: Dictionary(
                        values.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
                )
            }
        onAdd(name.trimmingCharacters(in: .whitespaces), config)
    }
}

// MARK: - Connections

/// The account's OAuth connections, mountable as `{connection: id}` —
/// the platform injects the live token server-side.
private struct ConnectionPicker: View {
    @SwiftUI.Environment(Session.self) private var session

    let existingNames: [String]
    let onAdd: (String, JSONValue) -> Void

    @State private var connections: [Connection]?
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView(
                    "Couldn't load connections",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if let connections {
                if connections.isEmpty {
                    ContentUnavailableView(
                        "No connections",
                        systemImage: "person.crop.circle.badge.plus",
                        description: Text("Connect Gmail, Microsoft and friends from your Fountain console, then mount them here.")
                    )
                } else {
                    List(connections) { connection in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(connection.provider)
                                    .fontWeight(.medium)
                                Text(connection.accountEmail ?? connection.id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let status = connection.status, status != .active {
                                Badge(text: status.rawValue, color: .orange)
                            }
                            Button("Add") {
                                onAdd(connection.provider, MCPServers.connectionConfig(id: connection.id))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard let client = session.client else { return }
            do {
                connections = try await client.connections.list()
            } catch {
                self.error = describe(error)
            }
        }
    }
}

// MARK: - Custom

/// Manual entry, for servers the registry doesn't know: a hosted URL with
/// headers, or a command with env.
private struct CustomServerForm: View {
    let existingNames: [String]
    let onAdd: (String, JSONValue) -> Void

    enum Kind: String, CaseIterable, Identifiable {
        case http = "Remote URL"
        case stdio = "Command"

        var id: String { rawValue }
    }

    struct Pair: Identifiable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    @State private var kind: Kind = .http
    @State private var name = ""
    @State private var url = ""
    @State private var command = ""
    @State private var pairs: [Pair] = []

    var body: some View {
        Form {
            Picker("Kind", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            TextField("Name in config", text: $name, prompt: Text("github"))
                .font(.body.monospaced())
            if existingNames.contains(name) {
                Text("Replaces the existing “\(name)” entry.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            switch kind {
            case .http:
                TextField("URL", text: $url, prompt: Text("https://mcp.example.com/mcp"))
                    .font(.body.monospaced())
            case .stdio:
                TextField("Command", text: $command, prompt: Text("npx -y @example/mcp-server"))
                    .font(.body.monospaced())
            }

            SwiftUI.Section(kind == .http ? "Headers" : "Environment variables") {
                ForEach($pairs) { $pair in
                    HStack {
                        TextField("KEY", text: $pair.key)
                        TextField("value", text: $pair.value, prompt: Text("${SECRET_NAME}"))
                        Button("Remove", systemImage: "minus.circle") {
                            pairs.removeAll { $0.id == pair.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                    .font(.body.monospaced())
                }
                Button("Add Row", systemImage: "plus") { pairs.append(Pair()) }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Add Server") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd)
            }
            .padding(12)
            .background(.bar)
        }
    }

    private var canAdd: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return switch kind {
        case .http: !url.trimmingCharacters(in: .whitespaces).isEmpty
        case .stdio: !command.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func add() {
        let filled = pairs.filter { !$0.key.isEmpty }
        let map = Dictionary(filled.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        let config: JSONValue =
            switch kind {
            case .http:
                MCPServers.httpConfig(url: url.trimmingCharacters(in: .whitespaces), headers: map)
            case .stdio:
                {
                    let words = command.split(separator: " ").map(String.init)
                    return MCPServers.stdioConfig(
                        command: words.first ?? "", args: Array(words.dropFirst()), env: map)
                }()
            }
        onAdd(name.trimmingCharacters(in: .whitespaces), config)
    }
}
