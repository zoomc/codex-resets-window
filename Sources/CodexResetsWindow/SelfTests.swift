import Foundation

/// The test suite backing `--selftest`.
///
/// Cases are grouped by the behaviour they pin down. Anything here must be deterministic and free
/// of network access: the fake launcher, the mutable clock and the in-memory store replace every
/// external dependency.
/// Everything here touches `ResumeScheduler`, which is `@MainActor`, so the whole suite runs on
/// the main actor. That is also how the app itself behaves.
@MainActor
enum SelfTests {
    static func run(filter: String? = nil, verbose: Bool = false) async -> TestRunner {
        var runner = TestRunner(verbose: verbose)
        let cases: [(String, (inout TestRunner) async -> Void)] = [
            ("stateMachine", testStateMachine),
            ("stateMachineRejectsResurrection", testStateMachineRejectsResurrection),
            ("retryBackoff", testRetryBackoff),
            ("retryGivesUpAfterMaxAttempts", testRetryGivesUpAfterMaxAttempts),
            ("runNowIsIdempotentWhileLive", testRunNowIsIdempotentWhileLive),
            ("successClearsTheContinuation", testSuccessClearsTheContinuation),
            ("missingSessionFailsOnce", testMissingSessionFailsOnce),
            ("queuedScheduleTracksResetChanges", testQueuedScheduleTracksResetChanges),
            ("resetReachedRunDoesNotMove", testResetReachedRunDoesNotMove),
            ("concurrencyLimit", testConcurrencyLimit),
            ("watchdogTerminatesHungRun", testWatchdogTerminatesHungRun),
            ("stopDoesNotRetry", testStopDoesNotRetry),
            ("staleContinuationIsPruned", testStaleContinuationIsPruned),
            ("reconciliationCompletesFromTranscript", testReconciliationCompletesFromTranscript),
            ("backoffMath", testBackoffMath),
            ("quotaWarningFiresOnce", testQuotaWarningFiresOnce),
            ("quotaResetRestoresAndRearms", testQuotaResetRestoresAndRearms),
            ("quotaDepletion", testQuotaDepletion),
            ("burnETARequiresEnoughData", testBurnETARequiresEnoughData),
            ("burnETAComputesDrainRate", testBurnETAComputesDrainRate),
            ("paceComparesAgainstBaseline", testPaceComparesAgainstBaseline),
            ("gitRepositoryDetection", testGitRepositoryDetection),
            ("transcriptPathDerivation", testTranscriptPathDerivation),
            ("sqliteWorkingDirectoryFallback", testSQLiteWorkingDirectoryFallback),
            ("continuationStoreMigratesLegacy", testContinuationStoreMigratesLegacy),
            ("continuationRecordRoundTrip", testContinuationRecordRoundTrip),
            ("richContextPrompt", testRichContextPrompt),
            ("plainPromptStaysPlain", testPlainPromptStaysPlain),
            ("taskStateRequiresMatchingStart", testTaskStateRequiresMatchingStart),
            ("tokenUsageParsing", testTokenUsageParsing),
            ("textHelpers", testTextHelpers),
            ("logRedaction", testLogRedaction),
            ("usageDecodingToleratesChange", testUsageDecodingToleratesChange),
            ("usageDecoding", testUsageDecoding),
            ("environmentOverrides", testEnvironmentOverrides),
            ("processLedgerLifecycle", testProcessLedgerLifecycle)
        ]

        for (name, body) in cases {
            if let filter, !name.localizedCaseInsensitiveContains(filter) { continue }
            runner.begin(name)
            await body(&runner)
        }
        return runner
    }

    // MARK: - Fixtures

    private static func makeConfig() -> AppConfig {
        var config = AppConfig()
        config.isHeadless = true
        config.isSandbox = true
        config.defaultsSuite = nil
        config.resetDelay = 0
        config.maxConcurrent = 1
        config.maxAttempts = 3
        config.backoffBase = 30
        config.backoffCap = 600
        config.maxRuntime = 0
        config.reconcileInterval = 100_000
        config.retention = 3_600
        return config
    }

    private static func makeSession(_ id: String = UUID().uuidString) -> CodexSession {
        CodexSession(id: id, threadName: "Test session", updatedAt: Date())
    }

    private static func makeScheduler(
        config: AppConfig,
        clock: MutableClock,
        launcher: FakeProcessLauncher,
        store: MemoryContinuationStore = MemoryContinuationStore(),
        sessions: [CodexSession],
        ledgerURL: URL? = nil
    ) -> ResumeScheduler {
        let scheduler = ResumeScheduler(
            config: config,
            clock: clock,
            store: store,
            launcher: launcher,
            notifier: NullNotificationService(),
            sessionStore: SessionStore(config: config),
            ledgerURL: ledgerURL ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("crw-ledger-\(UUID().uuidString).json")
        )
        scheduler.updateSessions(sessions)
        return scheduler
    }

    // MARK: - State machine

    private static func testStateMachine(_ runner: inout TestRunner) async {
        let clock = MutableClock(startingAt: Date(timeIntervalSince1970: 1_800_000_000))
        let launcher = FakeProcessLauncher()
        let session = makeSession()
        launcher.setOutcome(.init(exitCodes: [0], duration: 0, writesTranscriptEvents: false), for: session.id)
        let scheduler = makeScheduler(config: makeConfig(), clock: clock, launcher: launcher, sessions: [session])

        scheduler.setEnabled(true, for: session, resetAt: clock.now())
        runner.expectEqual(scheduler.activity(for: session)?.state, .running, "arming a due continuation launches it")
        launcher.advance(by: 1)
        await settle()
        runner.expectEqual(scheduler.activity(for: session)?.state, .succeeded, "exit 0 completes the run")
        runner.expectEqual(scheduler.activity(for: session)?.exitCode, 0)
        runner.expectFalse(scheduler.isEnabled(session), "a completed continuation disarms itself")
    }

