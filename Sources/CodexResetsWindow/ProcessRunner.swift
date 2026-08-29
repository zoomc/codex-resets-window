import Foundation

/// What to launch for one continuation.
struct LaunchRequest: Sendable, Equatable {
    let sessionID: String
    let executable: String
    let arguments: [String]
    let workingDirectory: URL?
}

/// Handle on a running child process.
protocol ContinuationProcess: AnyObject {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    /// `false` sends SIGTERM, `true` sends SIGKILL.
    func stop(force: Bool)
}

/// Launcher seam. The sandbox and the self-test inject fakes instead of spawning `codex`.
protocol ProcessLaunching: AnyObject {
    func launch(
        request: LaunchRequest,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> ContinuationProcess
}

/// Real `Process`-backed launcher.
final class SystemProcessLauncher: ProcessLaunching, @unchecked Sendable {
    func launch(
        request: LaunchRequest,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> ContinuationProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments
        process.currentDirectoryURL = request.workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser

        // A child that inherits our environment can pick up a nested `CODEX_HOME` or sandbox
        // variables. Only pass through what a CLI actually needs.
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("CRW_") { environment.removeValue(forKey: key) }
        environment.removeValue(forKey: "CODEX_SANDBOX")
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            onOutput(text)
        }
        process.terminationHandler = { completed in
            pipe.fileHandleForReading.readabilityHandler = nil
            onExit(completed.terminationStatus)
        }
        try process.run()
        return ProcessHandle(process: process)
    }

    private final class ProcessHandle: ContinuationProcess {
        private let process: Process

        init(process: Process) { self.process = process }

        var pid: Int32 { process.processIdentifier }
        var isRunning: Bool { process.isRunning }

        func stop(force: Bool) {
            guard process.isRunning else { return }
            if force {
                kill(process.processIdentifier, SIGKILL)
            } else {
                process.terminate()
            }
        }
    }
}

/// Scriptable fake launcher.
///
/// Each launch consults the scripted behaviour for the session, which lets the integration tests
/// express "fail twice then succeed", "hang forever" or "exit after 30 seconds" without a real CLI.
final class FakeProcessLauncher: ProcessLaunching, @unchecked Sendable {
    struct Outcome: Sendable {
        /// Exit code per attempt (1-based). The last value repeats for later attempts.
        var exitCodes: [Int32]
        /// Seconds the fake process "runs" before exiting. Zero exits on the next tick.
        var duration: TimeInterval
        /// Whether the fake writes `task_started` / `task_complete` into the transcript.
        var writesTranscriptEvents: Bool
        /// When true the fake never exits, forcing the watchdog to fire.
        var hangs: Bool

        init(exitCodes: [Int32] = [0],
             duration: TimeInterval = 0,
             writesTranscriptEvents: Bool = true,
             hangs: Bool = false) {
            self.exitCodes = exitCodes
            self.duration = duration
            self.writesTranscriptEvents = writesTranscriptEvents
            self.hangs = hangs
        }

        func exitCode(forAttempt attempt: Int) -> Int32 {
            guard !exitCodes.isEmpty else { return 0 }
            return exitCodes[min(attempt, exitCodes.count) - 1]
        }
    }

    struct Launch: Sendable {
        let request: LaunchRequest
        let attempt: Int
        let startedAt: Date
    }

    private let lock = NSLock()
    private var outcomes: [String: Outcome]
    private var launches: [Launch] = []
    private var handles: [String: FakeHandle] = [:]
    /// Transcript URL per session, so the fake can append lifecycle events like the real CLI does.
    var transcriptURLs: [String: URL] = [:]
    /// Called synchronously on launch so tests can observe ordering.
    var onLaunch: ((Launch) -> Void)?

    init(outcomes: [String: Outcome] = [:]) { self.outcomes = outcomes }

    func setOutcome(_ outcome: Outcome, for sessionID: String) {
        lock.lock()
        outcomes[sessionID] = outcome
        lock.unlock()
    }

    var launchedRequests: [Launch] {
        lock.lock()
        defer { lock.unlock() }
        return launches
    }

