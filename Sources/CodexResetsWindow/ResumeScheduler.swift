import AppKit
import Foundation
import UserNotifications

@MainActor
final class ResumeScheduler: ObservableObject {
    @Published private(set) var enabledIDs: Set<String>
    private var timer: Timer?
    private var knownSessions: [CodexSession] = []
    private let defaultsKey = "scheduledSessionIDs"

    private var codexExecutable: String {
        let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex"
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "/usr/bin/env"
    }

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
        let commandPath = codexExecutable.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedID = session.id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(commandPath) resume \(escapedID)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private func resume(_ session: CodexSession) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexExecutable)
        let workingDirectoryArguments = originalWorkingDirectory(for: session.id)
            .map { ["-C", $0.path] } ?? []
        let command = ["exec", "resume", session.id, "continue"]
        process.arguments = codexExecutable == "/usr/bin/env"
            ? ["codex"] + workingDirectoryArguments + command
            : workingDirectoryArguments + command
        try? process.run()

        let content = UNMutableNotificationContent()
        content.title = "Codex Resets Window"
        content.body = "Sent continue to the selected Codex session."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: session.id, content: content, trigger: nil))
    }

    /// A resumed session must start in the same repository as its original task.
    /// Codex keeps this private, local metadata beside the session transcript.
    private func originalWorkingDirectory(for sessionID: String) -> URL? {
        let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.contains(sessionID),
                  fileURL.pathExtension == "jsonl",
                  let handle = try? FileHandle(forReadingFrom: fileURL),
                  let firstLine = try? handle.read(upToCount: 16_384),
                  let object = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let path = payload["cwd"] as? String,
                  FileManager.default.fileExists(atPath: path) else { continue }
            defer { try? handle.close() }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }
}
