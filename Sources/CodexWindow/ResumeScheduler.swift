import AppKit
import Foundation
import UserNotifications

@MainActor
final class ResumeScheduler: ObservableObject {
    @Published private(set) var enabledIDs: Set<String>
    private var timer: Timer?
    private let defaultsKey = "scheduledSessionIDs"

    init() {
        enabledIDs = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func isEnabled(_ session: CodexSession) -> Bool { enabledIDs.contains(session.id) }

    func setEnabled(_ enabled: Bool, for session: CodexSession, resetAt: Date?) {
        if enabled { enabledIDs.insert(session.id) } else { enabledIDs.remove(session.id) }
        UserDefaults.standard.set(Array(enabledIDs), forKey: defaultsKey)
        schedule(resetAt: resetAt, sessions: [session])
    }

    func schedule(resetAt: Date?, sessions: [CodexSession]) {
        timer?.invalidate()
        guard let resetAt, !enabledIDs.isEmpty else { return }
        let fireDate = resetAt.addingTimeInterval(5 * 60)
        let interval = max(1, fireDate.timeIntervalSinceNow)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let targets = sessions.filter { self.enabledIDs.contains($0.id) }
                targets.forEach { self.resume($0) }
            }
        }
    }

    private func resume(_ session: CodexSession) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "resume", session.id]
        try? process.run()

        let content = UNMutableNotificationContent()
        content.title = "Codex Window"
        content.body = "已在本机尝试恢复：\(session.displayName)"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: session.id, content: content, trigger: nil))
    }
}
