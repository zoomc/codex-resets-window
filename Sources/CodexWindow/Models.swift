import Foundation

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
        resetAt = Date(timeIntervalSince1970: try container.decode(TimeInterval.self, forKey: .resetAt))
        usedPercent = try container.decode(Int.self, forKey: .usedPercent)
    }

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
    var resetText: String { resetAt.formatted(date: .omitted, time: .shortened) }
}

struct UsageSnapshot: Decodable, Equatable, Sendable {
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
}

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
        threadName = try container.decode(String.self, forKey: .threadName)
        let timestamp = try container.decode(String.self, forKey: .updatedAt)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let parsed = fractional.date(from: timestamp) ?? plain.date(from: timestamp) else {
            throw DecodingError.dataCorruptedError(forKey: .updatedAt, in: container, debugDescription: "Unsupported ISO8601 timestamp")
        }
        updatedAt = parsed
    }

    var displayName: String { threadName.isEmpty ? "未命名对话" : threadName }
}
