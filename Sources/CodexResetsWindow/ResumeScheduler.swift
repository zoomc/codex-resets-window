import AppKit
import Foundation
import UserNotifications

@MainActor
final class ResumeScheduler: ObservableObject {
    @Published private(set) var enabledIDs: Set<String>
    @Published private(set) var activities: [String: ResumeActivity] = [:]

    private var timer: Timer?
    private var reconciliationTimer: Timer?
    private var runningProcesses: [String: Process] = [:]
    private var continuations: [String: PersistedContinuation]
    private var knownSessions: [CodexSession] = []

    private let defaultsKey = "scheduledContinuations"
    private let legacyDefaultsKey = "scheduledSessionIDs"
    private let maximumRetention: TimeInterval = 7 * 60 * 60

    private var codexExecutable: String {
        let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex"
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "/usr/bin/env"
    }

    init() {
        continuations = Self.loadContinuations(forKey: defaultsKey)
        if continuations.isEmpty,
           let legacyIDs = UserDefaults.standard.stringArray(forKey: legacyDefaultsKey) {
            let now = Date()
            continuations = Dictionary(uniqueKeysWithValues: legacyIDs.map {
                ($0, PersistedContinuation(createdAt: now, activity: ResumeActivity(state: .queued)))
            })
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        }
        enabledIDs = Set(continuations.keys)
        activities = continuations.mapValues(\.activity)
        pruneExpiredContinuations()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        reconciliationTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcilePersistedTasks() }
        }
    }

    func isEnabled(_ session: CodexSession) -> Bool { enabledIDs.contains(session.id) }

    func activity(for session: CodexSession) -> ResumeActivity? { activities[session.id] }

    func updateSessions(_ sessions: [CodexSession]) {
        knownSessions = sessions
        reconcilePersistedTasks()
        scheduleNextQueuedContinuation()
    }

    func continuationDate(resetAt: Date?) -> Date? {
        resetAt?.addingTimeInterval(5 * 60)
    }

    func setEnabled(_ enabled: Bool, for session: CodexSession, resetAt: Date?) {
        if enabled {
            let activity = ResumeActivity(state: .queued, scheduledAt: continuationDate(resetAt: resetAt))
            continuations[session.id] = PersistedContinuation(createdAt: .now, activity: activity)
            enabledIDs.insert(session.id)
            activities[session.id] = activity
            persistContinuations()
        } else {
            removeContinuation(session.id, keepActivity: false)
        }
        schedule(resetAt: resetAt)
    }

    func schedule(resetAt: Date?) {
        pruneExpiredContinuations()
        guard let resetAt else { return }

        let defaultFireDate = resetAt.addingTimeInterval(5 * 60)
        for sessionID in enabledIDs where continuations[sessionID]?.activity.state == .queued {
            if continuations[sessionID]?.activity.scheduledAt == nil {
                updateActivity(ResumeActivity(state: .queued, scheduledAt: defaultFireDate), for: sessionID)
            }
        }

        scheduleNextQueuedContinuation()
    }

    private func scheduleNextQueuedContinuation() {
        timer?.invalidate()
        let queuedTargets = knownSessions.filter {
            enabledIDs.contains($0.id) && continuations[$0.id]?.activity.state == .queued
        }
        guard let fireDate = queuedTargets.compactMap({ continuations[$0.id]?.activity.scheduledAt }).min() else { return }
        let interval = max(1, fireDate.timeIntervalSinceNow)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pruneExpiredContinuations()
                let now = Date()
                let targets = self.knownSessions.filter {
                    self.enabledIDs.contains($0.id) &&
                    self.continuations[$0.id]?.activity.state == .queued &&
                    (self.continuations[$0.id]?.activity.scheduledAt ?? now) <= now
                }
                targets.forEach { self.resume($0) }
                self.scheduleNextQueuedContinuation()
            }
        }
    }

    func open(_ session: CodexSession) {
        guard let url = URL(string: "codex://threads/\(session.id)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func resume(_ session: CodexSession) {
        let startedAt = Date()
        updateActivity(ResumeActivity(state: .starting, scheduledAt: activity(for: session)?.scheduledAt, startedAt: startedAt), for: session.id)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexExecutable)
        let workingDirectoryArguments = originalWorkingDirectory(for: session.id).map { ["-C", $0.path] } ?? []
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
            Task { @MainActor in self?.complete(sessionID: session.id, exitCode: completed.terminationStatus) }
        }

        do {
            try process.run()
            runningProcesses[session.id] = process
            updateActivity(ResumeActivity(state: .running, scheduledAt: activity(for: session)?.scheduledAt, startedAt: startedAt), for: session.id)
            notify(title: "Codex Resets Window", body: "Started the selected Codex session.", identifier: session.id)
        } catch {
            updateActivity(ResumeActivity(
                state: .failed,
                scheduledAt: activity(for: session)?.scheduledAt,
                startedAt: startedAt,
                finishedAt: .now,
                lastOutput: error.localizedDescription
            ), for: session.id)
            notify(title: "Codex Resets Window", body: "Could not start the selected Codex session.", identifier: session.id)
        }
    }

    private func recordOutput(_ text: String, for sessionID: String) {
        let lastLine = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
        guard let lastLine else { return }
        let previous = activities[sessionID]
        updateActivity(ResumeActivity(
            state: .running,
            scheduledAt: previous?.scheduledAt,
            startedAt: previous?.startedAt ?? .now,
            lastOutput: String(lastLine.prefix(120))
        ), for: sessionID)
    }

    private func complete(sessionID: String, exitCode: Int32) {
        runningProcesses.removeValue(forKey: sessionID)
        let previous = activities[sessionID]
        let activity = ResumeActivity(
            state: exitCode == 0 ? .succeeded : .failed,
            scheduledAt: previous?.scheduledAt,
            startedAt: previous?.startedAt,
            finishedAt: .now,
            lastOutput: previous?.lastOutput,
            exitCode: exitCode
        )
        activities[sessionID] = activity

        if exitCode == 0 {
            removeContinuation(sessionID, keepActivity: true)
            notify(title: "Codex Resets Window", body: "Selected Codex session completed.", identifier: "\(sessionID).completed")
        } else {
            updateActivity(activity, for: sessionID)
            notify(title: "Codex Resets Window", body: "Selected Codex session failed (exit \(exitCode)).", identifier: "\(sessionID).completed")
        }
    }

    private func reconcilePersistedTasks() {
        pruneExpiredContinuations()
        for (sessionID, continuation) in continuations {
            guard continuation.activity.state == .starting || continuation.activity.state == .running,
                  let startedAt = continuation.activity.startedAt else { continue }
            switch sessionTaskState(sessionID: sessionID, after: startedAt) {
            case .running:
                if continuation.activity.state == .starting {
                    updateActivity(ResumeActivity(
                        state: .running,
                        scheduledAt: continuation.activity.scheduledAt,
                        startedAt: startedAt,
                        lastOutput: continuation.activity.lastOutput
                    ), for: sessionID)
                }
            case .completed:
                activities[sessionID] = ResumeActivity(
                    state: .succeeded,
                    scheduledAt: continuation.activity.scheduledAt,
                    startedAt: startedAt,
                    finishedAt: .now,
                    lastOutput: continuation.activity.lastOutput,
                    exitCode: 0
                )
                removeContinuation(sessionID, keepActivity: true)
            case .unknown:
                break
            }
        }
    }

    private func updateActivity(_ activity: ResumeActivity, for sessionID: String) {
        activities[sessionID] = activity
        guard var continuation = continuations[sessionID] else { return }
        continuation.activity = activity
        continuations[sessionID] = continuation
        persistContinuations()
    }

    private func removeContinuation(_ sessionID: String, keepActivity: Bool) {
        continuations.removeValue(forKey: sessionID)
        enabledIDs.remove(sessionID)
        if !keepActivity { activities.removeValue(forKey: sessionID) }
        persistContinuations()
    }

    private func pruneExpiredContinuations() {
        let expiredIDs = continuations.compactMap { sessionID, continuation in
            Date().timeIntervalSince(continuation.createdAt) > maximumRetention ? sessionID : nil
        }
        guard !expiredIDs.isEmpty else { return }
        expiredIDs.forEach { removeContinuation($0, keepActivity: false) }
    }

    private func persistContinuations() {
        enabledIDs = Set(continuations.keys)
        guard let data = try? JSONEncoder().encode(continuations) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func loadContinuations(forKey key: String) -> [String: PersistedContinuation] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let continuations = try? JSONDecoder().decode([String: PersistedContinuation].self, from: data) else { return [:] }
        return continuations
    }

    private func notify(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private enum SessionTaskState { case unknown, running, completed }

    private func sessionTaskState(sessionID: String, after startedAt: Date) -> SessionTaskState {
        guard let transcript = transcriptURL(for: sessionID),
              let contents = try? String(contentsOf: transcript, encoding: .utf8) else { return .unknown }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var activeTurnID: String?
        for line in contents.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let timestamp = object["timestamp"] as? String,
                  let eventDate = formatter.date(from: timestamp),
                  eventDate >= startedAt,
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            if type == "task_started" { activeTurnID = payload["turn_id"] as? String }
            if type == "task_complete", activeTurnID == payload["turn_id"] as? String { return .completed }
        }
        return activeTurnID == nil ? .unknown : .running
    }

    private func originalWorkingDirectory(for sessionID: String) -> URL? {
        guard let transcript = transcriptURL(for: sessionID),
              let handle = try? FileHandle(forReadingFrom: transcript),
              let firstLine = try? handle.read(upToCount: 16_384),
              let object = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let path = payload["cwd"] as? String,
              FileManager.default.fileExists(atPath: path) else { return nil }
        defer { try? handle.close() }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func transcriptURL(for sessionID: String) -> URL? {
        let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent.contains(sessionID) && fileURL.pathExtension == "jsonl" {
            return fileURL
        }
        return nil
    }
}