    /// The original bug: output arriving after termination flipped a finished run back to running.
    private static func testStateMachineRejectsResurrection(_ runner: inout TestRunner) async {
        let clock = MutableClock(startingAt: Date(timeIntervalSince1970: 1_800_000_000))
        let launcher = FakeProcessLauncher()
        let session = makeSession()
        launcher.setOutcome(.init(exitCodes: [0], duration: 0, writesTranscriptEvents: false), for: session.id)
        let scheduler = makeScheduler(config: makeConfig(), clock: clock, launcher: launcher, sessions: [session])

        scheduler.setEnabled(true, for: session, resetAt: clock.now())
        launcher.advance(by: 1)
        await settle()
        runner.expectEqual(scheduler.activity(for: session)?.state, .succeeded)

        // Late output must not resurrect a terminal state.
        launcher.advance(by: 1)
        await settle()
        runner.expectEqual(scheduler.activity(for: session)?.state, .succeeded, "terminal state is one-way")
    }

    // MARK: - Retry

    private static func testRetryBackoff(_ runner: inout TestRunner) async {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = MutableClock(startingAt: start)
        let launcher = FakeProcessLauncher()
        let session = makeSession()
        launcher.setOutcome(.init(exitCodes: [1], duration: 0, writesTranscriptEvents: false), for: session.id)
        let scheduler = makeScheduler(config: makeConfig(), clock: clock, launcher: launcher, sessions: [session])

        scheduler.setEnabled(true, for: session, resetAt: clock.now())
        runner.expectEqual(scheduler.activity(for: session)?.attempt, 1)
        launcher.advance(by: 1)
        await settle()

        guard let retrying = scheduler.activity(for: session) else {
            runner.expect(false, "expected an activity after the first failure")
            return
        }
        runner.expectEqual(retrying.state, .retrying, "a failed attempt schedules a retry")
        runner.expectEqual(retrying.attempt, 2, "attempt counter advances")
        // The fake clock is separate from the scheduler clock, so the failure lands at `start`.
        // backoffDelay(2) = 30 * 2^0 = 30
        runner.expectAlmost(retrying.nextAttemptAt?.timeIntervalSince(start) ?? -1, 30, tolerance: 0.5,
                            "first backoff is 30s after the failure")

        // Advancing the clock past the retry time relaunches.
        clock.advance(40)
        scheduler.advanceForTesting(by: 0)
        await settle()
        runner.expectEqual(scheduler.activity(for: session)?.state, .running, "the retry launches when due")
        runner.expectEqual(scheduler.activity(for: session)?.attempt, 2, "attempt stays at 2 while running")

        launcher.advance(by: 1)
        await settle()
        // backoffDelay(3) = 30 * 2^1 = 60
        guard let secondRetry = scheduler.activity(for: session) else {
            runner.expect(false, "expected an activity after the second failure")
            return
        }
        runner.expectEqual(secondRetry.attempt, 3)
        // The retry launched at start+40 and failed there; backoffDelay(3) = 30 * 2^1 = 60.
        runner.expectAlmost(secondRetry.nextAttemptAt?.timeIntervalSince(start) ?? -1, 40 + 60, tolerance: 0.5,
                            "second backoff doubles to 60s")
    }

    private static func testRetryGivesUpAfterMaxAttempts(_ runner: inout TestRunner) async {
        let clock = MutableClock(startingAt: Date(timeIntervalSince1970: 1_800_000_000))
        var config = makeConfig()
        config.maxAttempts = 3
        let launcher = FakeProcessLauncher()
        let session = makeSession()
        launcher.setOutcome(.init(exitCodes: [1], duration: 0, writesTranscriptEvents: false), for: session.id)
        let scheduler = makeScheduler(config: config, clock: clock, launcher: launcher, sessions: [session])

        scheduler.setEnabled(true, for: session, resetAt: clock.now())
        for step in 0..<3 {
            launcher.advance(by: 1)
            await settle()
            if step < 2 {
                clock.advance(600)
                scheduler.advanceForTesting(by: 0)
                await settle()
            }
        }
        runner.expectEqual(scheduler.activity(for: session)?.state, .failed, "gives up after the configured attempts")
        runner.expectEqual(scheduler.activity(for: session)?.attempt, 3)
        runner.expectEqual(launcher.launchedRequests.count, 3, "exactly three launches")
    }

    private static func testRunNowIsIdempotentWhileLive(_ runner: inout TestRunner) async {
        let clock = MutableClock(startingAt: Date(timeIntervalSince1970: 1_800_000_000))
        let launcher = FakeProcessLauncher()
        let session = makeSession()
        launcher.setOutcome(.init(writesTranscriptEvents: false, hangs: true), for: session.id)
        let scheduler = makeScheduler(config: makeConfig(), clock: clock, launcher: launcher, sessions: [session])

        scheduler.runNow(session.id)
        scheduler.runNow(session.id)
        runner.expectEqual(launcher.launchedRequests.count, 1, "run now does not duplicate a live child")
        runner.expectEqual(scheduler.activity(for: session)?.state, .running)
    }

    private static func testSuccessClearsTheContinuation(_ runner: inout TestRunner) async {
        let clock = MutableClock(startingAt: Date(timeIntervalSince1970: 1_800_000_000))
        let launcher = FakeProcessLauncher()
        let session = makeSession()
        launcher.setOutcome(.init(exitCodes: [0], duration: 0, writesTranscriptEvents: false), for: session.id)
        let store = MemoryContinuationStore()
        let scheduler = makeScheduler(config: makeConfig(), clock: clock, launcher: launcher, store: store, sessions: [session])

        scheduler.setEnabled(true, for: session, resetAt: clock.now())
        launcher.advance(by: 1)
        await settle()
        runner.expectFalse(scheduler.isEnabled(session), "success disarms the switch")
        runner.expectNotNil(scheduler.activity(for: session), "the completed status stays visible")
        runner.expectEqual(scheduler.activity(for: session)?.state, .succeeded)
    }

