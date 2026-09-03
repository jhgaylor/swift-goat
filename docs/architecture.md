# Architecture

The goal of this codebase is extensibility: every new Fountain surface
(schedules, webhooks, comms, billing…) should land as an additive module that
follows an existing shape, not a rework.

## Layering

```
SwiftGoat (SwiftUI app)          — views, navigation, commands
    │
GoatCore (app domain)            — Session, Settings, feature stores (@Observable)
    │
FountainKit (API client)         — client, resources, models, SSE, errors, transport
    │
URLSession                       — behind the HTTPTransport protocol
```

Dependencies point down only. FountainKit knows nothing about the app;
GoatCore knows nothing about SwiftUI views (it exposes `@Observable` stores
the views watch). A future iOS app, CLI, or menu-bar extra reuses everything
below the view layer.

## FountainKit rules

- **The OpenAPI document is the contract** (`docs/openapi.json`, generated
  from the server via `mix openapi.spec.json`). Models are hand-written
  Codable structs that follow it; when the server grows, regenerate the spec
  and diff to see what to add. The API is additive, so an older FountainKit
  keeps working against a newer Fountain.
- **Tolerant decoding.** Every server enum decodes through a wrapper that
  preserves unknown values (`.unknown(String)`) instead of throwing. Unknown
  JSON fields are ignored by Codable already. A new server value must never
  crash a deployed client.
- **Branch on `code`, never on HTTP status.** Errors decode the server error
  body and map by `code` to typed cases (`.conversationBusy`,
  `.insufficientCredits(upgradeURL:)`, `.notReady(retryAfter:)`,
  `.validation(fieldErrors:)`, …). Status is a fallback.
- **The 202 is not the answer.** Sending a prompt queues a turn; the words
  arrive on a stream. FountainKit exposes streams as `AsyncThrowingStream`
  and handles SSE reconnect itself (`Last-Event-ID`, linear backoff of
  `retryDelay × attempt`, five attempts; a 4xx is thrown at once because it
  never self-heals).
- **Render blocks, never a dialect.** Event feeds always request
  `blocks=true`; the app renders the block union
  (`text | thinking | tool_use | tool_result | init | result | error | raw`)
  and never parses runtime output.
- **One resource type per API namespace** (`AgentsResource`,
  `VaultsResource`, …), each a thin, stateless struct over the shared
  `APIClient`. Anything unwrapped is reachable via
  `client.request(_:path:...)` so a missing endpoint never blocks the app.
- **Transport is a protocol.** Tests inject a fake `HTTPTransport`; fixture
  responses are shaped from the real API (verify with one real call before
  writing the fake — the envelope trap).

- **Never substitute a host.** A base URL that isn't an absolute http(s)
  URL throws (`FountainConfig.baseURL(from:)`, `.invalidBaseURL`). Falling
  back to the hosted deployment would post a self-hosted key to a server the
  caller never named — `localhost:4000` parses to a URL with no host, so this
  is one typo away, not hypothetical.
- **`TurnFollower` is the fold.** It turns the multi-turn, multi-stream feed
  into one turn's answer (turn matching, ACP-vs-stdout paragraph joining,
  which block kinds count as the answer). Its semantics are a deliberate
  port of the TypeScript SDK's `turn.ts` — change them there first.
- **`Run` is the fold with a stream attached.** `client.run(prompt:agent:)`
  and `conversations.run(id:prompt:)` open or continue a conversation and
  follow the turn it starts: `events` for the pieces (every subscriber sees
  the whole transcript, the turn is followed once), `value()` for the answer.
  A turn that fails is a `RunResult` with a non-`done` state; only client-side
  failures throw. `timeout` stops the waiting, never the turn.
- **Conformance is a standing check, not a claim.** Fountain's
  cross-language SDK conformance scenarios are vendored under
  `Tests/FountainKitTests/Conformance/` and run on every `swift test`. They
  are copied verbatim and never edited here; `verdicts.json` says which run
  and records each deliberate deviation with its reason, and a scenario with
  no verdict fails the suite. Refresh with `Scripts/sync-conformance.sh`.

