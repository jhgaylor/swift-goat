import SwiftUI
import FountainKit
import GoatCore

/// Agents list. Click opens the agent's detail page; "+" (⌘N) creates;
/// delete key or the row's context menu deletes.
struct AgentsSectionView: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores
    @SwiftUI.Environment(Nav.self) private var nav
    @State private var selection: String?
    @State private var creating = false
    @State private var discovering = false
    @State private var pendingDelete: Agent?
    @State private var error: String?

    var body: some View {
        @Bindable var nav = nav
        NavigationStack(path: $nav.agentPath) {
            ResourceListView(store: stores.agents, title: "Agents", selection: $selection) { agent in
                NavigationLink(value: agent.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name)
                        Text("\(agent.runtime.rawValue) · \(agent.model)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button("Delete…", role: .destructive) { pendingDelete = agent }
                }
            }
            .navigationDestination(for: String.self) { id in
                AgentDetailView(agentID: id)
            }
            .toolbar {
                Button("Discover", systemImage: "sparkles") { discovering = true }
                    .help("Scan this Mac for agents to import and services to plug in")
                Button("New Agent", systemImage: "plus") { creating = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            .onDeleteCommand {
                pendingDelete = stores.agents.items.first { $0.id == selection }
            }
            .sheet(isPresented: $creating) {
                AgentCreateSheet {
                    creating = false
                    refresh()
                }
            }
            .sheet(isPresented: $discovering) {
                DiscoverAgentsSheet { refresh() }
            }
            .confirmationDialog(
                "Delete agent?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { agent in
                Button("Delete \"\(agent.name)\"", role: .destructive) {
                    delete(agent)
                }
            } message: { agent in
                Text("Conversations that used \(agent.name) keep their transcripts.")
            }
            .alert("Couldn't delete", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func delete(_ agent: Agent) {
        guard let client = session.client else { return }
        Task {
            do {
                try await client.agents.delete(agent.id)
                await stores.agents.refresh(client)
            } catch {
                self.error = describe(error)
            }
        }
    }

    private func refresh() {
        guard let client = session.client else { return }
        Task { await stores.agents.refresh(client) }
    }
}

/// The editable core of an agent's config, as plain values so the detail
/// page can diff against what it loaded (dirty check drives Save).
struct AgentFormValues: Equatable {
    var name = ""
    var description = ""
    var runtime: String = Runtime.claude.rawValue
    var model = ""
    var system = ""
    var environmentID: String?
    var sandboxProvider: String?
    var sandboxMode: String?
    var mcpServers: JSONValue?
    var skills: [Skill] = []

    init() {}

    init(_ agent: Agent) {
        name = agent.name
        description = agent.description ?? ""
        runtime = agent.runtime.rawValue
        model = agent.model
        system = agent.system ?? ""
        environmentID = agent.environmentID
        sandboxProvider = agent.sandboxProvider?.rawValue
        sandboxMode = agent.sandboxMode?.rawValue
        mcpServers = agent.mcpServers
        skills = agent.skills ?? []
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var input: AgentInput {
        AgentInput(
            name: name.trimmingCharacters(in: .whitespaces),
            description: description.isEmpty ? nil : description,
            system: system.isEmpty ? nil : system,
            model: model.trimmingCharacters(in: .whitespaces),
            runtime: Runtime(rawValue: runtime),
            sandboxProvider: sandboxProvider.map(SandboxProvider.init(rawValue:)),
            sandboxMode: sandboxMode.map(SandboxMode.init(rawValue:)),
            environmentID: environmentID,
            // Always sent so removing the last skill clears it server-side.
            skills: skills,
            mcpServers: mcpServers
        )
    }
}

/// The shared form fields (used by the create sheet and the detail page).
/// Skills and per-tool permission policies stay manifest territory for
/// now; MCP servers get the chooser.
struct AgentFormFields: View {
    @Binding var values: AgentFormValues
    let catalog: Catalog?
    let environments: [FountainKit.Environment]

    @State private var choosingMCP = false

    private var runtimeOptions: [String] {
        catalog?.runtimes ?? [
            Runtime.claude.rawValue, Runtime.codex.rawValue,
            Runtime.gemini.rawValue, Runtime.opencode.rawValue,
        ]
    }

    private var modelSuggestions: [String] {
        catalog?.models?[values.runtime] ?? []
    }

    private var providerOptions: [String] {
        catalog?.sandboxProviders?.enabled ?? []
    }

    var body: some View {
        TextField("Name", text: $values.name)
        TextField("Description", text: $values.description)

        Picker("Runtime", selection: $values.runtime) {
            ForEach(runtimeOptions, id: \.self) { Text($0).tag($0) }
        }

        HStack {
            TextField("Model", text: $values.model, prompt: Text("provider/model"))
            if !modelSuggestions.isEmpty {
                Menu("Suggestions") {
                    ForEach(modelSuggestions, id: \.self) { suggestion in
                        Button(suggestion) { values.model = suggestion }
                    }
                }
                .fixedSize()
            }
        }

        Picker("Default environment", selection: $values.environmentID) {
            Text("None").tag(String?.none)
            ForEach(environments) { environment in
                Text(environment.name).tag(Optional(environment.id))
            }
        }

        Picker("Sandbox provider", selection: $values.sandboxProvider) {
            Text("Deployment default").tag(String?.none)
            ForEach(providerOptions, id: \.self) { Text($0).tag(Optional($0)) }
        }

        Picker("Sandbox mode", selection: $values.sandboxMode) {
            Text("Default").tag(String?.none)
            Text("ephemeral").tag(Optional(SandboxMode.ephemeral.rawValue))
            Text("persistent").tag(Optional(SandboxMode.persistent.rawValue))
        }

        if !values.skills.isEmpty {
            SwiftUI.Section("Skills") {
                ForEach(Array(values.skills.enumerated()), id: \.offset) { index, skill in
                    HStack {
                        Image(systemName: skill.content != nil ? "doc.text" : "arrow.down.doc")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(skill.name ?? skill.source ?? "skill").font(.body.monospaced())
                            Text(skill.content.map { "inline · \($0.count.formatted()) chars" }
                                ?? [skill.source, skill.ref].compactMap { $0 }.joined(separator: " @ "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            values.skills.remove(at: index)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
            }
        }

        SwiftUI.Section("MCP servers") {
            let entries = MCPServers.parse(values.mcpServers)
            if entries.isEmpty {
                Text("None. The agent gets only its runtime's built-in tools.")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                HStack {
                    Image(systemName: icon(for: entry.kind))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name).font(.body.monospaced())
                        Text(entry.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        values.mcpServers = MCPServers.removing(values.mcpServers, name: entry.name)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            Button("Add MCP Server…", systemImage: "plus") { choosingMCP = true }
        }
        .sheet(isPresented: $choosingMCP) {
            MCPChooserSheet(
                existingNames: MCPServers.parse(values.mcpServers).map(\.name)
            ) { name, config in
                values.mcpServers = MCPServers.setting(values.mcpServers, name: name, config: config)
            }
        }

        SwiftUI.Section("System prompt") {
            TextEditor(text: $values.system)
                .font(.body.monospaced())
                .frame(minHeight: 120)
        }
    }

    private func icon(for kind: MCPServers.Entry.Kind) -> String {
        switch kind {
        case .http: "globe"
        case .stdio: "terminal"
        case .connection: "person.crop.circle.badge.checkmark"
        case .other: "questionmark.square.dashed"
        }
    }
}

/// One agent, editable in place. Save (⌘S) enables when something changed;
/// the toolbar also spawns a conversation with this agent or deletes it.
struct AgentDetailView: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores
    @SwiftUI.Environment(Nav.self) private var nav
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let agentID: String

    @State private var loaded: Agent?
    @State private var values = AgentFormValues()
    @State private var original = AgentFormValues()
    @State private var isSaving = false
    @State private var startingConversation = false
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        Group {
            if loaded == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    AgentFormFields(
                        values: $values,
                        catalog: stores.catalog,
                        environments: stores.environments.items
                    )
                    if let error {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle(loaded?.name ?? "Agent")
        .navigationSubtitle(loaded?.model ?? "")
        .toolbar {
            Button("New Conversation", systemImage: "bubble.left.and.text.bubble.right") {
                startingConversation = true
            }
            .help("Start a conversation with this agent")
            Button("Save", systemImage: "checkmark.circle") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(values == original || !values.isValid || isSaving)
            Button("Delete", systemImage: "trash") { confirmDelete = true }
        }
        .task(id: agentID) { await load() }
        .sheet(isPresented: $startingConversation) {
            NewConversationView(initialAgentID: agentID) { conversation in
                startingConversation = false
                nav.openConversation(conversation.id)
            }
        }
        .confirmationDialog("Delete agent?", isPresented: $confirmDelete) {
            Button("Delete \"\(loaded?.name ?? agentID)\"", role: .destructive) { delete() }
        } message: {
            Text("Conversations that used this agent keep their transcripts.")
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        async let catalog: () = stores.loadCatalog(client)
        async let environments: () = stores.environments.refresh(client)
        do {
            let agent = try await client.agents.get(agentID)
            loaded = agent
            values = AgentFormValues(agent)
            original = values
        } catch {
            self.error = describe(error)
            loaded = nil
        }
        _ = await (catalog, environments)
    }

    private func save() {
        guard let client = session.client else { return }
        isSaving = true
        error = nil
        Task {
            do {
                let updated = try await client.agents.update(agentID, values.input)
                loaded = updated
                values = AgentFormValues(updated)
                original = values
                await stores.agents.refresh(client)
            } catch {
                self.error = describe(error)
            }
            isSaving = false
        }
    }

    private func delete() {
        guard let client = session.client else { return }
        Task {
            do {
                try await client.agents.delete(agentID)
                await stores.agents.refresh(client)
                dismiss()
            } catch {
                self.error = describe(error)
            }
        }
    }
}

/// Create a new agent (sheet — creation is a modal moment; editing is not).
struct AgentCreateSheet: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let onCreated: () -> Void

    @State private var values: AgentFormValues
    @State private var isSaving = false
    @State private var error: String?

    /// `initial` pre-fills the form (Discover drafts); the user still confirms.
    init(initial: AgentFormValues = AgentFormValues(), onCreated: @escaping () -> Void) {
        _values = State(initialValue: initial)
        self.onCreated = onCreated
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                AgentFormFields(
                    values: $values,
                    catalog: stores.catalog,
                    environments: stores.environments.items
                )
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Agent") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!values.isValid || isSaving)
            }
            .padding(12)
            .overlay(alignment: .leading) {
                if isSaving {
                    ProgressView().controlSize(.small).padding(.leading, 12)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 520)
        .navigationTitle("New Agent")
        .task {
            guard let client = session.client else { return }
            async let catalog: () = stores.loadCatalog(client)
            async let environments: () = stores.environments.refresh(client)
            _ = await (catalog, environments)
        }
    }

    private func create() {
        guard let client = session.client else { return }
        isSaving = true
        error = nil
        Task {
            do {
                _ = try await client.agents.create(values.input)
                isSaving = false
                onCreated()
            } catch {
                isSaving = false
                self.error = describe(error)
            }
        }
    }
}