    private static func testMissingSessionFailsOnce(_ runner: inout TestRunner) async {
        let clock = MutableClock(startingAt: Date(timeIntervalSince1970: 1_800_000_000))
        let missingID = UUID().uuidString
        let store = MemoryContinuationStore(records: [
            missingID: PersistedContinuation(
                createdAt: clock.now(),
                activity: ResumeActivity(state: .queued, scheduledAt: clock.now())
            )
        ])
        let launcher = FakeProcessLauncher()
        let scheduler = makeScheduler(config: makeConfig(), clock: clock, launcher: launcher,
                                      store: store, sessions: [makeSession()])
        runner.expectEqual(scheduler.activity(for: missingID)?.state, .failed,
                           "a due session missing after a full index refresh fails visibly")
        scheduler.advanceForTesting(by: 2)
        runner.expectEqual(launcher.launchedRequests.count, 0, "the missing session is not retried every tick")
    }

    private static func testQueuedScheduleTracksResetChanges(_ runner: inout TestRunner) {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = MutableClock(startingAt: start)
        var config = makeConfig()
        config.resetDelay = 10
        let session = makeSession()
        let scheduler = makeScheduler(config: config, clock: clock, launcher: FakeProcessLauncher(), sessions: [session])

        scheduler.setEnabled(true, for: session, resetAt: start.addingTimeInterval(100))
        runner.expectAlmost(scheduler.activity(for: session)?.scheduledAt?.timeIntervalSince(start) ?? -1,
                            110, tolerance: 0.01, "initial reset time schedules the continuation")

        scheduler.schedule(resetAt: start.addingTimeInterval(300))
        runner.expectAlmost(scheduler.activity(for: session)?.scheduledAt?.timeIntervalSince(start) ?? -1,
                            310, tolerance: 0.01, "a fresh reset time moves a future queued run")

        config.maxConcurrent = 0
        let manualScheduler = makeScheduler(config: config, clock: clock,
                                            launcher: FakeProcessLauncher(), sessions: [session])
        manualScheduler.runNow(session.id)
        manualScheduler.schedule(resetAt: start.addingTimeInterval(900))
        runner.expectAlmost(manualScheduler.activity(for: session)?.scheduledAt?.timeIntervalSince(start) ?? -1,
                            0, tolerance: 0.01, "a manual run is not moved by a later usage refresh")
    }

    /// Regression: a refresh landing between the reset and the delayed fire must not move the
    /// run to the next window, or the continuation perpetually recedes and never runs.
    private static func testResetReachedRunDoesNotMove(_ runner: inout TestRunner) {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = MutableClock(startingAt: start)
        var config = makeConfig()
        config.resetDelay = 10
        let session = makeSession()
        let scheduler = makeScheduler(config: config, clock: clock,
                                      launcher: FakeProcessLauncher(), sessions: [session])

        scheduler.setEnabled(true, for: session, resetAt: start.addingTimeInterval(100))
        // The awaited reset (start+100) has arrived; the fire (start+110) is 5s out when a
        // usage refresh reports a much later window.
        clock.advance(105)
        scheduler.schedule(resetAt: start.addingTimeInterval(9999))
        runner.expectAlmost(scheduler.activity(for: session)?.scheduledAt?.timeIntervalSince(start) ?? -1,
                            110, tolerance: 0.01, "a run whose reset already arrived keeps its armed fire time")
        runner.expectEqual(scheduler.activity(for: session)?.state, .queued)
    }

    // MARK: - Concurrency

    private static func testConcurrencyLimit(_ runner: inout TestRunner) async {
        let clock = MutableClock(startingAt: Date(timeIntervalSince1970: 1_800_000_000))
        var config = makeConfig()
        config.maxConcurrent = 1
        let launcher = FakeProcessLauncher()
        let sessions = (0..<3).map { _ in makeSession() }
        for session in sessions {
            launcher.setOutcome(.init(exitCodes: [0], duration: 10, writesTranscriptEvents: false), for: session.id)
        }
        let scheduler = makeScheduler(config: config, clock: clock, launcher: launcher, sessions: sessions)

        for session in sessions { scheduler.setEnabled(true, for: session, resetAt: clock.now()) }
        runner.expectEqual(launcher.runningCount, 1, "only one child runs at a time")
        runner.expectEqual(scheduler.activeSessionIDs.count, 1)

        launcher.advance(by: 11)
        await settle()
        runner.expectEqual(scheduler.activity(for: sessions[0])?.state, .succeeded)
        scheduler.advanceForTesting(by: 0)
        await settle()
        runner.expectEqual(launcher.runningCount, 1, "the next queued continuation takes the freed slot")
        runner.expectEqual(launcher.launchedRequests.count, 2)
    }

    // MARK: - Watchdog

    private static func testWatchdogTerminatesHungRun(_ runner: inout TestRunner) async {
        let clock = MutableClock(startingAt: Date(timeIntervalSince1970: 1_800_000_000))
        var config = makeConfig()
        config.maxRuntime = 20
        config.maxAttempts = 1
        let launcher = FakeProcessLauncher()
        let session = makeSession()
        launcher.setOutcome(.init(exitCodes: [0], duration: 0, writesTranscriptEvents: false, hangs: true), for: session.id)
        let scheduler = makeScheduler(config: config, clock: clock, launcher: launcher, sessions: [session])

        scheduler.setEnabled(true, for: session, resetAt: clock.now())
        runner.expectEqual(scheduler.activity(for: session)?.state, .running)
        clock.advance(21)
        scheduler.advanceForTesting(by: 0)
        await settle()
        runner.expectEqual(scheduler.activity(for: session)?.state, .failed, "a hung run is terminated")
        runner.expectEqual(scheduler.activity(for: session)?.outcome, .timeout)
        runner.expectEqual(scheduler.activeSessionIDs.count, 0, "the slot is released")
    }

    private static func testStopDoesNotRetry(_ runner: inout TestRunner) async {
        let clock = MutableClock(startingAt: Date(timeIntervalSince1970: 1_800_000_000))
        let launcher = FakeProcessLauncher()
        let session = makeSession()
        launcher.setOutcome(.init(exitCodes: [0], duration: 0, writesTranscriptEvents: false, hangs: true), for: session.id)
        let scheduler = makeScheduler(config: makeConfig(), clock: clock, launcher: launcher, sessions: [session])

        scheduler.setEnabled(true, for: session, resetAt: clock.now())
        scheduler.stop(session.id)
        await settle()
        runner.expectEqual(scheduler.activity(for: session)?.outcome, .cancelled)
        runner.expectFalse(scheduler.isEnabled(session), "a manual stop disarms without retrying")
        runner.expectEqual(launcher.launchedRequests.count, 1, "no relaunch after a stop")
    }

