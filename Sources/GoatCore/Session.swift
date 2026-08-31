import Foundation
import Observation
import FountainKit

/// Owns the connection: base URL (UserDefaults), API key (Keychain), and the
/// configured client. Nothing else touches the key.
@Observable @MainActor
public final class Session {
    public enum State: Equatable {
        case signedOut
        case checking
        case signedIn(email: String)
        case failed(String)
    }

    public private(set) var state: State = .signedOut
    public private(set) var client: FountainClient?
    public private(set) var me: AuthMe?

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

    /// Reconnect with whatever key the Keychain holds for the current URL.
    public func restore() async {
        guard let key = Keychain.readAPIKey(account: baseURL.absoluteString) else {
            state = .signedOut
            return
        }
        await connect(apiKey: key, persist: false)
    }

    /// Verify a key against `/api/auth/me`; on success it becomes the session.
    public func connect(apiKey: String, persist: Bool = true) async {
        state = .checking
        let candidate = FountainClient(config: FountainConfig(baseURL: baseURL, apiKey: apiKey))
        do {
            let me = try await candidate.auth.me()
            self.me = me
            self.client = candidate
            if persist {
                Keychain.writeAPIKey(apiKey, account: baseURL.absoluteString)
            }
            state = .signedIn(email: me.email)
        } catch {
            self.client = nil
            self.me = nil
            state = .failed(describe(error))
        }
    }

    /// Drop the key locally. (Revoking the token server-side is the caller's
    /// choice — an OAuth session should, a pasted key usually shouldn't.)
    public func signOut() {
        Keychain.deleteAPIKey(account: baseURL.absoluteString)
        client = nil
        me = nil
        state = .signedOut
    }
}
