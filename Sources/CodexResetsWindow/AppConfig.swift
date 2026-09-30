import Foundation

/// Centralised configuration.
///
/// Every magic number that used to be scattered across the app lives here. Each value can be
/// overridden with a `CRW_`-prefixed environment variable, which is what makes the sandbox
/// integration tests possible: a five hour window collapses into a few seconds without touching
/// a single line of scheduling logic.
struct AppConfig: Sendable {
    // MARK: - Scheduling

    /// Delay between the 5-hour window reset and the continuation launch.
    var resetDelay: TimeInterval = 5 * 60
    /// How long a persisted continuation record survives.
    var retention: TimeInterval = 7 * 60 * 60
    /// How often local transcripts are re-checked for `task_started` / `task_complete`.
    var reconcileInterval: TimeInterval = 20
    /// How often the menu bar title is refreshed.
    var titleRefreshInterval: TimeInterval = 30
    /// How often usage is refreshed automatically.
    var usageRefreshInterval: TimeInterval = 5 * 60
    /// Minimum interval between two automatic usage refreshes (protects against refresh storms).
    var usageRefreshFloor: TimeInterval = 20

    // MARK: - Continuation reliability

    /// Hard cap on a single child process lifetime. Zero disables the watchdog.
    var maxRuntime: TimeInterval = 45 * 60
    /// Grace period between SIGTERM and SIGKILL.
    var killGrace: TimeInterval = 5
    /// Maximum launch attempts per continuation before giving up.
    var maxAttempts: Int = 3
    /// Exponential backoff base, in seconds.
    var backoffBase: TimeInterval = 30
    /// Upper bound for a single backoff delay.
    var backoffCap: TimeInterval = 15 * 60
    /// How many continuations may run at the same time.
    var maxConcurrent: Int = 1

    // MARK: - Notifications

    /// Used-percentage that triggers a warning notification.
    var warningThreshold: Int = 75
    /// Used-percentage that triggers a critical "depleted" notification.
    var criticalThreshold: Int = 95
    /// A drop in used percentage larger than this means the window reset.
    var resetDropPercent: Double = 25
    /// Used-percentage below this clears a previous depletion flag.
    var restoredBelowPercent: Double = 90

    // MARK: - Freshness

    /// Age after which the 5-hour window reading is considered stale.
    var stalePrimary: TimeInterval = 30 * 60
    /// Age after which the weekly window reading is considered stale.
    var staleSecondary: TimeInterval = 4 * 60 * 60

    // MARK: - Burn-down forecast

    var historyCap: Int = 240
    var historyMaxAge: TimeInterval = 6 * 60 * 60
    var baselineAlpha: Double = 0.04
    var etaMinSamples: Int = 3
    var etaMinSpan: TimeInterval = 120
    var etaLookback: TimeInterval = 30 * 60
    var burnLookback: TimeInterval = 15 * 60

    // MARK: - Presentation

    /// How many recent sessions are shown initially before the More button pages in the rest.
    var recentSessionLimit: Int = 5
    /// How many additional sessions each More press reveals.
    var sessionPageStep: Int = 10
    /// Prompt sent to the resumed session.
    var continuationPrompt: String = "continue"
    /// When true, the prompt is enriched with a bounded set of recent user requests.
    var richContextContinuation: Bool = false
    /// Maximum characters taken from the transcript when building a rich prompt.
    var richContextCharacters: Int = 280
    /// Maximum recent user requests embedded in a rich prompt.
    var richContextRequests: Int = 3

    // MARK: - Environment

    /// Root directory that holds `auth.json`, `session_index.jsonl` and `sessions/`.
    var codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    /// Explicit Codex CLI path. When nil the known install locations are probed.
    var codexExecutableOverride: String?
    /// Sandbox only: read the usage payload from a local file instead of the network.
    var usageFixture: URL?
    /// Sandbox only: write to a private `UserDefaults` suite instead of the shared one.
    var defaultsSuite: String?
    /// When set, log lines are additionally appended to this directory.
    var logDirectory: URL?
    /// Verbose logging.
    var verboseLogging: Bool = false
    /// True when running against sandbox fixtures.
    var isSandbox: Bool = false
    /// True when the process was started for headless verification.
    var isHeadless: Bool = false

    static let `default` = AppConfig()

