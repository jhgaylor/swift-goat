import Foundation
import Observation
import FountainKit

/// Owns the connection: base URL (UserDefaults), API key (`KeyStore`
/// file, Touch ID-gated at launch), and the configured client. Nothing
/// else touches the key.
@Observable @MainActor
public final class Session {
    private let keyStore = KeyStore()

    public enum State: Equatable {
        case signedOut
        case checking
        case signedIn(email: String)
        case failed(String)
    }

    public private(set) var state: State = .signedOut
    public private(set) var client: FountainClient?
    public private(set) var me: AuthMe?
    /// The verified key, exposed so the app can hand its session to a child
    /// process (the local runner daemon) via environment variables.
    public private(set) var apiKey: String?

    public var baseURL: URL {
        didSet {
            UserDefaults.standard.set(baseURL.absoluteString, forKey: Self.baseURLKey)
        }
    }

    static let baseURLKey = "fountain.baseURL"

    public init() {
        let stored = UserDefaults.standard.string(forKey: Self.baseURLKey)
        baseURL = stored.flatMap(URL.init(string:)) ?? FountainConfig.defaultBaseURL
    }

    /// Whether a key is stored for the current URL — checked without
    /// touching the secret, so the launch gate can decide before
    /// anything can prompt.
    public var hasStoredKey: Bool {
        keyStore.has(account: baseURL.absoluteString)
            || Keychain.hasAPIKey(account: baseURL.absoluteString)
    }

    /// Reconnect with the stored key for the current URL. Older installs
    /// kept it in the keychain: that read may prompt one last time, then
    /// the key moves into the file store and the item is deleted.
    public func restore() async {
        let account = baseURL.absoluteString
        if let key = keyStore.read(account: account) {
            await connect(apiKey: key, persist: false)
            return
        }
        if let key = Keychain.readAPIKey(account: account) {
            await connect(apiKey: key, persist: true)
            if case .signedIn = state {
                Keychain.deleteAPIKey(account: account)
            }
            return
        }
        state = .signedOut
    }

    /// Verify a key against `/api/auth/me`; on success it becomes the session.
    public func connect(apiKey: String, persist: Bool = true) async {
        state = .checking
        let candidate = FountainClient(config: FountainConfig(baseURL: baseURL, apiKey: apiKey))
        do {
            let me = try await candidate.auth.me()
            self.me = me
            self.client = candidate
            self.apiKey = apiKey
            if persist {
                keyStore.write(apiKey, account: baseURL.absoluteString)
            }
            state = .signedIn(email: me.email)
        } catch {
            self.client = nil
            self.me = nil
            self.apiKey = nil
            state = .failed(describe(error))
        }
    }

    /// Drop the key locally. (Revoking the token server-side is the caller's
    /// choice — an OAuth session should, a pasted key usually shouldn't.)
    public func signOut() {
        keyStore.delete(account: baseURL.absoluteString)
        Keychain.deleteAPIKey(account: baseURL.absoluteString)
        client = nil
        me = nil
        apiKey = nil
        state = .signedOut
    }
}
