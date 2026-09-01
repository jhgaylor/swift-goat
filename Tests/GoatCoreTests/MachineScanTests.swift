import Foundation
import SQLite3
import Testing
import FountainKit
@testable import GoatCore

// MARK: - Fixture home

/// A throwaway home directory laid out the way the harnesses lay theirs
/// out, so the scan runs against known files instead of the real machine.
struct FixtureHome {
    let root: URL
    var path: String { root.path }
    var app: String { root.appendingPathComponent("dev/app").path }
    var web: String { root.appendingPathComponent("dev/web").path }
    var web2: String { root.appendingPathComponent("other/web").path }

    static func make() throws -> FixtureHome {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goat-scan-\(UUID().uuidString)", isDirectory: true)
        let home = FixtureHome(root: root)
        try home.write(".claude/settings.json", #"""
        {"model": "fable", "env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"},
         "permissions": {"defaultMode": "auto"}}
        """#)
        try home.write(".claude/mcp.json", #"""
        {"mcpServers": {"ouroboros": {"command": "uvx", "args": ["--from", "ouroboros-ai", "ouroboros", "mcp", "serve"]}}}
        """#)
        try home.write(".claude.json", """
        {"mcpServers": {"engram": {"command": "engram", "args": ["mcp"], "env": {"ENGRAM_TOKEN": "tok_1234567890abcdef"}},
                        "ouroboros": {"command": "shadowed"}},
         "projects": {
           "\(home.app)": {"mcpServers": {"posthog": {"type": "http", "url": "https://mcp.posthog.com/mcp",
                                                       "headers": {"Authorization": "Bearer phx_secret1234567"}}}},
           "\(home.web)": {},
           "\(home.web2)": {},
           "\(home.path)/dev/tool": {},
           "\(home.path)/gone": {}
         }}
        """)
        try home.write(".claude/skills/bakery-plan/SKILL.md", """
        ---
        name: bakery-plan
        description: "Plan a bake"
        ---
        Preheat first.
        """)
        try home.write(".claude/plugins/installed_plugins.json", #"""
        {"version": 2, "plugins": {"rust-analyzer-lsp@claude-plugins-official": [{"scope": "user"}]}}
        """#)
        try home.write(".codex/config.toml", """
        model = "gpt-5.6-sol"
        model_reasoning_effort = "high"
        notify = ["/Applications/Codex.app/Contents/MacOS/notify", "turn-ended"]

        [projects."\(home.app)"]
        trust_level = "trusted"

        [mcp_servers.posthog]
        url = "https://mcp.posthog.com/mcp"

        [mcp_servers.node_repl]
        args = []
        command = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"
        startup_timeout_sec = 120

        [mcp_servers.node_repl.env]
        NODE_REPL_NODE_PATH = "/Applications/ChatGPT.app/node"
        """)
        // A Swift project with a Claude config and a git index.
        try home.write("dev/app/CLAUDE.md", "# app\n\nUse swift-format.")
        try home.write("dev/app/Package.swift", "// swift-tools-version: 6.1")
        try home.write("dev/app/.git/index", "x")
        // A TypeScript project with an AGENTS.md (codex) and a Cursor config.
        try home.write("dev/web/AGENTS.md", "Prefer pnpm.")
        try home.write("dev/web/package.json", "{}")
        try home.write("dev/web/tsconfig.json", "{}")
        try home.write("dev/web/.cursor/mcp.json", #"{"mcpServers": {"github": {"url": "https://api.githubcopilot.com/mcp/"}}}"#)
        // Same directory name under another parent: ids must not collide.
        try home.write("other/web/AGENTS.md", "Prefer yarn.")
        try home.write("other/web/package.json", "{}")
        try home.write("other/web/tsconfig.json", "{}")
        // Another Swift project so the role draft has two.
        try home.write("dev/tool/Package.swift", "// swift-tools-version: 6.1")
        try home.write("Applications/Linear.app/Contents/Info.plist", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.linear</string>
        </dict></plist>
        """)
        // Make the git-indexed project unambiguously the most recent one.
        let stale: [FileAttributeKey: Any] = [.modificationDate: Date().addingTimeInterval(-3 * 86400)]
        for dir in [home.web, home.web2, home.path + "/dev/tool"] {
            try FileManager.default.setAttributes(stale, ofItemAtPath: dir)
        }
        return home
    }

    /// The scanner pointed at this fixture and nothing else on the machine.
    var scanner: MachineScanner {
        MachineScanner(home: path, includeBrowsing: false, applicationDirectories: [path + "/Applications"])
    }

    func write(_ relative: String, _ content: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - TOML

@Suite("MiniTOML")
struct MiniTOMLTests {
    @Test func parsesCodexShapedConfig() throws {
        let doc = try MiniTOML.parse("""
        # comment
        model = "gpt-5.6-sol"
        effort = 'high'
        timeout = 1_200
        ratio = 0.5
        enabled = true
        notify = [
          "/bin/notify",
          "turn-ended",   # trailing
        ]
        inline = { a = 1, b = "two", c.d = true }

        [projects."/Users/x/dev app"]
        trust_level = "trusted"

        [mcp_servers.posthog]
        url = "https://mcp.posthog.com/mcp"

        [mcp_servers.posthog.env]
        KEY = "v"

        [[servers]]
        name = "a"
        [servers.opts]
        port = 1
        [[servers]]
        name = "b"
        """)
        #expect(doc["model"]?.stringValue == "gpt-5.6-sol")
        #expect(doc["effort"]?.stringValue == "high")
        #expect(doc["timeout"] == .integer(1200))
        #expect(doc["ratio"] == .float(0.5))
        #expect(doc["enabled"] == .bool(true))
        #expect(doc["notify"]?.arrayValue?.compactMap(\.stringValue) == ["/bin/notify", "turn-ended"])
        #expect(doc["inline"]?["b"]?.stringValue == "two")
        #expect(doc["inline"]?["c"]?["d"] == .bool(true))
        #expect(doc["projects"]?["/Users/x/dev app"]?["trust_level"]?.stringValue == "trusted")
        #expect(doc["mcp_servers"]?["posthog"]?["url"]?.stringValue == "https://mcp.posthog.com/mcp")
        #expect(doc["mcp_servers"]?["posthog"]?["env"]?.stringMap == ["KEY": "v"])
        let servers = try #require(doc["servers"]?.arrayValue)
        #expect(servers.count == 2)
        #expect(servers[0]["opts"]?["port"] == .integer(1))
        #expect(servers[1]["name"]?.stringValue == "b")
    }

    @Test func stringsAndEscapes() throws {
        let doc = try MiniTOML.parse(#"""
        a = "tab\there \"quoted\" \u00e9"
        b = 'C:\raw\path'
        c = """
        multi
        line"""
        d = ""
        """#)
        #expect(doc["a"]?.stringValue == "tab\there \"quoted\" é")
        #expect(doc["b"]?.stringValue == #"C:\raw\path"#)
        #expect(doc["c"]?.stringValue == "multi\nline")
        #expect(doc["d"]?.stringValue == "")
    }

    @Test func reportsLineOnError() {
        #expect(throws: MiniTOML.ParseError.self) {
            try MiniTOML.parse("ok = 1\nbroken = \n")
        }
        do {
            _ = try MiniTOML.parse("ok = 1\nbroken = \n")
        } catch let error as MiniTOML.ParseError {
            #expect(error.line == 2)
        } catch {
            Issue.record("wrong error type")
        }
    }
}

// MARK: - Harness discovery

@Suite("HarnessScan")
struct HarnessScanTests {
    @Test func frontmatterReadsNameAndDescription() {
        let fm = HarnessScan.frontmatter("---\nname: x\ndescription: \"Does a thing: well\"\n---\nbody")
        #expect(fm["name"] == "x")
        #expect(fm["description"] == "Does a thing: well")
        #expect(HarnessScan.frontmatter("no frontmatter").isEmpty)
    }

    @Test func normalizesClaudeAndOpencodeShapes() throws {
        let raw = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"a": {"command": "npx", "args": ["-y", "x"], "env": {"K": "v", "N": 3}},
         "b": {"type": "http", "url": "https://x/mcp", "headers": {"Authorization": "Bearer t"}},
         "c": {"type": "local", "command": ["bun", "run", "srv"], "environment": {"Z": "1"}},
         "d": {"type": "remote", "url": "https://r/sse"},
         "junk": {"nothing": true}}
        """#.utf8))
        let servers = HarnessScan.normalizeMCPServers(raw, source: "f")
        #expect(servers.map(\.name) == ["a", "b", "c", "d"])
        #expect(servers[0].command == "npx" && servers[0].args == ["-y", "x"] && servers[0].env == ["K": "v", "N": "3"])
        #expect(servers[1].url == "https://x/mcp" && servers[1].headers == ["Authorization": "Bearer t"])
        #expect(servers[2].command == "bun" && servers[2].args == ["run", "srv"] && servers[2].env == ["Z": "1"])
        #expect(servers[3].isRemote)
    }

    @Test func scansAFixtureHome() throws {
        let home = try FixtureHome.make()
        defer { home.remove() }
        let scan = home.scanner.scan()

        let ids = scan.sites.map(\.id).sorted()
        #expect(ids == [
            "project-claude-app", "project-codex-dev-web", "project-codex-other-web",
            "project-cursor-web", "user-claude", "user-codex",
        ])

        let user = try #require(scan.sites.first { $0.id == "user-claude" })
        #expect(user.model == "fable")
        #expect(user.env == ["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"])
        #expect(user.mcpServers.map(\.name) == ["engram", "ouroboros"])
        // mcp.json outranks ~/.claude.json for a duplicated name.
        #expect(user.mcpServers.first { $0.name == "ouroboros" }?.command == "uvx")
        #expect(user.skills.map(\.name) == ["bakery-plan"])
        #expect(user.skills.first?.description == "Plan a bake")
        #expect(user.plugins == ["rust-analyzer-lsp@claude-plugins-official"])
        #expect(user.sources.contains(home.path + "/.claude/mcp.json"))
        #expect(user.sources.contains(home.path + "/.claude.json"))

        let codex = try #require(scan.sites.first { $0.id == "user-codex" })
        #expect(codex.model == "gpt-5.6-sol")
        #expect(codex.mcpServers.map(\.name) == ["node_repl", "posthog"])

        let app = try #require(scan.sites.first { $0.id == "project-claude-app" })
        #expect(app.instructions.first?.content.contains("swift-format") == true)
        #expect(app.mcpServers.first?.name == "posthog")
        #expect(app.mcpServers.first?.headers["Authorization"] == "Bearer phx_secret1234567")

        let cursor = try #require(scan.sites.first { $0.id == "project-cursor-web" })
        #expect(cursor.mcpServers.first?.url == "https://api.githubcopilot.com/mcp/")

        // Provenance: the missing project is skipped; probed paths are recorded.
        #expect(!scan.probed.contains { $0.hasPrefix(home.path + "/gone/") })
        #expect(scan.probed.contains(home.path + "/.gemini/settings.json"))
        #expect(scan.unreadable.isEmpty)

        // Projects: the vanished one and the home itself are excluded;
        // the git-indexed one sorts first.
        #expect(scan.projects.map(\.name).contains("app"))
        #expect(!scan.projects.contains { $0.path == home.path + "/gone" })
        #expect(scan.projects.first?.name == "app")
        #expect(scan.projects.first { $0.name == "app" }?.languages == [.swift])
        #expect(scan.projects.first { $0.path == home.web }?.languages == [.typescript])
    }

    @Test func corruptFilesAreReportedNotFatal() throws {
        let home = try FixtureHome.make()
        defer { home.remove() }
        try home.write(".gemini/settings.json", "{not json")
        try home.write(".codex/config.toml", "model = \n")
        let scan = home.scanner.scan()
        #expect(scan.unreadable.contains { $0.path.hasSuffix("/.gemini/settings.json") })
        #expect(scan.unreadable.contains { $0.path.hasSuffix("/.codex/config.toml") && $0.reason.contains("line 1") })
        #expect(scan.sites.contains { $0.id == "user-claude" })
    }
}

