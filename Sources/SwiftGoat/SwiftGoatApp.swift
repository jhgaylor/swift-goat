import SwiftUI
import GoatCore

@main
struct SwiftGoatApp: App {
    @State private var session = Session()
    @State private var stores = AppStores()
    @State private var nav: Nav
    private let notifier = Notifier()

    init() {
        let nav = Nav()
        // Launch straight into a section (GOAT_SECTION=Runners) — for
        // scripted runs and screenshots.
        if let name = ProcessInfo.processInfo.environment["GOAT_SECTION"],
           let section = Section(rawValue: name) {
            nav.section = section
        }
        _nav = State(wrappedValue: nav)

        // Running from `swift run` there is no app bundle; make sure we
        // still get a Dock icon and can come to the front.
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        // Mouse buttons 4/5 go back/forward, like a browser. The monitor
        // lives for the app's lifetime; unhandled buttons pass through.
        NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            let button = event.buttonNumber
            let handled = MainActor.assumeIsolated {
                switch button {
                case 3: nav.goBack()
                case 4: nav.goForward()
                default: false
                }
            }
            return handled ? nil : event
        }

        // Permission requests → actionable notifications. Wired here
        // because it spans the watcher (GoatCore), the notifier, and
        // navigation. RootView starts/stops the watcher with the session.
        let stores = self.stores
        let notifier = self.notifier
        notifier.openConversation = { id in
            NSApp.activate(ignoringOtherApps: true)
            nav.openConversation(id)
        }
        notifier.answer = { requestID, prefix in
            await stores.permissions.answer(requestID: requestID, optionKindPrefix: prefix)
        }
        stores.permissions.onNew = { alert in
            // The foreground case is covered by the card above the
            // composer; only ring when the user is elsewhere.
            if !NSApp.isActive { notifier.post(alert) }
        }
        stores.permissions.onResolved = { notifier.withdraw($0) }
        notifier.setUp()
    }

    var body: some Scene {
        // The id lets the menu bar extra reopen the window after the user
        // closes it (the extra keeps the app alive without one).
        WindowGroup(id: "main") {
            // Session restore happens inside RootView, behind its launch
            // gate — nothing reads the stored key until Touch ID clears.
            RootView()
                .environment(session)
                .environment(stores)
                .environment(nav)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandMenu("Go") {
                Button("Back") { nav.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!nav.canGoBack)
                Button("Forward") { nav.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!nav.canGoForward)
            }
        }

        Settings {
            SettingsView()
                .environment(session)
                .environment(stores)
        }

        // Glanceable status + jump-back-in while the window is closed.
        MenuBarExtra {
            MenuBarContent()
                .environment(session)
                .environment(stores)
                .environment(nav)
        } label: {
            MenuBarLabel(session: session, stores: stores)
        }
    }
}
