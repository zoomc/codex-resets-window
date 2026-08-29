import Foundation

/// Rolling history of remaining quota, used to forecast when a window will run dry.
///
/// Design follows the small, well-tested approach used by LimitHUD: keep a bounded series of
/// samples, fit a least-squares slope for the burn-down ETA, and compare the short-term burn
/// against a slow EWMA baseline so the UI can say "burning 2x your usual pace".
///
/// Forecasts are deliberately conservative: with fewer than `etaMinSamples` points, or less than
/// `etaMinSpan` seconds of spread, no ETA is produced. A tool that cries wolf gets ignored.
struct UsageHistory: Sendable {
    struct Sample: Codable, Equatable, Sendable {
        /// Unix time.
        let t: TimeInterval
        /// Remaining fraction, 0…1.
        let r: Double
    }

    private let config: AppConfig
    private var series: [String: [Sample]]
    private var baseline: [String: Double]

    init(config: AppConfig = .default, series: [String: [Sample]] = [:], baseline: [String: Double] = [:]) {
        self.config = config
        self.series = series
        self.baseline = baseline
    }

    // MARK: - Keys

    static func key(_ window: UsageWindowKey) -> String { window.rawValue }

    // MARK: - Recording

    /// Records a reading, coalescing refreshes that arrive within five seconds of each other.
    mutating func record(_ window: UsageWindowKey, remainingFraction: Double, at date: Date) {
        let key = Self.key(window)
        let now = date.timeIntervalSince1970
        var samples = series[key] ?? []
        if let last = samples.last, now - last.t < 5 { samples.removeLast() }
        samples.append(Sample(t: now, r: min(1, max(0, remainingFraction))))
        samples = samples.filter { now - $0.t <= config.historyMaxAge }
        if samples.count > config.historyCap { samples.removeFirst(samples.count - config.historyCap) }
        series[key] = samples

        if let burn = currentBurn(window, at: date) {
            let previous = baseline[key]
            baseline[key] = previous.map { $0 * (1 - config.baselineAlpha) + burn * config.baselineAlpha } ?? burn
        }
    }

    mutating func forget(_ window: UsageWindowKey) {
        series.removeValue(forKey: Self.key(window))
        baseline.removeValue(forKey: Self.key(window))
    }

    // MARK: - Queries

    func recent(_ window: UsageWindowKey, at date: Date = Date(), lookback: TimeInterval? = nil) -> [Sample] {
        let key = Self.key(window)
        guard let samples = series[key], let last = samples.last else { return [] }
        let window = lookback ?? config.etaLookback
        return samples.filter { last.t - $0.t <= window }
    }

    /// Estimated seconds until the window reaches zero at the current burn rate.
    /// `nil` when there is not enough data, or when the window is refilling rather than draining.
    func burnETA(_ window: UsageWindowKey, remainingFraction: Double, at date: Date = Date()) -> TimeInterval? {
        let points = recent(window, at: date)
        guard points.count >= config.etaMinSamples else { return nil }
        guard let span = points.last.map({ $0.t - points.first!.t }), span >= config.etaMinSpan else { return nil }
        guard let slope = Self.slope(points) else { return nil }

        let burn = -slope
        guard burn > 1e-7 else { return nil }
        let eta = remainingFraction / burn
        guard eta.isFinite, eta > 0 else { return nil }
        return eta
    }

    /// Short-term burn rate as a fraction per second (positive means draining).
    func currentBurn(_ window: UsageWindowKey, at date: Date = Date()) -> Double? {
        let points = recent(window, at: date, lookback: config.burnLookback)
        guard points.count >= 2,
              points.last!.t - points.first!.t >= 60,
              let slope = Self.slope(points),
              slope < 0 else { return nil }
        return -slope
    }

    /// Ratio of the current burn to the long-run baseline. `2` means twice the usual pace.
    func pace(_ window: UsageWindowKey, at date: Date = Date()) -> Double? {
        guard let current = currentBurn(window, at: date),
              let base = baseline[Self.key(window)],
              base > 1e-9 else { return nil }
        return current / base
    }

    /// True only when the forecast says the window empties *before* it resets — never cries wolf.
    func willRunDry(_ window: UsageWindowKey, remainingFraction: Double, resetAt: Date, at date: Date = Date()) -> Bool {
        guard let eta = burnETA(window, remainingFraction: remainingFraction, at: date) else { return false }
        let timeToReset = resetAt.timeIntervalSince(date)
        guard timeToReset > 0 else { return false }
        return eta < timeToReset
    }

    // MARK: - Persistence model

    struct Snapshot: Codable, Sendable {
        let series: [String: [Sample]]
        let baseline: [String: Double]
    }

    var persisted: Snapshot { Snapshot(series: series, baseline: baseline) }

    init(config: AppConfig, snapshot: Snapshot) {
        self.config = config
        self.series = snapshot.series
        self.baseline = snapshot.baseline
    }

    // MARK: - Math

    /// Least-squares slope of remaining-over-time, in fraction per second (negative when draining).
    static func slope(_ points: [Sample]) -> Double? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.t } / n
        let meanY = points.reduce(0) { $0 + $1.r } / n
        var sxx = 0.0
        var sxy = 0.0
        for point in points {
            let dx = point.t - meanX
            sxx += dx * dx
            sxy += dx * (point.r - meanY)
        }
        guard sxx > 0 else { return nil }
        return sxy / sxx
    }
}

enum UsageWindowKey: String, Codable, Sendable, CaseIterable {
    case primary
    case secondary

    var title: String {
        switch self {
        case .primary: "5-hour"
        case .secondary: "Weekly"
        }
    }
}
