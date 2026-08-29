import AppKit
import Foundation

// MARK: - Entry point
//
// `@main` and `main.swift` cannot coexist, so the object graph is assembled by hand here.
// The same binary serves three roles: the menu bar app, a headless inspector (`--dump`) and
// the test runner (`--selftest`). Keeping them in one executable means the tests exercise the
// exact code that ships, and the sandbox scripts can drive the app without a GUI.

enum AppVersion {
    static let current = "0.2.0"
}

func printUsage() {
    print("""
    Codex Resets Window \(AppVersion.current)

    USAGE
      CodexResetsWindow                    Run the menu bar app
      CodexResetsWindow --dump             Print usage, sessions and continuations, then exit
      CodexResetsWindow --dump-json        Same as --dump, machine readable
      CodexResetsWindow --simulate <sec> [arm=<session-id> ...]
                                           Run the real scheduler headless for N seconds and
                                           print what happened. No GUI, no notifications.
      CodexResetsWindow --selftest [name]  Run the built-in suite (this toolchain has no XCTest)
      CodexResetsWindow --version
      CodexResetsWindow --help

    ENVIRONMENT (all optional; every value below has a sane default)
      CRW_SANDBOX=1               Isolate UserDefaults and the process ledger
      CRW_SUITE=<name>            UserDefaults suite used when CRW_SANDBOX=1
      CRW_CODEX_HOME=<path>       Read auth/sessions from a fake ~/.codex
      CRW_CODEX_BIN=<path>        Path to the `codex` CLI (sandbox: a shell stub)
      CRW_USAGE_FIXTURE=<path>    Serve the usage payload from disk, no network
      CRW_RESET_DELAY=<sec>       Delay after the 5h window resets before continuing
      CRW_RUN_TIMEOUT=<sec>       Watchdog: kill a continuation after N seconds
      CRW_MAX_ATTEMPTS=<n>        Retry budget per continuation
      CRW_MAX_CONCURRENT=<n>      Parallel continuation cap
      CRW_BACKOFF_BASE=<sec>      Exponential backoff base
      CRW_PROMPT=<text>           Prompt sent to the resumed session
      CRW_RICH_CONTEXT=1          Prefix recent user requests onto that prompt
      CRW_WARN_AT / CRW_CRITICAL_AT=<percent>
      CRW_LOG_DIR=<path>          Mirror log lines into this directory
      CRW_VERBOSE=1               Debug logging
    """)
}

/// True when another copy of the app is already in the menu bar.
///
/// LaunchAgents restart the app on crash, and a stray second instance would double every
/// continuation. The check is skipped for bare binaries because `NSRunningApplication` only
/// knows about bundles.
func isDuplicateLaunch() -> Bool {
    guard let bundleID = Bundle.main.bundleIdentifier else { return false }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .contains { $0.processIdentifier != ownPID }
}

@MainActor
func dumpText(_ environment: AppEnvironment) -> String {
    var lines: [String] = ["Codex Resets Window \(AppVersion.current)"]
    let model = environment.model
    if let reading = model.reading {
        let primary = reading.snapshot.primary
        let secondary = reading.snapshot.secondary
        lines.append("primary   \(primary.remainingPercent)% remaining · resets \(primary.countdownText(now: Date()))")
        lines.append("secondary \(secondary.remainingPercent)% remaining · resets \(secondary.countdownText(now: Date()))")
        if let eta = model.primaryETA {
            lines.append("burn-down empty in ~\(TextFormat.countdown(eta)) at the current rate")
        }
        if let pace = model.primaryPace {
            lines.append(String(format: "pace      %.2fx of your usual", pace))
        }
        lines.append("updated   \(model.updatedText)")
    } else if let error = model.errorMessage {
        lines.append("usage     unavailable: \(error)")
    } else {
        lines.append("usage     unavailable")
    }

    lines.append("")
    lines.append("sessions (\(model.sessions.count))")
    for session in model.sessions.prefix(20) {
        let armed = environment.scheduler.isEnabled(session) ? "armed " : "      "
        let title = session.displayName
        lines.append("  \(armed)\(title)")
    }

    let activities = environment.scheduler.activities
    if !activities.isEmpty {
        lines.append("")
        lines.append("continuations (\(activities.count))")
        for (id, activity) in activities.sorted(by: { $0.key < $1.key }) {
            var detail = "  \(activity.state.label)"
            if activity.attempt > 1 { detail += " · attempt \(activity.attempt)" }
            if let next = activity.nextAttemptAt, activity.state == .retrying {
                detail += " · retry at \(Formatters.time.string(from: next))"
            }
            if let scheduled = activity.scheduledAt {
                detail += " · due \(Formatters.time.string(from: scheduled))"
            }
            if activity.outcome != .none { detail += " · \(activity.outcome.label)" }
            lines.append("\(detail)  \(id)")
        }
    }
    return lines.joined(separator: "\n")
}

