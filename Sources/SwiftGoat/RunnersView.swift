import SwiftUI
import FountainKit
import GoatCore

/// Runners section: manage this Mac as a runner (spawn and supervise the
/// `fountain runner` daemon, inheriting the app's session) on top of the
/// account's registered-runner list.
struct RunnersSectionView: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores
    @State private var pendingForget: Runner?
    @State private var error: String?

    private var runner: LocalRunnerController { stores.localRunner }

    var body: some View {
        List {
            SwiftUI.Section("This Mac") {
                LocalRunnerPanel()
            }
            SwiftUI.Section("Registered runners") {
                registeredRows
            }
        }
        .navigationTitle("Runners")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await refresh() }
            }
        }
        .task { await refresh() }
        // While our daemon runs, poll so the list's online flag tracks it.
        .task(id: runner.isRunning) {
            guard runner.isRunning else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await refresh()
            }
        }
        .confirmationDialog(
            "Forget runner?",
            isPresented: Binding(get: { pendingForget != nil }, set: { if !$0 { pendingForget = nil } }),
            presenting: pendingForget
        ) { runner in
            Button("Forget \"\(runner.name)\"", role: .destructive) { forget(runner) }
        } message: { _ in
            Text("The registration is removed server-side. A running daemon will just re-register on reconnect.")
        }
        .alert("Couldn't forget runner", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder
    private var registeredRows: some View {
        switch stores.runners.phase {
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        default:
            if stores.runners.items.isEmpty {
                Text("No runners registered yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(stores.runners.items) { runner in
                    RunnerRow(runner: runner, isThisMac: isThisMac(runner))
                        .contextMenu {
                            Button("Forget…", role: .destructive) { pendingForget = runner }
                        }
                }
            }
        }
    }

    /// Names this machine could be registered under: the configured name,
    /// or the hostname (the CLI's default) with and without ".local".
    private var machineNames: Set<String> {
        var names: Set<String> = []
        if !runner.name.isEmpty { names.insert(runner.name.lowercased()) }
        let host = ProcessInfo.processInfo.hostName.lowercased()
        names.insert(host)
        if host.hasSuffix(".local") { names.insert(String(host.dropLast(".local".count))) }
        return names
    }

    private func isThisMac(_ runner: Runner) -> Bool {
        machineNames.contains(runner.name.lowercased())
            || runner.hostname.map { machineNames.contains($0.lowercased()) } == true
    }

    private func refresh() async {
        guard let client = session.client else { return }
        await stores.runners.refresh(client)
    }

    private func forget(_ runner: Runner) {
        guard let client = session.client else { return }
        Task {
            do {
                try await client.runners.delete(runner.id)
                await stores.runners.refresh(client)
            } catch {
                self.error = describe(error)
            }
        }
    }
}

private struct RunnerRow: View {
    let runner: Runner
    let isThisMac: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(runner.name)
                if isThisMac {
                    Text("this Mac")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(runner.online ? Color.green : .secondary)
        }
    }

    private var subtitle: String {
        var parts = [runner.online ? "online" : "offline"]
        if let os = runner.os, let arch = runner.arch { parts.append("\(os)/\(arch)") }
        if let version = runner.version { parts.append(version) }
        if !runner.online, let seen = runner.lastSeenAt {
            parts.append("last seen \(seen.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }
}

/// The supervised daemon: binary + config + start/stop + live log.
private struct LocalRunnerPanel: View {
    @SwiftUI.Environment(Session.self) private var session
    @SwiftUI.Environment(AppStores.self) private var stores
    @State private var showingLog = false

    private var runner: LocalRunnerController { stores.localRunner }

    var body: some View {
        @Bindable var runner = runner

        if runner.binaryPath.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("The `fountain` CLI wasn't found.", systemImage: "exclamationmark.triangle")
                Text("Install it, or point the app at the binary:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Path to fountain", text: $runner.binaryPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Re-check") { runner.rediscover() }
                }
            }
            .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    statusDot
                    Text(statusText)
                    Spacer()
                    if runner.isRunning {
                        Button("Stop") { runner.stop() }
                    } else {
                        Button("Start") {
                            if let key = session.apiKey {
                                runner.start(apiKey: key, baseURL: session.baseURL)
                            }
                        }
                        .disabled(session.apiKey == nil)
                    }
                }

                Text("\(runner.binaryPath)\(runner.version.map { " · \($0)" } ?? "")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                // The daemon runs agents as you, unsandboxed, on this
                // machine — same warning the CLI gives.
                Text("Trusted mode: agents run as your user with no sandbox between them and this Mac.")
                    .font(.caption)
                    .foregroundStyle(.orange)

                Grid(alignment: .leading, verticalSpacing: 6) {
                    GridRow {
                        Text("Name")
                        TextField(defaultName, text: $runner.name)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Root")
                        TextField("~/.fountain/runners/<name>/sandboxes", text: $runner.root)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .font(.callout)
                .disabled(runner.isRunning)

                if !runner.buffer.lines.isEmpty {
                    DisclosureGroup("Log", isExpanded: $showingLog) {
                        ScrollView {
                            Text(runner.buffer.lines.joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 220)
                        .defaultScrollAnchor(.bottom)
                        Button("Clear") { runner.clearLog() }
                            .controlSize(.small)
                    }
                }
            }
            .padding(.vertical, 4)
            .task { await runner.probeVersion() }
        }
    }

    private var defaultName: String {
        ProcessInfo.processInfo.hostName.lowercased()
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 9, height: 9)
    }

    private var statusColor: Color {
        switch runner.phase {
        case .running: .green
        case .stopped: .secondary.opacity(0.5)
        case .exited, .failed: .red
        }
    }

    private var statusText: String {
        switch runner.phase {
        case .running(let pid): "Running (pid \(pid))"
        case .stopped: "Not running"
        case .exited(let code): "Exited (\(code)) — see log"
        case .failed(let message): "Couldn't start: \(message)"
        }
    }
}