    // MARK: - Pruning

    private static func testStaleContinuationIsPruned(_ runner: inout TestRunner) async {
        let clock = MutableClock(startingAt: Date(timeIntervalSince1970: 1_800_000_000))
        var config = makeConfig()
        config.retention = 60
        let launcher = FakeProcessLauncher()
        let session = makeSession()
        launcher.setOutcome(.init(exitCodes: [0], duration: 0, writesTranscriptEvents: false), for: session.id)
        let scheduler = makeScheduler(config: config, clock: clock, launcher: launcher, sessions: [session])

        scheduler.setEnabled(true, for: session, resetAt: clock.now().addingTimeInterval(600))
        runner.expectEqual(scheduler.activity(for: session)?.state, .queued, "a future reset stays queued")
        clock.advance(120)
        scheduler.advanceForTesting(by: 0)
        await settle()
        runner.expectFalse(scheduler.isEnabled(session), "the record expires after the retention window")
        runner.expectNil(scheduler.activity(for: session), "the activity is dropped with it")
    }

    // MARK: - Reconciliation

    private static func testReconciliationCompletesFromTranscript(_ runner: inout TestRunner) async {
        // The clock starts in the past so every event written into the fixture transcript — the
        // fake uses the wall clock — counts as "after the continuation started".
        // Keep the deterministic clock just behind wall time used by FakeProcessLauncher when it
        // stamps lifecycle events. A fixed 2023 epoch made this fixture fail once the test runner
        // crossed that date, masking the reconciliation assertion itself.
        let clock = MutableClock(startingAt: Date().addingTimeInterval(-60))
        var config = makeConfig()
        config.reconcileInterval = 1
        let launcher = FakeProcessLauncher()
        let session = makeSession()

        // The store resolves transcripts under `codexHome/sessions`, so the fixture gets its own
        // throwaway `~/.codex`. It is deleted when this test returns.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("crw-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent("sessions/2026/01/01", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)) != nil else {
            runner.expect(false, "could not create the fixture transcript directory")
            return
        }
        config.codexHome = home

        let transcript = day.appendingPathComponent("rollout-2026-01-01T00-00-00-\(session.id).jsonl")
        let metadata = "{\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session.id)\",\"cwd\":\"\(home.path)\"}}\n"
        try? Data(metadata.utf8).write(to: transcript)

        launcher.transcriptURLs[session.id] = transcript
        // A long run, so the child is still alive when the app "dies".
        launcher.setOutcome(.init(exitCodes: [0], duration: 3_600, writesTranscriptEvents: true), for: session.id)

        let store = MemoryContinuationStore()
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("crw-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }

        let first = makeScheduler(config: config, clock: clock, launcher: launcher,
                                  store: store, sessions: [session], ledgerURL: ledgerURL)
        first.setEnabled(true, for: session, resetAt: clock.now())
        runner.expectEqual(first.activity(for: session)?.state, .running,
                           "arming the continuation launches the child")
        runner.expectNotNil(ledgerContents(ledgerURL), "the launch is journalled for the next instance")

        // The app dies without shutting down: the child keeps running, the in-memory handle is
        // gone, and the ledger pid no longer exists. Meanwhile the CLI finishes its turn.
        let completionTimestamp = Formatters.fractionalISO.string(from: Date())
        let completion = "{\"timestamp\":\"\(completionTimestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-1\"}}"
        if let handle = try? FileHandle(forWritingTo: transcript) {
            handle.seekToEndOfFile()
            handle.write(Data("\n\(completion)".utf8))
            try? handle.close()
        }
        runner.expectEqual(SessionStore.taskState(in: transcript, after: clock.now().addingTimeInterval(-60)),
                           .completed,
                           "the transcript contains a matching completed turn")

        // A fresh instance adopts whatever it finds on disk.
        let relaunched = makeScheduler(config: config, clock: clock, launcher: launcher,
                                       store: store, sessions: [session], ledgerURL: ledgerURL)
        runner.expectEqual(relaunched.activity(for: session)?.state, .running,
                           "the relaunched app still sees the continuation as live")
        clock.advance(10)
        relaunched.advanceForTesting(by: 10)
        await settle()
        runner.expectEqual(relaunched.activity(for: session)?.state, .succeeded,
                           "a lost child process is reconciled from its transcript")
    }

    private static func ledgerContents(_ url: URL) -> [ProcessLedgerEntry]? {
        let ledger = ProcessLedger(fileURL: url)
        let entries = ledger.read()
        return entries.isEmpty ? nil : entries
    }

    // MARK: - Backoff math

    private static func testBackoffMath(_ runner: inout TestRunner) {
        var config = AppConfig()
        config.backoffBase = 30
        config.backoffCap = 300
        runner.expectEqual(config.backoffDelay(forAttempt: 1), 0, "the first attempt is immediate")
        runner.expectEqual(config.backoffDelay(forAttempt: 2), 30)
        runner.expectEqual(config.backoffDelay(forAttempt: 3), 60)
        runner.expectEqual(config.backoffDelay(forAttempt: 4), 120)
        runner.expectEqual(config.backoffDelay(forAttempt: 5), 240)
        runner.expectEqual(config.backoffDelay(forAttempt: 6), 300, "growth is capped")
        runner.expectEqual(config.backoffDelay(forAttempt: 20), 300, "the cap holds")
    }

    // MARK: - Quota notifications

