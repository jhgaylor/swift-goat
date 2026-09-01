import Foundation

/// Where the API key lives: a `0600` JSON file in Application Support,
/// keyed by base URL — the same trust model as the CLI's plaintext
/// `~/.fountain/credentials`, which holds this very key. The login
/// keychain was tried first and lost: its ACLs (and Sierra's partition
/// lists) key on the binary's code signature, which every dev rebuild
/// changes, so "Always Allow" never stuck and each launch prompted for
/// the keychain password. The app's own Touch ID launch gate
/// (`SecurityGate.Scope.session`) is the user-facing protection.
public struct KeyStore: Sendable {
    let fileURL: URL

    /// The production store. Tests point at a scratch directory instead.
    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SwiftGoat")
        fileURL = base.appending(path: "credentials.json")
    }

    public func read(account: String) -> String? {
        load()[account]
    }

    public func has(account: String) -> Bool {
        load()[account] != nil
    }

    @discardableResult
    public func write(_ key: String, account: String) -> Bool {
        var all = load()
        all[account] = key
        return save(all)
    }

    public func delete(account: String) {
        var all = load()
        all[account] = nil
        save(all)
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    @discardableResult
    private func save(_ all: [String: String]) -> Bool {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(all)
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }
}
