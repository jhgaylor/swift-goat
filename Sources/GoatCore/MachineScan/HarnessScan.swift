import Foundation
import FountainKit

// The normalized model for an agent configuration found on this Mac, and
// the location-driven scan that fills it. Ported from chant's
// `packages/core/src/agents/discover.ts` (INTENTIUS/chant#1597): each
// harness publishes a fixed set of paths, so the scan is a few dozen stats
// per root rather than a filesystem walk, and "we looked and it wasn't
// there" is a fact the result states (`probed`) instead of an absence of
// evidence.

/// A local coding-agent harness. The first four are exactly Fountain's
/// `runtime` enum; Cursor is discovered and importable but runs as Claude.
public enum Harness: String, CaseIterable, Sendable, Codable, Hashable {
    case claude, codex, gemini, opencode, cursor

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .opencode: "OpenCode"
        case .cursor: "Cursor"
        }
    }

    /// Fountain runtime with the same semantics, if one exists.
    public var fountainRuntime: Runtime? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .gemini: .gemini
        case .opencode: .opencode
        case .cursor: nil
        }
    }
}

public enum HarnessScope: String, Sendable, Codable, Hashable {
    /// The home directory: applies to every project the user opens.
    case user
    /// Checked into (or sitting beside) a repo.
    case project
}

/// A standing-instructions file (CLAUDE.md, AGENTS.md, GEMINI.md, .cursorrules).
public struct InstructionFile: Sendable, Hashable {
    public var path: String
    public var content: String
}

/// One MCP server declaration, normalized across every file that can declare one.
public struct LocalMCPServer: Sendable, Hashable, Identifiable {
    public var name: String
    /// The file it was read from.
    public var source: String
    public var command: String?
    public var args: [String] = []
    public var url: String?
    public var env: [String: String] = [:]
    public var headers: [String: String] = [:]

    public var id: String { name }
    public var isRemote: Bool { url != nil && command == nil }
}

/// A skill on disk (`<dir>/<name>/SKILL.md`).
public struct LocalSkill: Sendable, Hashable, Identifiable {
    public var name: String
    public var path: String
    public var description: String?
    public var content: String
    public var id: String { path }
}

/// A subagent definition (`.claude/agents/*.md`).
public struct LocalSubagent: Sendable, Hashable, Identifiable {
    public var name: String
    public var path: String
    public var description: String?
    public var content: String
    public var id: String { path }
}

/// One complete agent configuration governing one root, for one harness —
/// every file at that scope the harness would merge together.
public struct HarnessSite: Sendable, Hashable, Identifiable {
    public var id: String
    public var harness: Harness
    public var scope: HarnessScope
    /// Directory this configuration governs; the home directory for user scope.
    public var root: String
    /// Every file that contributed, absolute.
    public var sources: [String] = []
    public var instructions: [InstructionFile] = []
    public var mcpServers: [LocalMCPServer] = []
    public var skills: [LocalSkill] = []
    public var subagents: [LocalSubagent] = []
    public var commands: [String] = []
    public var plugins: [String] = []
    public var env: [String: String] = [:]
    public var model: String?

    public var hasContent: Bool {
        !instructions.isEmpty || !mcpServers.isEmpty || !skills.isEmpty
            || !subagents.isEmpty || !commands.isEmpty || !plugins.isEmpty
            || !env.isEmpty || model != nil
    }

    /// "Claude Code (this Mac)" / "Codex · swift-goat".
    public var title: String {
        switch scope {
        case .user: "\(harness.displayName) (this Mac)"
        case .project: "\(harness.displayName) · \(URL(fileURLWithPath: root).lastPathComponent)"
        }
    }
}

public struct UnreadablePath: Sendable, Hashable {
    public var path: String
    public var reason: String
}

/// Collects provenance while a scan runs: what was looked for, what
/// existed but couldn't be read. A parse failure is never fatal — one
/// corrupt settings file shouldn't hide the other twelve.
final class ScanRecorder {
    private(set) var probed: [String] = []
    private(set) var unreadable: [UnreadablePath] = []
    private var jsonCache: [String: JSONValue?] = [:]
    let fileManager = FileManager.default