    private static func testQuotaWarningFiresOnce(_ runner: inout TestRunner) {
        var notifier = QuotaNotifier(config: AppConfig.default)
        let resetAt = Date().addingTimeInterval(3_600)
        let reading = Self.reading(primaryUsed: 80, secondaryUsed: 10, resetAt: resetAt)

        let first = notifier.evaluate(reading)
        runner.expectEqual(first.count, 1, "crossing 75% warns once")
        runner.expectEqual(first.first?.kind, "warning")

        // Still above the threshold: no repeat.
        let second = notifier.evaluate(Self.reading(primaryUsed: 82, secondaryUsed: 10, resetAt: resetAt))
        runner.expectEqual(second.count, 0, "no duplicate warning while above the threshold")

        // Dropping below re-arms.
        let dropped = notifier.evaluate(Self.reading(primaryUsed: 40, secondaryUsed: 10, resetAt: resetAt))
        runner.expectEqual(dropped.count, 0, "dropping below is silent")
        let rearmed = notifier.evaluate(Self.reading(primaryUsed: 80, secondaryUsed: 10, resetAt: resetAt))
        runner.expectEqual(rearmed.count, 1, "crossing again warns again")
    }

    private static func testQuotaResetRestoresAndRearms(_ runner: inout TestRunner) {
        var notifier = QuotaNotifier(config: AppConfig.default)
        let resetAt = Date().addingTimeInterval(3_600)
        _ = notifier.evaluate(Self.reading(primaryUsed: 100, secondaryUsed: 10, resetAt: resetAt))
        let restored = notifier.evaluate(Self.reading(primaryUsed: 4, secondaryUsed: 10, resetAt: resetAt))
        runner.expect(restored.contains { $0.kind == "restored" }, "a large drop fires a restored event")
        let nextClimb = notifier.evaluate(Self.reading(primaryUsed: 80, secondaryUsed: 10, resetAt: resetAt))
        runner.expect(nextClimb.contains { $0.kind == "warning" }, "thresholds re-arm after a reset")
    }

    private static func testQuotaDepletion(_ runner: inout TestRunner) {
        var notifier = QuotaNotifier(config: AppConfig.default)
        let resetAt = Date().addingTimeInterval(3_600)
        _ = notifier.evaluate(Self.reading(primaryUsed: 70, secondaryUsed: 10, resetAt: resetAt))
        let events = notifier.evaluate(Self.reading(primaryUsed: 100, secondaryUsed: 10, resetAt: resetAt))
        runner.expect(events.contains { $0.kind == "critical" }, "crossing 95% is critical")
        runner.expect(events.contains { $0.kind == "depleted" }, "reaching 100% is depleted")
        let again = notifier.evaluate(Self.reading(primaryUsed: 100, secondaryUsed: 10, resetAt: resetAt))
        runner.expect(!again.contains { $0.kind == "depleted" }, "depletion fires once")
    }

    private static func reading(primaryUsed: Int, secondaryUsed: Int, resetAt: Date) -> UsageReading {
        UsageReading(
            snapshot: UsageSnapshot(
                primary: UsageWindow(limitWindowSeconds: 18_000, resetAfterSeconds: 3_600, resetAt: resetAt, usedPercent: primaryUsed),
                secondary: UsageWindow(limitWindowSeconds: 604_800, resetAfterSeconds: 86_400, resetAt: resetAt, usedPercent: secondaryUsed)
            ),
            fetchedAt: Date()
        )
    }

    // MARK: - Forecast

    private static func testBurnETARequiresEnoughData(_ runner: inout TestRunner) {
        var history = UsageHistory(config: AppConfig.default)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        history.record(.primary, remainingFraction: 1.0, at: start)
        history.record(.primary, remainingFraction: 0.9, at: start.addingTimeInterval(60))
        runner.expectNil(history.burnETA(.primary, remainingFraction: 0.9, at: start.addingTimeInterval(60)),
                         "two samples are not enough")
        history.record(.primary, remainingFraction: 0.8, at: start.addingTimeInterval(90))
        runner.expectNil(history.burnETA(.primary, remainingFraction: 0.8, at: start.addingTimeInterval(90)),
                         "a span under two minutes is not enough")
    }

    private static func testBurnETAComputesDrainRate(_ runner: inout TestRunner) {
        var history = UsageHistory(config: AppConfig.default)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // Drain 10 percentage points every 5 minutes: 0.10 / 300s per step.
        for step in 0..<6 {
            let at = start.addingTimeInterval(Double(step) * 300)
            history.record(.primary, remainingFraction: 1.0 - Double(step) * 0.1, at: at)
        }
        let now = start.addingTimeInterval(1_500)
        guard let eta = history.burnETA(.primary, remainingFraction: 0.5, at: now) else {
            runner.expect(false, "expected an ETA with six samples over 25 minutes")
            return
        }
        // 0.5 remaining at 0.1/300s means 1500 seconds.
        runner.expect(eta > 1_400 && eta < 1_600, "ETA lands near 1500s, got \(eta)")
    }

    private static func testPaceComparesAgainstBaseline(_ runner: inout TestRunner) {
        var config = AppConfig()
        config.baselineAlpha = 0.5
        var history = UsageHistory(config: config)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for step in 0..<4 {
            history.record(.primary, remainingFraction: 1.0 - Double(step) * 0.05, at: start.addingTimeInterval(Double(step) * 300))
        }
        let baselinePace = history.pace(.primary, at: start.addingTimeInterval(900))
        runner.expectNotNil(baselinePace, "a pace is available once a baseline exists")
        if let pace = baselinePace {
            runner.expect(pace > 0.5 && pace < 2.0, "steady drain reads as roughly 1x, got \(pace)")
        }
    }

    // MARK: - Filesystem

    private static func testGitRepositoryDetection(_ runner: inout TestRunner) {
        do {
            try withTemporaryDirectory { root in
                let plain = root.appendingPathComponent("plain", isDirectory: true)
                try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
                runner.expectFalse(SessionStore.isInsideGitRepository(plain), "a bare directory is not a repository")

                let repo = root.appendingPathComponent("repo", isDirectory: true)
                let gitDir = repo.appendingPathComponent(".git", isDirectory: true)
                try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
                runner.expect(SessionStore.isInsideGitRepository(repo), "a directory containing .git is a repository")

                let nested = repo.appendingPathComponent("Sources/Deep", isDirectory: true)
                try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
                runner.expect(SessionStore.isInsideGitRepository(nested), "a subdirectory resolves to its parent repository")

                // A linked worktree stores .git as a file, not a directory.
                let worktree = root.appendingPathComponent("worktree", isDirectory: true)
                try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
                try "gitdir: /tmp/elsewhere".write(
                    to: worktree.appendingPathComponent(".git"),
                    atomically: true,
                    encoding: .utf8
                )
                runner.expect(SessionStore.isInsideGitRepository(worktree), "a worktree marker file counts")
            }
        } catch {
            runner.expect(false, "fixture setup failed: \(error)")
        }
    }

