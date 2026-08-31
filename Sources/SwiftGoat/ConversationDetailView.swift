import SwiftUI
import FountainKit
import GoatCore

/// Transcript + composer for one conversation. Renders parsed blocks —
/// never a runtime dialect — and treats agent output as plain text, not
/// markup.
struct ConversationDetailView: View {
    @SwiftUI.Environment(Session.self) private var session
    let conversationID: String

    @State private var store: ConversationStore?
    @State private var draft = ""

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

            Divider()
            composer(store)
        }
        .navigationTitle(store.conversation?.title ?? "Conversation")
        .navigationSubtitle(store.conversation?.status.rawValue ?? "")
        .toolbar {
            if store.conversation?.status == .running {
                Button("Interrupt", systemImage: "stop.circle") {
                    Task { await store.interrupt() }
                }
            }
        }
    }

    private func composer(_ store: ConversationStore) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !store.queuedPrompts.isEmpty {
                Text("\(store.queuedPrompts.count) message(s) queued — the agent is mid-turn")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("Message the agent…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit { submit(store) }
                Button("Send", systemImage: "paperplane.fill") { submit(store) }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
    }

    private func submit(_ store: ConversationStore) {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        draft = ""
        Task { await store.send(prompt) }
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
