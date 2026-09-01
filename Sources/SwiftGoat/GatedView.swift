import SwiftUI
import GoatCore

/// Wraps a sensitive surface behind the `SecurityGate`: shows the content
/// only while the scope is unlocked, otherwise a lock screen that prompts
/// on appear (and again from its button if the user cancels).
struct GatedView<Content: View>: View {
    @SwiftUI.Environment(AppStores.self) private var stores
    let scope: SecurityGate.Scope
    let reason: String
    @ViewBuilder let content: () -> Content

    @State private var didFail = false

    var body: some View {
        if stores.security.isUnlocked(scope) {
            content()
        } else {
            ContentUnavailableView {
                Label("Locked", systemImage: "lock.fill")
            } description: {
                Text(didFail
                    ? "Unlock was canceled. Try again to continue."
                    : "Confirm it's you to continue.")
            } actions: {
                Button("Unlock with \(SecurityGate.methodLabel)") {
                    Task { await attempt() }
                }
                .buttonStyle(.borderedProminent)
            }
            .task { await attempt() }
        }
    }

    private func attempt() async {
        didFail = !(await stores.security.unlock(scope, reason: reason))
    }
}
