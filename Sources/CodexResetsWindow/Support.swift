import Foundation

// MARK: - Clock

/// Time source abstraction.
///
/// Everything that schedules work reads the current date through this protocol, which is what lets
/// the self-test advance time instead of waiting five hours.
protocol Clock: Sendable {
    func now() -> Date
}

/// Wall-clock time source.
struct SystemClock: Clock {
    func now() -> Date { Date() }
}

/// A clock whose value is driven by the test.
final class MutableClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(startingAt date: Date = Date()) { current = date }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }

    func set(_ date: Date) {
        lock.lock()
        current = date
        lock.unlock()
    }
}

// MARK: - Formatters

/// `DateFormatter` is expensive to create and was previously rebuilt on every view refresh.
enum Formatters {
    static let time: DateFormatter = make(dateStyle: .none, timeStyle: .short)
    static let date: DateFormatter = make(dateStyle: .medium, timeStyle: .none)
    static let dateTime: DateFormatter = make(dateStyle: .medium, timeStyle: .short)

    // `ISO8601DateFormatter` is not `Sendable`, but these two are configured once and never
    // mutated afterwards, so the explicit opt-out is safe here.
    nonisolated(unsafe) static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let plainISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func make(dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }

    /// Parses both the fractional and plain ISO8601 forms that Codex writes to disk.
    static func parseTimestamp(_ raw: String) -> Date? {
        fractionalISO.date(from: raw) ?? plainISO.date(from: raw)
    }

    static func timeString(_ value: Date) -> String { time.string(from: value) }
    static func dateString(_ value: Date) -> String { date.string(from: value) }
    static func dateTimeString(_ value: Date) -> String { dateTime.string(from: value) }
}

// MARK: - Text helpers

enum TextFormat {
    /// Compact "3m ago" / "2h 10m" style durations.
    static func countdown(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    /// "just now" / "3m ago" style relative age.
    static func relativeAge(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        if total < 10 { return "just now" }
        if total < 60 { return "\(total)s ago" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m ago" }
        return "\(hours / 24)d ago"
    }

    static func clampPercent(_ value: Int) -> Int { max(0, min(100, value)) }

    /// Trims a free-form log line down to the last meaningful line, keeping it short.
    static func lastMeaningfulLine(_ text: String, limit: Int = 120) -> String? {
        let line = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
        guard let line else { return nil }
        return String(line.prefix(limit))
    }
}

// MARK: - Result helper

/// Lets `Result` carry a typed error while still being constructible from a throwing call.
extension Result where Failure == Error {
    init(catching body: () throws -> Success) {
        do { self = .success(try body()) } catch { self = .failure(error) }
    }
}
