import AppKit
import Foundation
import UserNotifications

/// Schedules, launches and supervises session continuations.
///
/// Rewritten around four ideas that were missing before:
/// - **One transition entry point.** Every state change goes through `transition`, which rejects
///   illegal moves. Previously `recordOutput` could flip a finished run back to `.running`.
/// - **Failure is recoverable.** A non-zero exit now schedules a bounded retry with exponential
///   backoff instead of stranding the switch in a dead `.failed` state.
/// - **Bounded resources.** At most `maxConcurrent` children run at once, and each one has a
///   watchdog deadline, so a hung CLI can no longer occupy a slot for seven hours.
/// - **Children survive their parent.** Launches are journalled to disk, so a relaunch can tell a
///   still-running process from a dead one instead of leaving an orphan consuming quota.
@MainActor
final class ResumeScheduler: ObservableObject {
    @Published private(set) var activities: [String: ResumeActivity] = [:]
    @Published private(set) var enabledIDs: Set<String> = []

    // MARK: - Dependencies

    private let config: AppConfig
    private let clock: any Clock
    private let store: any ContinuationStoring
    private let launcher: any ProcessLaunching
    private let notifier: any NotificationSending
    private let sessions: SessionStore

    // MARK: - State

    private var records: [String: PersistedContinuation] = [:]
    private var knownSessions: [CodexSession] = []
    private var sessionByID: [String: CodexSession] = [:]
    private var processes: [String: ContinuationProcess] = [:]
    /// Ledger entries adopted after an app restart. We cannot safely recreate a `Process` handle
    /// for them, but must retain their identity across another restart until the PID exits.
    private var adoptedProcesses: [String: ProcessLedgerEntry] = [:]
    private var deadlines: [String: Date] = [:]
    private var transcriptObservations: [String: Observation] = [:]

    private var tickTimer: Timer?
    private var lastReconcileAt: Date = .distantPast
    private var cachedExecutable: (path: String, at: Date)?
    private var ledger: ProcessLedger

    private struct Observation {
        let modificationDate: Date
        let state: SessionTaskState
    }

    // MARK: - Init

    init(config: AppConfig = .default,
         clock: any Clock = SystemClock(),
         store: (any ContinuationStoring)? = nil,
         launcher: (any ProcessLaunching)? = nil,
         notifier: (any NotificationSending)? = nil,
         sessionStore: SessionStore? = nil,
         ledgerURL: URL? = nil) {
        self.config = config
        self.clock = clock
        self.sessions = sessionStore ?? SessionStore(config: config)

        let resolvedStore: any ContinuationStoring
        if let store {
            resolvedStore = store
        } else if let suite = config.defaultsSuite, let sandbox = UserDefaults(suiteName: suite) {
            resolvedStore = UserDefaultsContinuationStore(suite: sandbox)
        } else {
            resolvedStore = UserDefaultsContinuationStore(suite: .standard)
        }
        self.store = resolvedStore

        self.launcher = launcher ?? SystemProcessLauncher()
        self.notifier = notifier ?? (config.isSandbox || config.isHeadless
            ? NullNotificationService()
            : SystemNotificationService())
        self.ledger = ProcessLedger(
            fileURL: ledgerURL ?? ProcessLedger.defaultURL(isSandbox: config.isSandbox)
        )

        records = resolvedStore.load()
        enabledIDs = Set(records.keys)
        activities = records.mapValues(\.activity)

        if !config.isSandbox && !config.isHeadless && NotificationCenterGate.isAvailable {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                AppLog.info("notification authorisation granted=\(granted) error=\(error?.localizedDescription ?? "none")",
                            category: .notification)
            }
        }

