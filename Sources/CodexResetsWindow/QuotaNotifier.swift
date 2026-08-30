import Foundation

/// What the notifier decided happened.
enum QuotaEvent: Equatable, Sendable {
    case warning(window: UsageWindowKey, usedPercent: Int, resetAt: Date)
    case critical(window: UsageWindowKey, usedPercent: Int, resetAt: Date)
    case depleted(window: UsageWindowKey, resetAt: Date)
    case restored(window: UsageWindowKey, usedPercent: Int, resetAt: Date)

    var title: String {
        switch self {
        case .warning(let window, _, _): "Codex \(window.title) window at capacity warning"
        case .critical(let window, _, _): "Codex \(window.title) window nearly used up"
        case .depleted(let window, _): "Codex \(window.title) window used up"
        case .restored(let window, _, _): "Codex \(window.title) window reset"
        }
    }

    var body: String {
        switch self {
        case .warning(let window, let percent, let resetAt):
            return "\(window.title) window is \(percent)% used. It resets at \(Formatters.timeString(resetAt))."
        case .critical(let window, let percent, let resetAt):
            return "\(window.title) window is \(percent)% used. It resets at \(Formatters.timeString(resetAt))."
        case .depleted(let window, let resetAt):
            return "\(window.title) window is used up. It resets at \(Formatters.timeString(resetAt))."
        case .restored(let window, let percent, _):
            return "\(window.title) window reset. \(100 - percent)% is available again."
        }
    }

    var isUrgent: Bool {
        switch self {
        case .critical, .depleted: true
        case .warning, .restored: false
        }
    }

    /// Stable event name used for logging and tests.
    var kind: String {
        switch self {
        case .warning: "warning"
        case .critical: "critical"
        case .depleted: "depleted"
        case .restored: "restored"
        }
    }

    /// Stable identity for one event in one server-provided reset cycle. Including the window and
    /// reset timestamp prevents primary/weekly alerts from replacing each other.
    var notificationIdentifier: String {
        "quota.\(windowKey.rawValue).\(kind).\(Int(resetAt.timeIntervalSince1970))"
    }

    private var windowKey: UsageWindowKey {
        switch self {
        case .warning(let window, _, _), .critical(let window, _, _),
             .depleted(let window, _), .restored(let window, _, _): window
        }
    }

    private var resetAt: Date {
        switch self {
        case .warning(_, _, let resetAt), .critical(_, _, let resetAt),
             .depleted(_, let resetAt), .restored(_, _, let resetAt): resetAt
        }
    }
}

/// Per-window notification state.
///
/// Two ideas borrowed from the projects we studied:
/// - `aqua5230/usage` detects a reset by watching for a sudden *drop* in used percentage, which is
///   far more reliable than comparing reset timestamps across app restarts.
/// - `ClaudeMeter` re-arms a threshold only after the value falls back below it, so a value that
///   hovers around 75% does not produce a notification every single refresh.
struct QuotaChannelState: Codable, Equatable, Sendable {
    var lastUsedPercent: Double?
    var warnedThresholds: Set<Int> = []
    var depleted: Bool = false

    /// Evaluates one window and returns any events that should fire.
    mutating func update(
        window: UsageWindowKey,
        usedPercent: Int,
        resetAt: Date,
        warningThreshold: Int,
        criticalThreshold: Int,
        resetDropPercent: Double,
        restoredBelowPercent: Double
    ) -> [QuotaEvent] {
        var events: [QuotaEvent] = []
        let current = Double(usedPercent)

        if let previous = lastUsedPercent, (previous - current) > resetDropPercent {
            // The window reset: clear the armed thresholds so the next climb warns again.
            let wasDepleted = depleted
            warnedThresholds.removeAll()
            depleted = false
            if wasDepleted || previous >= restoredBelowPercent {
                events.append(.restored(window: window, usedPercent: usedPercent, resetAt: resetAt))
            }
        }

        if usedPercent >= warningThreshold, !warnedThresholds.contains(warningThreshold) {
            warnedThresholds.insert(warningThreshold)
            events.append(.warning(window: window, usedPercent: usedPercent, resetAt: resetAt))
        }
        if usedPercent >= criticalThreshold, !warnedThresholds.contains(criticalThreshold) {
            warnedThresholds.insert(criticalThreshold)
            events.append(.critical(window: window, usedPercent: usedPercent, resetAt: resetAt))
        }
        if usedPercent >= 100, !depleted {
            depleted = true
            events.append(.depleted(window: window, resetAt: resetAt))
        }

        // Re-arm once the value falls back below each threshold.
        if usedPercent < warningThreshold { warnedThresholds.remove(warningThreshold) }
        if usedPercent < criticalThreshold { warnedThresholds.remove(criticalThreshold) }
        if Double(usedPercent) < restoredBelowPercent { depleted = false }

        lastUsedPercent = current
        return events
    }
}

/// Turns a stream of usage readings into notification events.
struct QuotaNotifier: Sendable {
    private let config: AppConfig
    private var channels: [UsageWindowKey: QuotaChannelState]

    init(config: AppConfig = .default, channels: [UsageWindowKey: QuotaChannelState] = [:]) {
        self.config = config
        self.channels = channels
    }

    mutating func evaluate(_ reading: UsageReading) -> [QuotaEvent] {
        var events: [QuotaEvent] = []
        for window in UsageWindowKey.allCases {
            let value = window == .primary ? reading.snapshot.primary : reading.snapshot.secondary
            let resetAt = value.resetAt
            var channel = channels[window] ?? QuotaChannelState()
            let produced = channel.update(
                window: window,
                usedPercent: TextFormat.clampPercent(value.usedPercent),
                resetAt: resetAt,
                warningThreshold: config.warningThreshold,
                criticalThreshold: config.criticalThreshold,
                resetDropPercent: config.resetDropPercent,
                restoredBelowPercent: config.restoredBelowPercent
            )
            channels[window] = channel
            events.append(contentsOf: produced)
        }
        return events
    }

    /// Restores state persisted across launches.
    mutating func restore(_ state: [UsageWindowKey: QuotaChannelState]) {
        channels = state
    }

    var persisted: [UsageWindowKey: QuotaChannelState] { channels }
}
