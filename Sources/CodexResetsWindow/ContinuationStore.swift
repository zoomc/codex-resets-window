import Foundation

/// Persistence seam for continuation records.
protocol ContinuationStoring: Sendable {
    func load() -> [String: PersistedContinuation]
    func save(_ records: [String: PersistedContinuation])
}

/// `UserDefaults`-backed store with coalesced writes.
///
/// The old code encoded and wrote the whole dictionary once per mutation, and the prune pass
/// mutated once per expired record — so a batch of expiries produced a batch of full writes.
/// Writes are now debounced onto a single queue.
final class UserDefaultsContinuationStore: ContinuationStoring, @unchecked Sendable {
    private let key: String
    private let legacyKey: String
    private let suite: UserDefaults
    private let queue = DispatchQueue(label: "com.codexresets.window.continuations")
    private var pending: [String: PersistedContinuation]?
    private var workItem: DispatchWorkItem?
    private let debounce: TimeInterval

    init(suite: UserDefaults = .standard,
         key: String = "scheduledContinuations",
         legacyKey: String = "scheduledSessionIDs",
         debounce: TimeInterval = 0.4) {
        self.suite = suite
        self.key = key
        self.legacyKey = legacyKey
        self.debounce = debounce
    }

    func load() -> [String: PersistedContinuation] {
        guard let data = suite.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: PersistedContinuation].self, from: data),
              !decoded.isEmpty else {
            return migrateLegacy()
        }
        return decoded
    }

    func save(_ records: [String: PersistedContinuation]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending = records
            self.workItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.flush() }
            self.workItem = item
            self.queue.asyncAfter(deadline: .now() + self.debounce, execute: item)
        }
    }

    /// Writes immediately. Used on termination so nothing is lost.
    func flushNow() {
        queue.sync { flush() }
    }

    private func flush() {
        guard let records = pending else { return }
        pending = nil
        guard let data = try? JSONEncoder().encode(records) else { return }
        suite.set(data, forKey: key)
    }

    /// Upgrades the pre-0.2 `[String]` payload to the structured record format.
    private func migrateLegacy() -> [String: PersistedContinuation] {
        guard let legacy = suite.stringArray(forKey: legacyKey), !legacy.isEmpty else { return [:] }
        let now = Date()
        let migrated = Dictionary(uniqueKeysWithValues: legacy.map {
            ($0, PersistedContinuation(createdAt: now, activity: ResumeActivity(state: .queued)))
        })
        if let data = try? JSONEncoder().encode(migrated) {
            suite.set(data, forKey: key)
        }
        suite.removeObject(forKey: legacyKey)
        AppLog.info("migrated \(legacy.count) legacy continuation record(s)", category: .continuation)
        return migrated
    }
}

/// In-memory store used by the self-test.
final class MemoryContinuationStore: ContinuationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: PersistedContinuation]
    private(set) var saveCount = 0

    init(records: [String: PersistedContinuation] = [:]) { self.records = records }

    func load() -> [String: PersistedContinuation] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func save(_ records: [String: PersistedContinuation]) {
        lock.lock()
        self.records = records
        saveCount += 1
        lock.unlock()
    }
}

// MARK: - Orphan process ledger

/// Records child processes on disk so a relaunch can tell whether a continuation is still running.
///
/// Without this the app loses all knowledge of its children when it quits or crashes: the next
/// launch sees a `.running` record it did not start, cannot observe, and cannot stop. The ledger
/// lets the next launch decide whether the process survived (leave it alone, it is still doing
/// useful work) or died (reconcile from the transcript).
struct ProcessLedgerEntry: Codable, Equatable, Sendable {
    let sessionID: String
    let pid: Int32
    let launchedAt: Date
}

struct ProcessLedger: Sendable {
    private let fileURL: URL

    init(fileURL: URL) { self.fileURL = fileURL }

    static func defaultURL(isSandbox: Bool) -> URL {
        let name = isSandbox ? "running-processes.sandbox.json" : "running-processes.json"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codexresets")
        let directory = base.appendingPathComponent("CodexResetsWindow", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    func write(_ entries: [ProcessLedgerEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func read() -> [ProcessLedgerEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([ProcessLedgerEntry].self, from: data) else { return [] }
        return entries
    }

    func clear() { try? FileManager.default.removeItem(at: fileURL) }

    /// True when a process with this pid exists and looks like a `codex` process.
    static func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
}
