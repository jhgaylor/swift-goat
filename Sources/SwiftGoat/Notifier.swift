import AppKit
import UserNotifications
import GoatCore

/// Permission requests as actionable macOS notifications: Allow / Deny
/// buttons answer without focusing the app (Allow additionally demands an
/// unlocked device); clicking the body opens the transcript. Wants a real
/// app bundle — UserNotifications refuses a bare executable, so under
/// `swift run` this quietly does nothing (package with
/// Scripts/package-app.sh to get notifications).
@MainActor
final class Notifier: NSObject {
    static let categoryID = "goat.permission"
    static let allowActionID = "goat.permission.allow"
    static let denyActionID = "goat.permission.deny"

    var openConversation: (@MainActor (String) -> Void)?
    var answer: (@MainActor (_ requestID: String, _ optionKindPrefix: String) async -> Void)?

    private let center: UNUserNotificationCenter?

    override init() {
        center = Bundle.main.bundleIdentifier != nil ? .current() : nil
        super.init()
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        let allow = UNNotificationAction(
            identifier: Self.allowActionID, title: "Allow",
            options: [.authenticationRequired])
        let deny = UNNotificationAction(
            identifier: Self.denyActionID, title: "Deny",
            options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID, actions: [allow, deny],
                intentIdentifiers: [])
        ])
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }

    func post(_ alert: PermissionWatcher.Alert) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.request.toolName.map { "Permission: \($0)" } ?? "Permission requested"
        content.body = alert.request.summary ?? "An agent wants to use a tool."
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = [
            "requestID": alert.id,
            "conversationID": alert.conversationID,
        ]
        // The request id doubles as the notification id, so withdrawal is a
        // straight lookup when the request stops being answerable.
        center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
    }

    func withdraw(_ requestIDs: [String]) {
        guard let center else { return }
        center.removeDeliveredNotifications(withIdentifiers: requestIDs)
        center.removePendingNotificationRequests(withIdentifiers: requestIDs)
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let requestID = info["requestID"] as? String
        let conversationID = info["conversationID"] as? String
        let action = response.actionIdentifier
        await Task { @MainActor in
            switch action {
            case Self.allowActionID:
                if let requestID { await self.answer?(requestID, "allow") }
            case Self.denyActionID:
                if let requestID { await self.answer?(requestID, "reject") }
            default:
                if let conversationID { self.openConversation?(conversationID) }
            }
        }.value
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
