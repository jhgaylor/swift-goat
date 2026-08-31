# swift-goat

A native macOS client for [Fountain](https://github.com/BinaryBourbon/fountain),
the open-source control plane for coding agents.

Manage agents, environments, vaults, runners, conversations and your team from
a desktop app instead of a browser tab.

## Status

Foundation. The architecture is the deliverable right now: a clean, extensible
client library (`FountainKit`) plus an app shell (`SwiftGoat`) that proves the
layering. Feature surface grows from here.

## Layout

| Target | What |
|---|---|
| `FountainKit` | Pure Swift client for the Fountain API. No UI, no app state. Usable by any Swift program. |
| `GoatCore` | App domain: session (Keychain-held key), settings, observable stores. |
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
