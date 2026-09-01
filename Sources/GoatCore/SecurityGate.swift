import Foundation
import LocalAuthentication
import Observation

/// Local-authentication gate (Touch ID, falling back to the account
/// password) in front of the app's sensitive surfaces. Purely client-side
/// defense-in-depth — the server enforces its own authorization; this keeps
/// a walked-away-from Mac from being an admin console.
///
/// An unlock is per-scope and lasts `graceWindow`; sign-out locks
/// everything. The authenticator and clock are injected so tests never
/// touch LocalAuthentication.
@Observable @MainActor
public final class SecurityGate {
    public enum Scope: String, CaseIterable, Sendable {
        /// App launch, before the stored session key is read.
        case session
        case admin
        case secrets
        /// Reading browser history and local agent configs (Discover agents).
        case machineScan
    }

    /// User toggle (Settings). Off means every scope reads as unlocked.
    public var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    static let enabledKey = "goat.securityGate.enabled"

    private let graceWindow: TimeInterval
    private let authenticate: (String) async -> Bool
    private let now: () -> Date
    private var unlockedAt: [Scope: Date] = [:]

    public init(
        enabled: Bool? = nil,
        graceWindow: TimeInterval = 300,
        authenticate: ((String) async -> Bool)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.isEnabled = enabled
            ?? (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true)
        self.graceWindow = graceWindow
        self.authenticate = authenticate ?? Self.systemAuthenticate
        self.now = now
    }

    public func isUnlocked(_ scope: Scope) -> Bool {
        guard isEnabled else { return true }
        guard let at = unlockedAt[scope] else { return false }
        return now().timeIntervalSince(at) < graceWindow
    }

    /// True when the scope is (or becomes) unlocked. Prompts only when the
    /// grace window has lapsed.
    public func unlock(_ scope: Scope, reason: String) async -> Bool {
        guard !isUnlocked(scope) else { return true }
        guard await authenticate(reason) else { return false }
        unlockedAt[scope] = now()
        return true
    }

    /// Sign-out (or anything else that ends trust) relocks every scope.
    public func lockAll() {
        unlockedAt = [:]
    }

    /// What the unlock button should promise — "Touch ID" only when the
    /// hardware is there and enrolled.
    public static var methodLabel: String {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return "password"
        }
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        default: return "password"
        }
    }

    /// Biometry with password fallback. A Mac with no password set has
    /// nothing to gate with, so it passes through rather than locking the
    /// user out of their own data.
    private static func systemAuthenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return true
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