    static let maxFileBytes = 4 * 1024 * 1024
    /// `~/.claude.json` legitimately reaches hundreds of KB.
    static let maxStateFileBytes = 32 * 1024 * 1024
    static let maxDirectoryEntries = 500

    func probe(_ path: String) -> Bool {
        probed.append(path)
        return fileManager.fileExists(atPath: path)
    }

    func fail(_ path: String, _ reason: String) {
        unreadable.append(UnreadablePath(path: path, reason: reason))
    }

    func text(_ path: String, maxBytes: Int = maxFileBytes) -> String? {
        guard probe(path) else { return nil }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: path)
            if let size = attributes[.size] as? Int, size > maxBytes {
                fail(path, "file is \(size) bytes, over the \(maxBytes)-byte scan cap")
                return nil
            }
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            fail(path, error.localizedDescription)
            return nil
        }
    }

    func json(_ path: String, maxBytes: Int = maxFileBytes) -> JSONValue? {
        if let cached = jsonCache[path] { return cached }
        var parsed: JSONValue?
        if let raw = text(path, maxBytes: maxBytes) {
            do {
                parsed = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
            } catch {
                fail(path, "not valid JSON")
            }
        }
        jsonCache[path] = parsed
        return parsed
    }

    func toml(_ path: String) -> [String: MiniTOML.Value]? {
        guard let raw = text(path) else { return nil }
        do {
            return try MiniTOML.parse(raw)
        } catch {
            fail(path, "not valid TOML (\(error))")
            return nil
        }
    }

    /// Subdirectory names, sorted, hidden ones skipped.
    func directories(_ dir: String) -> [String] {
        entries(dir).filter { name in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: (dir as NSString).appendingPathComponent(name), isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    /// File names ending in `suffix`, sorted.
    func files(_ dir: String, suffix: String) -> [String] {
        entries(dir).filter { $0.hasSuffix(suffix) }
    }

    private func entries(_ dir: String) -> [String] {
        guard probe(dir) else { return [] }
        do {
            return try fileManager.contentsOfDirectory(atPath: dir)
                .filter { !$0.hasPrefix(".") }
                .sorted()
                .prefix(Self.maxDirectoryEntries)
                .map { $0 }
        } catch {
            fail(dir, error.localizedDescription)
            return []
        }
    }
}

// MARK: - Discovery

public enum HarnessScan {
    /// Parse a markdown file's `---` YAML-ish frontmatter into flat
    /// `key: value` pairs. Enough for `name`/`description`; nested YAML
    /// isn't something skills use for those.
    public static func frontmatter(_ markdown: String) -> [String: String] {
        guard markdown.hasPrefix("---") else { return [:] }
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        var out: [String: String] = [:]
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !key.contains(" ") { out[key] = value }
        }
        return out
    }

    /// Normalize one `mcpServers` / `mcp_servers` map. Claude Code, Gemini
    /// and Cursor share the shape; OpenCode spells it `mcp` with
    /// `type: local|remote` and a command *array*, handled here too.
    public static func normalizeMCPServers(_ raw: JSONValue?, source: String) -> [LocalMCPServer] {
        guard let map = raw?.objectValue else { return [] }
        return map.compactMap { name, value -> LocalMCPServer? in
            guard let object = value.objectValue else { return nil }
            var server = LocalMCPServer(name: name, source: source)
            if let command = object["command"]?.stringValue {
                server.command = command
                server.args = object["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
            } else if let parts = object["command"]?.arrayValue?.compactMap(\.stringValue), let first = parts.first {
                server.command = first
                server.args = Array(parts.dropFirst())
            }
            server.url = object["url"]?.stringValue ?? object["endpoint"]?.stringValue
            server.env = stringMap(object["env"] ?? object["environment"])
            server.headers = stringMap(object["headers"])
            guard server.command != nil || server.url != nil else { return nil }
            return server
        }
        .sorted { $0.name < $1.name }
    }

    static func normalizeMCPServers(_ raw: MiniTOML.Value?, source: String) -> [LocalMCPServer] {
        guard let map = raw?.tableValue else { return [] }
        return map.compactMap { name, value -> LocalMCPServer? in
            guard let table = value.tableValue else { return nil }
            var server = LocalMCPServer(name: name, source: source)
            server.command = table["command"]?.stringValue
            server.args = table["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
            server.url = table["url"]?.stringValue
            server.env = table["env"]?.stringMap ?? [:]
            server.headers = table["http_headers"]?.stringMap ?? table["headers"]?.stringMap ?? [:]
            guard server.command != nil || server.url != nil else { return nil }
            return server
        }
        .sorted { $0.name < $1.name }
    }

    private static func stringMap(_ value: JSONValue?) -> [String: String] {
        guard let object = value?.objectValue else { return [:] }
        return object.compactMapValues { entry in
            switch entry {
            case .string(let s): s
            case .number(let n): n == n.rounded() ? String(Int(n)) : String(n)
            case .bool(let b): String(b)
            default: nil
            }
        }
    }

    /// First declaration of a name wins, matching how the harnesses merge.
    static func mergeMCP(_ groups: [LocalMCPServer]...) -> [LocalMCPServer] {
        var seen: Set<String> = []
        var out: [LocalMCPServer] = []
        for group in groups {
            for server in group where !seen.contains(server.name) {
                seen.insert(server.name)
                out.append(server)
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    // MARK: Shared readers

    static func readSkillTree(_ rec: ScanRecorder, _ dir: String) -> [LocalSkill] {
        rec.directories(dir).compactMap { name in
            let path = dir + "/" + name + "/SKILL.md"
            guard let content = rec.text(path) else { return nil }
            let fm = frontmatter(content)
            return LocalSkill(name: fm["name"] ?? name, path: path, description: fm["description"], content: content)
        }
    }

    static func readSubagents(_ rec: ScanRecorder, _ dir: String) -> [LocalSubagent] {
        rec.files(dir, suffix: ".md").compactMap { file in
            let path = dir + "/" + file
            guard let content = rec.text(path) else { return nil }
            let fm = frontmatter(content)
            return LocalSubagent(
                name: fm["name"] ?? String(file.dropLast(3)),
                path: path, description: fm["description"], content: content
            )
        }
    }

    static func readCommands(_ rec: ScanRecorder, _ dir: String) -> [String] {
        rec.files(dir, suffix: ".md").map { String($0.dropLast(3)) }
    }

    static func readInstructions(_ rec: ScanRecorder, _ paths: String...) -> [InstructionFile] {
        paths.compactMap { path in
            guard let content = rec.text(path), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return InstructionFile(path: path, content: content)
        }
    }

    // MARK: Per-harness

    static func claude(_ rec: ScanRecorder, scope: HarnessScope, root: String, home: String) -> HarnessSite? {
        var site = HarnessSite(id: "", harness: .claude, scope: scope, root: root)
        let dir = root + "/.claude"
        let settingsPath = dir + "/settings.json"
        let localPath = dir + "/settings.local.json"
        let mcpPath = scope == .user ? dir + "/mcp.json" : root + "/.mcp.json"
        let statePath = home + "/.claude.json"

        let settings = rec.json(settingsPath)
        let local = rec.json(localPath)
        let mcpFile = rec.json(mcpPath)
        let state = rec.json(statePath, maxBytes: ScanRecorder.maxStateFileBytes)
        for (path, value) in [(settingsPath, settings), (localPath, local), (mcpPath, mcpFile)] where value != nil {
            site.sources.append(path)
        }

        var stateServers: [LocalMCPServer] = []
        if let state {
            let raw: JSONValue?
            if scope == .user {
                raw = state["mcpServers"]
            } else {
                raw = state["projects"]?[root]?["mcpServers"]
            }
            stateServers = normalizeMCPServers(raw, source: statePath)
            if !stateServers.isEmpty { site.sources.append(statePath) }
        }

        site.mcpServers = mergeMCP(
            normalizeMCPServers(local?["mcpServers"], source: localPath),
            normalizeMCPServers(settings?["mcpServers"], source: settingsPath),
            normalizeMCPServers(mcpFile?["mcpServers"], source: mcpPath),
            stateServers
        )
        site.instructions = scope == .user
            ? readInstructions(rec, dir + "/CLAUDE.md")
            : readInstructions(rec, root + "/CLAUDE.md", dir + "/CLAUDE.md")
        site.skills = readSkillTree(rec, dir + "/skills")
        site.subagents = readSubagents(rec, dir + "/agents")
        site.commands = readCommands(rec, dir + "/commands")
        site.env = stringMap(settings?["env"]).merging(stringMap(local?["env"])) { _, new in new }
        site.model = local?["model"]?.stringValue ?? settings?["model"]?.stringValue

        if scope == .user, let installed = rec.json(dir + "/plugins/installed_plugins.json")?["plugins"]?.objectValue {
            site.plugins = installed.keys.sorted()
            site.sources.append(dir + "/plugins/installed_plugins.json")
        }
        site.sources += (site.instructions.map(\.path) + site.skills.map(\.path) + site.subagents.map(\.path))
        return finish(site)
    }

    static func codex(_ rec: ScanRecorder, scope: HarnessScope, root: String) -> HarnessSite? {
        var site = HarnessSite(id: "", harness: .codex, scope: scope, root: root)
        let dir = root + "/.codex"
        let configPath = dir + "/config.toml"
        if let config = rec.toml(configPath) {
            site.sources.append(configPath)
            site.mcpServers = normalizeMCPServers(config["mcp_servers"], source: configPath)
            site.model = config["model"]?.stringValue
            site.env = config["shell_environment_policy"]?["set"]?.stringMap ?? [:]
        }
        site.instructions = scope == .user
            ? readInstructions(rec, dir + "/AGENTS.md")
            : readInstructions(rec, root + "/AGENTS.md")
        site.skills = readSkillTree(rec, dir + "/skills")
        site.commands = readCommands(rec, dir + "/prompts")
        site.sources += site.instructions.map(\.path) + site.skills.map(\.path)
        return finish(site)
    }

    static func gemini(_ rec: ScanRecorder, scope: HarnessScope, root: String) -> HarnessSite? {
        var site = HarnessSite(id: "", harness: .gemini, scope: scope, root: root)
        let dir = root + "/.gemini"
        let settingsPath = dir + "/settings.json"
        if let settings = rec.json(settingsPath) {
            site.sources.append(settingsPath)
            site.mcpServers = normalizeMCPServers(settings["mcpServers"], source: settingsPath)
            site.model = settings["model"]?["name"]?.stringValue ?? settings["model"]?.stringValue
        }
        site.instructions = readInstructions(rec, root + "/GEMINI.md", dir + "/GEMINI.md")
        site.sources += site.instructions.map(\.path)
        return finish(site)
    }

    static func opencode(_ rec: ScanRecorder, scope: HarnessScope, root: String) -> HarnessSite? {
        var site = HarnessSite(id: "", harness: .opencode, scope: scope, root: root)
        let configPath = scope == .user ? root + "/.config/opencode/opencode.json" : root + "/opencode.json"
        guard let settings = rec.json(configPath) else { return nil }
        site.sources.append(configPath)
        site.mcpServers = normalizeMCPServers(settings["mcp"], source: configPath)
        site.model = settings["model"]?.stringValue
        site.instructions = scope == .user
            ? readInstructions(rec, root + "/.config/opencode/AGENTS.md")
            : readInstructions(rec, root + "/AGENTS.md")
        site.sources += site.instructions.map(\.path)
        return finish(site)
    }

    static func cursor(_ rec: ScanRecorder, scope: HarnessScope, root: String) -> HarnessSite? {
        var site = HarnessSite(id: "", harness: .cursor, scope: scope, root: root)
        let dir = root + "/.cursor"
        let mcpPath = dir + "/mcp.json"
        if let mcpFile = rec.json(mcpPath) {
            site.sources.append(mcpPath)
            site.mcpServers = normalizeMCPServers(mcpFile["mcpServers"], source: mcpPath)
        }
        if scope == .project {
            site.instructions = readInstructions(rec, root + "/.cursorrules")
            for file in rec.files(dir + "/rules", suffix: ".mdc") {
                site.instructions += readInstructions(rec, dir + "/rules/" + file)
            }
        }
        site.sources += site.instructions.map(\.path)
        return finish(site)
    }

    private static func finish(_ site: HarnessSite) -> HarnessSite? {
        guard site.hasContent else { return nil }
        var site = site
        site.sources = Array(Set(site.sources)).sorted()
        site.id = site.scope == .user
            ? "user-\(site.harness.rawValue)"
            : "project-\(site.harness.rawValue)-\(slug(URL(fileURLWithPath: site.root).lastPathComponent))"
        return site
    }

    static func slug(_ segment: String) -> String {
        let lowered = segment.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(lowered).split(separator: "-").joined(separator: "-")
    }

    /// Scan the home directory plus every project root, all harnesses.
    /// Project roots that no longer exist are skipped, not reported.
    static func scan(home: String, projectRoots: [String], recorder rec: ScanRecorder) -> [HarnessSite] {
        var sites: [HarnessSite] = []
        for harness in Harness.allCases {
            if let site = discover(harness, rec, scope: .user, root: home, home: home) { sites.append(site) }
        }
        for root in projectRoots where rec.fileManager.fileExists(atPath: root) {
            for harness in Harness.allCases {
                if let site = discover(harness, rec, scope: .project, root: root, home: home) { sites.append(site) }
            }
        }
        uniquify(&sites)
        return sites
    }

    private static func discover(_ harness: Harness, _ rec: ScanRecorder, scope: HarnessScope, root: String, home: String) -> HarnessSite? {
        switch harness {
        case .claude: claude(rec, scope: scope, root: root, home: home)
        case .codex: codex(rec, scope: scope, root: root)
        case .gemini: gemini(rec, scope: scope, root: root)
        case .opencode: opencode(rec, scope: scope, root: root)
        case .cursor: cursor(rec, scope: scope, root: root)
        }
    }

    /// Two checkouts named `behold` under different parents collide on the
    /// directory-name id; qualify with parent segments until they don't.
    static func uniquify(_ sites: inout [HarnessSite]) {
        var counts: [String: Int] = [:]
        for site in sites { counts[site.id, default: 0] += 1 }
        guard counts.values.contains(where: { $0 > 1 }) else { return }
        var taken = Set(sites.filter { counts[$0.id] == 1 }.map(\.id))
        for i in sites.indices where counts[sites[i].id]! > 1 {
            let segments = sites[i].root.split(separator: "/").map(String.init)
            let prefix = "project-\(sites[i].harness.rawValue)"
            var chosen: String?
            for depth in 2...6 where depth <= segments.count {
                let candidate = prefix + "-" + segments.suffix(depth).map(slug).joined(separator: "-")
                if !taken.contains(candidate) { chosen = candidate; break }
            }
            if chosen == nil {
                var n = 2
                while taken.contains("\(sites[i].id)-\(n)") { n += 1 }
                chosen = "\(sites[i].id)-\(n)"
            }
            sites[i].id = chosen!
            taken.insert(chosen!)
        }
    }

    /// Project roots the harnesses already track: Claude Code's
    /// `~/.claude.json` `projects` map and Codex's `[projects]` table.
    static func registeredProjects(home: String, recorder rec: ScanRecorder) -> [String] {
        var roots: [String] = []
        if let state = rec.json(home + "/.claude.json", maxBytes: ScanRecorder.maxStateFileBytes),
           let projects = state["projects"]?.objectValue {
            roots += projects.keys
        }
        if let config = rec.toml(home + "/.codex/config.toml"), let projects = config["projects"]?.tableValue {
            roots += projects.keys
        }
        return Array(Set(roots)).sorted()
    }
}
