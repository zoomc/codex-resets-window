import Foundation

// MARK: - Continuation lifecycle

enum ResumeRunState: String, Codable, Sendable, CaseIterable {
    case queued
    case starting
    case running
    case retrying
    case succeeded
    case failed

    var label: String {
        switch self {
        case .queued: "Queued"
        case .starting: "Starting"
        case .running: "Running"
        case .retrying: "Retrying"
        case .succeeded: "Completed"
        case .failed: "Failed"
        }
    }

    /// States that no longer change on their own.
    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed: true
        case .queued, .starting, .running, .retrying: false
        }
    }

    /// States that occupy a child process slot.
    var isLive: Bool {
        switch self {
        case .starting, .running: true
        case .queued, .retrying, .succeeded, .failed: false
        }
    }
}

/// Why a queued continuation was created. A manual run must not be moved by a later quota refresh.
enum ResumeTrigger: String, Codable, Sendable {
    case reset
    case manual
}

/// Why a continuation stopped. Kept separate from the state so the UI can explain itself.
enum ContinuationOutcome: String, Codable, Sendable {
    case none
    case exitCode
    case launchError
    case timeout
    case cancelled
    case missingSession
    case missingCLI

    var label: String {
        switch self {
        case .none: ""
        case .exitCode: "Exited with an error"
        case .launchError: "Could not launch"
        case .timeout: "Timed out"
        case .cancelled: "Stopped manually"
        case .missingSession: "Session no longer available"
        case .missingCLI: "Codex CLI not found"
        }
    }
}

struct ResumeActivity: Codable, Equatable, Sendable {
    let state: ResumeRunState
    let scheduledAt: Date?
    let startedAt: Date?
    let finishedAt: Date?
    let lastOutput: String?
    let exitCode: Int32?
    /// 1-based launch attempt. Reset when a continuation is (re)armed by the user.
    let attempt: Int
    /// When `state == .retrying`, the moment the next attempt is due.
    let nextAttemptAt: Date?
    /// Machine-readable reason the run ended.
    let outcome: ContinuationOutcome
    /// Whether the schedule came from a reset observation or an explicit user action.
    let trigger: ResumeTrigger
    /// Whether the `codex queue` fallback has already been tried for this record. A resume that
    /// fails because the thread is open elsewhere (Codex Desktop holds the writer lock) fails
    /// identically on every retry, so the fallback runs at most once per arming.
    let liveQueued: Bool

    init(
        state: ResumeRunState,
        scheduledAt: Date? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        lastOutput: String? = nil,
        exitCode: Int32? = nil,
        attempt: Int = 1,
        nextAttemptAt: Date? = nil,
        outcome: ContinuationOutcome = .none,
        trigger: ResumeTrigger = .reset,
        liveQueued: Bool = false
    ) {
        self.state = state
        self.scheduledAt = scheduledAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.lastOutput = lastOutput
        self.exitCode = exitCode
        self.attempt = max(1, attempt)
        self.nextAttemptAt = nextAttemptAt
        self.outcome = outcome
        self.trigger = trigger
        self.liveQueued = liveQueued
    }

    /// Returns a copy with selected fields replaced.
    func replacing(
        state: ResumeRunState? = nil,
        scheduledAt: Date?? = nil,
        startedAt: Date?? = nil,
        finishedAt: Date?? = nil,
        lastOutput: String?? = nil,
        exitCode: Int32?? = nil,
        attempt: Int? = nil,
        nextAttemptAt: Date?? = nil,
        outcome: ContinuationOutcome? = nil,
        trigger: ResumeTrigger? = nil,
        liveQueued: Bool? = nil
    ) -> ResumeActivity {
        ResumeActivity(
            state: state ?? self.state,
            scheduledAt: (scheduledAt ?? self.scheduledAt),
            startedAt: (startedAt ?? self.startedAt),
            finishedAt: (finishedAt ?? self.finishedAt),
            lastOutput: (lastOutput ?? self.lastOutput),
            exitCode: (exitCode ?? self.exitCode),
            attempt: attempt ?? self.attempt,
            nextAttemptAt: (nextAttemptAt ?? self.nextAttemptAt),
            outcome: outcome ?? self.outcome,
            trigger: trigger ?? self.trigger,
            liveQueued: liveQueued ?? self.liveQueued
        )
    }

