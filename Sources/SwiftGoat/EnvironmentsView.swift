import SwiftUI
import FountainKit
import GoatCore

/// Environments list. Click opens the environment's detail page; "+" (⌘N)
/// creates; delete key or the row's context menu deletes.
struct EnvironmentsSectionView: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores
    @SwiftUI.Environment(Nav.self) private var nav
    @State private var selection: String?
    @State private var creating = false
    @State private var pendingDelete: FountainKit.Environment?
    @State private var error: String?

    var body: some View {
        @Bindable var nav = nav
        NavigationStack(path: $nav.environmentPath) {
            ResourceListView(store: stores.environments, title: "Environments", selection: $selection) { environment in
                NavigationLink(value: environment.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(environment.name)
                        Text("\(environment.secretCount ?? 0) secrets · \(environment.agentCount ?? 0) agents")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button("Delete…", role: .destructive) { pendingDelete = environment }
                }
            }
            .navigationDestination(for: String.self) { id in
                EnvironmentDetailView(environmentID: id)
            }
            .toolbar {
                Button("New Environment", systemImage: "plus") { creating = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            .onDeleteCommand {
                pendingDelete = stores.environments.items.first { $0.id == selection }
            }
            .sheet(isPresented: $creating) {
                EnvironmentCreateSheet {
                    creating = false
                    refresh()
                }
            }
            .confirmationDialog(
                "Delete environment?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { environment in
                Button("Delete \"\(environment.name)\"", role: .destructive) {
                    delete(environment)
                }
            } message: { environment in
                Text("Agents using \(environment.name) as their default lose it. Secrets are destroyed.")
            }
            .alert("Couldn't delete", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func delete(_ environment: FountainKit.Environment) {
        guard let client = session.client else { return }
        Task {
            do {
                try await client.environments.delete(environment.id)
                await stores.environments.refresh(client)
            } catch {
                self.error = describe(error)
            }
        }
    }

    private func refresh() {
        guard let client = session.client else { return }
        Task { await stores.environments.refresh(client) }
    }
}

/// One editable env-var row (a dictionary loses ordering under editing).
struct EnvVarRow: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
}

/// Editable environment config as plain values, diffable for the dirty
/// check. Packages and repositories stay manifest-only for now.
struct EnvironmentFormValues: Equatable {
    var name = ""
    var envVars: [EnvVarRow] = []
    var setupScript = ""
    var networkingType: String?

    init() {}

    init(_ environment: FountainKit.Environment) {
        name = environment.name
        setupScript = environment.setupScript ?? ""
        networkingType = environment.networkingType?.rawValue
        envVars = (environment.envVars ?? [:])
            .sorted { $0.key < $1.key }
            .map { EnvVarRow(key: $0.key, value: $0.value) }
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var input: EnvironmentInput {
        var vars: [String: String] = [:]
        for row in envVars {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            vars[key] = row.value
        }
        return EnvironmentInput(
            name: name.trimmingCharacters(in: .whitespaces),
            envVars: vars,
            setupScript: setupScript.isEmpty ? nil : setupScript,
            networkingType: networkingType.map(NetworkingType.init(rawValue:))
        )
    }
}

/// The shared form fields (create sheet + detail page).
struct EnvironmentFormFields: View {
    @Binding var values: EnvironmentFormValues

    var body: some View {
        TextField("Name", text: $values.name)

        Picker("Networking", selection: $values.networkingType) {
            Text("Default").tag(String?.none)
            Text("unrestricted").tag(Optional(NetworkingType.unrestricted.rawValue))
            Text("limited").tag(Optional(NetworkingType.limited.rawValue))
        }

        SwiftUI.Section("Environment variables") {
            ForEach($values.envVars) { $row in
                HStack {
                    TextField("KEY", text: $row.key)
                        .font(.body.monospaced())
                    TextField("value", text: $row.value)
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        values.envVars.removeAll { $0.id == row.id }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            Button("Add Variable", systemImage: "plus") {
                values.envVars.append(EnvVarRow(key: "", value: ""))
            }
        }

        SwiftUI.Section("Setup script") {
            TextEditor(text: $values.setupScript)
                .font(.body.monospaced())
                .frame(minHeight: 90)
        }
    }
}

/// One environment, editable in place, secrets included.
struct EnvironmentDetailView: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: String

    @State private var loaded: FountainKit.Environment?
    @State private var values = EnvironmentFormValues()
    @State private var original = EnvironmentFormValues()
    @State private var isSaving = false
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        Group {
            if loaded == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    EnvironmentFormFields(values: $values)

                    if let client = session.client {
                        SecretsEditor(
                            list: { try await client.environments.secrets(environmentID) },
                            set: { key, value in
                                _ = try await client.environments.setSecret(environmentID, key: key, value: value)
                            },
                            delete: { key in
                                try await client.environments.deleteSecret(environmentID, key: key)
                            }
                        )
                    }

                    if let error {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle(loaded?.name ?? "Environment")
        .toolbar {
            Button("Save", systemImage: "checkmark.circle") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(values == original || !values.isValid || isSaving)
            Button("Delete", systemImage: "trash") { confirmDelete = true }
        }
        .task(id: environmentID) { await load() }
        .confirmationDialog("Delete environment?", isPresented: $confirmDelete) {
            Button("Delete \"\(loaded?.name ?? environmentID)\"", role: .destructive) { delete() }
        } message: {
            Text("Agents using this environment as their default lose it. Secrets are destroyed.")
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            let environment = try await client.environments.get(environmentID)
            loaded = environment
            values = EnvironmentFormValues(environment)
            original = values
        } catch {
            self.error = describe(error)
            loaded = nil
        }
    }

    private func save() {
        guard let client = session.client else { return }
        isSaving = true
        error = nil
        Task {
            do {
                let updated = try await client.environments.update(environmentID, values.input)
                loaded = updated
                values = EnvironmentFormValues(updated)
                original = values
                await stores.environments.refresh(client)
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
                try await client.environments.delete(environmentID)
                await stores.environments.refresh(client)
                dismiss()
            } catch {
                self.error = describe(error)
            }
        }
    }
}

/// Create a new environment. Secrets attach on the detail page once it
/// exists (they need an id).
struct EnvironmentCreateSheet: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let onCreated: () -> Void

    @State private var values = EnvironmentFormValues()
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                EnvironmentFormFields(values: $values)
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
                Button("Create Environment") { create() }
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
        .frame(minWidth: 540, minHeight: 480)
        .navigationTitle("New Environment")
    }

    private func create() {
        guard let client = session.client else { return }
        isSaving = true
        error = nil
        Task {
            do {
                _ = try await client.environments.create(values.input)
                isSaving = false
                onCreated()
            } catch {
                isSaving = false
                self.error = describe(error)
            }
        }
    }
}
