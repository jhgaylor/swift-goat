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
    case search = "Search"
    case audit = "Audit"
    case admin = "Admin"

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
        case .search: "magnifyingglass"
        case .audit: "list.bullet.rectangle"
        case .admin: "person.badge.key"
        }
    }
}

/// Cross-section navigation: which section is showing and every stack's
/// push path — with browser-style history, so back/forward (mouse buttons
/// 4/5, ⌘[ / ⌘]) walk through everywhere the user has been, across
/// sections and detail pages alike.
@Observable @MainActor
final class Nav {
    /// One place the user was: the section plus each stack's pushes.
    struct Place: Equatable, Sendable {
        var section: Section? = .conversations
        var conversations: [String] = []
        var agents: [String] = []
        var environments: [String] = []
        var vaults: [String] = []
        var search: [String] = []
        var admin: [String] = []
    }

    var section: Section? = .conversations { didSet { record() } }
    var conversationPath: [String] = [] { didSet { record() } }
    var agentPath: [String] = [] { didSet { record() } }
    var environmentPath: [String] = [] { didSet { record() } }
    var vaultPath: [String] = [] { didSet { record() } }
    var searchPath: [String] = [] { didSet { record() } }
    var adminPath: [String] = [] { didSet { record() } }

    private var history = NavHistory(initial: Place())
    private var isApplying = false

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    @discardableResult
    func goBack() -> Bool {
        guard let place = history.goBack() else { return false }
        apply(place)
        return true
    }

    @discardableResult
    func goForward() -> Bool {
        guard let place = history.goForward() else { return false }
        apply(place)
        return true
    }

    func openConversation(_ id: String) {
        // One history entry, not two, for the section+path jump.
        isApplying = true
        section = .conversations
        conversationPath = [id]
        isApplying = false
        record()
    }

    /// Set from outside the Conversations section (menu bar extra); the
    /// section consumes it by opening the create sheet. Not part of
    /// history — it's a request, not a place.
    var newConversationRequested = false

    func requestNewConversation() {
        isApplying = true
        section = .conversations
        conversationPath = []
        isApplying = false
        record()
        newConversationRequested = true
    }

    private var place: Place {
        Place(
            section: section,
            conversations: conversationPath,
            agents: agentPath,
            environments: environmentPath,
            vaults: vaultPath,
            search: searchPath,
            admin: adminPath
        )
    }

    private func record() {
        guard !isApplying else { return }
        history.record(place)
    }

    private func apply(_ place: Place) {
        isApplying = true
        section = place.section
        conversationPath = place.conversations
        agentPath = place.agents
        environmentPath = place.environments
        vaultPath = place.vaults
        searchPath = place.search
        adminPath = place.admin
        isApplying = false
    }
}

struct RootView: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores
    @SwiftUI.Environment(Nav.self) private var nav

    /// One Touch ID at launch replaces the keychain's own prompts (the
    /// stored item's ACL is deliberately prompt-free — see `Keychain`).
    /// One-way: once open, the session never re-locks mid-use.
    enum LaunchGate {
        case undecided
        case locked
        case open
    }

    @State private var launchGate: LaunchGate = .undecided

    var body: some View {
        Group {
            switch launchGate {
            case .undecided:
                Color.clear.onAppear { decideLaunchGate() }
            case .locked:
                LaunchLockView { launchGate = .open }
            case .open:
                mainContent
            }
        }
        // The runner daemon is our child; SIGTERM it so it parks its
        // sandboxes instead of being orphaned when the app quits.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            stores.localRunner.stop()
        }
        // The permission watcher lives exactly as long as a signed-in
        // session; its pending count doubles as the Dock badge.
        .onChange(of: session.state, initial: true) {
            if case .signedIn = session.state, let client = session.client {
                stores.permissions.start(client: client)
            } else {
                stores.permissions.stop()
            }
        }
        .onChange(of: stores.permissions.pending.count, initial: true) {
            let count = stores.permissions.pending.count
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
    }

    /// Only gate when there's a stored key to protect — a fresh install
    /// goes straight to the connect screen. Restore runs after the gate
    /// (it's a `mainContent` task), so nothing touches the key while
    /// locked.
    private func decideLaunchGate() {
        launchGate = (stores.security.isEnabled && session.hasStoredKey) ? .locked : .open
    }

    @ViewBuilder
    private var mainContent: some View {
        Group {
            switch session.state {
            case .signedIn:
                @Bindable var nav = nav
                NavigationSplitView {
                    List(visibleSections, selection: $nav.section) { section in
                        Label(section.rawValue, systemImage: section.systemImage)
                            .tag(section)
                    }
                    .navigationTitle("Fountain")
                } detail: {
                    SectionView(section: nav.section ?? .conversations)
                }
            case .signedOut, .checking, .failed:
                ConnectView()
            }
        }
        .task { await session.restore() }
    }

    /// Admin only shows for admin accounts (the API 403s it anyway).
    private var visibleSections: [Section] {
        Section.allCases.filter { $0 != .admin || session.me?.role == .admin }
    }
}