@MainActor
func dumpJSON(_ environment: AppEnvironment) throws -> String {
    let model = environment.model
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    struct Payload: Encodable {
        let version: String
        let generatedAt: String
        let error: String?
        let primary: UsageWindow?
        let secondary: UsageWindow?
        let etaSeconds: TimeInterval?
        let pace: Double?
        let willRunDry: Bool
        let sessions: [Summary]
        let continuations: [Continuation]

        struct Summary: Encodable {
            let id: String
            let title: String?
            let updatedAt: Date?
            let armed: Bool
        }
        struct Continuation: Encodable {
            let sessionID: String
            let state: String
            let attempt: Int
            let outcome: String
            let scheduledAt: Date?
            let nextAttemptAt: Date?
        }
    }

    let sessions = model.sessions.map {
        Payload.Summary(id: $0.id,
                        title: $0.threadName,
                        updatedAt: $0.updatedAt,
                        armed: environment.scheduler.isEnabled($0))
    }
    let continuations = environment.scheduler.activities.map { id, activity in
        Payload.Continuation(sessionID: id,
                             state: activity.state.label,
                             attempt: activity.attempt,
                             outcome: activity.outcome.label,
                             scheduledAt: activity.scheduledAt,
                             nextAttemptAt: activity.nextAttemptAt)
    }.sorted { $0.sessionID < $1.sessionID }

    let payload = Payload(version: AppVersion.current,
                          generatedAt: Formatters.plainISO.string(from: Date()),
                          error: model.errorMessage,
                          primary: model.reading?.snapshot.primary,
                          secondary: model.reading?.snapshot.secondary,
                          etaSeconds: model.primaryETA,
                          pace: model.primaryPace,
                          willRunDry: model.willRunDry,
                          sessions: sessions,
                          continuations: continuations)
    let data = try encoder.encode(payload)
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Startup

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") {
    printUsage()
    exit(0)
}

if arguments.contains("--version") {
    print(AppVersion.current)
    exit(0)
}

let verbose = arguments.contains("--verbose") || arguments.contains("-v")
var config = AppConfig.load()
if verbose { config.verboseLogging = true }
AppLog.configure(verbose: config.verboseLogging, directory: config.logDirectory)

// The toolchain that builds this project ships neither XCTest nor swift-testing, so the suite
// lives inside the product. `--selftest foo` runs only the matching cases.
if let index = arguments.firstIndex(of: "--selftest") {
    let filter = arguments.dropFirst(index + 1).first { !$0.hasPrefix("-") }
    let runner = await SelfTests.run(filter: filter, verbose: verbose)
    print(runner.summary)
    exit(runner.failures.isEmpty ? 0 : 1)
}

/// Runs the real scheduler for a fixed number of seconds without ever touching the menu bar.
///
/// This is the workhorse of the sandbox tests: the shipped binary, the shipped scheduling logic,
/// a stub `codex` on `PATH` and a fake `~/.codex`, but no GUI, no notifications and no network.
/// `--simulate 20 arm=<session-id>` is enough to watch a full arm → launch → retry cycle.
@MainActor
func simulate(seconds: TimeInterval,
              arm armIDs: [String],
              run runIDs: [String],
              json: Bool,
              environment: AppEnvironment) async {
    await environment.model.refresh(reason: .launch)
    await settle(30)
    // `arm=` respects the reset delay, so it exercises the real "wait for the window to reset"
    // path. `run=` fires immediately, which keeps the fast scenarios fast.
    for id in armIDs {
        guard let session = environment.model.sessions.first(where: { $0.id == id }) else {
            AppLog.warning("no session \(id) to arm", category: .continuation)
            continue
        }
        environment.scheduler.setEnabled(true, for: session, resetAt: Date())
    }
    for id in runIDs { environment.scheduler.runNow(id) }

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 200_000_000)
        environment.scheduler.advanceForTesting(by: 0.2)
    }
    environment.scheduler.shutdown()
    await settle(10)

    if json {
        do { print(try dumpJSON(environment)) } catch { print("{\"error\":\"\(error)\"}") }
    } else {
        print(dumpText(environment))
    }
}

if let index = arguments.firstIndex(of: "--simulate") {
    let tail = Array(arguments.dropFirst(index + 1))
    let seconds = tail.first { !$0.hasPrefix("-") && !$0.contains("=") }.flatMap(Double.init) ?? 30
    let armIDs = tail.filter { $0.hasPrefix("arm=") }.map { String($0.dropFirst(4)) }
    let runIDs = tail.filter { $0.hasPrefix("run=") }.map { String($0.dropFirst(4)) }
    var sim = config
    sim.isHeadless = true
    let environment = AppEnvironment(config: sim)
    await simulate(seconds: seconds, arm: armIDs, run: runIDs,
                   json: arguments.contains("--dump-json"), environment: environment)
    exit(0)
}

if arguments.contains("--dump") || arguments.contains("--dump-json") {
    var headless = config
    headless.isHeadless = true
    headless.isSandbox = headless.isSandbox || headless.usageFixture != nil
    let environment = AppEnvironment(config: headless)
    await environment.model.refresh(reason: .launch)
    if arguments.contains("--dump-json") {
        do { print(try dumpJSON(environment)) } catch { print("{\"error\":\"\(error)\"}"); exit(1) }
    } else {
        print(dumpText(environment))
    }
    exit(0)
}

if isDuplicateLaunch() {
    AppLog.warning("another instance owns the menu bar; exiting", category: .app)
    exit(0)
}

let environment = AppEnvironment(config: config)
AppEnvironment.shared = environment
let delegate = StatusBarDelegate(environment: environment)

let app = NSApplication.shared
app.delegate = delegate
AppLog.info("launched (sandbox=\(config.isSandbox), suite=\(config.defaultsSuite ?? "shared"))", category: .app)
Task { @MainActor in
    await environment.model.refresh(reason: .launch)
}
app.run()
