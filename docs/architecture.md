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
  and handles SSE reconnect (Last-Event-ID, 1s → ×2 → 15s backoff) itself.
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

## GoatCore rules

- `Session` owns credentials (Keychain) and hands out a configured
  `FountainClient`. Nothing else touches the key.
- One store per feature (`AgentsStore`, `ConversationsStore`, …), each
  `@Observable @MainActor`, owning its loading/error state. Stores call
  FountainKit; views never do.
- Errors surface as user copy via one `describe(_ error:)` table, same
  pattern as fountain-team's `describeError`.

## App conventions

- `NavigationSplitView`: sidebar of sections (Conversations, Team, Agents,
  Environments, Vaults, Runners, Sandboxes, Audit), detail per selection.
- Settings scene holds base URL + API key; the base URL is user-editable so
  the app works against any Fountain deployment.
- Secret values are write-only server-side; the UI says so instead of
  pretending it can read them back.

## Auth

Paste-a-key first (an API key from the console, `$FOUNTAIN_TOKEN`, or
`~/.fountain/credentials`). Sign in with Fountain (OAuth code + PKCE against
a registered client with a loopback redirect) is a later, additive layer —
the token it yields *is* an API key, so Session doesn't change shape.
