import SwiftUI
import FountainKit
import GoatCore

/// Transcript + composer for one conversation. Renders parsed blocks —
/// never a runtime dialect — and treats agent output as plain text, not
/// markup.
struct ConversationDetailView: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let conversationID: String

    @State private var store: ConversationStore?
    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @State private var attachmentError: String?
    @State private var showingFilePicker = false
    @State private var confirmTerminate = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let store {
                content(store)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: conversationID) {
            store?.stop()
            guard let client = session.client else { return }
            let fresh = ConversationStore(client: client, id: conversationID)
            store = fresh
            await fresh.start()
        }
        .onDisappear { store?.stop() }
    }

    @ViewBuilder
    private func content(_ store: ConversationStore) -> some View {
        VStack(spacing: 0) {
            if let error = store.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(.red)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.events) { event in
                            EventRow(event: event)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: store.events.count) {
                    if let last = store.events.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if !store.pendingPermissions.isEmpty {
                Divider()
                VStack(spacing: 8) {
                    ForEach(store.pendingPermissions, id: \.requestID) { request in
                        PermissionCard(request: request) { optionID in
                            Task { await store.answer(request, optionID: optionID) }
                        }
                    }
                }
                .padding(10)
            }

            Divider()
            composer(store)
        }
        // Anywhere on the transcript is a drop target: images attach,
        // text files inline into the prompt.
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls)
            return true
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { attach(urls) }
        }
        .navigationTitle(store.conversation?.title ?? "Conversation")
        .navigationSubtitle(store.conversation?.status.rawValue ?? "")
        .toolbar {
            if store.conversation?.status == .running {
                Button("Interrupt", systemImage: "stop.circle") {
                    Task { await store.interrupt() }
                }
            }
            Menu {
                if store.conversation?.status.isTerminal != true {
                    Button("Terminate Sandbox…", role: .destructive) { confirmTerminate = true }
                }
                Button("Delete Conversation…", role: .destructive) { confirmDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
        .confirmationDialog(
            "Terminate this conversation's sandbox?",
            isPresented: $confirmTerminate
        ) {
            Button("Terminate", role: .destructive) {
                Task { await store.terminate() }
            }
        } message: {
            Text("The agent stops and the sandbox is torn down. The transcript stays.")
        }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: $confirmDelete
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    if await store.delete() {
                        if let client = session.client {
                            await stores.conversations.refresh(client)
                        }
                        dismiss()
                    }
                }
            }
        } message: {
            Text("The transcript is deleted server-side. This can't be undone.")
        }
    }

    private func composer(_ store: ConversationStore) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !store.queuedPrompts.isEmpty {
                Text("\(store.queuedPrompts.count) message(s) queued — the agent is mid-turn")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            AttachmentChip(attachment: attachment) {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Attach", systemImage: "paperclip") { showingFilePicker = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Attach a file — or drop one anywhere on the transcript")
                TextField("Message the agent…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit { submit(store) }
                Button("Send", systemImage: "paperplane.fill") { submit(store) }
                    .disabled(!canSend)
            }
        }
        .padding(10)
    }

    /// Images need at least a word of text to hang off; a text attachment
    /// makes a prompt on its own.
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || attachments.contains { !$0.isImage }
    }

    private func attach(_ urls: [URL]) {
        attachmentError = nil
        for url in urls {
            do {
                attachments.append(try Attachment.load(from: url))
            } catch {
                attachmentError = error.localizedDescription
            }
        }
    }

    private func submit(_ store: ConversationStore) {
        guard canSend else { return }
        let prompt = attachments.assemblePrompt(
            draft: draft.trimmingCharacters(in: .whitespacesAndNewlines))
        let images = attachments.images
        draft = ""
        attachments = []
        attachmentError = nil
        Task { await store.send(prompt, images: images) }
    }
}

/// One staged file: name, kind icon, and its remove button.
struct AttachmentChip: View {
    let attachment: Attachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Label(attachment.filename, systemImage: attachment.isImage ? "photo" : "doc.text")
                .font(.caption)
                .lineLimit(1)
            Button("Remove", systemImage: "xmark.circle.fill", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }
}

/// One log event. Stage events render as thin lifecycle markers; output
/// events render their blocks.
struct EventRow: View {
    let event: LogEvent

    var body: some View {
        if event.kind == .stage {
            if let stage = event.stage {
                Text("\(stage) \(event.state?.rawValue ?? "")")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        } else {
            ForEach(Array((event.blocks ?? []).enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
    }
}

struct BlockView: View {
    let block: Block

    var body: some View {
        switch block.kind {
        case .text:
            Text(block.body ?? "")
                .textSelection(.enabled)
        case .thinking:
            Text(block.body ?? "")
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .toolUse:
            Label(block.summary ?? block.name ?? "tool", systemImage: "wrench.and.screwdriver")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        case .toolResult:
            if block.isError == true {
                Text(block.body ?? "")
                    .font(.callout.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        case .error:
            Text(block.body ?? "")
                .font(.callout.monospaced())
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .permissionRequest:
            // The transcript row is just a marker; the answerable card lives
            // above the composer while the request is pending.
            Label(block.summary ?? "Permission requested", systemImage: "hand.raised")
                .font(.callout)
                .foregroundStyle(.orange)
        case .initialize, .raw, .result:
            EmptyView()
        default:
            // A block kind this build doesn't know: show, don't crash.
            Text(block.body ?? block.summary ?? block.kind.rawValue)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// One pending permission request: what the agent wants, and only the
/// options it offered (the server rejects invented ones).
struct PermissionCard: View {
    let request: PermissionRequest
    let answer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(request.summary ?? request.toolName ?? "Permission requested", systemImage: "hand.raised")
                .font(.callout.weight(.medium))
            HStack {
                ForEach(request.options.filter { $0.optionID != nil }, id: \.optionID) { option in
                    Button(option.name ?? option.kind ?? option.optionID ?? "?") {
                        if let optionID = option.optionID { answer(optionID) }
                    }
                    .buttonStyle(.bordered)
                    .tint(tint(for: option.kind))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tint(for kind: String?) -> Color? {
        guard let kind else { return nil }
        if kind.hasPrefix("allow") { return .green }
        if kind.hasPrefix("reject") { return .red }
        return nil
    }
}
