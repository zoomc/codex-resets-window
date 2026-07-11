import AppKit
import Foundation
import UserNotifications

@MainActor
final class ResumeScheduler: ObservableObject {
    @Published private(set) var enabledIDs: Set<String>
    private var timer: Timer?
    private var knownSessions: [CodexSession] = []
    private let defaultsKey = "scheduledSessionIDs"

    init() {
        enabledIDs = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func isEnabled(_ session: CodexSession) -> Bool { enabledIDs.contains(session.id) }

    func updateSessions(_ sessions: [CodexSession]) {
        knownSessions = sessions
    }

    func continuationDate(resetAt: Date?) -> Date? {
        resetAt?.addingTimeInterval(5 * 60)
    }

    func setEnabled(_ enabled: Bool, for session: CodexSession, resetAt: Date?) {
        if enabled { enabledIDs.insert(session.id) } else { enabledIDs.remove(session.id) }
        UserDefaults.standard.set(Array(enabledIDs), forKey: defaultsKey)
        schedule(resetAt: resetAt)
    }

    func schedule(resetAt: Date?) {
        timer?.invalidate()
        guard let resetAt, !enabledIDs.isEmpty else { return }
        let fireDate = resetAt.addingTimeInterval(5 * 60)
        let interval = max(1, fireDate.timeIntervalSinceNow)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let targets = self.knownSessions.filter { self.enabledIDs.contains($0.id) }
                targets.forEach { self.resume($0) }
            }
        }
    }

    func open(_ session: CodexSession) {
        let escapedID = session.id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"codex resume \(escapedID)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private func resume(_ session: CodexSession) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "exec", "resume", session.id, "continue"]
        try? process.run()

        let content = UNMutableNotificationContent()
        content.title = "Codex Window"
        content.body = "Sent continue to the selected Codex session."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: session.id, content: content, trigger: nil))
    }
}