## GoatCore rules

- `Session` owns credentials and hands out a configured `FountainClient`.
  Nothing else touches the key. It lives in `KeyStore` — a `0600` JSON
  file in Application Support, the same trust model as the CLI's
  plaintext `~/.fountain/credentials` — because the login keychain lost:
  its ACLs and partition lists key on the binary's code signature, which
  every dev rebuild changes, so each launch prompted for the keychain
  password. The user-facing protection is the Touch ID launch gate
  (below); a key found in the legacy keychain location migrates to the
  file on first restore (one last prompt) and the item is deleted.
- One store per feature (`ListStore` per sidebar section,
  `ConversationStore` per open transcript), each `@Observable @MainActor`,
  owning its loading/error state. Long-lived state always flows through a
  store; a one-shot mutation (an editor sheet's create/update/delete) may
  call the session client directly, but must refresh the owning store on
  success so every list stays store-fed.
- `ConversationStore` owns the two feed rules: merge history and live
  events by event id (gaps are normal — the all-events stream only follows
  unfinished conversations; a stage change triggers a backfill), and
  `conversation_busy` queues the prompt to flush on turn end.
- Errors surface as user copy via one `describe(_ error:)` table, same
  pattern as fountain-team's `describeError`.
- `SecurityGate` is the local-auth gate (Touch ID, password fallback) in
  front of sensitive surfaces — app launch (one prompt before the stored
  key is read; `RootView`'s gate is one-way, so an opened session never
  re-locks mid-use), the Admin section (view-gated via `GatedView`) and
  secret writes (action-gated right before the mutation). Per-scope
  unlocks last a 5-minute grace window; sign-out and the Settings toggle
  relock/disable. Client-side defense-in-depth only — the server still
  enforces authorization. The authenticator and clock are injected, so
  tests never touch LocalAuthentication.
- `MachineScan/` is the local-only "Discover agents" scan, modelled on
  chant's agent audit (INTENTIUS/chant#1597): discovery is
  location-driven, not a filesystem walk. Each harness (Claude Code,
  Codex, Gemini, OpenCode, Cursor) publishes a fixed set of paths, so a
  scan of the home directory plus every project the harnesses already
  register is a few hundred stats, and the result records what it
  `probed` and what was `unreadable` rather than leaving absence
  ambiguous. Three signals chant doesn't read sit beside it — browser
  history (each browser's SQLite copied, opened read-only, aggregated to
  the domain; Safari needs Full Disk Access and says so), installed apps
  (bundle ids only), and project languages (root marker files). The
  `Recommender` is pure: signals in, `AgentDraft`s and `Integration`
  suggestions out. Imports turn instructions into the system prompt,
  inline local skills, and carry MCP servers over with literal
  credentials rewritten to `${NAME}` references and machine-local
  commands dropped, each loss reported as a note. Nothing leaves the Mac
  until the user confirms the pre-filled create sheet; the scan is
  gated (`.machineScan`) because it reads browsing history. Everything
  is injectable (`home`, app folders, clock), so the tests run against a
  fixture home and never the real machine.

## App conventions

- `NavigationSplitView`: sidebar of sections (Conversations, Team, Agents,
  Environments, Vaults, Sandboxes, Runners, Search, Audit), detail per
  selection.
- Interactivity is click-first: a row click pushes the item's detail page,
  where editing happens in place (Save ⌘S enables on a dirty diff against
  what loaded; Delete lives in the toolbar). Context menus and the delete
  key are accelerators, never the only path. Creation is the one modal
  moment: "+" (⌘N) opens a create sheet. Destructive actions always
  confirm. Mutations call FountainKit through the session client and
  refresh the owning `ListStore` on success.
- `Nav` (SwiftGoat) owns all routing state — sidebar selection plus every
  stack's push path — so any feature can land the user in a specific
  transcript (e.g. "New Conversation" on an agent's detail page), and so
  the whole thing has browser-style history: mouse buttons 4/5 and ⌘[ / ⌘]
  (the Go menu) walk back/forward across sections and detail pages. The
  history mechanics live in GoatCore's `NavHistory` (tested); `Nav` just
  snapshots its state into it on every change.
- Pending permission requests surface as answerable cards above the
  composer; the transcript row stays a passive marker. Only options the
  agent offered are shown — the server rejects invented ones.
- Settings scene holds base URL + API key; the base URL is user-editable so
  the app works against any Fountain deployment.
- The Runners section manages this Mac as a runner, not just the account's
  list: `LocalRunnerController` (GoatCore) discovers the `fountain` binary
  in well-known install paths, spawns `fountain runner` as a supervised
  child `Process`, and tails its output into a capped `LineBuffer`. The
  child inherits the app's session via `FOUNTAIN_API_KEY` /
  `FOUNTAIN_BASE_URL` env vars (both honored by the CLI) — the app never
  writes `~/.fountain/credentials`. RootView SIGTERMs the child on
  `NSApplication.willTerminate` so sandboxes park instead of orphaning;
  a force-kill of the app does leak the daemon (harmless — it just keeps
  serving until stopped). While the daemon runs, the section polls
  `GET /api/runners` so the registered list's online flag tracks it.
- Secret values are write-only server-side; the UI says so instead of
  pretending it can read them back.
- The MCP chooser (agent editor → "Add MCP Server…") has three sources:
  the official MCP registry (`MCPRegistryClient` in GoatCore — not a
  Fountain API, but it rides the same `HTTPTransport` seam; only
  `version=latest`, non-deleted entries), the account's OAuth
  connections (`{connection: id}` entries), and manual entry. `MCPServers`
  (GoatCore, tested) owns the `mcp_servers` wire shapes — http / stdio /
  connection, unknown shapes preserved untouched — plus registry→config
  conversion: key derivation from reverse-DNS names, and `{api_key}`
  templates rewritten to Fountain's `${API_KEY}` secret interpolation so
  secrets land in environment secrets, never the manifest. Edits go
  through the same dirty-checked `AgentFormValues` diff as every other
  agent field.
- Permission requests reach the user wherever they are:
  `PermissionWatcher` (GoatCore) tails the account-wide
  `/api/events/stream` for the life of a signed-in session, opening an
  alert per `permission_request` block and mooting a conversation's
  alerts on turn end / teardown (same rule as `ConversationStore`).
  `Notifier` (SwiftGoat) turns alerts into actionable notifications —
  Allow (`.authenticationRequired`) / Deny buttons answer through the
  watcher, mirroring the card's only-offered-options rule; clicking the
  body opens the transcript; the pending count is the Dock badge.
  Notifications need a real bundle (`Scripts/package-app.sh` →
  `dist/SwiftGoat.app`); under bare `swift run` the notifier no-ops and
  the cards/badge still work.
- The menu bar extra is the glanceable surface while the window is
  closed: its label badges conversations the agent is working (the label
  owns a once-a-minute poll of the conversations store) and the menu
  lists live conversations as jump-back-in rows through `Nav`. The main
  `WindowGroup` carries `id: "main"` so the extra can reopen it.
- The composer takes Finder files: drop anywhere on the transcript or
  use the paperclip. Images ride the API's base64 attachment lane
  (`ImageInput`); text files inline into the prompt as named fences;
  anything else is refused with a reason (the API has no arbitrary-file
  upload). Attachments queue with their prompt on `conversation_busy`.

## Auth

Paste-a-key first (an API key from the console, `$FOUNTAIN_TOKEN`, or
`~/.fountain/credentials`). Sign in with Fountain (OAuth code + PKCE against
a registered client with a loopback redirect) is a later, additive layer —
the token it yields *is* an API key, so Session doesn't change shape.
