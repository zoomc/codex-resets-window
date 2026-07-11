import AppKit
import Foundation
import UserNotifications

@MainActor
final class ResumeScheduler: ObservableObject {
    @Published private(set) var enabledIDs: Set<String>
    @Published private(set) var activities: [String: ResumeActivity] = [:]
    private var timer: Timer?
    private var runningProcesses: [String: Process] = [:]
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

    func activity(for session: CodexSession) -> ResumeActivity? { activities[session.id] }

    func updateSessions(_ sessions: [CodexSession]) {
        knownSessions = sessions
    }

    func continuationDate(resetAt: Date?) -> Date? {
        resetAt?.addingTimeInterval(5 * 60)
    }

    func setEnabled(_ enabled: Bool, for session: CodexSession, resetAt: Date?) {
        if enabled {
            enabledIDs.insert(session.id)
            activities[session.id] = ResumeActivity(
                state: .queued,
                scheduledAt: continuationDate(resetAt: resetAt)
            )
        } else {
            enabledIDs.remove(session.id)
            activities.removeValue(forKey: session.id)
        }
        UserDefaults.standard.set(Array(enabledIDs), forKey: defaultsKey)
        schedule(resetAt: resetAt)
    }

    func schedule(resetAt: Date?) {
        timer?.invalidate()
        guard let resetAt, !enabledIDs.isEmpty else { return }
        let fireDate = resetAt.addingTimeInterval(5 * 60)
        for sessionID in enabledIDs where activities[sessionID] == nil {
            activities[sessionID] = ResumeActivity(state: .queued, scheduledAt: fireDate)
        }
        let interval = max(1, fireDate.timeIntervalSinceNow)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let targets = self.knownSessions.filter { self.enabledIDs.contains($0.id) }
                // A switch represents one continuation after the next reset, not a
                // recurring job. Remove it before spawning so a refresh or app
                // restart cannot send duplicate `continue` prompts.
                self.enabledIDs.subtract(targets.map(\.id))
                UserDefaults.standard.set(Array(self.enabledIDs), forKey: self.defaultsKey)
                targets.forEach { self.resume($0) }
            }
        }
    }

    func open(_ session: CodexSession) {
        guard let url = URL(string: "codex://threads/\(session.id)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func resume(_ session: CodexSession) {
        activities[session.id] = ResumeActivity(state: .starting, startedAt: .now)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexExecutable)
        let workingDirectoryArguments = originalWorkingDirectory(for: session.id)
            .map { ["-C", $0.path] } ?? []
        let command = ["exec", "resume", session.id, "continue"]
        process.arguments = codexExecutable == "/usr/bin/env"
            ? ["codex"] + workingDirectoryArguments + command
            : workingDirectoryArguments + command
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.recordOutput(text, for: session.id) }
        }
        process.terminationHandler = { [weak self, weak output] completed in
            output?.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self?.complete(sessionID: session.id, exitCode: completed.terminationStatus)
            }
        }

        do {
            try process.run()
            runningProcesses[session.id] = process
            activities[session.id] = ResumeActivity(state: .running, startedAt: .now)
        } catch {
            activities[session.id] = ResumeActivity(
                state: .failed,
                startedAt: .now,
                finishedAt: .now,
                lastOutput: error.localizedDescription
            )
        }

        let content = UNMutableNotificationContent()
        content.title = "Codex Resets Window"
        content.body = "Started the selected Codex session."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: session.id, content: content, trigger: nil))
    }

    private func recordOutput(_ text: String, for sessionID: String) {
        let lastLine = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
        guard let lastLine else { return }
        let clipped = String(lastLine.prefix(120))
        let previous = activities[sessionID]
        activities[sessionID] = ResumeActivity(
            state: .running,
            scheduledAt: previous?.scheduledAt,
            startedAt: previous?.startedAt ?? .now,
            lastOutput: clipped
        )
    }

    private func complete(sessionID: String, exitCode: Int32) {
        runningProcesses.removeValue(forKey: sessionID)
        let previous = activities[sessionID]
        let succeeded = exitCode == 0
        activities[sessionID] = ResumeActivity(
            state: succeeded ? .succeeded : .failed,
            scheduledAt: previous?.scheduledAt,
            startedAt: previous?.startedAt,
            finishedAt: .now,
            lastOutput: previous?.lastOutput,
            exitCode: exitCode
        )

        let content = UNMutableNotificationContent()
        content.title = "Codex Resets Window"
        content.body = succeeded ? "Selected Codex session completed." : "Selected Codex session failed (exit \(exitCode))."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(sessionID).completed", content: content, trigger: nil))
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