    /// Builds a configuration from the current environment.
    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppConfig {
        var config = AppConfig()
        let env = EnvironmentReader(environment)

        config.isSandbox = env.bool("CRW_SANDBOX")
        config.verboseLogging = env.bool("CRW_VERBOSE")
        config.isHeadless = env.bool("CRW_HEADLESS")

        config.resetDelay = env.time("CRW_RESET_DELAY", default: config.resetDelay)
        config.retention = env.time("CRW_RETENTION", default: config.retention)
        config.reconcileInterval = env.time("CRW_RECONCILE_INTERVAL", default: config.reconcileInterval)
        config.titleRefreshInterval = env.time("CRW_TITLE_INTERVAL", default: config.titleRefreshInterval)
        config.usageRefreshInterval = env.time("CRW_REFRESH_INTERVAL", default: config.usageRefreshInterval)
        config.usageRefreshFloor = env.time("CRW_REFRESH_FLOOR", default: config.usageRefreshFloor)

        config.maxRuntime = env.time("CRW_RUN_TIMEOUT", default: config.maxRuntime)
        config.killGrace = env.time("CRW_KILL_GRACE", default: config.killGrace)
        config.maxAttempts = env.int("CRW_MAX_ATTEMPTS", default: config.maxAttempts)
        config.backoffBase = env.time("CRW_BACKOFF_BASE", default: config.backoffBase)
        config.backoffCap = env.time("CRW_BACKOFF_CAP", default: config.backoffCap)
        config.maxConcurrent = max(1, env.int("CRW_MAX_CONCURRENT", default: config.maxConcurrent))

        config.warningThreshold = env.int("CRW_WARN_AT", default: config.warningThreshold)
        config.criticalThreshold = env.int("CRW_CRITICAL_AT", default: config.criticalThreshold)
        config.resetDropPercent = env.double("CRW_RESET_DROP", default: config.resetDropPercent)
        config.restoredBelowPercent = env.double("CRW_RESTORED_BELOW", default: config.restoredBelowPercent)

        config.stalePrimary = env.time("CRW_STALE_PRIMARY", default: config.stalePrimary)
        config.staleSecondary = env.time("CRW_STALE_SECONDARY", default: config.staleSecondary)

        config.historyCap = env.int("CRW_HISTORY_CAP", default: config.historyCap)
        config.historyMaxAge = env.time("CRW_HISTORY_MAX_AGE", default: config.historyMaxAge)
        config.baselineAlpha = env.double("CRW_BASELINE_ALPHA", default: config.baselineAlpha)
        config.etaMinSamples = env.int("CRW_ETA_MIN_SAMPLES", default: config.etaMinSamples)
        config.etaMinSpan = env.time("CRW_ETA_MIN_SPAN", default: config.etaMinSpan)

        config.recentSessionLimit = env.int("CRW_RECENT_LIMIT", default: config.recentSessionLimit)
        config.sessionPageStep = max(1, env.int("CRW_PAGE_STEP", default: config.sessionPageStep))
        config.continuationPrompt = env.string("CRW_PROMPT") ?? config.continuationPrompt
        config.richContextContinuation = env.bool("CRW_RICH_CONTEXT")
        config.richContextCharacters = env.int("CRW_RICH_CHARS", default: config.richContextCharacters)
        config.richContextRequests = env.int("CRW_RICH_REQUESTS", default: config.richContextRequests)

        if let path = env.string("CRW_CODEX_HOME") {
            config.codexHome = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        config.codexExecutableOverride = env.string("CRW_CODEX_BIN")
        if let path = env.string("CRW_USAGE_FIXTURE") {
            config.usageFixture = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        if config.isSandbox {
            config.defaultsSuite = env.string("CRW_SUITE") ?? "com.codexresets.window.sandbox"
        }
        // Mirror logs to disk by default for the real app. A continuation that silently fails is
        // nearly impossible to diagnose from the UI alone, and the unified log needs a working
        // `/usr/bin/log` plus the right predicate. Sandbox and headless runs stay quiet so the
        // test scripts never write into the user's support directory.
        if !config.isSandbox && !config.isHeadless {
            config.logDirectory = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CodexResetsWindow", isDirectory: true)
        }
        if let path = env.string("CRW_LOG_DIR") {
            config.logDirectory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return config
    }

    /// Exponential backoff for attempt `attempt` (1-based), capped at `backoffCap`.
    func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        let exponent = Double(min(attempt - 1, 12))
        return min(backoffBase * pow(2, exponent - 1), backoffCap)
    }
}

private struct EnvironmentReader {
    private let values: [String: String]

    init(_ values: [String: String]) { self.values = values }

    func string(_ key: String, default fallback: String? = nil) -> String? {
        guard let raw = values[key], !raw.isEmpty else { return fallback }
        return raw
    }

    func bool(_ key: String) -> Bool {
        guard let raw = values[key], !raw.isEmpty else { return false }
        switch raw.lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    func int(_ key: String, default fallback: Int) -> Int {
        guard let raw = values[key], let value = Int(raw) else { return fallback }
        return value
    }

    func double(_ key: String, default fallback: Double) -> Double {
        guard let raw = values[key], let value = Double(raw) else { return fallback }
        return value
    }

    func time(_ key: String, default fallback: TimeInterval) -> TimeInterval {
        guard let raw = values[key], let value = Double(raw), value >= 0 else { return fallback }
        return value
    }
}