// MARK: - Browser history

@Suite("BrowserHistory")
struct BrowserHistoryTests {
    @Test func domainExtraction() {
        #expect(BrowserHistory.domain(of: "https://www.github.com/a/b?x=1") == "github.com")
        #expect(BrowserHistory.domain(of: "http://localhost:4000/") == nil)
        #expect(BrowserHistory.domain(of: "http://127.0.0.1:3000/") == nil)
        #expect(BrowserHistory.domain(of: "file:///Users/x/a.html") == nil)
        #expect(BrowserHistory.domain(of: "chrome://settings") == nil)
        #expect(BrowserHistory.domain(of: "https://Mail.Google.com/mail/u/0") == "mail.google.com")
    }

    @Test func aggregatesAcrossBrowsers() {
        let now = Date()
        let usage = BrowserHistory.aggregate([
            (.arc, .init(url: "https://github.com/x/pulls", visits: 100, lastVisit: now)),
            (.arc, .init(url: "https://github.com/y", visits: 50, lastVisit: now.addingTimeInterval(-10))),
            (.chrome, .init(url: "https://www.github.com/", visits: 3, lastVisit: now.addingTimeInterval(-5))),
            (.chrome, .init(url: "https://linear.app/team", visits: 0, lastVisit: nil)),
            (.chrome, .init(url: "http://localhost:4000/", visits: 999, lastVisit: now)),
        ])
        #expect(usage.map(\.domain) == ["github.com", "linear.app"])
        #expect(usage[0].visits == 153)
        #expect(usage[0].browsers == [.arc, .chrome])
        #expect(usage[0].lastVisit == now)
        #expect(usage[1].visits == 1)
    }