    private enum CodingKeys: String, CodingKey {
        case state, scheduledAt, startedAt, finishedAt, lastOutput, exitCode, attempt, nextAttemptAt, outcome, trigger, liveQueued
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = (try? container.decode(ResumeRunState.self, forKey: .state)) ?? .queued
        scheduledAt = try? container.decode(Date.self, forKey: .scheduledAt)
        startedAt = try? container.decode(Date.self, forKey: .startedAt)
        finishedAt = try? container.decode(Date.self, forKey: .finishedAt)
        lastOutput = try? container.decode(String.self, forKey: .lastOutput)
        exitCode = try? container.decode(Int32.self, forKey: .exitCode)
        attempt = (try? container.decode(Int.self, forKey: .attempt)) ?? 1
        nextAttemptAt = try? container.decode(Date.self, forKey: .nextAttemptAt)
        outcome = (try? container.decode(ContinuationOutcome.self, forKey: .outcome)) ?? .none
        trigger = (try? container.decode(ResumeTrigger.self, forKey: .trigger)) ?? .reset
        liveQueued = (try? container.decode(Bool.self, forKey: .liveQueued)) ?? false
    }
}

/// A persisted continuation. Survives app restarts for up to `AppConfig.retention`.
struct PersistedContinuation: Codable, Sendable {
    var createdAt: Date
    var activity: ResumeActivity
    /// Cached so a session that disappears from the index can still be identified in the UI.
    var sessionTitle: String?

    init(createdAt: Date, activity: ResumeActivity, sessionTitle: String? = nil) {
        self.createdAt = createdAt
        self.activity = activity
        self.sessionTitle = sessionTitle
    }

    private enum CodingKeys: String, CodingKey { case createdAt, activity, sessionTitle }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? .distantPast
        activity = (try? container.decode(ResumeActivity.self, forKey: .activity))
            ?? ResumeActivity(state: .queued)
        sessionTitle = try? container.decode(String.self, forKey: .sessionTitle)
    }
}

// MARK: - Usage

struct UsageWindow: Codable, Equatable, Sendable {
    let limitWindowSeconds: TimeInterval
    let resetAfterSeconds: TimeInterval
    let resetAt: Date
    let usedPercent: Int

    enum CodingKeys: String, CodingKey {
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
        case usedPercent = "used_percent"
    }

    init(limitWindowSeconds: TimeInterval, resetAfterSeconds: TimeInterval, resetAt: Date, usedPercent: Int) {
        self.limitWindowSeconds = limitWindowSeconds
        self.resetAfterSeconds = resetAfterSeconds
        self.resetAt = resetAt
        self.usedPercent = usedPercent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limitWindowSeconds = try container.decode(TimeInterval.self, forKey: .limitWindowSeconds)
        resetAfterSeconds = try container.decode(TimeInterval.self, forKey: .resetAfterSeconds)
        let resetTimestamp = try container.decode(TimeInterval.self, forKey: .resetAt)
        let usedValue = try container.decode(Double.self, forKey: .usedPercent)
        guard limitWindowSeconds.isFinite, limitWindowSeconds > 0,
              resetAfterSeconds.isFinite, resetAfterSeconds >= 0,
              resetTimestamp.isFinite, resetTimestamp > 1_600_000_000,
              usedValue.isFinite, usedValue >= 0, usedValue <= 100 else {
            throw DecodingError.dataCorruptedError(
                forKey: .resetAt,
                in: container,
                debugDescription: "Usage window contains an invalid range"
            )
        }
        resetAt = Date(timeIntervalSince1970: resetTimestamp)
        usedPercent = Int(usedValue.rounded())
    }

    var remainingPercent: Int { TextFormat.clampPercent(100 - usedPercent) }
    var resetText: String { Formatters.timeString(resetAt) }
    var resetDateText: String { Formatters.dateString(resetAt) }

