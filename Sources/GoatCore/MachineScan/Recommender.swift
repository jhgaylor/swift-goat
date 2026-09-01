import Foundation
import FountainKit

/// A service an agent could plug into, and how to recognize that this
/// Mac's owner uses it. The `config` is the Fountain `mcp_servers` entry
/// to add; entries without one carry a registry search instead.
public struct Integration: Sendable, Hashable, Identifiable {
    public enum Auth: Sendable, Hashable {
        /// Works as-is or via the server's own OAuth dance.
        case oauth
        /// Needs these secrets in the conversation's environment.
        case secrets([String])
        /// Mounts a Fountain OAuth connection (`{connection: id}`).
        case connection
    }

    public var id: String
    public var title: String
    public var blurb: String
    public var domains: [String] = []
    public var bundleIDs: [String] = []
    public var appNames: [String] = []
    /// Substrings of a Fountain connection provider id/slug that mean this integration.
    public var connectionProviders: [String] = []
    public var config: JSONValue?
    public var auth: Auth = .oauth
    /// For integrations without a known config: what to search the MCP registry for.
    public var registryQuery: String?
    /// True for things a coding agent typically needs (they ride along on role drafts).
    public var developerTool = false
}

/// Why an integration or draft is being recommended.
public enum Evidence: Sendable, Hashable {
    case browsing(domain: String, visits: Int, browsers: [BrowserHistory.Browser])
    case app(name: String)
    case harness(site: String, server: String)
    case connection(provider: String)
    case projects(language: ProjectLanguage, count: Int)

    public var label: String {
        switch self {
        case .browsing(let domain, let visits, let browsers):
            let where_ = browsers.map(\.rawValue).joined(separator: ", ")
            return "\(domain): \(visits.formatted()) visits in \(where_)"
        case .app(let name):
            return "\(name) is installed"
        case .harness(let site, let server):
            return "already configured as \"\(server)\" in \(site)"
        case .connection(let provider):
            return "connected in Fountain (\(provider))"
        case .projects(let language, let count):
            return "\(count) \(language.rawValue) project\(count == 1 ? "" : "s")"
        }
    }
}

public struct Recommendation: Sendable, Hashable, Identifiable {
    public var integration: Integration
    public var evidence: [Evidence]
    public var score: Int
    /// The config to add. Prefers what the user already declared locally,
    /// then a Fountain connection, then the catalog's default.
    public var config: JSONValue?
    /// `${NAME}` secrets the config expects in the environment.
    public var secrets: [String]
    public var notes: [String]
    public var id: String { integration.id }
}

/// A ready-to-create agent. Opens the create sheet pre-filled; nothing is
/// sent until the user confirms there.
public struct AgentDraft: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case imported(siteID: String)
        case role(ProjectLanguage)
        case integration(String)
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String
    public var name: String
    public var description: String
    public var runtime: Runtime
    public var system: String
    public var skills: [Skill]
    public var mcpServers: JSONValue?
    /// What was dropped, redacted, or defaulted on the way over.
    public var notes: [String]
    public var evidence: [Evidence]
}

public struct Recommendations: Sendable {
    public var drafts: [AgentDraft]
    public var integrations: [Recommendation]
}

public enum Recommender {
    // MARK: - Catalog

