import SwiftUI
import FountainKit
import GoatCore

/// Full-text search over conversations and turns. A hit navigates into the
/// conversation transcript.
struct SearchSectionView: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(Nav.self) private var nav
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var error: String?

    var body: some View {
        @Bindable var nav = nav
        NavigationStack(path: $nav.searchPath) {
            Group {
                if isSearching {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView(
                        "Search failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else if hits.isEmpty {
                    ContentUnavailableView(
                        hasSearched ? "No matches" : "Search conversations",
                        systemImage: "magnifyingglass",
                        description: Text(hasSearched
                            ? "Nothing matched \"\(query)\"."
                            : "Titles, prompts and replies across every conversation.")
                    )
                } else {
                    List(Array(hits.enumerated()), id: \.offset) { _, hit in
                        NavigationLink(value: hit.conversationID) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.snippet ?? hit.conversationID)
                                    .lineLimit(2)
                                Text(subtitle(hit))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .navigationDestination(for: String.self) { id in
                ConversationDetailView(conversationID: id)
            }
        }
        .searchable(text: $query, prompt: "Search conversations…")
        .onSubmit(of: .search) { search() }
    }

    private func subtitle(_ hit: SearchHit) -> String {
        var parts: [String] = [hit.kind.rawValue]
        if let turn = hit.turnNumber { parts.append("turn \(turn)") }
        if let ts = hit.ts { parts.append(ts.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }

    private func search() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client = session.client else { return }
        isSearching = true
        error = nil
        Task {
            do {
                hits = try await client.search.search(trimmed).items
            } catch {
                self.error = describe(error)
                hits = []
            }
            isSearching = false
            hasSearched = true
        }
    }
}