    private static func testTranscriptPathDerivation(_ runner: inout TestRunner) {
        // A real Codex session id: UUIDv7, so the first 12 hex digits are the creation timestamp.
        let sessionID = "019dedda-3bf7-73e0-b406-2cee3cf2bed8"
        let root = URL(fileURLWithPath: "/tmp/crw-nonexistent/sessions", isDirectory: true)
        let directory = SessionStore.derivedTranscriptDirectory(sessionID: sessionID, root: root)
        runner.expectNotNil(directory, "a UUIDv7 id yields a derived path")
        if let directory {
            runner.expect(directory.path.contains("/2026/"),
                          "the derived path points at the creation date, got \(directory.path)")
        }
        runner.expectNil(SessionStore.derivedTranscriptDirectory(sessionID: "not-a-uuid", root: root),
                         "a non-UUIDv7 id yields nothing")
        runner.expectNil(SessionStore.derivedTranscriptDate(sessionID: "00000000-0000-0000-0000-000000000000"),
                         "an all-zero id predates Codex and is rejected")

        // The lookup flavour finds the file when it really exists, in O(1) instead of a full walk.
        do {
            try withTemporaryDirectory { home in
                let day = SessionStore.derivedTranscriptDirectory(sessionID: sessionID, root: home)!
                try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
                let file = day.appendingPathComponent("rollout-2026-05-03T10-00-00-\(sessionID).jsonl")
                try Data("{}".utf8).write(to: file)
                runner.expectEqual(SessionStore.derivedTranscriptURL(sessionID: sessionID, root: home)?.lastPathComponent,
                                   file.lastPathComponent,
                                   "the derived lookup finds the real transcript")
            }
        } catch {
            runner.expect(false, "fixture setup failed: \(error)")
        }
    }

