import SwiftUI
import GoatCore

@main
struct SwiftGoatApp: App {
    @State private var session = Session()
    @State private var stores = AppStores()

    init() {
        // Running from `swift run` there is no app bundle; make sure we
        // still get a Dock icon and can come to the front.
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(stores)
                .task { await session.restore() }
        }
        .defaultSize(width: 1100, height: 720)

        Settings {
            SettingsView()
                .environment(session)
        }
    }
}
