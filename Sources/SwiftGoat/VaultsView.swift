import SwiftUI
import FountainKit
import GoatCore

/// Vaults list. Click opens the vault's detail page; "+" (⌘N) creates;
/// delete key or the row's context menu deletes.
struct VaultsSectionView: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores
    @SwiftUI.Environment(Nav.self) private var nav
    @State private var selection: String?
    @State private var creating = false
    @State private var pendingDelete: Vault?
    @State private var error: String?

    var body: some View {
        @Bindable var nav = nav
        NavigationStack(path: $nav.vaultPath) {
            ResourceListView(store: stores.vaults, title: "Vaults", selection: $selection) { vault in
                NavigationLink(value: vault.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vault.name)
                        Text("\(vault.secretCount ?? 0) secrets")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button("Delete…", role: .destructive) { pendingDelete = vault }
                }
            }
            .navigationDestination(for: String.self) { id in
                VaultDetailView(vaultID: id)
            }
            .toolbar {
                Button("New Vault", systemImage: "plus") { creating = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            .onDeleteCommand {
                pendingDelete = stores.vaults.items.first { $0.id == selection }
            }
            .sheet(isPresented: $creating) {
                VaultCreateSheet {
                    creating = false
                    refresh()
                }
            }
            .confirmationDialog(
                "Delete vault?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { vault in
                Button("Delete \"\(vault.name)\"", role: .destructive) {
                    delete(vault)
                }
            } message: { vault in
                Text("Secrets in \(vault.name) are destroyed. Running conversations keep what they were spawned with.")
            }
            .alert("Couldn't delete", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func delete(_ vault: Vault) {
        guard let client = session.client else { return }
        Task {
            do {
                try await client.vaults.delete(vault.id)
                await stores.vaults.refresh(client)
            } catch {
                self.error = describe(error)
            }
        }
    }

    private func refresh() {
        guard let client = session.client else { return }
        Task { await stores.vaults.refresh(client) }
    }
}

/// One vault, editable in place, secrets included.
struct VaultDetailView: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let vaultID: String

    @State private var loaded: Vault?
    @State private var name = ""
    @State private var description = ""
    @State private var isSaving = false
    @State private var confirmDelete = false
    @State private var error: String?

    private var isDirty: Bool {
        name != loaded?.name ?? "" || description != (loaded?.description ?? "")
    }

    var body: some View {
        Group {
            if loaded == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description)

                    if let client = session.client {
                        SecretsEditor(
                            list: { try await client.vaults.secrets(vaultID) },
                            set: { key, value in
                                _ = try await client.vaults.setSecret(vaultID, key: key, value: value)
                            },
                            delete: { key in
                                try await client.vaults.deleteSecret(vaultID, key: key)
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
        .navigationTitle(loaded?.name ?? "Vault")
        .toolbar {
            Button("Save", systemImage: "checkmark.circle") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty || name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            Button("Delete", systemImage: "trash") { confirmDelete = true }
        }
        .task(id: vaultID) { await load() }
        .confirmationDialog("Delete vault?", isPresented: $confirmDelete) {
            Button("Delete \"\(loaded?.name ?? vaultID)\"", role: .destructive) { delete() }
        } message: {
            Text("Secrets in this vault are destroyed. Running conversations keep what they were spawned with.")
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            let vault = try await client.vaults.get(vaultID)
            loaded = vault
            name = vault.name
            description = vault.description ?? ""
        } catch {
            self.error = describe(error)
            loaded = nil
        }
    }

    private func save() {
        guard let client = session.client else { return }
        isSaving = true
        error = nil
        let input = VaultInput(
            name: name.trimmingCharacters(in: .whitespaces),
            description: description.isEmpty ? nil : description
        )
        Task {
            do {
                let updated = try await client.vaults.update(vaultID, input)
                loaded = updated
                name = updated.name
                description = updated.description ?? ""
                await stores.vaults.refresh(client)
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
                try await client.vaults.delete(vaultID)
                await stores.vaults.refresh(client)
                dismiss()
            } catch {
                self.error = describe(error)
            }
        }
    }
}

/// Create a new vault. Secrets attach on the detail page once it exists.
struct VaultCreateSheet: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let onCreated: () -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name)
                TextField("Description", text: $description)
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
                Button("Create Vault") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
            .padding(12)
            .overlay(alignment: .leading) {
                if isSaving {
                    ProgressView().controlSize(.small).padding(.leading, 12)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 280)
        .navigationTitle("New Vault")
    }

    private func create() {
        guard let client = session.client else { return }
        isSaving = true
        error = nil
        let input = VaultInput(
            name: name.trimmingCharacters(in: .whitespaces),
            description: description.isEmpty ? nil : description
        )
        Task {
            do {
                _ = try await client.vaults.create(input)
                isSaving = false
                onCreated()
            } catch {
                isSaving = false
                self.error = describe(error)
            }
        }
    }
}
