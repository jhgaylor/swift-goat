# The Fountain API surface, from this client's seat

FountainKit ships from the Fountain repo's `sdk/swift` (Fountain ADR 0041);
this file is the app's map of what it wraps, kept here because this app is
what exercises it.

The contract is `GET /api/openapi.json` (vendored snapshot:
[openapi.json](openapi.json), ~163 operations). This file records which of
it FountainKit wraps, and what any new wrapper must respect.

## Conventions that hold everywhere

- Everything JSON is `{"data": …}`-enveloped, **except**: `GET /api/auth/me`,
  `POST /api/auth/api-keys`, `POST …/prompts`, `POST …/requests/:id`,
  `POST /api/team/:id/messages`, `POST …/schedules/:id/run`,
  webhook test/redeliver, `/health*`. Unwrapping one of these as an envelope
  silently yields nothing — it shipped as a real bug once.
- Error bodies come in four shapes: `{error}`, `{error, message}`,
  `{error, reason}` (auth routes — `error` is prose, `reason` is the code),
  and `{errors: {field: [msgs]}}` (422 changesets). `Retry-After` is a
  header. `APIErrorBody` decodes all four; branch on `FountainError`, and on
  `code` within it.
- Pagination is per-resource, not standardised: forward cursor (`after` +
  `meta.next_cursor`) on the log feed; backward cursor (`before`) on audit;
  offset on search; none at all on most collections. Loop on
  `meta.has_more`, never on the cursor being non-nil.
- SSE resume is the `Last-Event-ID` header only (the streams ignore
  `after`); ids are global monotonic integers shared with the JSON feed.
  Streams close after ~60s idle — reconnecting is normal operation.
- Send `Accept: text/event-stream` on stream routes and `image/*` on image
  routes; a JSON route 406s on an event-stream Accept.

## Wrapped in FountainKit

| Namespace | Covers |
|---|---|
| `agents` | CRUD, versions, avatar bytes |
| `environments` / `vaults` | CRUD + write-only secrets (delete path takes the **key**, percent-encoded) |
| `conversations` | list/get/create (resume detection), prompts, interrupt, terminate, read, turns, tree, permission answers, events page, full history, SSE tail, turn images |
| `events` | the all-conversations stream |
| `connections` | list, providers, delete (the MCP chooser's Connections source) |
| `team` | roster CRUD, messages (202 + busy semantics), threads, fresh conversation, comms status, stream, schedules |
| `sandboxes` | list/get/reset |
| `runners` | list/delete |
| `auth` | me, API keys mint/list/revoke, OAuth token revoke |
| `audit` / `search` | paged reads |
| `admin` | users (search/filter + the API's one page-number pagination), role/suspend/comp/credits/sandbox-limit, account deletion, cross-tenant sandboxes + reap, cross-tenant audit, privilege trail — all 403 unless `me.role == admin` |
| client-level | `catalog()`, `apply()`, `run()` (open a conversation and follow the turn) |

## Reachable only via `client.request(_:_:)` for now

Wrap these as features need them, following the shapes above:

- **Account**: billing + credit checkout (404 `billing_disabled` when off),
  exports, deletion, inference credentials, onboarding state
- **Secret bindings**, **egress log** — gated on `me.brokered`
  (connections list/providers/delete are wrapped; the OAuth dance itself
  stays a browser flow via `ConnectionProvider.connectURL`)
- **Webhooks** (outbound) + deliveries
- **Support reports**, **buzz agents**
- `/v1/*` OpenAI-compat and `/api/agui/:id` — different framing, flag-gated

## Checked against Fountain's own suite

Shape comes from the OpenAPI document above; behaviour comes from Fountain's
cross-language SDK conformance scenarios (`sdk/conformance`), which FountainKit
runs as the `swift-kit` column. They pin what no schema can: which error class
a 402 becomes, that a code outranks its status, that a dropped stream resumes
from the last id it saw, that a data field split over two writes rejoins.

All 24 run green — including the timeout scenario the untyped `swift` client
skips. Now that FountainKit lives in the Fountain repo, that check runs beside
the client rather than against a vendored copy of the scenarios.

## Feature gates a UI must respect

- `me.brokered` — hides connections/bindings/egress
- `GET /api/team/comms` `{enabled, configured}` — hides teammate contact
- `catalog.apps.conversations` / `.team` — deep-link targets, each nullable
- `comped == nil` on `/api/auth/me` — billing is off on this deployment
- `me.role == admin` — shows the Admin section (the sidebar filters on it)
