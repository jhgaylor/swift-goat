# swift-goat

A native macOS client for [Fountain](https://github.com/BinaryBourbon/fountain),
the open-source control plane for coding agents.

Manage agents, environments, vaults, runners, conversations and your team from
a desktop app instead of a browser tab.

## Status

Usable. On top of the FountainKit foundation the app now covers the core
loop — spawn a conversation (agent + environment + vault + first prompt),
watch it stream, answer permission requests inline, queue prompts mid-turn,
interrupt, terminate, delete — plus create/edit/delete for agents,
environments and vaults (secrets included), full-text search, and the audit
trail. The Runners section can also run *this* Mac as a runner: it finds the
`fountain` CLI, starts/stops the daemon with the app's own session, and tails
its log.

Being native earns its keep: Touch ID (password fallback) gates the Admin
console and secret changes, a menu bar extra badges working conversations
and jumps back into live ones while the window is closed, Finder files
drop straight onto a transcript — images attach to the prompt, text files
inline into it — and permission requests arrive as actionable
notifications you can Allow/Deny without focusing the app (run the
bundled build for those: `Scripts/package-app.sh`, then
`open dist/SwiftGoat.app`).

Agents get an MCP chooser: search the official MCP registry and add a
server with its auth prefilled as `${SECRET}` references, mount one of
your OAuth connections (Gmail, Microsoft, …), or type a custom remote or
command. "Discover" scans this Mac — the Claude Code / Codex / Gemini /
OpenCode / Cursor configs you already have, the projects you work in,
the apps you've installed and the sites you visit — and turns that into
ready-to-create agent drafts (your local setups imported with secrets
redacted, a "TypeScript engineer" for the languages you actually use)
and integration suggestions you can add to any agent. It runs locally
and sends nothing until you confirm. Team schedules, webhooks and
billing are next; see [docs/api-surface.md](docs/api-surface.md) for
the wrapping backlog.

## Layout

| Target | What |
|---|---|
| `GoatCore` | App domain: session (Touch ID-gated key store), settings, observable stores. |
| `SwiftGoat` | The SwiftUI macOS app. |

`FountainKit`, the typed Fountain API client this app is built on, used to
live here and now ships from the Fountain repo itself
([`sdk/swift`](https://github.com/BinaryBourbon/fountain/tree/main/sdk/swift),
Apache-2.0), where it runs Fountain's cross-language conformance suite. This
app is its first consumer and its worked example.

See [docs/architecture.md](docs/architecture.md) for the design and the rules
that keep it extensible.

## Build

Requires Swift 6.1+ (Command Line Tools are enough; Xcode not required).

```bash
swift build
swift test
swift run SwiftGoat
```

## Connect

Settings take a base URL and an API key. Get a key from your Fountain's
console under API keys, or use an existing `~/.fountain/credentials`.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE) — the project was MIT
through 2026-09-03 and was relicensed by its sole copyright holder to match
the license Fountain's clients carry.
