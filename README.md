# swift-goat

A native macOS client for [Fountain](https://github.com/BinaryBourbon/fountain),
the open-source control plane for coding agents.

Manage agents, environments, vaults, runners, conversations and your team from
a desktop app instead of a browser tab.

## Status

Usable. The app covers the core loop end to end, and the pieces below are
what's built today.

### Conversations

Spawn one from the sheet (agent + environment + vault + first prompt),
watch the turn stream in, answer permission requests on a card above the
composer, queue prompts mid-turn, interrupt, terminate the sandbox, delete.
Drop Finder files onto a transcript — images attach to the prompt, text
files inline into it.

### Agents, environments, vaults

Create, edit and delete all three, secrets included (write-only, deleted by
key). Agents also get:

- **An MCP chooser** — search the official MCP registry and add a server
  with its auth prefilled as `${SECRET}` references, mount one of your
  OAuth connections (Gmail, Microsoft, …), or type a custom remote or
  command.
- **Discover** — scans this Mac (the Claude Code / Codex / Gemini /
  OpenCode / Cursor configs you already have, the projects you work in,
  the apps you've installed, the sites you visit) and turns it into
  ready-to-create agent drafts — your local setups imported with secrets
  redacted, a "TypeScript engineer" for the languages you actually use —
  plus integration suggestions you can add to any agent. It runs locally
  and sends nothing until you confirm.

### Runners

The list of your registered runners, and this Mac as one of them: the app
finds the `fountain` CLI, starts and stops the daemon under its own
session, and tails the log.

### Everywhere else

Full-text search, the audit trail, read-only Team and Sandboxes lists, and
an Admin console (users, roles, credits, cross-tenant sandboxes and audit)
for admin accounts.

### Native touches

- **Touch ID**, password fallback: unlocks the stored key at launch, and
  gates the Admin console and secret changes after that.
- **Menu bar extra** that badges working conversations and jumps back into
  live ones while the window is closed; the Dock icon badges pending
  permission requests.
- **Actionable notifications** for permission requests — Allow or Deny
  without focusing the app. These need a real bundle:
  `Scripts/package-app.sh`, then `open dist/SwiftGoat.app`.
- **Browser-style history** — back and forward (⌘[ / ⌘], or mouse buttons
  4 and 5) walk everywhere you've been, across sections and detail pages.

Team schedules, webhooks and billing are next; see
[docs/api-surface.md](docs/api-surface.md) for the wrapping backlog.

## Layout

| Target | What |
|---|---|
| `FountainKit` | Pure Swift client for the Fountain API. No UI, no app state. Usable by any Swift program. |
| `GoatCore` | App domain: session (Touch ID-gated key store), settings, observable stores. |
| `SwiftGoat` | The SwiftUI macOS app. |

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

MIT