    /// The `threads` database is the recovery path when a rollout file has been archived or is
    /// unavailable. Keep this small integration regression around the exact narrow query.
    private static func testSQLiteWorkingDirectoryFallback(_ runner: inout TestRunner) {
        guard FileManager.default.isExecutableFile(atPath: CodexDatabase.executable) else {
            runner.expect(false, "sqlite3 is required for the supported macOS runtime")
            return
        }
        do {
            try withTemporaryDirectory { home in
                let database = home.appendingPathComponent("state_test.sqlite")
                let sessionID = "session-with-apostrophe'"
                let expected = "/tmp/crw project"
                let sql = "CREATE TABLE threads (id TEXT, cwd TEXT); "
                    + "INSERT INTO threads (id, cwd) VALUES ('session-with-apostrophe''', '/tmp/crw project');"
                let process = Process()
                process.executableURL = URL(fileURLWithPath: CodexDatabase.executable)
                process.arguments = [database.path, sql]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    runner.expect(false, "could not create SQLite fixture")
                    return
                }
                runner.expectEqual(CodexDatabase.workingDirectory(sessionID: sessionID, codexHome: home), expected,
                                   "SQLite cwd fallback survives SQL escaping and returns a row")
            }
        } catch {
            runner.expect(false, "SQLite fixture setup failed: \(error)")
        }
    }

    // MARK: - Persistence

    private static func testContinuationStoreMigratesLegacy(_ runner: inout TestRunner) {
        let suiteName = "crw.test.migration.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            runner.expect(false, "could not create a test suite")
            return
        }
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(["session-a", "session-b"], forKey: "scheduledSessionIDs")
        let store = UserDefaultsContinuationStore(suite: suite, debounce: 0)
        let loaded = store.load()
        runner.expectEqual(loaded.count, 2, "legacy identifiers are migrated")
        runner.expectEqual(loaded["session-a"]?.activity.state, .queued)
        runner.expectNil(suite.stringArray(forKey: "scheduledSessionIDs"), "the legacy key is removed")
    }

    private static func testContinuationRecordRoundTrip(_ runner: inout TestRunner) {
        let activity = ResumeActivity(
            state: .retrying,
            scheduledAt: Date(timeIntervalSince1970: 1_800_000_000),
            startedAt: Date(timeIntervalSince1970: 1_800_000_010),
            finishedAt: nil,
            lastOutput: "Exited with code 1",
            exitCode: 1,
            attempt: 2,
            nextAttemptAt: Date(timeIntervalSince1970: 1_800_000_100),
            outcome: .exitCode
        )
        let record = PersistedContinuation(createdAt: Date(timeIntervalSince1970: 1_799_999_900),
                                           activity: activity,
                                           sessionTitle: "Round trip")
        guard let data = try? JSONEncoder().encode(["id": record]),
              let decoded = try? JSONDecoder().decode([String: PersistedContinuation].self, from: data),
              let restored = decoded["id"] else {
            runner.expect(false, "round trip failed to encode or decode")
            return
        }
        runner.expectEqual(restored.activity.state, .retrying)
        runner.expectEqual(restored.activity.attempt, 2)
        runner.expectEqual(restored.activity.exitCode, 1)
        runner.expectEqual(restored.activity.outcome, .exitCode)
        runner.expectEqual(restored.activity.nextAttemptAt, activity.nextAttemptAt)
        runner.expectEqual(restored.sessionTitle, "Round trip")

        // An old record written by a previous version must still decode.
        let legacy = """
        {"createdAt":1799999900,"activity":{"state":"queued","scheduledAt":1800000000}}
        """
        guard let legacyRecord = try? JSONDecoder().decode(PersistedContinuation.self, from: Data(legacy.utf8)) else {
            runner.expect(false, "legacy record should decode")
            return
        }
        runner.expectEqual(legacyRecord.activity.state, .queued)
        runner.expectEqual(legacyRecord.activity.attempt, 1, "missing fields fall back to sane defaults")
    }

    // MARK: - Prompt construction

    private static func testRichContextPrompt(_ runner: inout TestRunner) {
        do {
            try withTemporaryDirectory { root in
                let session = makeSession()
                let day = root.appendingPathComponent("sessions/2026/01/01", isDirectory: true)
                try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
                let transcript = day.appendingPathComponent("rollout-2026-01-01T00-00-00-\(session.id).jsonl")
                let lines = [
                    #"{"timestamp":"2026-01-01T00:00:00.000Z","type":"session_meta","payload":{"id":"\#(session.id)","cwd":"\#(root.path)"}}"#,
                    #"{"timestamp":"2026-01-01T00:01:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"First request about parsing"}]}}"#,
                    #"{"timestamp":"2026-01-01T00:02:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Second request about retries"}]}}"#,
                    #"{"timestamp":"2026-01-01T00:03:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Third request about the scheduler"}]}}"#
                ]
                try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

                let requests = SessionStore.recentRequests(in: transcript, limit: 3, characterBudget: 280)
                runner.expectEqual(requests.count, 3, "all three recent requests are collected")
                runner.expectEqual(requests.first, "Third request about the scheduler", "newest first")

                var config = makeConfig()
                config.codexHome = root
                config.richContextContinuation = true
                config.richContextRequests = 3
                config.continuationPrompt = "continue"
                let scheduler = ResumeScheduler(
                    config: config,
                    clock: MutableClock(),
                    store: MemoryContinuationStore(),
                    launcher: FakeProcessLauncher(),
                    notifier: NullNotificationService(),
                    ledgerURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("crw-ledger-\(UUID().uuidString).json")
                )
                let prompt = scheduler.buildPrompt(for: session)
                runner.expect(prompt.hasPrefix("continue"), "the configured prompt stays first")
                runner.expect(prompt.contains("Third request about the scheduler"),
                              "recent requests are appended, newest first")
                runner.expect(prompt.contains("First request about parsing"), "all three make the cut")
            }
        } catch {
            runner.expect(false, "fixture setup failed: \(error)")
        }
    }

    private static func testPlainPromptStaysPlain(_ runner: inout TestRunner) {
        var config = makeConfig()
        config.continuationPrompt = "continue"
        config.richContextContinuation = false
        let scheduler = ResumeScheduler(
            config: config,
            clock: MutableClock(),
            store: MemoryContinuationStore(),
            launcher: FakeProcessLauncher(),
            notifier: NullNotificationService(),
            ledgerURL: FileManager.default.temporaryDirectory.appendingPathComponent("crw-ledger-\(UUID().uuidString).json")
        )
        let session = makeSession()
        runner.expectEqual(scheduler.buildPrompt(for: session), "continue", "plain mode sends only the prompt")
    }

    private static func testTaskStateRequiresMatchingStart(_ runner: inout TestRunner) {
        do {
            try withTemporaryDirectory { root in
                let transcript = root.appendingPathComponent("events.jsonl")
                let timestamp = Formatters.fractionalISO.string(from: Date())
                let unpaired = """
                {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}
                """
                try unpaired.write(to: transcript, atomically: true, encoding: .utf8)
                runner.expectEqual(SessionStore.taskState(in: transcript, after: Date().addingTimeInterval(-1)),
                                   .unknown,
                                   "an unpaired completion cannot finish a continuation")

                let mismatched = """
                {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
                {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-2"}}
                """
                try mismatched.write(to: transcript, atomically: true, encoding: .utf8)
                runner.expectEqual(SessionStore.taskState(in: transcript, after: Date().addingTimeInterval(-1)),
                                   .running,
                                   "a mismatched completion leaves the matching turn running")

                let paired = mismatched.replacingOccurrences(of: "turn-2", with: "turn-1")
                try paired.write(to: transcript, atomically: true, encoding: .utf8)
                runner.expectEqual(SessionStore.taskState(in: transcript, after: Date().addingTimeInterval(-1)),
                                   .completed,
                                   "a matching completion marks the turn complete")
            }
        } catch {
            runner.expect(false, "task state fixture failed: \(error)")
        }
    }

    private static func testTokenUsageParsing(_ runner: inout TestRunner) {
        do {
            try withTemporaryDirectory { root in
                let transcript = root.appendingPathComponent("tokens.jsonl")
                let timestamp = Formatters.fractionalISO.string(from: Date())
                let line = "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"info\":{\"total_token_usage\":{\"input_tokens\":1200,\"cached_input_tokens\":300,\"output_tokens\":450,\"reasoning_output_tokens\":50,\"total_tokens\":1650}}}\n"
                try line.write(to: transcript, atomically: true, encoding: .utf8)
                let usage = SessionStore.tokenUsage(in: transcript, after: Date().addingTimeInterval(-1))
                runner.expectEqual(usage?.inputTokens, 1_200)
                runner.expectEqual(usage?.cachedInputTokens, 300)
                runner.expectEqual(usage?.outputTokens, 450)
                runner.expectEqual(usage?.reasoningOutputTokens, 50)
                runner.expectEqual(usage?.totalTokens, 1_650)
            }
        } catch {
            runner.expect(false, "token usage fixture failed: \(error)")
        }
    }

    // MARK: - Utilities

    private static func testTextHelpers(_ runner: inout TestRunner) {
        runner.expectEqual(TextFormat.countdown(45), "45s")
        runner.expectEqual(TextFormat.countdown(90), "1m")
        runner.expectEqual(TextFormat.countdown(3_720), "1h 2m")
        runner.expectEqual(TextFormat.countdown(90_000), "1d 1h")
        runner.expectEqual(TextFormat.countdown(-5), "0s", "negative durations clamp to zero")
        runner.expectEqual(TextFormat.relativeAge(3), "just now")
        runner.expectEqual(TextFormat.relativeAge(45), "45s ago")
        runner.expectEqual(TextFormat.relativeAge(600), "10m ago")
        runner.expectEqual(TextFormat.clampPercent(120), 100)
        runner.expectEqual(TextFormat.clampPercent(-20), 0)
        runner.expectEqual(TextFormat.lastMeaningfulLine("one\n\n  two  \n"), "two")
        runner.expectNil(TextFormat.lastMeaningfulLine("\n\n  \n"), "whitespace only yields nothing")
        runner.expectEqual(TextFormat.lastMeaningfulLine(String(repeating: "x", count: 300), limit: 10)?.count, 10)
    }

    private static func testLogRedaction(_ runner: inout TestRunner) {
        let bearer = AppLog.redact("Authorization: Bearer abcdef123456.abcdef")
        runner.expect(!bearer.contains("abcdef123456"), "bearer tokens are masked")
        let email = AppLog.redact("user@example.com signed in")
        runner.expect(!email.contains("user@example.com"), "email addresses are masked")
        let long = AppLog.redact(String(repeating: "a", count: 900))
        runner.expect(long.count <= 402, "over-long lines are truncated")
    }

    // MARK: - Decoding

    private static func testUsageDecoding(_ runner: inout TestRunner) {
        let payload = """
        {"rate_limit":{"primary_window":{"limit_window_seconds":18000,"reset_after_seconds":3600,
        "reset_at":1800003600,"used_percent":42},
        "secondary_window":{"limit_window_seconds":604800,"reset_after_seconds":86400,
        "reset_at":1800086400,"used_percent":7}}}
        """
        guard let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: Data(payload.utf8)) else {
            runner.expect(false, "a well-formed payload must decode")
            return
        }
        runner.expectEqual(snapshot.primary.usedPercent, 42)
        runner.expectEqual(snapshot.primary.remainingPercent, 58)
        runner.expectEqual(snapshot.secondary.remainingPercent, 93)
        runner.expectEqual(snapshot.primary.resetAt.timeIntervalSince1970, 1_800_003_600, accuracy: 0.001)
    }

    /// A renamed or added field must not blank the whole UI.
    private static func testUsageDecodingToleratesChange(_ runner: inout TestRunner) {
        let missingWindow = """
        {"rate_limit":{"primary_window":{"limit_window_seconds":18000,"reset_at":1800003600,"used_percent":42}}}
        """
        runner.expectNil(try? JSONDecoder().decode(UsageSnapshot.self, from: Data(missingWindow.utf8)),
                         "a missing window is still an error, but a typed one")

        let extraFields = """
        {"rate_limit":{"primary_window":{"limit_window_seconds":18000,"reset_after_seconds":3600,
        "reset_at":1800003600,"used_percent":42,"plan_type":"pro"},
        "secondary_window":{"limit_window_seconds":604800,"reset_after_seconds":86400,
        "reset_at":1800086400,"used_percent":7}},"something_new":{"a":1}}
        """
        runner.expectNotNil(try? JSONDecoder().decode(UsageSnapshot.self, from: Data(extraFields.utf8)),
                            "unknown extra fields are ignored")

        let wrongType = """
        {"rate_limit":{"primary_window":{"limit_window_seconds":"18000","reset_after_seconds":3600,
        "reset_at":1800003600,"used_percent":42},
        "secondary_window":{"limit_window_seconds":604800,"reset_after_seconds":86400,
        "reset_at":1800086400,"used_percent":7}}}
        """
        runner.expectNil(try? JSONDecoder().decode(UsageSnapshot.self, from: Data(wrongType.utf8)),
                         "a type change is rejected instead of fabricating zero usage")
    }

    // MARK: - Configuration

    private static func testEnvironmentOverrides(_ runner: inout TestRunner) {
        let env = [
            "CRW_SANDBOX": "1",
            "CRW_RESET_DELAY": "12",
            "CRW_MAX_ATTEMPTS": "5",
            "CRW_MAX_CONCURRENT": "2",
            "CRW_RUN_TIMEOUT": "90",
            "CRW_CODEX_HOME": "/tmp/crw-home",
            "CRW_PROMPT": "please continue"
        ]
        let config = AppConfig.load(environment: env)
        runner.expect(config.isSandbox, "sandbox flag is honoured")
        runner.expectEqual(config.resetDelay, 12)
        runner.expectEqual(config.maxAttempts, 5)
        runner.expectEqual(config.maxConcurrent, 2)
        runner.expectEqual(config.maxRuntime, 90)
        runner.expectEqual(config.codexHome.path, "/tmp/crw-home")
        runner.expectEqual(config.continuationPrompt, "please continue")
        runner.expectNotNil(config.defaultsSuite, "sandbox mode gets an isolated defaults suite")

        let plain = AppConfig.load(environment: [:])
        runner.expectFalse(plain.isSandbox, "sandbox stays off without CRW_SANDBOX")
        runner.expectNil(plain.defaultsSuite, "the real app uses the shared suite")
        runner.expectEqual(plain.resetDelay, 300, "defaults are unchanged without overrides")
    }

    // MARK: - Ledger

    private static func testProcessLedgerLifecycle(_ runner: inout TestRunner) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crw-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = ProcessLedger(fileURL: url)
        runner.expectEqual(ledger.read().count, 0, "a missing ledger reads empty")

        let entry = ProcessLedgerEntry(sessionID: "abc", pid: 4242, launchedAt: Date())
        ledger.write([entry])
        runner.expectEqual(ledger.read().count, 1)
        runner.expectEqual(ledger.read().first?.pid, 4242)

        ledger.clear()
        runner.expectEqual(ledger.read().count, 0, "clear removes the ledger")

        // Our own pid is definitely alive.
        runner.expect(ProcessLedger.isAlive(pid: Int32(ProcessInfo.processInfo.processIdentifier)),
                      "the current process is detected as alive")
        runner.expectFalse(ProcessLedger.isAlive(pid: -1), "invalid pids are reported dead")
    }
}

private extension TestRunner {
    mutating func expectFalse(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) {
        expect(!condition, message, file: file, line: line)
    }

    mutating func expectEqual(_ lhs: Double, _ rhs: Double, accuracy: Double, _ message: String = "", file: String = #fileID, line: Int = #line) {
        expect(abs(lhs - rhs) <= accuracy, message.isEmpty ? "expected \(rhs) ± \(accuracy), got \(lhs)" : message, file: file, line: line)
    }
}