    @Test func readsAChromiumHistoryDatabase() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("goat-hist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let path = scratch.appendingPathComponent("History").path

        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        let now = Date()
        func chromeTime(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) }
        let sql = """
        CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER);
        INSERT INTO urls VALUES (1, 'https://github.com/a', 't', 40, \(chromeTime(now)));
        INSERT INTO urls VALUES (2, 'https://old.example.com/', 't', 400, \(chromeTime(now.addingTimeInterval(-400 * 86400))));
        INSERT INTO urls VALUES (3, 'https://www.github.com/b', 't', 2, \(chromeTime(now.addingTimeInterval(-60))));
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let profile = BrowserHistory.Profile(browser: .chrome, path: path, profileName: "Default")
        let rows = try BrowserHistory.read(profile, since: now.addingTimeInterval(-90 * 86400), scratch: scratch)
        #expect(rows.count == 2)
        let usage = BrowserHistory.aggregate(rows.map { (.chrome, $0) })
        #expect(usage.map(\.domain) == ["github.com"])
        #expect(usage[0].visits == 42)
        #expect(abs(usage[0].lastVisit!.timeIntervalSince(now)) < 1)
        // The copy is cleaned up; the original is untouched.
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path) == ["History"])
    }

    @Test func missingProfileReadsAsEmpty() throws {
        let profile = BrowserHistory.Profile(browser: .firefox, path: "/nonexistent/places.sqlite", profileName: "x")
        #expect(try BrowserHistory.read(profile, since: .distantPast, scratch: FileManager.default.temporaryDirectory).isEmpty)
    }
}

// MARK: - Projects and apps

@Suite("ProjectScan")
struct ProjectScanTests {
    @Test func languagesFromMarkers() {
        #expect(ProjectScan.languages(in: ["Package.swift", "Dockerfile"]) == [.swift, .docker])
        #expect(ProjectScan.languages(in: ["package.json"]) == [.javascript])
        #expect(ProjectScan.languages(in: ["package.json", "tsconfig.json"]) == [.typescript])
        #expect(ProjectScan.languages(in: ["App.xcodeproj", "main.tf"]) == [.swift, .terraform])
        #expect(ProjectScan.languages(in: ["README.md"]).isEmpty)
    }

    @Test func installedAppsReadBundleIDs() throws {
        let home = try FixtureHome.make()
        defer { home.remove() }
        let apps = InstalledApps.scan(directories: [home.path + "/Applications"])
        let linear = try #require(apps.first { $0.name == "Linear" })
        #expect(linear.bundleID == "com.linear")
    }
}

// MARK: - Recommender

@Suite("Recommender")
struct RecommenderTests {
    @Test func redactsCredentialsButNotPinsOrPaths() {
        #expect(Recommender.redact(key: "Authorization", value: "Bearer abc123456789", server: "posthog")
            == ("Bearer ${POSTHOG_TOKEN}", "POSTHOG_TOKEN"))
        #expect(Recommender.redact(key: "SLACK_BOT_TOKEN", value: "xoxb-1234567890", server: "slack")
            == ("${SLACK_BOT_TOKEN}", "SLACK_BOT_TOKEN"))
        #expect(Recommender.redact(key: "API_KEY", value: "${API_KEY}", server: "x") == ("${API_KEY}", nil))
        #expect(Recommender.redact(key: "KEY_PATH", value: "/Users/x/key.pem", server: "x") == ("/Users/x/key.pem", nil))
        #expect(Recommender.redact(key: "PORT", value: "12345678", server: "x") == ("12345678", nil))
        #expect(Recommender.redact(key: "image_digest_key", value: "sha256:abcd", server: "x") == ("sha256:abcd", nil))
        #expect(Recommender.envName("my-server.name") == "MY_SERVER_NAME")
    }

    @Test func convertsRemoteAndSkipsLocalCommands() {
        let remote = LocalMCPServer(
            name: "posthog", source: "f", url: "https://mcp.posthog.com/mcp",
            headers: ["Authorization": "Bearer phx_secret1234567"]
        )
        let converted = Recommender.convert(remote, siteID: "s")
        #expect(converted.config?["headers"]?["Authorization"]?.stringValue == "Bearer ${POSTHOG_TOKEN}")
        #expect(converted.secrets == ["POSTHOG_TOKEN"])

        let local = LocalMCPServer(name: "node_repl", source: "f", command: "/Applications/X.app/bin/node_repl")
        let skipped = Recommender.convert(local, siteID: "s")
        #expect(skipped.config == nil)
        #expect(skipped.notes.first?.contains("won't exist in a sandbox") == true)

        let stdio = LocalMCPServer(name: "engram", source: "f", command: "engram", args: ["mcp", "/Users/x/db"])
        let ok = Recommender.convert(stdio, siteID: "s")
        #expect(ok.config?["command"]?.stringValue == "engram")
        #expect(ok.notes.first?.contains("local paths") == true)
    }

    @Test func endToEndOnTheFixture() throws {
        let home = try FixtureHome.make()
        defer { home.remove() }
        var scan = home.scanner.scan()
        scan.browsing = [
            .init(domain: "github.com", visits: 1780, browsers: [.arc]),
            .init(domain: "mail.google.com", visits: 260, browsers: [.arc, .chrome]),
            .init(domain: "dashboard.render.com", visits: 122, browsers: [.arc]),
            .init(domain: "reddit.com", visits: 358, browsers: [.arc]),
        ]
        let connections = try JSONDecoder().decode(
            [Connection].self, from: Data(#"[{"id": "c-1", "provider": "google_gmail"}]"#.utf8)
        )
        let recs = Recommender.recommend(scan, connections: connections)

        // Integrations, strongest signal first.
        let ids = recs.integrations.map(\.id)
        #expect(ids.first == "github")
        #expect(ids.contains("posthog") && ids.contains("render") && ids.contains("linear") && ids.contains("google"))
        #expect(!ids.contains("discord"))

        let posthog = try #require(recs.integrations.first { $0.id == "posthog" })
        // Reuses the locally declared config, with its credential redacted.
        #expect(posthog.config?["headers"]?["Authorization"]?.stringValue == "Bearer ${POSTHOG_TOKEN}")
        #expect(posthog.evidence.contains { if case .harness = $0 { true } else { false } })

        let linear = try #require(recs.integrations.first { $0.id == "linear" })
        #expect(linear.evidence == [.app(name: "Linear")])

        let google = try #require(recs.integrations.first { $0.id == "google" })
        #expect(google.config == MCPServers.connectionConfig(id: "c-1"))

        // Drafts: one per site plus a role for the two Swift and two TS projects.
        let imported = recs.drafts.filter { if case .imported = $0.kind { true } else { false } }
        #expect(imported.count == scan.sites.count)
        let user = try #require(recs.drafts.first { $0.id == "import-user-claude" })
        #expect(user.runtime == .claude)
        #expect(user.skills.map(\.name) == ["bakery-plan"])
        #expect(user.mcpServers?["engram"]?["env"]?["ENGRAM_TOKEN"]?.stringValue == "${ENGRAM_TOKEN}")
        #expect(user.notes.contains { $0.contains("Plugins aren't carried over") })
        #expect(user.notes.contains { $0.contains("\"fable\"") })

        let codex = try #require(recs.drafts.first { $0.id == "import-user-codex" })
        #expect(codex.runtime == .codex)
        #expect(codex.mcpServers?["node_repl"] == nil)
        #expect(codex.mcpServers?["posthog"] != nil)

        let cursor = try #require(recs.drafts.first { $0.id == "import-project-cursor-web" })
        #expect(cursor.runtime == .claude)
        #expect(cursor.notes.contains { $0.contains("no Fountain runtime") })

        let roles = recs.drafts.filter { if case .role = $0.kind { true } else { false } }
        #expect(roles.map(\.id).sorted() == ["role-swift", "role-typescript"])
        let ts = try #require(roles.first { $0.id == "role-typescript" })
        #expect(ts.subtitle.hasPrefix("2 active"))
        #expect(ts.mcpServers?["github"] != nil)
        #expect(ts.system.contains("TypeScript engineer"))
    }
}

/// Runs the real scanner against this machine and prints what it found.
/// Off by default; run with `GOAT_SCAN_SMOKE=1 swift test --filter MachineScanSmoke`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GOAT_SCAN_SMOKE"] != nil))
struct MachineScanSmokeTests {
    @Test func scansThisMac() {
        let scan = MachineScanner().scan()
        let recs = Recommender.recommend(scan)
        print("scan: \(scan.sites.count) sites, \(scan.projects.count) projects, \(scan.browsing.count) domains from \(scan.browsersRead.count) browser profiles, \(scan.apps.count) apps, \(scan.probed.count) probes in \(String(format: "%.2f", scan.duration))s")
        for site in scan.sites.prefix(12) { print("  site \(site.id): \(site.mcpServers.count) mcp, \(site.skills.count) skills, \(site.instructions.count) instr") }
        for u in scan.unreadable { print("  unreadable \(u.path): \(u.reason)") }
        for s in scan.browsing.prefix(15) { print("  \(s.visits)\t\(s.domain)\t\(s.browsers.map(\.rawValue))") }
        for r in recs.integrations { print("  rec \(r.id) score=\(r.score) \(r.evidence.map(\.label)) notes=\(r.notes)") }
        for d in recs.drafts { print("  draft \(d.id): \(d.subtitle) notes=\(d.notes.count)") }
        #expect(scan.duration < 30)
    }
}
