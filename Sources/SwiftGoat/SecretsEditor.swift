import SwiftUI
import FountainKit
import GoatCore

/// Key/value secret management for an environment or vault. Values are
/// write-only — the API never returns one, so rows show keys and
/// timestamps and the only edit is "set a new value".
struct SecretsEditor: View {
    @SwiftUI.Environment(AppStores.self) private var stores
    let list: @MainActor () async throws -> [Secret]
    let set: @MainActor (String, String) async throws -> Void
    let delete: @MainActor (String) async throws -> Void

    @State private var secrets: [Secret] = []
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var error: String?
    @State private var isWorking = false

    var body: some View {
        SwiftUI.Section("Secrets") {
            if secrets.isEmpty {
                Text("No secrets. Values are write-only once set.")
                    .foregroundStyle(.secondary)
            }
            ForEach(secrets) { secret in
                HStack {
                    Text(secret.key).font(.body.monospaced())
                    Spacer()
                    Text("value hidden")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        remove(secret.key)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("KEY", text: $newKey)
                    .font(.body.monospaced())
                SecureField("value", text: $newValue)
                Button("Add") { add() }
                    .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty
                        || newValue.isEmpty || isWorking)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        do {
            secrets = try await list()
        } catch {
            self.error = describe(error)
        }
    }

    private func add() {
        let key = newKey.trimmingCharacters(in: .whitespaces)
        let value = newValue
        isWorking = true
        error = nil
        Task {
            // Touch ID (or password) before the write — secrets are the
            // most sensitive thing this app mutates.
            guard await stores.security.unlock(.secrets, reason: "set a secret value") else {
                isWorking = false
                return
            }
            do {
                try await set(key, value)
                newKey = ""
                newValue = ""
                await refresh()
            } catch {
                self.error = describe(error)
            }
            isWorking = false
        }
    }

    private func remove(_ key: String) {
        isWorking = true
        error = nil
        Task {
            guard await stores.security.unlock(.secrets, reason: "remove a secret") else {
                isWorking = false
                return
            }
            do {
                try await delete(key)
                await refresh()
            } catch {
                self.error = describe(error)
            }
            isWorking = false
        }
    }
}
