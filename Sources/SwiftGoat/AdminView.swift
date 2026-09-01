import SwiftUI
import FountainKit
import GoatCore

/// The admin console: users, cross-tenant sandboxes, the cross-tenant audit
/// feed, and the privilege trail. Only reachable when `me.role == admin`.
struct AdminSectionView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case users = "Users"
        case sandboxes = "Sandboxes"
        case audit = "Audit"
        case events = "Privilege Trail"

        var id: String { rawValue }
    }

    @SwiftUI.Environment(Nav.self) private var nav
    @State private var tab: Tab = .users

    var body: some View {
        @Bindable var nav = nav
        NavigationStack(path: $nav.adminPath) {
            Group {
                switch tab {
                case .users:
                    AdminUsersListView()
                case .sandboxes:
                    AdminSandboxesView()
                case .audit:
                    AdminAuditView()
                case .events:
                    AdminEventsView()
                }
            }
            .navigationTitle("Admin")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .navigationDestination(for: String.self) { id in
                AdminUserDetailView(userID: id)
            }
        }
    }
}

/// Searchable, filterable, page-paginated account list.
struct AdminUsersListView: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores

    var body: some View {
        @Bindable var store = stores.adminUsers
        Group {
            switch store.phase {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView(
                    "Couldn't load accounts",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .loaded:
                if store.users.isEmpty {
                    ContentUnavailableView("No matching accounts", systemImage: "person.slash")
                } else {
                    List {
                        ForEach(store.users) { user in
                            NavigationLink(value: user.id) {
                                AdminUserRow(user: user)
                            }
                        }
                        if store.hasMore {
                            HStack {
                                Spacer()
                                if store.isLoadingMore {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button("Load More (\(store.users.count) of \(store.total))") {
                                        loadMore()
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $store.query, prompt: "Search by email…")
        .onSubmit(of: .search) { refresh() }
        .onChange(of: store.query) {
            // Clearing the field with the ⓧ should reset, not linger stale.
            if store.query.isEmpty { refresh() }
        }
        .toolbar {
            Menu {
                Picker("Role", selection: $store.roleFilter) {
                    Text("Any role").tag(UserRole?.none)
                    Text("user").tag(Optional(UserRole.user))
                    Text("admin").tag(Optional(UserRole.admin))
                }
                Picker("Billing", selection: $store.compedFilter) {
                    Text("Anyone").tag(Bool?.none)
                    Text("Comped").tag(Optional(true))
                    Text("Paying").tag(Optional(false))
                }
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
            .onChange(of: store.roleFilter) { refresh() }
            .onChange(of: store.compedFilter) { refresh() }

            Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
        }
        .task {
            if store.phase == .idle { refresh() }
        }
    }

    private func refresh() {
        guard let client = session.client else { return }
        Task { await stores.adminUsers.refresh(client) }
    }

    private func loadMore() {
        guard let client = session.client else { return }
        Task { await stores.adminUsers.loadMore(client) }
    }
}

struct AdminUserRow: View {
    let user: AdminUser

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(user.email)
                    if user.role == .admin {
                        Text("admin")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.purple.opacity(0.2), in: Capsule())
                    }
                    if user.suspended == true {
                        Text("suspended")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.red.opacity(0.2), in: Capsule())
                    }
                    if user.comped == true {
                        Text("comped")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.green.opacity(0.2), in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let cents = user.creditBalanceCents {
                Text(dollars(cents))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(cents < 0 ? .red : .secondary)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let active = user.activeSandboxes { parts.append("\(active) active sandboxes") }
        if let last = user.lastActivityAt {
            parts.append("active \(last.formatted(.relative(presentation: .named)))")
        }
        return parts.isEmpty ? user.id : parts.joined(separator: " · ")
    }
}

/// Cents → a currency string (deployments bill in USD).
func dollars(_ cents: Int) -> String {
    (Double(cents) / 100).formatted(.currency(code: "USD"))
}

/// One account: the facts, then the levers. Every mutation confirms and
/// swaps in the server's fresh record on success.
struct AdminUserDetailView: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let userID: String

    @State private var user: AdminUser?
    @State private var creditCents: Int = 0
    @State private var creditNote = ""
    @State private var sandboxLimit: Int = 0
    @State private var isWorking = false
    @State private var error: String?

    enum Confirmation: Identifiable {
        case role, suspend, comp, credits, delete
        var id: Int { hashValue }
    }
    @State private var confirming: Confirmation?

    var body: some View {
        Group {
            if let user {
                content(user)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(user?.email ?? "Account")
        .task(id: userID) { await load() }
    }

    @ViewBuilder
    private func content(_ user: AdminUser) -> some View {
        Form {
            SwiftUI.Section("Account") {
                LabeledContent("Email", value: user.email)
                LabeledContent("Role", value: user.role?.rawValue ?? "user")
                LabeledContent("Verified", value: user.emailVerified == true ? "yes" : "no")
                if let created = user.insertedAt {
                    LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened))
                }
                if let last = user.lastActivityAt {
                    LabeledContent("Last active", value: last.formatted(.relative(presentation: .named)))
                }
                if user.suspended == true, let at = user.suspendedAt {
                    LabeledContent("Suspended", value: at.formatted(date: .abbreviated, time: .shortened))
                }
            }

            SwiftUI.Section("Billing") {
                LabeledContent("Credit balance", value: dollars(user.creditBalanceCents ?? 0))
                LabeledContent("Comped", value: user.comped == true ? "yes" : "no")
                LabeledContent("Stripe customer", value: user.hasStripeCustomer == true ? "yes" : "no")
                HStack {
                    TextField("Cents", value: $creditCents, format: .number)
                        .frame(width: 100)
                    TextField("Note (optional)", text: $creditNote)
                    Button("Grant Credit") { confirming = .credits }
                        .disabled(creditCents == 0 || isWorking)
                }
            }

            SwiftUI.Section("Sandboxes") {
                LabeledContent("Active", value: "\(user.activeSandboxes ?? 0)")
                LabeledContent("Limit", value: limitDescription(user))
                HStack {
                    TextField("Limit", value: $sandboxLimit, format: .number)
                        .frame(width: 100)
                    Button("Set Limit Override") { setLimit() }
                        .disabled(isWorking)
                }
            }

            SwiftUI.Section("Actions") {
                HStack {
                    Button(user.role == .admin ? "Revoke Admin" : "Grant Admin") { confirming = .role }
                    Button(user.suspended == true ? "Unsuspend" : "Suspend") { confirming = .suspend }
                    Button(user.comped == true ? "Remove Comp" : "Comp Account") { confirming = .comp }
                }
                .disabled(isWorking)
                Button("Delete Account…", role: .destructive) { confirming = .delete }
                    .disabled(isWorking)
            }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(dialogTitle, isPresented: presentingConfirmation, presenting: confirming) { which in
            confirmButton(which, user)
        } message: { which in
            Text(dialogMessage(which, user))
        }
    }

    private var presentingConfirmation: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private var dialogTitle: String {
        switch confirming {
        case .role: "Change role?"
        case .suspend: "Change suspension?"
        case .comp: "Change comp status?"
        case .credits: "Grant credit?"
        case .delete: "Delete this account?"
        case nil: ""
        }
    }

    @ViewBuilder
    private func confirmButton(_ which: Confirmation, _ user: AdminUser) -> some View {
        switch which {
        case .role:
            Button(user.role == .admin ? "Revoke admin from \(user.email)" : "Make \(user.email) an admin") {
                mutate { try await $0.admin.setRole(userID, role: user.role == .admin ? .user : .admin) }
            }
        case .suspend:
            Button(user.suspended == true ? "Unsuspend \(user.email)" : "Suspend \(user.email)", role: user.suspended == true ? nil : .destructive) {
                mutate { try await $0.admin.setSuspended(userID, user.suspended != true) }
            }
        case .comp:
            Button(user.comped == true ? "Remove comp" : "Comp this account") {
                mutate { try await $0.admin.setComped(userID, user.comped != true) }
            }
        case .credits:
            Button("Grant \(dollars(creditCents)) to \(user.email)") {
                let note = creditNote.trimmingCharacters(in: .whitespaces)
                mutate { try await $0.admin.grantCredits(userID, cents: creditCents, note: note.isEmpty ? nil : note) }
                creditCents = 0
                creditNote = ""
            }
        case .delete:
            Button("Permanently delete \(user.email)", role: .destructive) { deleteAccount() }
        }
    }

    private func dialogMessage(_ which: Confirmation, _ user: AdminUser) -> String {
        switch which {
        case .role:
            "Admins can see and act on every account and sandbox."
        case .suspend:
            user.suspended == true
                ? "The account regains access immediately."
                : "The account loses all access until unsuspended."
        case .comp:
            "Comped accounts run without billing."
        case .credits:
            creditCents < 0
                ? "This subtracts \(dollars(-creditCents)) from the balance."
                : "This adds prepaid credit; it is not a Stripe charge."
        case .delete:
            "Everything this account owns — agents, environments, vaults, conversations, sandboxes — is destroyed. This cannot be undone."
        }
    }

    private func limitDescription(_ user: AdminUser) -> String {
        if let override = user.sandboxLimitOverride {
            return "\(override) (override)"
        }
        return "\(user.maxConcurrentSandboxes ?? 0)"
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            let loaded = try await client.admin.user(userID)
            user = loaded
            sandboxLimit = loaded.sandboxLimitOverride ?? loaded.maxConcurrentSandboxes ?? 0
        } catch {
            self.error = describe(error)
        }
    }

    private func setLimit() {
        mutate { try await $0.admin.setSandboxLimit(userID, limit: sandboxLimit) }
    }

    private func mutate(_ op: @escaping @Sendable (FountainClient) async throws -> AdminUser) {
        guard let client = session.client else { return }
        isWorking = true
        error = nil
        Task {
            do {
                let updated = try await op(client)
                user = updated
                stores.adminUsers.replace(updated)
            } catch {
                self.error = describe(error)
            }
            isWorking = false
        }
    }

    private func deleteAccount() {
        guard let client = session.client else { return }
        isWorking = true
        error = nil
        Task {
            do {
                try await client.admin.deleteUser(userID)
                await stores.adminUsers.refresh(client)
                dismiss()
            } catch {
                self.error = describe(error)
            }
            isWorking = false
        }
    }
}

/// Every live sandbox across every tenant, reapable.
struct AdminSandboxesView: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores
    @State private var pendingReap: AdminSandbox?
    @State private var error: String?

    var body: some View {
        ResourceListView(store: stores.adminSandboxes, title: "All Sandboxes") { sandbox in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sandbox.spriteName ?? sandbox.id)
                    Text(subtitle(sandbox))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reap…") { pendingReap = sandbox }
                    .buttonStyle(.bordered)
            }
            .contextMenu {
                Button("Reap…", role: .destructive) { pendingReap = sandbox }
            }
        }
        .confirmationDialog(
            "Reap sandbox?",
            isPresented: Binding(get: { pendingReap != nil }, set: { if !$0 { pendingReap = nil } }),
            presenting: pendingReap
        ) { sandbox in
            Button("Reap \(sandbox.spriteName ?? sandbox.id)", role: .destructive) {
                reap(sandbox)
            }
        } message: { sandbox in
            Text("Force-terminates \(sandbox.userEmail ?? "the tenant")'s sandbox mid-flight.")
        }
        .alert("Couldn't reap", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func subtitle(_ sandbox: AdminSandbox) -> String {
        var parts: [String] = []
        if let email = sandbox.userEmail { parts.append(email) }
        if let status = sandbox.status { parts.append(status.rawValue) }
        if let provider = sandbox.provider { parts.append(provider.rawValue) }
        if let count = sandbox.conversationCount { parts.append("\(count) conversations") }
        return parts.joined(separator: " · ")
    }

    private func reap(_ sandbox: AdminSandbox) {
        guard let client = session.client else { return }
        Task {
            do {
                try await client.admin.reap(sandboxID: sandbox.id)
                await stores.adminSandboxes.refresh(client)
            } catch {
                self.error = describe(error)
            }
        }
    }
}

/// Cross-tenant audit feed (same rows as the account-level audit section).
struct AdminAuditView: View {
    @SwiftUI.Environment(AppStores.self) private var stores

    var body: some View {
        ResourceListView(store: stores.adminAudit, title: "All Audit Events") { event in
            AuditEventRow(event: event)
        }
    }
}

/// The privilege trail: who did what to whom.
struct AdminEventsView: View {
    @SwiftUI.Environment(AppStores.self) private var stores

    var body: some View {
        ResourceListView(store: stores.adminEvents, title: "Privilege Trail") { event in
            VStack(alignment: .leading, spacing: 2) {
                Text(event.eventType)
                    .font(.body.monospaced())
                Text(subtitle(event))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func subtitle(_ event: AdminEvent) -> String {
        var parts: [String] = []
        if let actor = event.actorUserID { parts.append("by \(actor)") }
        if let target = event.targetUserID { parts.append("on \(target)") }
        if let ts = event.insertedAt {
            parts.append(ts.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }
}
