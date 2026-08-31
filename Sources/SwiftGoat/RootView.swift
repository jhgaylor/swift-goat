import SwiftUI
import FountainKit
import GoatCore

/// The sidebar sections. Adding a Fountain surface = a case here plus a
/// detail view — nothing else moves.
enum Section: String, CaseIterable, Identifiable {
    case conversations = "Conversations"
    case team = "Team"
    case agents = "Agents"
    case environments = "Environments"
    case vaults = "Vaults"
    case sandboxes = "Sandboxes"
    case runners = "Runners"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .conversations: "bubble.left.and.bubble.right"
        case .team: "person.3"
        case .agents: "cpu"
        case .environments: "shippingbox"
        case .vaults: "lock"
        case .sandboxes: "desktopcomputer"
        case .runners: "server.rack"
        }
    }
}

struct RootView: View {
    @SwiftUI.Environment(Session.self) private var session
    @State private var selection: Section? = .conversations

    var body: some View {
        switch session.state {
        case .signedIn:
            NavigationSplitView {
                List(Section.allCases, selection: $selection) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(section)
                }
                .navigationTitle("Fountain")
            } detail: {
                SectionView(section: selection ?? .conversations)
            }
        case .signedOut, .checking, .failed:
            ConnectView()
        }
    }
}

/// Routes a sidebar selection to its list view.
struct SectionView: View {
    @SwiftUI.Environment(AppStores.self) private var stores
    let section: Section

    var body: some View {
        switch section {
        case .conversations:
            ResourceListView(store: stores.conversations, title: "Conversations") { conversation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title ?? conversation.firstPrompt ?? conversation.id)
                        .lineLimit(1)
                    Text("\(conversation.status.rawValue) · \(conversation.runtime.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .team:
            ResourceListView(store: stores.team, title: "Team") { teammate in
                VStack(alignment: .leading, spacing: 2) {
                    Text(teammate.name)
                    Text(teammate.presence.label ?? teammate.presence.state.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .agents:
            ResourceListView(store: stores.agents, title: "Agents") { agent in
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                    Text("\(agent.runtime.rawValue) · \(agent.model)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .environments:
            ResourceListView(store: stores.environments, title: "Environments") { environment in
                VStack(alignment: .leading, spacing: 2) {
                    Text(environment.name)
                    Text("\(environment.secretCount ?? 0) secrets · \(environment.agentCount ?? 0) agents")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .vaults:
            ResourceListView(store: stores.vaults, title: "Vaults") { vault in
                VStack(alignment: .leading, spacing: 2) {
                    Text(vault.name)
                    Text("\(vault.secretCount ?? 0) secrets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .sandboxes:
            ResourceListView(store: stores.sandboxes, title: "Sandboxes") { sandbox in
                VStack(alignment: .leading, spacing: 2) {
                    Text(sandbox.spriteName ?? sandbox.id)
                    Text("\(sandbox.status?.rawValue ?? "unknown") · \(sandbox.provider?.rawValue ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .runners:
            ResourceListView(store: stores.runners, title: "Runners") { runner in
                VStack(alignment: .leading, spacing: 2) {
                    Text(runner.name)
                    Text(runner.online ? "online" : "offline")
                        .font(.caption)
                        .foregroundStyle(runner.online ? Color.green : .secondary)
                }
            }
        }
    }
}

/// Generic list: loads on appear, shows phase, refreshes on demand.
struct ResourceListView<Item: Identifiable & Sendable, Row: View>: View {
    @SwiftUI.Environment(Session.self) private var session
    let store: ListStore<Item>
    let title: String
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading where store.items.isEmpty:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView(
                    "Couldn't load \(title.lowercased())",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            default:
                if store.items.isEmpty {
                    ContentUnavailableView("No \(title.lowercased()) yet", systemImage: "tray")
                } else {
                    List(store.items) { row($0) }
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await refresh() }
            }
        }
        .task(id: title) { await refresh() }
    }

    private func refresh() async {
        guard let client = session.client else { return }
        await store.refresh(client)
    }
}
