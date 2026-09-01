import SwiftUI
import FountainKit
import GoatCore

/// "Discover agents": scan this Mac — local harness configs, the projects
/// worked in, installed apps, browsing history — and turn what it finds
/// into agent drafts and integration suggestions. Everything is read
/// locally; the only network call is listing the account's connections so
/// a Gmail visit can map onto a connection the account already holds.
struct DiscoverAgentsSheet: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores
    @SwiftUI.Environment(\.dismiss) private var dismiss
    /// Called after an agent was created from a draft (refresh the list).
    let onCreated: () -> Void

    @State private var scan: MachineScan?
    @State private var recommendations: Recommendations?
    @State private var isScanning = false
    @State private var includeBrowsing = true
    @State private var draft: AgentDraft?
    @State private var showAllImports = false
    @State private var status: String?
    @State private var error: String?

    /// Machines with dozens of registered projects get dozens of imports.
    private static let importPreview = 8

    var body: some View {
        VStack(spacing: 0) {
            GatedView(scope: .machineScan, reason: "scan this Mac for agent recommendations") {
                content
            }
            Divider()
            HStack {
                Label("Scanned locally. Nothing leaves this Mac until you create an agent.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if scan != nil {
                    Button("Rescan") { runScan() }.disabled(isScanning)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 760, minHeight: 640)
        .navigationTitle("Discover Agents")
        .sheet(item: $draft) { draft in
            AgentCreateSheet(initial: values(for: draft)) {
                self.draft = nil
                status = "Created \"\(draft.name)\""
                onCreated()
            }
        }
        .alert("Couldn't update agent", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        if let recommendations, let scan {
            results(recommendations, scan)
        } else if isScanning {
            ProgressView("Scanning this Mac…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Discover Agents", systemImage: "sparkles.rectangle.stack")
            } description: {
                Text("""
                Looks at the agent configs already on this Mac (Claude Code, Codex, Gemini, OpenCode, Cursor), \
                the projects you work in, the apps you have installed, and the sites you visit — \
                then suggests agents to create and services to plug in.
                """)
            } actions: {
                VStack(spacing: 12) {
                    Toggle("Include browser history (aggregated by site; Safari needs Full Disk Access)", isOn: $includeBrowsing)
                        .toggleStyle(.checkbox)
                    Button("Scan This Mac") { runScan() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func results(_ recommendations: Recommendations, _ scan: MachineScan) -> some View {
        let imported = recommendations.drafts.filter { if case .imported = $0.kind { true } else { false } }
        let roles = recommendations.drafts.filter { if case .role = $0.kind { true } else { false } }
        return Form {
            SwiftUI.Section {
                if imported.isEmpty {
                    Text("No local harness configs found.").foregroundStyle(.secondary)
                }
                let visible = showAllImports ? imported : Array(imported.prefix(Self.importPreview))
                ForEach(visible) { draft in
                    DraftRow(draft: draft) { self.draft = draft }
                }
                if imported.count > Self.importPreview {
                    Button(showAllImports
                        ? "Show fewer"
                        : "Show \(imported.count - Self.importPreview) more project configs") {
                        showAllImports.toggle()
                    }
                    .buttonStyle(.link)
                }
            } header: {
                Text("Import your local agent configs")
            } footer: {
                Text("Instructions become the system prompt, local skills are inlined, MCP servers carry over with credentials replaced by ${SECRET} references.")
            }

            SwiftUI.Section("Suggested agents") {
                if roles.isEmpty {
                    Text("Not enough project activity to suggest a role yet.").foregroundStyle(.secondary)
                }
                ForEach(roles) { draft in
                    DraftRow(draft: draft) { self.draft = draft }
                }
            }

            SwiftUI.Section {
                if recommendations.integrations.isEmpty {
                    Text("Nothing recognized. Turn on browser history or connect a provider under Fountain › Connections.")
                        .foregroundStyle(.secondary)
                }
                ForEach(recommendations.integrations) { recommendation in
                    IntegrationRow(recommendation: recommendation, agents: stores.agents.items) { agent in
                        add(recommendation, to: agent)
                    } newAgent: {
                        draft = Recommender.draft(for: recommendation)
                    }
                }
            } header: {
                Text("Integrations you use")
            }

            SwiftUI.Section("What was scanned") {
                LabeledContent("Harness configs", value: "\(scan.sites.count) (\(scan.sites.filter { $0.scope == .user }.count) user-level)")
                LabeledContent("Projects", value: "\(scan.projects.count) registered, \(scan.projects.filter { $0.lastActive.map { $0 > Date().addingTimeInterval(-90 * 86400) } ?? false }.count) active in 90 days")
                LabeledContent("Browsing", value: scan.browsersRead.isEmpty
                    ? "off"
                    : "\(scan.browsing.count) sites across \(scan.browsersRead.map(\.browser.rawValue).uniqued().joined(separator: ", "))")
                LabeledContent("Apps", value: "\(scan.apps.count)")
                LabeledContent("Locations probed", value: "\(scan.probed.count) in \(String(format: "%.1f", scan.duration))s")
                Toggle("Include browser history", isOn: $includeBrowsing)
                if !scan.unreadable.isEmpty {
                    DisclosureGroup("\(scan.unreadable.count) location\(scan.unreadable.count == 1 ? "" : "s") couldn't be read") {
                        ForEach(scan.unreadable, id: \.path) { item in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Actions

    private func runScan() {
        isScanning = true
        error = nil
        let include = includeBrowsing
        let client = session.client
        Task {
            let scan = await Task.detached(priority: .userInitiated) {
                MachineScanner(includeBrowsing: include).scan()
            }.value
            var connections: [Connection] = []
            if let client {
                connections = (try? await client.connections.list()) ?? []
                await stores.agents.refresh(client)
                await stores.loadCatalog(client)
            }
            self.scan = scan
            recommendations = Recommender.recommend(scan, connections: connections)
            isScanning = false
        }
    }

    private func add(_ recommendation: Recommendation, to agent: Agent) {
        guard let client = session.client, let config = recommendation.config else { return }
        Task {
            do {
                let patch = AgentInput(mcpServers: MCPServers.setting(
                    agent.mcpServers, name: recommendation.integration.id, config: config
                ))
                _ = try await client.agents.update(agent.id, patch)
                await stores.agents.refresh(client)
                status = "Added \(recommendation.integration.title) to \"\(agent.name)\""
            } catch {
                self.error = describe(error)
            }
        }
    }

    private func values(for draft: AgentDraft) -> AgentFormValues {
        var values = AgentFormValues()
        values.name = draft.name
        values.description = draft.description
        values.runtime = draft.runtime.rawValue
        values.model = stores.catalog?.models?[draft.runtime.rawValue]?.first ?? ""
        values.system = draft.system
        values.skills = draft.skills
        values.mcpServers = draft.mcpServers
        return values
    }
}

/// One draft: what it is, what it carries, what got lost on the way.
private struct DraftRow: View {
    let draft: AgentDraft
    let create: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(draft.title).font(.headline)
                    Text(draft.runtime.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Text(draft.subtitle).font(.caption).foregroundStyle(.secondary)
                ForEach(draft.evidence.map(\.label), id: \.self) { line in
                    Text("• " + line).font(.caption)
                }
                if !draft.notes.isEmpty {
                    DisclosureGroup("\(draft.notes.count) note\(draft.notes.count == 1 ? "" : "s")") {
                        ForEach(draft.notes, id: \.self) { note in
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
            Spacer()
            Button("Create…") { create() }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch draft.kind {
        case .imported: "square.and.arrow.down"
        case .role: "person.text.rectangle"
        case .integration: "puzzlepiece.extension"
        }
    }
}

/// One integration with its evidence and an "Add to Agent" menu.
private struct IntegrationRow: View {
    let recommendation: Recommendation
    let agents: [Agent]
    let addTo: (Agent) -> Void
    let newAgent: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: recommendation.config == nil ? "questionmark.circle" : "puzzlepiece.extension")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(recommendation.integration.title).font(.headline)
                Text(recommendation.integration.blurb).font(.caption).foregroundStyle(.secondary)
                ForEach(recommendation.evidence.prefix(3).map(\.label), id: \.self) { line in
                    Text("• " + line).font(.caption)
                }
                if !recommendation.secrets.isEmpty {
                    Text("Needs " + recommendation.secrets.map { "${\($0)}" }.joined(separator: ", ") + " in the conversation's environment.")
                        .font(.caption)
                }
                ForEach(recommendation.notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if recommendation.config != nil {
                Menu("Add to Agent") {
                    ForEach(agents) { agent in
                        Button(agent.name) { addTo(agent) }
                    }
                    if !agents.isEmpty { Divider() }
                    Button("New Agent with \(recommendation.integration.title)…") { newAgent() }
                }
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }
}

extension Array where Element: Hashable {
    /// Order-preserving de-duplication.
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