        adoptSurvivingProcesses()
        pruneExpired()
        startTimer()
    }

    // MARK: - Queries

    func isEnabled(_ session: CodexSession) -> Bool { enabledIDs.contains(session.id) }
    func activity(for session: CodexSession) -> ResumeActivity? { activities[session.id] }
    func activity(for sessionID: String) -> ResumeActivity? { activities[sessionID] }
    var activeSessionIDs: [String] { Set(processes.keys).union(adoptedProcesses.keys).sorted() }

    /// Sessions that are queued, retrying or running — drives the faster tick cadence.
    var hasActiveWork: Bool {
        let now = clock.now()
        let live = !processes.isEmpty || !adoptedProcesses.isEmpty
        let dueSoon = records.values.contains { record in
            switch record.activity.state {
            case .starting, .running, .retrying: return true
            case .queued: return record.activity.scheduledAt.map { $0 <= now.addingTimeInterval(30) } ?? false
            case .succeeded, .failed: return false
            }
        }
        return live || dueSoon
    }

    func continuationDate(resetAt: Date?) -> Date? {
        guard let resetAt else { return nil }
        return resetAt.addingTimeInterval(config.resetDelay)
    }

    // MARK: - Session list

    func updateSessions(_ updated: [CodexSession]) {
        knownSessions = updated
        sessionByID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        // Keep a readable title on records whose session has disappeared from the index.
        for (id, var record) in records where record.sessionTitle == nil {
            if let session = sessionByID[id] {
                record.sessionTitle = session.displayName
                records[id] = record
            }
        }
        pruneExpired()
        startDueContinuations()
    }

    // MARK: - Scheduling entry points

    /// Applies a freshly fetched reset time to queued continuations. Future queued runs move with
    /// the newest reset; a manually-triggered run that is already due is left untouched.
    ///
    /// Once the reset a run was waiting for has arrived (`now >= scheduledAt - resetDelay`),
    /// the run is frozen: it must fire at its armed time and must not chase the next window.
    /// Without this, a usage refresh landing in the post-reset delay gap moves the target to
    /// the following window, and the continuation perpetually recedes instead of running.
    func schedule(resetAt: Date?) {
        pruneExpired()
        guard let resetAt else { return }
        let target = continuationDate(resetAt: resetAt)
        let now = clock.now()
        for (id, record) in records where record.activity.state == .queued && record.activity.trigger == .reset {
            // A fresh usage response is authoritative for a queued future run. Do not move a
            // manually-triggered run that is already due, or overwrite a retry in flight.
            let resetReached = record.activity.scheduledAt.map {
                $0.addingTimeInterval(-config.resetDelay) <= now
            } ?? false
            guard !resetReached else { continue }
            let shouldUpdate = record.activity.scheduledAt == nil
                || (record.activity.scheduledAt.map { $0 > now } ?? false)
            if shouldUpdate {
                transition(id, to: record.activity.replacing(state: .queued, scheduledAt: target))
            }
        }
        startDueContinuations()
    }

    /// Turns a continuation on or off.
    func setEnabled(_ enabled: Bool, for session: CodexSession, resetAt: Date?) {
        if enabled {
            guard processes[session.id] == nil, adoptedProcesses[session.id] == nil else {
                AppLog.warning("cannot re-arm \(session.id) until its stopping process exits", category: .continuation)
                return
            }
            let target = continuationDate(resetAt: resetAt)
            let activity = ResumeActivity(state: .queued, scheduledAt: target, attempt: 1)
            records[session.id] = PersistedContinuation(
                createdAt: clock.now(),
                activity: activity,
                sessionTitle: session.displayName
            )
            enabledIDs.insert(session.id)
            activities[session.id] = activity
            sessionByID[session.id] = session
            persist()
            AppLog.info("armed continuation for \(session.id) at \(target.map { Formatters.dateTimeString($0) } ?? "unscheduled")",
                        category: .continuation)
        } else {
            stop(session.id, outcome: .cancelled)
            remove(session.id, keepActivity: false)
        }
        schedule(resetAt: resetAt)
        startTimer()
    }

    /// Launches a continuation immediately, regardless of its scheduled time.
    ///
    /// Arms the session first when it is not armed yet, so "Run now" works from a cold start —
    /// previously the button was a no-op unless the toggle had already been flipped.
    func runNow(_ sessionID: String) {
        guard processes[sessionID] == nil, adoptedProcesses[sessionID] == nil else {
            AppLog.warning("run-now ignored for \(sessionID): a process is still live", category: .continuation)
            return
        }
        let activity = ResumeActivity(state: .queued, scheduledAt: clock.now(), attempt: 1, trigger: .manual)
        if var record = records[sessionID] {
            record.activity = activity
            record.createdAt = clock.now()
            record.sessionTitle = record.sessionTitle ?? sessionByID[sessionID]?.displayName
            records[sessionID] = record
        } else {
            records[sessionID] = PersistedContinuation(
                createdAt: clock.now(),
                activity: activity,
                sessionTitle: sessionByID[sessionID]?.displayName
            )
        }
        activities[sessionID] = activity
        enabledIDs.insert(sessionID)
        persist()
        startDueContinuations()
        startTimer()
    }

    /// Schedules another attempt right away after a failure.
    func retryNow(_ sessionID: String) {
        guard let record = records[sessionID], record.activity.state == .failed else { return }
        let attempt = record.activity.attempt + 1
        guard attempt <= config.maxAttempts else { return }
        transition(sessionID, to: ResumeActivity(
            state: .queued,
            scheduledAt: clock.now(),
            startedAt: nil,
            finishedAt: nil,
            lastOutput: nil,
            exitCode: nil,
            attempt: attempt,
            trigger: .manual
        ))
        startDueContinuations()
        startTimer()
    }

    /// Stops a running continuation and abandons it without retrying.
    func stop(_ sessionID: String, outcome: ContinuationOutcome = .cancelled) {
        if let process = processes[sessionID], process.isRunning {
            terminate(process, for: sessionID)
            AppLog.info("stopped child process \(process.pid)", category: .continuation)
        }
        if let adopted = adoptedProcesses[sessionID] {
            terminate(adopted, for: sessionID)
            adoptedProcesses.removeValue(forKey: sessionID)
            AppLog.info("stopped adopted child process \(adopted.pid)", category: .continuation)
        }
        deadlines.removeValue(forKey: sessionID)
        writeLedger()
        guard let record = records[sessionID], !record.activity.state.isTerminal else { return }
        transition(sessionID, to: record.activity.replacing(
            state: .failed,
            finishedAt: clock.now(),
            outcome: outcome
        ))
        if outcome == .cancelled { remove(sessionID, keepActivity: true) }
    }

    /// Terminates every child process. Called when the app quits.
    func shutdown() {
        tickTimer?.invalidate()
        tickTimer = nil
        // There is no run loop after an explicit app quit to deliver the delayed SIGKILL, so
        // terminate children decisively rather than risking an untracked Codex process.
        for (_, process) in processes where process.isRunning { process.stop(force: true) }
        for (_, adopted) in adoptedProcesses { terminate(adopted, force: true) }
        processes.removeAll()
        adoptedProcesses.removeAll()
        deadlines.removeAll()
        writeLedger()
        (store as? UserDefaultsContinuationStore)?.flushNow()
        AppLog.info("scheduler shut down", category: .continuation)
    }

    func open(_ session: CodexSession) {
        guard let url = URL(string: "codex://threads/\(session.id)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Ticking

    private var tickInterval: TimeInterval { hasActiveWork ? 1 : 30 }

    private func startTimer() {
        // Headless runs are driven by `advanceForTesting`, so no timer is installed.
        guard !config.isHeadless else { return }
        let interval = tickInterval
        if let tickTimer, abs(tickTimer.timeInterval - interval) < 0.01 { return }
        tickTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = interval / 4
        tickTimer = timer
    }

    private func tick() {
        let now = clock.now()
        pruneExpired()
        enforceWatchdogs(now: now)
        startDueContinuations()
        if now.timeIntervalSince(lastReconcileAt) >= config.reconcileInterval {
            lastReconcileAt = now
            reconcile()
        }
        startTimer()
    }

    /// Manual advance used by the self-test in place of a timer.
    func advanceForTesting(by interval: TimeInterval) {
        lastReconcileAt = lastReconcileAt.addingTimeInterval(-interval)
        tick()
    }

    // MARK: - Launching

    private func startDueContinuations() {
        let now = clock.now()
        let running = processes.count + adoptedProcesses.count
        var slots = max(0, config.maxConcurrent - running)
        guard slots > 0 else { return }

        let candidates = records
            .filter { _, record in
                let state = record.activity.state
                guard state == .queued || state == .retrying else { return false }
                guard let due = state == .retrying ? record.activity.nextAttemptAt : record.activity.scheduledAt else { return false }
                return due <= now
            }
            .sorted { lhs, rhs in
                let left = lhs.value.activity.state == .retrying
                    ? (lhs.value.activity.nextAttemptAt ?? .distantFuture)
                    : (lhs.value.activity.scheduledAt ?? .distantFuture)
                let right = rhs.value.activity.state == .retrying
                    ? (rhs.value.activity.nextAttemptAt ?? .distantFuture)
                    : (rhs.value.activity.scheduledAt ?? .distantFuture)
                return left < right
            }

        for (sessionID, _) in candidates where slots > 0 {
            guard let session = sessionByID[sessionID] else {
                AppLog.warning("continuation \(sessionID) is no longer in the session index", category: .continuation)
                transition(sessionID, to: ResumeActivity(
                    state: .failed,
                    scheduledAt: records[sessionID]?.activity.scheduledAt,
                    finishedAt: now,
                    lastOutput: ContinuationOutcome.missingSession.label,
                    attempt: records[sessionID]?.activity.attempt ?? 1,
                    outcome: .missingSession,
                    trigger: records[sessionID]?.activity.trigger ?? .reset
                ))
                notify(title: "Codex Resets Window",
                       body: "A selected session is no longer available locally.",
                       identifier: "\(sessionID).missing-session",
                       urgent: true)
                continue
            }
            guard processes[sessionID] == nil else { continue }
            launch(session)
            slots -= 1
        }
    }

    private func launch(_ session: CodexSession) {
        let now = clock.now()
        let attempt = records[session.id]?.activity.attempt ?? 1

        guard let executable = codexExecutable() else {
            AppLog.error("no Codex CLI found", category: .continuation)
            transition(session.id, to: ResumeActivity(
                state: .failed,
                scheduledAt: records[session.id]?.activity.scheduledAt,
                startedAt: nil,
                finishedAt: now,
                lastOutput: CodexDataError.missingLogin.errorDescription.map { _ in "Codex CLI not found" } ?? "Codex CLI not found",
                attempt: attempt,
                outcome: .missingCLI,
                trigger: records[session.id]?.activity.trigger ?? .reset
            ))
            notify(title: "Codex Resets Window", body: "The Codex CLI could not be found.", identifier: "\(session.id).missing-cli", urgent: true)
            return
        }

        let workingDirectory = sessions.workingDirectory(for: session.id)
        let needsGitBypass = workingDirectory.map { !SessionStore.isInsideGitRepository($0) } ?? true
        var arguments: [String] = []
        if executable == "/usr/bin/env" { arguments.append("codex") }
        if let workingDirectory {
            arguments += ["-C", workingDirectory.path]
        }
        arguments += ["exec", "resume"]
        if needsGitBypass { arguments.append("--skip-git-repo-check") }
        arguments += [session.id, buildPrompt(for: session)]

        transition(session.id, to: ResumeActivity(
            state: .starting,
            scheduledAt: records[session.id]?.activity.scheduledAt,
            startedAt: now,
            attempt: attempt,
            trigger: records[session.id]?.activity.trigger ?? .reset
        ))

        let request = LaunchRequest(
            sessionID: session.id,
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: Self.childEnvironment(codexHome: config.codexHome)
        )

        do {
            let process = try launcher.launch(request: request) { [weak self] text in
                Task { @MainActor in self?.recordOutput(text, for: session.id, attempt: attempt) }
            } onExit: { [weak self] code in
                Task { @MainActor in self?.complete(sessionID: session.id, exitCode: code, attempt: attempt) }
            }
            processes[session.id] = process
            if config.maxRuntime > 0 {
                deadlines[session.id] = now.addingTimeInterval(config.maxRuntime)
            }
            writeLedger()
            transition(session.id, to: (activities[session.id] ?? ResumeActivity(state: .starting))
                .replacing(state: .running, startedAt: now))
            let detail = workingDirectory == nil ? " using a safe no-project fallback." : "."
            AppLog.info("launched continuation for \(session.id) attempt \(attempt)", category: .continuation)
            notify(title: "Codex Resets Window",
                   body: "Started the selected Codex session\(detail)",
                   identifier: "\(session.id).started",
                   urgent: false)
        } catch {
            handleFailure(sessionID: session.id, exitCode: nil, outcome: .launchError, detail: error.localizedDescription)
        }
    }

    /// The prompt sent to the resumed session.
    ///
    /// "Rich context" mode borrows an idea from `aqua5230/usage`: instead of a bare `continue`,
    /// hand the model a short bundle of recent requests from the transcript. The intelligence still lives in
    /// the model's reply — the app only supplies facts, and it caps every field so a prompt can
    /// never balloon into a process argument or leak a large chunk of conversation.
    func buildPrompt(for session: CodexSession) -> String {
        let base = config.continuationPrompt
        guard config.richContextContinuation,
              let transcript = sessions.transcriptURL(for: session.id) else { return base }
        let requests = SessionStore.recentRequests(
            in: transcript,
            limit: config.richContextRequests,
            characterBudget: config.richContextCharacters
        )
        guard !requests.isEmpty else { return base }
        let bulletList = requests.enumerated().map { index, text in "\(index + 1). \(text)" }.joined(separator: "\n")
        return """
        \(base)

        Continue from where this session stopped. The most recent requests, newest first, were:
        \(bulletList)
        """
    }

    private func recordOutput(_ text: String, for sessionID: String, attempt: Int) {
        guard let line = TextFormat.lastMeaningfulLine(text) else { return }
        guard let current = activities[sessionID] else { return }
        // A process from an earlier attempt can flush output after a retry has started. Never
        // let its stale output overwrite the status of the newer attempt.
        guard current.attempt == attempt else { return }
        // Output arriving after the run finished must not resurrect a terminal state.
        guard current.state == .starting || current.state == .running else { return }
        transition(sessionID, to: current.replacing(state: .running, lastOutput: line))
    }

    private func complete(sessionID: String, exitCode: Int32, attempt: Int) {
        // A delayed termination callback belongs to the process which launched this attempt,
        // not to a queued retry or a freshly re-armed run. Treat it as an audit event only.
        guard let activity = activities[sessionID], activity.attempt == attempt,
              activity.state == .starting || activity.state == .running else {
            // A stopped or timed-out process remains in `processes` until its actual exit so it
            // still occupies a concurrency slot. Release that slot only once this callback
            // confirms the tracked handle has stopped.
            if let process = processes[sessionID], !process.isRunning {
                processes.removeValue(forKey: sessionID)
                deadlines.removeValue(forKey: sessionID)
                writeLedger()
                startDueContinuations()
            }
            AppLog.info("ignoring stale exit \(exitCode) for \(sessionID) attempt \(attempt)",
                        category: .continuation)
            return
        }
        processes.removeValue(forKey: sessionID)
        adoptedProcesses.removeValue(forKey: sessionID)
        deadlines.removeValue(forKey: sessionID)
        transcriptObservations.removeValue(forKey: sessionID)
        writeLedger()
        // A late exit for a run that already reached a terminal state must not overwrite the
        // recorded outcome. This happens after a watchdog kill or a manual stop: the child reports
        // its signal-induced exit *after* we have already settled on "timed out" or "cancelled".
        if let state = activities[sessionID]?.state, state.isTerminal {
            AppLog.info("ignoring late exit \(exitCode) for \(sessionID); already \(state.rawValue)",
                        category: .continuation)
            return
        }
        if exitCode == 0 {
            finishSucceeded(sessionID: sessionID)
        } else {
            handleFailure(sessionID: sessionID, exitCode: exitCode, outcome: .exitCode, detail: nil)
        }
        startDueContinuations()
    }

    private func finishSucceeded(sessionID: String) {
        let now = clock.now()
        let previous = activities[sessionID]
        transition(sessionID, to: ResumeActivity(
            state: .succeeded,
            scheduledAt: previous?.scheduledAt,
            startedAt: previous?.startedAt,
            finishedAt: now,
            lastOutput: previous?.lastOutput,
            exitCode: 0,
            attempt: previous?.attempt ?? 1,
            outcome: .none
        ))
        notify(title: "Codex Resets Window",
               body: "Selected Codex session completed.",
               identifier: "\(sessionID).completed",
               urgent: false)
        remove(sessionID, keepActivity: true)
    }

    private func handleFailure(sessionID: String,
                               exitCode: Int32?,
                               outcome: ContinuationOutcome,
                               detail: String?,
                               preserveProcess: Bool = false) {
        let now = clock.now()
        let previous = activities[sessionID]
        let attempt = previous?.attempt ?? 1
        if !preserveProcess { processes.removeValue(forKey: sessionID) }
        deadlines.removeValue(forKey: sessionID)
        writeLedger()

        let message: String = {
            if let detail, !detail.isEmpty { return TextFormat.lastMeaningfulLine(detail) ?? outcome.label }
            if let exitCode { return Self.failureMessage(exitCode: exitCode, lastOutput: previous?.lastOutput) }
            return outcome.label
        }()

        if attempt < config.maxAttempts {
            let normalBackoff = config.backoffDelay(forAttempt: attempt + 1)
            // A watchdog-terminated child holds its concurrency slot until the SIGTERM/SIGKILL
            // callback arrives. Do not make a retry due before the configured kill grace either.
            let delay = outcome == .timeout ? max(normalBackoff, config.killGrace) : normalBackoff
            let next = now.addingTimeInterval(delay)
            transition(sessionID, to: ResumeActivity(
                state: .retrying,
                scheduledAt: previous?.scheduledAt,
                startedAt: previous?.startedAt,
                finishedAt: nil,
                lastOutput: message,
                exitCode: exitCode,
                attempt: attempt + 1,
                nextAttemptAt: next,
                outcome: outcome,
                trigger: previous?.trigger ?? .reset
            ))
            AppLog.warning("continuation \(sessionID) attempt \(attempt) failed (\(message)); retry \(attempt + 1) at \(Formatters.timeString(next))",
                           category: .continuation)
            notify(title: "Codex Resets Window",
                   body: "Continuation failed (\(message)). Retry \(attempt + 1) of \(config.maxAttempts) at \(Formatters.timeString(next)).",
                   identifier: "\(sessionID).retry",
                   urgent: false)
        } else {
            transition(sessionID, to: ResumeActivity(
                state: .failed,
                scheduledAt: previous?.scheduledAt,
                startedAt: previous?.startedAt,
                finishedAt: now,
                lastOutput: message,
                exitCode: exitCode,
                attempt: attempt,
                outcome: outcome,
                trigger: previous?.trigger ?? .reset
            ))
            AppLog.error("continuation \(sessionID) gave up after \(attempt) attempt(s): \(message)",
                         category: .continuation)
            notify(title: "Codex Resets Window",
                   body: "Continuation failed after \(attempt) attempts: \(message)",
                   identifier: "\(sessionID).failed",
                   urgent: true)
        }
        startTimer()
    }

    /// Why a child died, in words the user can act on.
    ///
    /// The old code reported only "Exited with code N" and discarded the child's own last line.
    /// That hid the most useful fact in this subsystem: an npm-installed `codex` is a
    /// `#!/usr/bin/env node` script, so a child `PATH` without `node` yields a bare 127 while the
    /// real reason (`env: node: No such file or directory`) never reaches the UI.
    private static func failureMessage(exitCode: Int32, lastOutput: String?) -> String {
        let tail = lastOutput.flatMap { TextFormat.lastMeaningfulLine($0) }
        if exitCode == 127 {
            return tail.map { "Codex CLI could not start: \($0)" }
                ?? "Codex CLI could not start (exit 127): it or its runtime is not on the app PATH"
        }
        if let tail, !tail.isEmpty { return "\(tail) (exit \(exitCode))" }
        return "Exited with code \(exitCode)"
    }

    // MARK: - Watchdog

    private func enforceWatchdogs(now: Date) {
        guard config.maxRuntime > 0 else { return }
        for (sessionID, deadline) in deadlines where deadline <= now {
            guard let process = processes[sessionID] else {
                if let adopted = adoptedProcesses[sessionID] {
                    AppLog.warning("adopted continuation \(sessionID) exceeded the runtime cap; terminating",
                                   category: .continuation)
                    terminate(adopted, for: sessionID)
                    adoptedProcesses.removeValue(forKey: sessionID)
                    deadlines.removeValue(forKey: sessionID)
                    handleFailure(sessionID: sessionID, exitCode: nil, outcome: .timeout,
                                  detail: "Timed out after \(TextFormat.countdown(config.maxRuntime))")
                } else {
                    deadlines.removeValue(forKey: sessionID)
                }
                continue
            }
            AppLog.warning("continuation \(sessionID) exceeded the \(Int(config.maxRuntime))s runtime cap; terminating",
                           category: .continuation)
            terminate(process, for: sessionID)
            deadlines.removeValue(forKey: sessionID)
            let previous = activities[sessionID]
            handleFailure(
                sessionID: sessionID,
                exitCode: previous?.exitCode,
                outcome: .timeout,
                detail: "Timed out after \(TextFormat.countdown(config.maxRuntime))",
                preserveProcess: true
            )
        }
    }

    /// Ask a child to exit cleanly, then enforce the configured hard-stop grace period.
    ///
    /// `Process.terminate()` is only SIGTERM; a stuck CLI can ignore it. The previous scheduler
    /// advertised a SIGKILL grace period but never executed it, allowing a stale child to overlap
    /// a later retry. Completion callbacks carry the launch attempt, so a late exit is harmless.
    private func terminate(_ process: ContinuationProcess, for sessionID: String) {
        process.stop(force: false)
        let grace = config.killGrace
        guard grace > 0 else {
            if process.isRunning { process.stop(force: true) }
            return
        }
        Task { @MainActor [weak process] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard let process, process.isRunning else { return }
            AppLog.warning("continuation \(sessionID) ignored SIGTERM; sending SIGKILL", category: .continuation)
            process.stop(force: true)
        }
    }

    private func terminate(_ entry: ProcessLedgerEntry, for sessionID: String) {
        terminate(entry, force: false)
        let grace = config.killGrace
        guard grace > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard ProcessLedger.matches(entry), ProcessLedger.isAlive(pid: entry.pid) else { return }
            AppLog.warning("adopted continuation \(sessionID) ignored SIGTERM; sending SIGKILL", category: .continuation)
            terminate(entry, force: true)
        }
    }

    private func terminate(_ entry: ProcessLedgerEntry, force: Bool) {
        guard ProcessLedger.matches(entry) else {
            AppLog.warning("refusing to signal PID \(entry.pid): process identity no longer matches", category: .continuation)
            return
        }
        kill(entry.pid, force ? SIGKILL : SIGTERM)
    }

    // MARK: - Reconciliation

    private func reconcile() {
        let now = clock.now()
        reconcileAdoptedProcesses(now: now)
        for (sessionID, record) in records {
            switch record.activity.state {
            case .starting, .running:
                reconcileLive(sessionID: sessionID, record: record, now: now)
            case .failed, .succeeded, .queued, .retrying:
                break
            }
        }
    }

    private func reconcileLive(sessionID: String, record: PersistedContinuation, now: Date) {
        guard let startedAt = record.activity.startedAt else { return }
        // We are actively supervising this process; nothing to reconcile.
        if processes[sessionID] != nil || adoptedProcesses[sessionID] != nil { return }

        guard let transcript = sessions.transcriptURL(for: sessionID),
              let attributes = try? FileManager.default.attributesOfItem(atPath: transcript.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            // No transcript at all: the session vanished. Give up rather than retry forever.
            if record.activity.state == .running || record.activity.state == .starting {
                handleFailure(sessionID: sessionID, exitCode: nil, outcome: .missingSession, detail: nil)
            }
            return
        }
        if let observation = transcriptObservations[sessionID], observation.modificationDate == modificationDate {
            applyReconciledState(sessionID: sessionID, state: observation.state, now: now)
            return
        }
        let state = SessionStore.taskState(in: transcript, after: startedAt)
        transcriptObservations[sessionID] = Observation(modificationDate: modificationDate, state: state)
        applyReconciledState(sessionID: sessionID, state: state, now: now)
    }

    private func reconcileAdoptedProcesses(now: Date) {
        for (sessionID, entry) in Array(adoptedProcesses) {
            guard !ProcessLedger.isAlive(pid: entry.pid) else { continue }
            adoptedProcesses.removeValue(forKey: sessionID)
            deadlines.removeValue(forKey: sessionID)
            guard let record = records[sessionID] else { continue }
            let state: SessionTaskState
            if let startedAt = record.activity.startedAt,
               let transcript = sessions.transcriptURL(for: sessionID) {
                state = SessionStore.taskState(in: transcript, after: startedAt)
            } else {
                state = .unknown
            }
            if state == .completed {
                applyReconciledState(sessionID: sessionID, state: .completed, now: now)
            } else {
                handleFailure(sessionID: sessionID, exitCode: nil, outcome: .exitCode,
                              detail: "Adopted Codex process exited before task completion")
            }
        }
        writeLedger()
    }

    private func applyReconciledState(sessionID: String, state: SessionTaskState, now: Date) {
        guard let record = records[sessionID] else { return }
        switch state {
        case .running:
            if record.activity.state == .starting {
                transition(sessionID, to: record.activity.replacing(state: .running))
            }
        case .completed:
            let previous = record.activity
            transition(sessionID, to: previous.replacing(
                state: .succeeded,
                startedAt: previous.startedAt ?? now,
                finishedAt: now,
                exitCode: 0,
                outcome: ContinuationOutcome.none
            ))
            adoptedProcesses.removeValue(forKey: sessionID)
            AppLog.info("reconciled continuation \(sessionID) as completed from its transcript", category: .continuation)
            notify(title: "Codex Resets Window",
                   body: "Selected Codex session completed.",
                   identifier: "\(sessionID).completed",
                   urgent: false)
            remove(sessionID, keepActivity: true)
        case .unknown:
            break
        }
    }

    // MARK: - Orphan handling

    /// Checks the ledger written by a previous launch and decides what to do with each entry.
    private func adoptSurvivingProcesses() {
        let entries = ledger.read()
        guard !entries.isEmpty else { return }
        var survivors: [ProcessLedgerEntry] = []
        for entry in entries {
            if ProcessLedger.isAlive(pid: entry.pid) {
                // A previous instance's child is still running. Do not launch a second one; let
                // reconciliation follow the transcript instead. Keep the entry: a second app
                // crash before the child exits must not forget that it already exists.
                AppLog.warning("found a surviving child process \(entry.pid) for \(entry.sessionID)",
                               category: .continuation)
                guard records[entry.sessionID] != nil else {
                    AppLog.warning("found orphan process \(entry.pid) without a continuation record; attempting identity-checked termination",
                                   category: .continuation)
                    terminate(entry, for: entry.sessionID)
                    continue
                }
                survivors.append(entry)
                adoptedProcesses[entry.sessionID] = entry
                if config.maxRuntime > 0 {
                    deadlines[entry.sessionID] = entry.launchedAt.addingTimeInterval(config.maxRuntime)
                }
                continue
            }
            guard let record = records[entry.sessionID] else { continue }
            if record.activity.state == .starting || record.activity.state == .running {
                AppLog.info("child process \(entry.pid) for \(entry.sessionID) is gone; reconciling",
                            category: .continuation)
                transcriptObservations.removeValue(forKey: entry.sessionID)
            }
        }
        if survivors.isEmpty { ledger.clear() } else { ledger.write(survivors) }
    }

    private func writeLedger() {
        adoptedProcesses = adoptedProcesses.filter { ProcessLedger.isAlive(pid: $0.value.pid) }
        let liveEntries = processes.compactMap { sessionID, process -> ProcessLedgerEntry? in
            guard process.isRunning else { return nil }
            return ProcessLedgerEntry(
                sessionID: sessionID,
                pid: process.pid,
                launchedAt: activities[sessionID]?.startedAt ?? clock.now()
            )
        }
        let trackedIDs = Set(liveEntries.map(\.sessionID))
        let entries = liveEntries + adoptedProcesses.values.filter { !trackedIDs.contains($0.sessionID) }
        if entries.isEmpty {
            ledger.clear()
        } else {
            ledger.write(entries)
        }
    }

    // MARK: - State machine

    /// Legal transitions. Terminal states are one-way unless the user re-arms the switch.
    private func canTransition(from: ResumeRunState, to: ResumeRunState) -> Bool {
        if from == to { return true }
        switch (from, to) {
        case (.queued, .starting), (.queued, .failed), (.queued, .succeeded):
            return true
        case (.starting, .running), (.starting, .retrying), (.starting, .failed), (.starting, .succeeded):
            return true
        case (.running, .retrying), (.running, .failed), (.running, .succeeded):
            return true
        case (.retrying, .starting), (.retrying, .failed), (.retrying, .succeeded):
            return true
        case (.failed, .queued):
            // Only an explicit user retry may leave the failed state.
            return true
        default:
            return false
        }
    }

    private func transition(_ sessionID: String, to activity: ResumeActivity) {
        if let current = activities[sessionID], !canTransition(from: current.state, to: activity.state) {
            AppLog.warning("rejected illegal transition \(current.state.rawValue) -> \(activity.state.rawValue) for \(sessionID)",
                           category: .continuation)
            return
        }
        activities[sessionID] = activity
        if var record = records[sessionID] {
            record.activity = activity
            records[sessionID] = record
        } else {
            records[sessionID] = PersistedContinuation(createdAt: clock.now(), activity: activity)
        }
        enabledIDs = Set(records.keys)
        persist()
    }

    private func remove(_ sessionID: String, keepActivity: Bool) {
        records.removeValue(forKey: sessionID)
        enabledIDs.remove(sessionID)
        // A manually stopped process may still be consuming its SIGTERM grace period. Keep its
        // handle (and therefore its concurrency slot) until the termination callback confirms it
        // is gone; otherwise an immediate re-arm could create two Codex children.
        if processes[sessionID]?.isRunning != true { processes.removeValue(forKey: sessionID) }
        deadlines.removeValue(forKey: sessionID)
        transcriptObservations.removeValue(forKey: sessionID)
        if !keepActivity { activities.removeValue(forKey: sessionID) }
        writeLedger()
        persist()
    }

    private func pruneExpired() {
        let now = clock.now()
        var expired: [String] = []
        for (sessionID, record) in records {
            let age = now.timeIntervalSince(record.createdAt)
            let terminal = record.activity.state.isTerminal
            let olderThanRetention = age > config.retention
            // A record whose session vanished from the index is dead weight; give it a grace
            // period in case the index simply has not been refreshed yet, then drop it.
            let orphaned = sessionByID[sessionID] == nil && !knownSessions.isEmpty && age > config.retention
            if olderThanRetention || (terminal && orphaned) {
                expired.append(sessionID)
            }
        }
        guard !expired.isEmpty else { return }
        for sessionID in expired {
            AppLog.info("pruning continuation record \(sessionID)", category: .continuation)
            remove(sessionID, keepActivity: false)
        }
    }

    private func persist() {
        store.save(records)
    }

    // MARK: - CLI discovery

    /// Locates the Codex CLI, caching the result so resume does not stat four paths every time.
    func codexExecutable() -> String? {
        if let override = config.codexExecutableOverride, !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let now = clock.now()
        if let cached = cachedExecutable, now.timeIntervalSince(cached.at) < 60 {
            return cached.path
        }
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/Applications/Codex.app/Contents/Resources/codex",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/opt/local/bin/codex"
        ]
        let resolved = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        let fallback = resolved ?? (ToolchainPaths.locate("codex").map { _ in "/usr/bin/env" })
        if let fallback { cachedExecutable = (fallback, now) }
        if let resolved {
            AppLog.info("codex CLI resolved to \(resolved)", category: .continuation)
        } else if fallback != nil {
            // `/usr/bin/env codex` only works because the child receives ToolchainPaths.value.
            // Without a node runtime on that PATH an npm-installed codex exits 127 immediately.
            AppLog.warning("no bundled Codex CLI found; using PATH (node runtime on child PATH: \(ToolchainPaths.hasNodeRuntime()))",
                           category: .continuation)
        } else {
            AppLog.error("no Codex CLI found on \(ToolchainPaths.value)", category: .continuation)
        }
        return fallback
    }

    /// Keep the resumed CLI in the same account/configuration as the dashboard while excluding
    /// app-only flags and secrets that should never leak into a child process.
    private static func childEnvironment(codexHome: URL) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            // Not the app's own PATH: launchd's minimal PATH cannot run an npm-installed CLI.
            "PATH": ToolchainPaths.value,
            "HOME": inherited["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
            "CODEX_HOME": codexHome.path
        ]
        for key in ["TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "SSH_AUTH_SOCK",
                    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR"] {
            if let value = inherited[key], !value.isEmpty { environment[key] = value }
        }
        return environment
    }

    /// Resolves a binary through `PATH` without spawning a shell.
    private static func locateOnPATH(_ name: String) -> Bool {
        ToolchainPaths.locate(name) != nil
    }

    // MARK: - Notifications

    private func notify(title: String, body: String, identifier: String, urgent: Bool) {
        notifier.post(title: title, body: body, identifier: identifier, urgent: urgent)
    }
}
