import Foundation
@preconcurrency import UserNotifications

/// `UNUserNotificationCenter.current()` raises an `NSInternalInconsistencyException` when the
/// process has no bundle — exactly what happens when the bare binary runs `--selftest` or `--dump`.
enum NotificationCenterGate {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }
}

/// Notification seam. The self-test injects a spy instead of touching the notification centre.
protocol NotificationSending: Sendable {
    func post(title: String, body: String, identifier: String, urgent: Bool)
    func isAuthorized() async -> Bool
    var isEnabled: Bool { get set }
}

/// Posts through `UNUserNotificationCenter`.
///
/// Request identifiers now carry a timestamp. The old code reused the session id, so a second
/// continuation for the same session silently replaced the first notification and the user never
/// saw it.
final class SystemNotificationService: NotificationSending, @unchecked Sendable {
    var isEnabled: Bool = true

    func post(title: String, body: String, identifier: String, urgent: Bool) {
        guard isEnabled, NotificationCenterGate.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                AppLog.warning("notification skipped: not authorised", category: .notification)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = urgent ? .defaultCritical : .default
            content.categoryIdentifier = "com.codexresets.window.continuation"
            let unique = "\(identifier).\(Int(Date().timeIntervalSince1970))"
            center.add(UNNotificationRequest(identifier: unique, content: content, trigger: nil)) { error in
                if let error {
                    AppLog.error("notification failed: \(error.localizedDescription)", category: .notification)
                }
            }
        }
    }

    func isAuthorized() async -> Bool {
        guard NotificationCenterGate.isAvailable else { return false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
    }
}

/// Records notifications instead of delivering them.
final class SpyNotificationService: NotificationSending, @unchecked Sendable {
    struct Posting: Equatable, Sendable {
        let title: String
        let body: String
        let identifier: String
        let urgent: Bool
    }

    private let lock = NSLock()
    private var postings: [Posting] = []
    var isEnabled: Bool = true
    var authorized: Bool = true

    var sent: [Posting] {
        lock.lock()
        defer { lock.unlock() }
        return postings
    }

    func post(title: String, body: String, identifier: String, urgent: Bool) {
        guard isEnabled, authorized else { return }
        lock.lock()
        postings.append(Posting(title: title, body: body, identifier: identifier, urgent: urgent))
        lock.unlock()
    }

    func isAuthorized() async -> Bool { authorized }
}

/// Silently drops everything. Used by the headless self-test and the sandbox.
final class NullNotificationService: NotificationSending, @unchecked Sendable {
    var isEnabled: Bool = false
    func post(title: String, body: String, identifier: String, urgent: Bool) {}
    func isAuthorized() async -> Bool { false }
}