    var runningCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return handles.values.filter(\.isRunning).count
    }

    func launch(
        request: LaunchRequest,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> ContinuationProcess {
        lock.lock()
        let attempt = launches.filter { $0.request.sessionID == request.sessionID }.count + 1
        let outcome = outcomes[request.sessionID] ?? Outcome()
        let launch = Launch(request: request, attempt: attempt, startedAt: Date())
        launches.append(launch)
        lock.unlock()

        onLaunch?(launch)

        if outcome.writesTranscriptEvents, let transcript = transcriptURLs[request.sessionID] {
            appendEvent(type: "task_started", turn: "turn-\(attempt)", to: transcript)
        }

        let handle = FakeHandle(sessionID: request.sessionID, pid: Int32(40_000 + launches.count))
        lock.lock()
        handles[request.sessionID] = handle
        lock.unlock()

        // `onStop` only records the lifecycle event. `FakeHandle.finish` reports the exit exactly
        // once, and a real process only ever terminates once.
        handle.onStop = { [weak self] _ in
            guard let self else { return }
            if outcome.writesTranscriptEvents, let transcript = self.transcriptURLs[request.sessionID] {
                self.appendEvent(type: "task_complete", turn: "turn-\(attempt)", to: transcript)
            }
        }
        handle.remaining = outcome.hangs ? .infinity : outcome.duration
        handle.onOutput = { text in onOutput(text) }
        handle.onExit = onExit
        handle.outcome = outcome
        handle.attempt = attempt
        return handle
    }

    /// Simulates losing track of a child without it having exited — what happens when the app is
    /// relaunched and its in-memory handle is gone. The transcript is the only remaining witness.
    func dropHandle(for sessionID: String) {
        lock.lock()
        handles.removeValue(forKey: sessionID)
        lock.unlock()
    }

    /// Drives the fake processes forward. Called by the test between clock advances.
    func advance(by interval: TimeInterval) {
        lock.lock()
        let snapshot = Array(handles.values)
        lock.unlock()
        for handle in snapshot { handle.advance(by: interval) }
    }

    private func appendEvent(type: String, turn: String, to url: URL) {
        let payload = "{\"timestamp\":\"\(Self.isoString(Date()))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\",\"turn_id\":\"\(turn)\"}}\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(payload.utf8))
            try? handle.close()
        } else {
            try? payload.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func isoString(_ date: Date) -> String {
        Formatters.fractionalISO.string(from: date)
    }

    final class FakeHandle: ContinuationProcess, @unchecked Sendable {
        let sessionID: String
        let pid: Int32
        private let lock = NSLock()
        private var _isRunning = true
        private var _remaining: TimeInterval = 0
        private var _forced = false

        var onOutput: ((String) -> Void)?
        var onExit: ((Int32) -> Void)?
        var onStop: ((Bool) -> Void)?
        var outcome = Outcome()
        var attempt = 1

        var remaining: TimeInterval {
            get { lock.lock(); defer { lock.unlock() }; return _remaining }
            set { lock.lock(); _remaining = newValue; lock.unlock() }
        }

        init(sessionID: String, pid: Int32) {
            self.sessionID = sessionID
            self.pid = pid
        }

        var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _isRunning
        }

        func advance(by interval: TimeInterval) {
            lock.lock()
            guard _isRunning else { lock.unlock(); return }
            if _remaining == .infinity { lock.unlock(); return }
            _remaining -= interval
            let shouldExit = _remaining <= 0
            lock.unlock()
            if shouldExit { finish(forced: false) }
        }

        func stop(force: Bool) { finish(forced: force) }

        private func finish(forced: Bool) {
            lock.lock()
            guard _isRunning else { lock.unlock(); return }
            _isRunning = false
            _forced = forced
            lock.unlock()
            if !forced { onOutput?("fake codex output for \(sessionID)") }
            onStop?(forced)
            onExit?(forced ? SIGKILLTerminationStatus : outcome.exitCode(forAttempt: attempt))
        }
    }
}

/// Exit status reported when a process had to be killed.
let SIGKILLTerminationStatus: Int32 = 137
