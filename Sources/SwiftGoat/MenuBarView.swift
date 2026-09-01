import SwiftUI
import AppKit
import FountainKit
import GoatCore

/// The menu bar presence: the label badges how many conversations an agent
/// is actively working, and the menu lists the live ones as jump-back-in
/// rows. This is the app's glanceable surface while the main window is
/// closed — so the label owns a once-a-minute poll of the conversations
/// list instead of relying on the Conversations section being open.
struct MenuBarLabel: View {
    let session: Session
    let stores: AppStores

    var body: some View {
        let working = stores.conversations.items.count { $0.status == .running || $0.status == .pending }
        HStack(spacing: 2) {
            Image(systemName: working > 0 ? "drop.circle.fill" : "drop.circle")
            if working > 0 {
                Text("\(working)")
            }
        }
        .task {
            while !Task.isCancelled {
                if let client = session.client {
                    await stores.conversations.refresh(client)
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

struct MenuBarContent: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores
    @SwiftUI.Environment(Nav.self) private var nav
    @SwiftUI.Environment(\.openWindow) private var openWindow

    var body: some View {
        if case .signedIn = session.state {
            Text(headline)
            Divider()
            ForEach(active.prefix(6)) { conversation in
                Button {
                    openMainWindow()
                    nav.openConversation(conversation.id)
                } label: {
                    Label(title(of: conversation), systemImage: icon(for: conversation))
                }
            }
            if !active.isEmpty {
                Divider()
            }
            Button("New Conversation…") {
                openMainWindow()
                nav.requestNewConversation()
            }
            Button("Open swift-goat") { openMainWindow() }
        } else {
            Text("Not connected")
            Button("Open swift-goat") { openMainWindow() }
        }
    }

    /// Non-terminal conversations, busiest first.
    private var active: [Conversation] {
        let rank: (Conversation) -> Int = {
            switch $0.status {
            case .running: 0
            case .pending: 1
            case .idle: 2
            default: 3
            }
        }
        return stores.conversations.items
            .filter { !$0.status.isTerminal }
            .sorted { rank($0) < rank($1) }
    }

    private var headline: String {
        let working = active.count { $0.status == .running || $0.status == .pending }
        let idle = active.count { $0.status == .idle }
        if working == 0 && idle == 0 { return "No active conversations" }
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if idle > 0 { parts.append("\(idle) idle") }
        return parts.joined(separator: " · ")
    }

    private func title(of conversation: Conversation) -> String {
        let raw = conversation.title ?? conversation.firstPrompt ?? conversation.id
        return raw.count > 40 ? String(raw.prefix(40)) + "…" : raw
    }

    private func icon(for conversation: Conversation) -> String {
        switch conversation.status {
        case .running: "play.circle"
        case .pending: "clock"
        case .idle: "bubble.left"
        default: "circle"
        }
    }

    /// Surface the main window: reuse one that's already open (possibly
    /// behind other apps), otherwise spawn a fresh one from the WindowGroup.
    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix("main") == true
        }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}