    public static let catalog: [Integration] = [
        Integration(
            id: "github", title: "GitHub", blurb: "Repos, pull requests, issues, and code search.",
            domains: ["github.com"], bundleIDs: ["com.github.GitHubClient"], appNames: ["GitHub Desktop"],
            config: MCPServers.httpConfig(
                url: "https://api.githubcopilot.com/mcp/",
                headers: ["Authorization": "Bearer ${GITHUB_TOKEN}"]
            ),
            auth: .secrets(["GITHUB_TOKEN"]), developerTool: true
        ),
        Integration(
            id: "linear", title: "Linear", blurb: "Issues, projects, and cycles.",
            domains: ["linear.app"], bundleIDs: ["com.linear"], appNames: ["Linear"],
            config: MCPServers.httpConfig(url: "https://mcp.linear.app/mcp"), developerTool: true
        ),
        Integration(
            id: "notion", title: "Notion", blurb: "Pages and databases.",
            domains: ["notion.so", "notion.com"], bundleIDs: ["notion.id"], appNames: ["Notion"],
            config: MCPServers.httpConfig(url: "https://mcp.notion.com/mcp")
        ),
        Integration(
            id: "slack", title: "Slack", blurb: "Read channels and post messages.",
            domains: ["slack.com"], bundleIDs: ["com.tinyspeck.slackmacgap"], appNames: ["Slack"],
            config: MCPServers.stdioConfig(
                command: "npx", args: ["-y", "@modelcontextprotocol/server-slack"],
                env: ["SLACK_BOT_TOKEN": "${SLACK_BOT_TOKEN}", "SLACK_TEAM_ID": "${SLACK_TEAM_ID}"]
            ),
            auth: .secrets(["SLACK_BOT_TOKEN", "SLACK_TEAM_ID"])
        ),
        Integration(
            id: "posthog", title: "PostHog", blurb: "Product analytics, feature flags, error tracking.",
            domains: ["posthog.com"],
            config: MCPServers.httpConfig(
                url: "https://mcp.posthog.com/mcp",
                headers: ["Authorization": "Bearer ${POSTHOG_API_KEY}"]
            ),
            auth: .secrets(["POSTHOG_API_KEY"]), developerTool: true
        ),
        Integration(
            id: "sentry", title: "Sentry", blurb: "Errors, traces, and releases.",
            domains: ["sentry.io"],
            config: MCPServers.httpConfig(url: "https://mcp.sentry.dev/mcp"), developerTool: true
        ),
        Integration(
            id: "render", title: "Render", blurb: "Services, deploys, and logs.",
            domains: ["render.com"],
            config: MCPServers.httpConfig(
                url: "https://mcp.render.com/mcp",
                headers: ["Authorization": "Bearer ${RENDER_API_KEY}"]
            ),
            auth: .secrets(["RENDER_API_KEY"]), developerTool: true
        ),
        Integration(
            id: "vercel", title: "Vercel", blurb: "Projects, deployments, and logs.",
            domains: ["vercel.com"],
            config: MCPServers.httpConfig(url: "https://mcp.vercel.com"), developerTool: true
        ),
        Integration(
            id: "atlassian", title: "Jira & Confluence", blurb: "Atlassian issues and wiki pages.",
            domains: ["atlassian.net", "atlassian.com"],
            config: MCPServers.httpConfig(url: "https://mcp.atlassian.com/v1/mcp"), developerTool: true
        ),
        Integration(
            id: "figma", title: "Figma", blurb: "Design files and components.",
            domains: ["figma.com"], bundleIDs: ["com.figma.Desktop"], appNames: ["Figma"],
            config: MCPServers.httpConfig(url: "https://mcp.figma.com/mcp")
        ),
        Integration(
            id: "stripe", title: "Stripe", blurb: "Customers, payments, and subscriptions.",
            domains: ["stripe.com"],
            config: MCPServers.httpConfig(
                url: "https://mcp.stripe.com",
                headers: ["Authorization": "Bearer ${STRIPE_SECRET_KEY}"]
            ),
            auth: .secrets(["STRIPE_SECRET_KEY"])
        ),
        Integration(
            id: "supabase", title: "Supabase", blurb: "Postgres, auth, and storage projects.",
            domains: ["supabase.com"],
            config: MCPServers.httpConfig(url: "https://mcp.supabase.com/mcp"), developerTool: true
        ),
        Integration(
            id: "huggingface", title: "Hugging Face", blurb: "Models, datasets, and Spaces.",
            domains: ["huggingface.co"],
            config: MCPServers.httpConfig(
                url: "https://huggingface.co/mcp",
                headers: ["Authorization": "Bearer ${HF_TOKEN}"]
            ),
            auth: .secrets(["HF_TOKEN"])
        ),
        Integration(
            id: "netlify", title: "Netlify", blurb: "Sites and deploys.",
            domains: ["netlify.com", "netlify.app"],
            config: MCPServers.httpConfig(url: "https://netlify-mcp.netlify.app/mcp"), developerTool: true
        ),
        Integration(
            id: "heroku", title: "Heroku", blurb: "Apps, dynos, and add-ons.",
            domains: ["heroku.com"],
            config: MCPServers.httpConfig(
                url: "https://mcp.heroku.com",
                headers: ["Authorization": "Bearer ${HEROKU_API_KEY}"]
            ),
            auth: .secrets(["HEROKU_API_KEY"]), developerTool: true
        ),
        Integration(
            id: "hubspot", title: "HubSpot", blurb: "CRM contacts, companies, and deals.",
            domains: ["hubspot.com"],
            config: MCPServers.httpConfig(url: "https://mcp.hubspot.com/anthropic")
        ),
        Integration(
            id: "asana", title: "Asana", blurb: "Tasks and projects.",
            domains: ["asana.com"], bundleIDs: ["com.asana.app"], appNames: ["Asana"],
            config: MCPServers.httpConfig(url: "https://mcp.asana.com/sse")
        ),
        Integration(
            id: "intercom", title: "Intercom", blurb: "Conversations and contacts.",
            domains: ["intercom.com"],
            config: MCPServers.httpConfig(url: "https://mcp.intercom.com/mcp")
        ),
        Integration(
            id: "google", title: "Google Workspace", blurb: "Gmail, Calendar, and Drive through a Fountain connection.",
            domains: ["mail.google.com", "calendar.google.com", "drive.google.com", "docs.google.com"],
            connectionProviders: ["google", "gmail"],
            auth: .connection
        ),
        Integration(
            id: "microsoft", title: "Microsoft 365", blurb: "Outlook, Teams, and OneDrive through a Fountain connection.",
            domains: ["outlook.office.com", "outlook.live.com", "teams.microsoft.com", "sharepoint.com", "office.com"],
            bundleIDs: ["com.microsoft.Outlook", "com.microsoft.teams2"], appNames: ["Microsoft Outlook", "Microsoft Teams"],
            connectionProviders: ["microsoft", "outlook"],
            auth: .connection
        ),
        Integration(
            id: "gitlab", title: "GitLab", blurb: "Projects, merge requests, and pipelines.",
            domains: ["gitlab.com"], registryQuery: "gitlab", developerTool: true
        ),
        Integration(
            id: "cloudflare", title: "Cloudflare", blurb: "Workers, DNS, and R2.",
            domains: ["cloudflare.com"], registryQuery: "cloudflare", developerTool: true
        ),
        Integration(
            id: "discord", title: "Discord", blurb: "Servers and channels.",
            domains: ["discord.com"], bundleIDs: ["com.hnc.Discord"], appNames: ["Discord"],
            registryQuery: "discord"
        ),
        Integration(
            id: "zapier", title: "Zapier", blurb: "Thousands of apps through Zapier's MCP.",
            domains: ["zapier.com"], registryQuery: "zapier"
        ),
    ]

