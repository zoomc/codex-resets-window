import Foundation
import OSLog

/// Minimal structured logger.
///
/// The app is privacy-first, so the logger never receives a token, an account identifier or raw
/// conversation text. `AppLog.redact` exists as a second line of defence: anything that looks like
/// a credential or a long free-form string is truncated and masked before it reaches a handler.
enum AppLog {
    enum Level: String, CaseIterable, Sendable {
        case debug, info, warning, error

        var rank: Int {
            switch self {
            case .debug: 0
            case .info: 1
            case .warning: 2
            case .error: 3
            }
        }

        var osLogType: OSLogType {
            switch self {
            case .debug: .debug
            case .info: .info
            case .warning: .default
            case .error: .error
            }
        }
    }

    enum Category: String, Sendable {
        case app, usage, session, continuation, notification, forecast
    }

    /// Sink used by the headless self-test so assertions can inspect what was logged.
    nonisolated(unsafe) static var mirror: (@Sendable (Level, Category, String) -> Void)?

    nonisolated(unsafe) private static var minimumLevel: Level = .info
    private static let log = OSLog(subsystem: "com.codexresets.window", category: "app")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fileHandle: FileHandle?
    nonisolated(unsafe) private static var fileURL: URL?

    static func configure(verbose: Bool, directory: URL?) {
        lock.lock()
        defer { lock.unlock() }
        minimumLevel = verbose ? .debug : .info
        fileHandle = nil
        fileURL = nil
        guard let directory else { return }
        let url = directory.appendingPathComponent("CodexResetsWindow.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data().write(to: url)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
        fileURL = url
    }

    static func debug(_ message: String, category: Category = .app) { emit(.debug, category, message) }
    static func info(_ message: String, category: Category = .app) { emit(.info, category, message) }
    static func warning(_ message: String, category: Category = .app) { emit(.warning, category, message) }
    static func error(_ message: String, category: Category = .app) { emit(.error, category, message) }

    static func emit(_ level: Level, _ category: Category, _ message: String) {
        guard level.rank >= minimumLevel.rank else { return }
        let safe = redact(message)
        os_log("%{public}@", log: log, type: level.osLogType, "[\(category.rawValue)] \(safe)")
        lock.lock()
        if let fileHandle {
            let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
            fileHandle.write(Data("\(stamp) \(level.rawValue.uppercased()) [\(category.rawValue)] \(safe)\n".utf8))
        }
        lock.unlock()
        mirror?(level, category, safe)
    }

    /// Masks anything that could carry identity: bearer tokens, long free-form text, home paths.
    static func redact(_ text: String) -> String {
        var output = text
        output = output.replacingOccurrences(
            of: #"(?i)(bearer\s+)[A-Za-z0-9._\-]+"#,
            with: "$1<redacted>",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"(?i)([\w.+\-]+@[\w\-]+\.[\w.\-]+)"#,
            with: "<email>",
            options: .regularExpression
        )
        if let home = FileManager.default.homeDirectoryForCurrentUser.path as String?,
           home.count > 1 {
            output = output.replacingOccurrences(of: home, with: "~")
        }
        if output.count > 400 { output = String(output.prefix(400)) + "…" }
        return output
    }
}