/// The launch lock screen: prompts on appear, retries from its button.
/// Unlike `GatedView` it reports unlock through a callback, so the opened
/// app can never flip back to locked when the grace window lapses.
private struct LaunchLockView: View {
    @SwiftUI.Environment(AppStores.self) private var stores
    let unlocked: () -> Void

    @State private var didFail = false

    var body: some View {
        ContentUnavailableView {
            Label("Locked", systemImage: "lock.fill")
        } description: {
            Text(didFail
                ? "Unlock was canceled. Try again to continue."
                : "Confirm it's you to open your Fountain session.")
        } actions: {
            Button("Unlock with \(SecurityGate.methodLabel)") {
                Task { await attempt() }
            }
            .buttonStyle(.borderedProminent)
        }
        .task { await attempt() }
    }

    private func attempt() async {
        if await stores.security.unlock(.session, reason: "unlock your Fountain session") {
            unlocked()
        } else {
            didFail = true
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
            ConversationsSectionView()
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
            AgentsSectionView()
        case .environments:
            EnvironmentsSectionView()
        case .vaults:
            VaultsSectionView()
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
            RunnersSectionView()
        case .search:
            SearchSectionView()
        case .audit:
            ResourceListView(store: stores.audit, title: "Audit") { event in
                AuditEventRow(event: event)
            }
        case .admin:
            GatedView(scope: .admin, reason: "open the Admin console") {
                AdminSectionView()
            }
        }
    }
}

/// One audit-trail row, shared by the account audit and admin audit feeds.
struct AuditEventRow: View {
    let event: AuditEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.action)
                .font(.body.monospaced())
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let actor = event.actor { parts.append(actor) }
        if let type = event.resourceType { parts.append(type) }
        if let ts = event.insertedAt {
            parts.append(ts.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }
}

/// Conversations list + the spawn flow: click opens the transcript, "+"
/// (⌘N) opens the new-conversation sheet, delete lives on the row too.
struct ConversationsSectionView: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores
    @SwiftUI.Environment(Nav.self) private var nav
    @State private var selection: String?
    @State private var showingNew = false
    @State private var pendingDelete: Conversation?
    @State private var error: String?

    var body: some View {
        @Bindable var nav = nav
        NavigationStack(path: $nav.conversationPath) {
            ResourceListView(store: stores.conversations, title: "Conversations", selection: $selection) { conversation in
                NavigationLink(value: conversation.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conversation.title ?? conversation.firstPrompt ?? conversation.id)
                            .lineLimit(1)
                        Text("\(conversation.status.rawValue) · \(conversation.runtime.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button("Delete…", role: .destructive) { pendingDelete = conversation }
                }
            }
            .navigationDestination(for: String.self) { id in
                ConversationDetailView(conversationID: id)
            }
            .toolbar {
                Button("New Conversation", systemImage: "plus") { showingNew = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            .onDeleteCommand {
                pendingDelete = stores.conversations.items.first { $0.id == selection }
            }
            .onAppear { consumeNewConversationRequest() }
            .onChange(of: nav.newConversationRequested) { consumeNewConversationRequest() }
            .sheet(isPresented: $showingNew) {
                NewConversationView { conversation in
                    showingNew = false
                    nav.conversationPath.append(conversation.id)
                    if let client = session.client {
                        Task { await stores.conversations.refresh(client) }
                    }
                }
            }
            .confirmationDialog(
                "Delete conversation?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { conversation in
                Button("Delete \"\(conversation.title ?? conversation.firstPrompt ?? conversation.id)\"", role: .destructive) {
                    delete(conversation)
                }
            } message: { _ in
                Text("The transcript is deleted server-side. This can't be undone.")
            }
            .alert("Couldn't delete", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func delete(_ conversation: Conversation) {
        guard let client = session.client else { return }
        Task {
            do {
                try await client.conversations.delete(conversation.id)
                await stores.conversations.refresh(client)
            } catch {
                self.error = describe(error)
            }
        }
    }

    private func consumeNewConversationRequest() {
        guard nav.newConversationRequested else { return }
        nav.newConversationRequested = false
        showingNew = true
    }
}

/// Generic list: loads on appear, shows phase, refreshes on demand. Pass a
/// `selection` binding to get row selection (and with it, delete-key
/// support in the section view).
struct ResourceListView<Item: Identifiable & Sendable, Row: View>: View {
    @SwiftUI.Environment(Session.self) private var session
    let store: ListStore<Item>
    let title: String
    var selection: Binding<Item.ID?>? = nil
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        Group {
            switch store.phase {
            case .idle,
                 .loading where store.items.isEmpty:
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
                } else if let selection {
                    List(store.items, selection: selection) { row($0) }
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