    // MARK: - Entry point

    public static func recommend(_ scan: MachineScan, connections: [Connection] = []) -> Recommendations {
        let integrations = recommendIntegrations(scan, connections: connections)
        // User-scope configs first, then projects by how recently they were touched.
        let activity = Dictionary(scan.projects.map { ($0.path, $0.lastActive ?? .distantPast) }, uniquingKeysWith: { a, _ in a })
        let ordered = scan.sites.sorted { a, b in
            if a.scope != b.scope { return a.scope == .user }
            let (ta, tb) = (activity[a.root] ?? .distantPast, activity[b.root] ?? .distantPast)
            return ta == tb ? a.id < b.id : ta > tb
        }
        var drafts = ordered.map { importSite($0, scan: scan) }
        drafts += roleDrafts(scan, integrations: integrations)
        return Recommendations(drafts: drafts, integrations: integrations)
    }

    /// A minimal agent whose whole point is one integration.
    public static func draft(for recommendation: Recommendation) -> AgentDraft {
        let integration = recommendation.integration
        var notes: [String] = recommendation.notes
        if !recommendation.secrets.isEmpty {
            notes.append("Needs \(recommendation.secrets.joined(separator: ", ")) in the conversation's environment.")
        }
        return AgentDraft(
            id: "integration-" + integration.id,
            kind: .integration(integration.id),
            title: "\(integration.title) assistant",
            subtitle: integration.blurb,
            name: "\(integration.title) assistant",
            description: "Works with \(integration.title) on your behalf.",
            runtime: .claude,
            system: """
            You help with \(integration.title): \(integration.blurb)
            Use the \(integration.id) MCP server for anything that touches it. Confirm before creating, \
            sending, or deleting anything on the user's behalf; reading is always fine.
            """,
            skills: [],
            mcpServers: recommendation.config.map { .object([integration.id: $0]) },
            notes: notes,
            evidence: recommendation.evidence
        )
    }

