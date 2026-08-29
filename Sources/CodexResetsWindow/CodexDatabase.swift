import Foundation

/// One row of Codex's `threads` table.
struct ThreadRecord: Sendable, Equatable {
    let id: String
    let title: String
    /// Working directory Codex recorded when the thread was created.
    let cwd: String
    let updatedAt: Date
    let rolloutPath: String
}

/// Lock-protected view of the threads that were last read from disk.
///
/// `SessionStore` is a value type, so the cache has to live behind a reference. It is shared
/// between the dashboard and the scheduler so a continuation launched minutes after the last
/// refresh still resolves its working directory in O(1).
final class ThreadDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: ThreadRecord] = [:]

    func replace(_ records: [ThreadRecord]) {
        lock.lock()
        rows.removeAll(keepingCapacity: true)
        for record in records { rows[record.id] = record }
        lock.unlock()
    }

    func record(for id: String) -> ThreadRecord? {
        lock.lock()
        defer { lock.unlock() }
        return rows[id]
    }

    func snapshot() -> [ThreadRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(rows.values)
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rows.isEmpty
    }
}

/// Reads Codex's SQLite thread store.
///
/// Recent Codex builds keep the authoritative session list — including every thread's original
/// working directory — in `~/.codex/state_*.sqlite`, while `session_index.jsonl` is only refreshed
/// by the desktop app. Sessions started from the CLI never reach the index at all, so without this
/// source the app cannot see or continue them.
///
/// The query runs through `/usr/bin/sqlite3` rather than linking SQLite: it keeps the package
/// dependency-free and tolerates a database that Codex may be writing to at that very moment.
/// Every failure is non-fatal — the caller falls back to the JSONL index.
enum CodexDatabase {
    static let executable = "/usr/bin/sqlite3"
    static let defaultLimit = 300
    /// A read must never outlive this, or the menu bar would hang with Codex holding a lock.
    static let timeout: TimeInterval = 3

    /// Newest `state_*.sqlite` in the Codex home, if any.
    static func databaseURL(codexHome: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: codexHome,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let candidates = entries.filter {
            $0.pathExtension == "sqlite" && $0.lastPathComponent.hasPrefix("state_")
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.sorted { lhs, rhs in modifiedAt(lhs) > modifiedAt(rhs) }.first
    }

    /// Active threads, most recently updated first.
    static func readThreads(codexHome: URL, limit: Int = defaultLimit) -> [ThreadRecord] {
        guard let database = databaseURL(codexHome: codexHome) else { return [] }
        let sql = """
        SELECT id,
               COALESCE(NULLIF(name, ''), title) AS title,
               cwd,
               COALESCE(updated_at_ms, updated_at * 1000) AS updated_ms,
               rollout_path
        FROM threads
        WHERE archived = 0
        ORDER BY updated_ms DESC
        LIMIT \(limit);
        """
        guard let output = run(database: database, sql: sql) else { return [] }
        return parse(output)
    }

    /// The working directory Codex recorded for one thread, without reading a whole rollout.
    static func workingDirectory(sessionID: String, codexHome: URL) -> String? {
        guard let database = databaseURL(codexHome: codexHome) else { return nil }
        let literal = sessionID.replacingOccurrences(of: "'", with: "''")
        guard let output = run(database: database,
                               // `parse` intentionally rejects rows without an id. Keep the id in
                               // this narrow query too; selecting only `cwd` made this fallback
                               // silently return nil for every session.
                               sql: "SELECT id, cwd FROM threads WHERE id = '\(literal)' LIMIT 1;") else { return nil }
        return parse(output).first?.cwd
    }

    // MARK: - Internals

    private static func modifiedAt(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private static func run(database: URL, sql: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-json", database.path, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            AppLog.warning("sqlite3 could not be started: \(error.localizedDescription)", category: .session)
            return nil
        }

        let box = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.append(pipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            AppLog.warning("sqlite3 read timed out after \(timeout)s", category: .session)
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            AppLog.warning("sqlite3 exited with \(process.terminationStatus)", category: .session)
            return nil
        }
        return String(decoding: box.snapshot(), as: UTF8.self)
    }

    private static func parse(_ output: String) -> [ThreadRecord] {
        guard let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var records: [ThreadRecord] = []
        records.reserveCapacity(rows.count)
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty else { continue }
            let milliseconds = (row["updated_ms"] as? NSNumber)?.doubleValue ?? 0
            records.append(ThreadRecord(
                id: id,
                title: (row["title"] as? String) ?? "",
                cwd: (row["cwd"] as? String) ?? "",
                updatedAt: Date(timeIntervalSince1970: milliseconds / 1000),
                rolloutPath: (row["rollout_path"] as? String) ?? ""
            ))
        }
        return records
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()

        func append(_ chunk: Data) {
            lock.lock()
            value.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
}
