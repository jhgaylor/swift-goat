import SwiftUI
import FountainKit
import GoatCore

/// Spawn a conversation: pick an agent, optionally override its environment
/// or layer a vault, and send the first prompt. Environment/vault pickers
/// honour the agent's allowlists (`nil` = any, `[]` = none).
struct NewConversationView: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores
    @SwiftUI.Environment(\.dismiss) private var dismiss
    /// Preselects the agent picker (e.g. spawning from an agent's detail).
    var initialAgentID: String? = nil
    let onCreated: (Conversation) -> Void

    @State private var agentID: String?
    @State private var environmentID: String?
    @State private var vaultID: String?
    @State private var title = ""
    @State private var prompt = ""
    @State private var isCreating = false
    @State private var error: String?

    private var selectedAgent: Agent? {
        stores.agents.items.first { $0.id == agentID }
    }

    private var allowedEnvironments: [FountainKit.Environment] {
        guard let allowed = selectedAgent?.allowedEnvironmentIDs else {
            return stores.environments.items
        }
        return stores.environments.items.filter { allowed.contains($0.id) }
    }

    private var allowedVaults: [Vault] {
        guard let allowed = selectedAgent?.allowedVaultIDs else {
            return stores.vaults.items
        }
        return stores.vaults.items.filter { allowed.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Agent", selection: $agentID) {
                    Text("Choose an agent…").tag(String?.none)
                    ForEach(stores.agents.items) { agent in
                        Text("\(agent.name) — \(agent.runtime.rawValue)").tag(Optional(agent.id))
                    }
                }

                Picker("Environment", selection: $environmentID) {
                    Text("Agent default").tag(String?.none)
                    ForEach(allowedEnvironments) { environment in
                        Text(environment.name).tag(Optional(environment.id))
                    }
                }

                Picker("Vault", selection: $vaultID) {
                    Text("None").tag(String?.none)
                    ForEach(allowedVaults) { vault in
                        Text(vault.name).tag(Optional(vault.id))
                    }
                }

                TextField("Title (optional)", text: $title)

                SwiftUI.Section("First prompt") {
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(minHeight: 90)
                }

                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Conversation") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(agentID == nil || isCreating)
            }
            .padding(12)
            .overlay(alignment: .leading) {
                if isCreating {
                    ProgressView().controlSize(.small).padding(.leading, 12)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .navigationTitle("New Conversation")
        .task {
            if agentID == nil { agentID = initialAgentID }
            await loadOptions()
        }
        .onChange(of: agentID) {
            // A different agent may not allow the previous selections.
            if let environmentID, !allowedEnvironments.contains(where: { $0.id == environmentID }) {
                self.environmentID = nil
            }
            if let vaultID, !allowedVaults.contains(where: { $0.id == vaultID }) {
                self.vaultID = nil
            }
        }
    }

    private func loadOptions() async {
        guard let client = session.client else { return }
        async let agents: () = stores.agents.refresh(client)
        async let environments: () = stores.environments.refresh(client)
        async let vaults: () = stores.vaults.refresh(client)
        _ = await (agents, environments, vaults)
    }

    private func create() {
        guard let agentID, let client = session.client else { return }
        isCreating = true
        error = nil
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let opened = try await client.conversations.create(ConversationCreateRequest(
                    agentID: agentID,
                    prompt: trimmedPrompt.isEmpty ? nil : trimmedPrompt,
                    title: trimmedTitle.isEmpty ? nil : trimmedTitle,
                    vaultID: vaultID,
                    environmentID: environmentID
                ))
                isCreating = false
                onCreated(opened.conversation)
            } catch {
                isCreating = false
                self.error = describe(error)
            }
        }
    }
}