    // MARK: - Integrations

    static func recommendIntegrations(_ scan: MachineScan, connections: [Connection]) -> [Recommendation] {
        let appIndex = scan.apps
        return catalog.compactMap { integration -> Recommendation? in
            var evidence: [Evidence] = []
            var score = 0
            var config = integration.config
            var notes: [String] = []
            var secrets: [String] = []
            if case .secrets(let names) = integration.auth { secrets = names }

            // Browsing: the strongest "you use this" signal there is.
            for usage in scan.browsing where matches(domain: usage.domain, integration.domains) {
                evidence.append(.browsing(domain: usage.domain, visits: usage.visits, browsers: usage.browsers))
                score += min(usage.visits, 500) / 25 + 1
            }

            for app in appIndex
            where integration.bundleIDs.contains(where: { app.bundleID?.hasPrefix($0) == true })
                || integration.appNames.contains(app.name) {
                evidence.append(.app(name: app.name))
                score += 5
            }

            // Already declared for a local harness: reuse that config when
            // it says how to authenticate (or the catalog has nothing better).
            for site in scan.sites {
                for server in site.mcpServers where matches(server: server, integration) {
                    evidence.append(.harness(site: site.title, server: server.name))
                    score += 8
                    let carriesAuth = !server.headers.isEmpty || !server.env.isEmpty
                    guard carriesAuth || integration.config == nil else { continue }
                    let converted = convert(server, siteID: site.id)
                    if let value = converted.config {
                        config = value
                        secrets = converted.secrets
                        notes += converted.notes
                    }
                }
            }

            for connection in connections
            where integration.connectionProviders.contains(where: { connection.provider.lowercased().contains($0) }) {
                evidence.append(.connection(provider: connection.provider))
                score += 8
                config = MCPServers.connectionConfig(id: connection.id)
                secrets = []
            }

            guard score > 0 else { return nil }
            if config == nil {
                if integration.auth == .connection {
                    notes.append("Connect \(integration.title) under Fountain › Connections, then rescan.")
                } else if let query = integration.registryQuery {
                    notes.append("No official remote server known; search the MCP registry for \"\(query)\".")
                }
            } else if case .oauth = integration.auth, !evidence.contains(where: { if case .harness = $0 { true } else { false } }) {
                notes.append("Remote server authenticates with OAuth; the agent's first call will need an authorized token.")
            }
            return Recommendation(
                integration: integration, evidence: evidence, score: score,
                config: config, secrets: secrets, notes: notes
            )
        }
        .sorted { $0.score == $1.score ? $0.integration.title < $1.integration.title : $0.score > $1.score }
    }