    func countdownText(now: Date = Date()) -> String {
        TextFormat.countdown(resetAt.timeIntervalSince(now))
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    let primary: UsageWindow
    let secondary: UsageWindow

    enum CodingKeys: String, CodingKey { case rateLimit = "rate_limit" }
    enum RateLimitKeys: String, CodingKey { case primary = "primary_window", secondary = "secondary_window" }

    init(primary: UsageWindow, secondary: UsageWindow) {
        self.primary = primary
        self.secondary = secondary
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        let rate = try root.nestedContainer(keyedBy: RateLimitKeys.self, forKey: .rateLimit)
        primary = try rate.decode(UsageWindow.self, forKey: .primary)
        secondary = try rate.decode(UsageWindow.self, forKey: .secondary)
    }

    func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: CodingKeys.self)
        var rate = root.nestedContainer(keyedBy: RateLimitKeys.self, forKey: .rateLimit)
        try rate.encode(primary, forKey: .primary)
        try rate.encode(secondary, forKey: .secondary)
    }
}

/// A usage snapshot paired with the moment it was read, so the UI can say how old it is.
struct UsageReading: Codable, Equatable, Sendable {
    let snapshot: UsageSnapshot
    let fetchedAt: Date
}

enum UsageFreshness: Equatable, Sendable {
    case fresh
    case stale
    case unknown

    var label: String {
        switch self {
        case .fresh: "Live"
        case .stale: "Stale"
        case .unknown: "Offline"
        }
    }
}

// MARK: - Sessions

struct CodexSession: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let threadName: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey { case id, threadName = "thread_name", updatedAt = "updated_at" }

    init(id: String, threadName: String, updatedAt: Date) {
        self.id = id
        self.threadName = threadName
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        threadName = (try? container.decode(String.self, forKey: .threadName)) ?? ""
        let timestamp = try container.decode(String.self, forKey: .updatedAt)
        guard let parsed = Formatters.parseTimestamp(timestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .updatedAt,
                in: container,
                debugDescription: "Unsupported ISO8601 timestamp"
            )
        }
        updatedAt = parsed
    }

    var displayName: String { threadName.isEmpty ? "Untitled session" : threadName }
    var updatedText: String { Formatters.dateTimeString(updatedAt) }
}

// MARK: - Transcript events

/// The two transcript events that tell us whether a turn is still going.
enum SessionTaskState: Equatable, Sendable {
    case unknown
    case running
    case completed
}

/// Token totals emitted by Codex's local `token_count` transcript event.
///
/// These are measured local session totals, not a reconstruction from quota percentage. Older
/// transcripts may not contain this event, in which case the UI deliberately reports unavailable.
struct TokenUsage: Equatable, Sendable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64
    let measuredAt: Date?

    init(inputTokens: Int64, cachedInputTokens: Int64, outputTokens: Int64,
         reasoningOutputTokens: Int64, totalTokens: Int64? = nil, measuredAt: Date? = nil) {
        let safeInput = max(0, inputTokens)
        let safeCached = max(0, cachedInputTokens)
        let safeOutput = max(0, outputTokens)
        let safeReasoning = max(0, reasoningOutputTokens)
        self.inputTokens = safeInput
        self.cachedInputTokens = safeCached
        self.outputTokens = safeOutput
        self.reasoningOutputTokens = safeReasoning
        self.totalTokens = max(0, totalTokens ?? Self.saturatingAdd(safeInput, safeOutput))
        self.measuredAt = measuredAt
    }

    func adding(_ other: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: Self.saturatingAdd(inputTokens, other.inputTokens),
            cachedInputTokens: Self.saturatingAdd(cachedInputTokens, other.cachedInputTokens),
            outputTokens: Self.saturatingAdd(outputTokens, other.outputTokens),
            reasoningOutputTokens: Self.saturatingAdd(reasoningOutputTokens, other.reasoningOutputTokens),
            totalTokens: Self.saturatingAdd(totalTokens, other.totalTokens),
            measuredAt: [measuredAt, other.measuredAt].compactMap { $0 }.max()
        )
    }

    var compactTotal: String { TextFormat.compactNumber(totalTokens) }
    var detailDescription: String {
        "input \(TextFormat.compactNumber(inputTokens)) · cached \(TextFormat.compactNumber(cachedInputTokens)) · output \(TextFormat.compactNumber(outputTokens)) · reasoning \(TextFormat.compactNumber(reasoningOutputTokens))"
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }
}