    static func matches(domain: String, _ candidates: [String]) -> Bool {
        candidates.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    static func matches(server: LocalMCPServer, _ integration: Integration) -> Bool {
        let name = server.name.lowercased().replacingOccurrences(of: "_", with: "-")
        if name == integration.id || name.hasPrefix(integration.id + "-") || name.hasSuffix("-" + integration.id) {
            return true
        }
        if let url = server.url, let host = BrowserHistory.domain(of: url) {
            return matches(domain: host, integration.domains)
        }
        return false
    }

    // MARK: - Importing harness sites

    struct Converted {
        var config: JSONValue?
        var secrets: [String] = []
        var notes: [String] = []
    }

    /// One local MCP declaration → a Fountain `mcp_servers` value. Literal
    /// credentials become `${NAME}` references (generated config ends up in
    /// an account, not on this disk); machine-local commands are dropped
    /// because the sandbox doesn't have them.
    static func convert(_ server: LocalMCPServer, siteID: String) -> Converted {
        var out = Converted()
        if let url = server.url, server.command == nil {
            var headers: [String: String] = [:]
            for (key, value) in server.headers {
                let (redacted, secret) = redact(key: key, value: value, server: server.name)
                headers[key] = redacted
                if let secret { out.secrets.append(secret) }
            }
            out.config = MCPServers.httpConfig(url: url, headers: headers)
        } else if let command = server.command {
            if command.hasPrefix("/") || command.hasPrefix("~") {
                out.notes.append("Skipped \"\(server.name)\": its command is a path on this Mac (\(command)) that won't exist in a sandbox.")
                return out
            }
            if server.args.contains(where: { $0.hasPrefix("/Users/") || $0.hasPrefix("/Volumes/") || $0.hasPrefix("~") }) {
                out.notes.append("\"\(server.name)\" passes local paths as arguments; check them after import.")
            }
            var env: [String: String] = [:]
            for (key, value) in server.env {
                let (redacted, secret) = redact(key: key, value: value, server: server.name)
                env[key] = redacted
                if let secret { out.secrets.append(secret) }
            }
            out.config = MCPServers.stdioConfig(command: command, args: server.args, env: env)
        }
        for secret in out.secrets {
            out.notes.append("\"\(server.name)\": literal credential replaced with ${\(secret)}; add it to a vault.")
        }
        return out
    }

    /// `(value to write, secret name if one was redacted)`.
    static func redact(key: String, value: String, server: String) -> (String, String?) {
        if value.contains("${") || value.isEmpty { return (value, nil) }
        let lowered = key.lowercased()
        let hint = ["token", "secret", "password", "passwd", "credential", "cookie", "auth", "api_key", "apikey", "api-key"]
        let sensitiveKey = hint.contains(where: lowered.contains) || lowered == "key" || lowered.hasSuffix("_key")
        guard sensitiveKey else { return (value, nil) }
        // A SHA-256 pin or a path is the opposite of a secret.
        if value.hasPrefix("/") || value.hasPrefix("sha256:") { return (value, nil) }
        if lowered == "authorization" {
            let name = envName(server + "_token")
            let scheme = value.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            let known = ["bearer", "basic", "token"].contains(scheme.lowercased())
            return (known ? "\(scheme) ${\(name)}" : "${\(name)}", name)
        }
        guard value.count >= 8 else { return (value, nil) }
        let name = envName(key)
        return ("${\(name)}", name)
    }

    static func envName(_ raw: String) -> String {
        let mapped = raw.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let collapsed = String(mapped).split(separator: "_").joined(separator: "_")
        return collapsed.first?.isNumber == true ? "_" + collapsed : collapsed
    }

    static func importSite(_ site: HarnessSite, scan: MachineScan) -> AgentDraft {
        var notes: [String] = []
        var servers: [String: JSONValue] = [:]
        for server in site.mcpServers {
            let converted = convert(server, siteID: site.id)
            notes += converted.notes
            if let config = converted.config { servers[server.name] = config }
        }

        let runtime = site.harness.fountainRuntime ?? .claude
        if site.harness.fountainRuntime == nil {
            notes.append("\(site.harness.displayName) has no Fountain runtime; the draft runs on Claude Code.")
        }
        if let model = site.model {
            notes.append("Local model \"\(model)\" isn't a Fountain model id; pick one in the form.")
        }
        for subagent in site.subagents {
            notes.append("Subagent \"\(subagent.name)\" has no Fountain equivalent; its prompt is appended to the system prompt.")
        }
        if !site.plugins.isEmpty {
            notes.append("Plugins aren't carried over: \(site.plugins.joined(separator: ", ")).")
        }
        if !site.commands.isEmpty {
            notes.append("Slash commands aren't carried over: \(site.commands.joined(separator: ", ")).")
        }
        if !site.env.isEmpty {
            notes.append("Harness env vars belong on a Fountain environment: \(site.env.keys.sorted().joined(separator: ", ")).")
        }

        var system = site.instructions.map(\.content).joined(separator: "\n\n---\n\n")
        for subagent in site.subagents {
            system += (system.isEmpty ? "" : "\n\n---\n\n") + "# Subagent: \(subagent.name)\n\n" + subagent.content
        }
        let skills = site.skills.map { Skill(name: $0.name, content: $0.content) }

        var parts: [String] = []
        if !site.instructions.isEmpty { parts.append("\(site.instructions.count) instruction file\(site.instructions.count == 1 ? "" : "s")") }
        if !skills.isEmpty { parts.append("\(skills.count) skill\(skills.count == 1 ? "" : "s")") }
        if !servers.isEmpty { parts.append("\(servers.count) MCP server\(servers.count == 1 ? "" : "s")") }
        let subtitle = parts.isEmpty ? "settings only" : parts.joined(separator: " · ")

        let description = switch site.scope {
        case .user: "Imported from \(site.harness.displayName)'s user-level config on \(hostName())."
        case .project: "Imported from \(site.harness.displayName) config in \(site.root)."
        }

        return AgentDraft(
            id: "import-" + site.id,
            kind: .imported(siteID: site.id),
            title: site.title,
            subtitle: subtitle,
            name: site.title,
            description: description,
            runtime: runtime,
            system: system,
            skills: skills,
            mcpServers: servers.isEmpty ? nil : .object(servers),
            notes: notes,
            evidence: []
        )
    }

    static func hostName() -> String {
        ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
    }

    // MARK: - Role drafts from project activity

    static func roleDrafts(_ scan: MachineScan, integrations: [Recommendation]) -> [AgentDraft] {
        var counts: [ProjectLanguage: Int] = [:]
        for project in scan.projects {
            for language in project.languages where language != .docker {
                counts[language, default: 0] += 1
            }
        }
        let ranked = counts
            .filter { $0.value >= 2 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3)

        // Developer tooling the person demonstrably uses rides along.
        let tools = integrations.filter { $0.integration.developerTool && $0.config != nil }.prefix(4)
        var servers: [String: JSONValue] = [:]
        for tool in tools { servers[tool.integration.id] = tool.config }
        let secrets = tools.flatMap(\.secrets)

        return ranked.map { language, count in
            var notes: [String] = []
            if !tools.isEmpty {
                notes.append("Includes " + tools.map(\.integration.title).joined(separator: ", ") + " because you use them.")
            }
            if !secrets.isEmpty {
                notes.append("Needs \(secrets.joined(separator: ", ")) in the conversation's environment.")
            }
            return AgentDraft(
                id: "role-\(language.rawValue.lowercased())",
                kind: .role(language),
                title: "\(language.rawValue) engineer",
                subtitle: "\(count) active \(language.rawValue) projects" + (tools.isEmpty ? "" : " · \(tools.count) tools"),
                name: "\(language.rawValue) engineer",
                description: "Day-to-day engineering in \(language.rawValue) codebases like the ones on this Mac.",
                runtime: .claude,
                system: roleSystemPrompt(language, projects: scan.projects.filter { $0.languages.contains(language) }),
                skills: [],
                mcpServers: servers.isEmpty ? nil : .object(servers),
                notes: notes,
                evidence: [.projects(language: language, count: count)]
            )
        }
    }

    static func roleSystemPrompt(_ language: ProjectLanguage, projects: [ProjectSignal]) -> String {
        let names = projects.prefix(6).map(\.name).joined(separator: ", ")
        return """
        You are a senior \(language.rawValue) engineer working in a sandboxed checkout.

        Ways of working:
        - Read the repository's existing conventions (build files, lint config, CI) before changing code, and follow them.
        - Make the smallest change that fully solves the task; keep unrelated refactors out of the diff.
        - Run the project's own build and test commands before reporting done, and quote failures verbatim.
        - When a task is ambiguous, state the assumption you're making and proceed.

        Typical projects: \(names).
        """
    }
}
