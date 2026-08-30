import Foundation

/// Reads Codex's local session index and locates session transcripts.
///
/// Two performance fixes live here:
/// 1. Transcript lookup used to walk every file under `~/.codex/sessions` on every call — once per
///    reconciliation pass, on the main thread. Codex names transcripts
///    `rollout-<timestamp>-<session-uuid>.jsonl` under `YYYY/MM/DD/`, and its session ids are
///    UUIDv7, so the date directory can be derived from the id itself. That turns an O(n) directory
///    walk into an O(1) stat. A bounded index scan is kept as the fallback.
/// 2. All parsing happens off the main thread.
struct SessionStore: Sendable {
    private let config: AppConfig
    /// Shared SQLite-backed directory. Kept as a reference so the dashboard and the scheduler see
    /// the same rows.
    let directory: ThreadDirectory

    init(config: AppConfig = .default, directory: ThreadDirectory = ThreadDirectory()) {
        self.config = config
        self.directory = directory
    }

    var indexURL: URL { config.codexHome.appendingPathComponent("session_index.jsonl") }
    var sessionsRootURL: URL { config.codexHome.appendingPathComponent("sessions", isDirectory: true) }

    // MARK: - Session index

    /// Parses `session_index.jsonl` and merges it with Codex's SQLite thread store.
    ///
    /// The index is only maintained by the desktop app, so sessions started from the CLI would be
    /// invisible otherwise. Reading the database costs one short-lived `sqlite3` process, which is
    /// why it happens off the main thread alongside the index parse.
    func loadSessions() async -> [CodexSession] {
        let url = indexURL
        let home = config.codexHome
        let directory = self.directory
        return await Task.detached(priority: .utility) {
            directory.replace(CodexDatabase.readThreads(codexHome: home))
            return Self.merge(index: Self.parseSessions(at: url), threads: directory.snapshot())
        }.value
    }

    /// Synchronous variant used by the headless self-test.
    func loadSessionsSync() -> [CodexSession] {
        directory.replace(CodexDatabase.readThreads(codexHome: config.codexHome))
        return Self.merge(index: Self.parseSessions(at: indexURL), threads: directory.snapshot())
    }

    /// Reads measured token totals for a bounded set of recent sessions off the main actor.
    func loadTokenUsage(for sessions: [CodexSession], limit: Int = 100) async -> [String: TokenUsage] {
        let candidates = Array(sessions.prefix(max(0, limit)))
        let store = self
        return await Task.detached(priority: .utility) {
            var result: [String: TokenUsage] = [:]
            for session in candidates {
                guard let transcript = store.transcriptURL(for: session.id),
                      let usage = Self.tokenUsage(in: transcript) else { continue }
                result[session.id] = usage
            }
            return result
        }.value
    }

    /// Unions both sources by id, keeping the freshest reading of each session.
    static func merge(index: [CodexSession], threads: [ThreadRecord]) -> [CodexSession] {
        var byID: [String: CodexSession] = [:]
        for session in index { byID[session.id] = session }
        for row in threads {
            let candidate = CodexSession(id: row.id, threadName: row.title, updatedAt: row.updatedAt)
            guard let existing = byID[row.id] else {
                byID[row.id] = candidate
                continue
            }
            byID[row.id] = existing.updatedAt >= candidate.updatedAt ? existing : candidate
        }
        return byID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func parseSessions(at url: URL) -> [CodexSession] {
        guard let data = try? Data(contentsOf: url) else {
            AppLog.warning("session index is unreadable", category: .session)
            return []
        }
        let text = String(decoding: data, as: UTF8.self)
        var sessions: [CodexSession] = []
        sessions.reserveCapacity(256)
        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? String, !id.isEmpty,
                  let timestamp = object["updated_at"] as? String,
                  let updatedAt = Formatters.parseTimestamp(timestamp) else { continue }
            let title = (object["thread_name"] as? String) ?? ""
            sessions.append(CodexSession(id: id, threadName: title, updatedAt: updatedAt))
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Transcript location

    /// Resolves the transcript for a session id, preferring the O(1) derived path.
    ///
    /// Newer Codex builds keep an active thread in SQLite and move finished rollouts to
    /// `archived_sessions/`, so the derived `sessions/YYYY/MM/DD/` path often comes up empty.
    /// Without the archived lookup everything downstream silently dies: the original working
    /// directory cannot be recovered, reconciliation never sees `task_complete`, and the rich
    /// context prompt has nothing to read.
    func transcriptURL(for sessionID: String) -> URL? {
        // The database knows the exact rollout path, which beats guessing from the UUIDv7 date.
        if let recorded = directory.record(for: sessionID)?.rolloutPath,
           !recorded.isEmpty,
           FileManager.default.fileExists(atPath: recorded) {
            return URL(fileURLWithPath: recorded)
        }
        if let derived = Self.derivedTranscriptURL(sessionID: sessionID, root: sessionsRootURL),
           FileManager.default.fileExists(atPath: derived.path) {
            return derived
        }
        if let archived = Self.archivedTranscriptURL(sessionID: sessionID, root: config.codexHome) {
            return archived
        }
        return Self.searchTranscript(sessionID: sessionID, root: sessionsRootURL)
    }

    /// Flat lookup in `archived_sessions/`, where finished rollouts are moved.
    static func archivedTranscriptURL(sessionID: String, root: URL) -> URL? {
        let directory = root.appendingPathComponent("archived_sessions", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.first {
            $0.pathExtension == "jsonl" && $0.lastPathComponent.contains(sessionID)
        }
    }

    /// Pure path derivation: UUIDv7 timestamp -> `YYYY/MM/DD` under `root`. Touches no disk.
    ///
    /// UUIDv7 stores a 48-bit big-endian Unix millisecond timestamp in the first three groups,
    /// which turns the old "walk every session directory" lookup into simple arithmetic.
    static func derivedTranscriptDirectory(sessionID: String, root: URL) -> URL? {
        let compact = sessionID.replacingOccurrences(of: "-", with: "")
        guard compact.count >= 12, let milliseconds = UInt64(compact.prefix(12), radix: 16) else { return nil }
        let seconds = Double(milliseconds) / 1000
        guard seconds > 1_600_000_000 else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return root
            .appendingPathComponent(String(format: "%04d", calendar.component(.year, from: date)), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", calendar.component(.month, from: date)), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", calendar.component(.day, from: date)), isDirectory: true)
    }

    /// Finds the transcript file, returning nil when it is not on disk.
    static func derivedTranscriptURL(sessionID: String, root: URL) -> URL? {
        guard let date = Self.derivedTranscriptDate(sessionID: sessionID) else { return nil }
        let prefix = "rollout-"
        // Codex encodes the file timestamp in local time, so scan the two candidate days.
        for candidate in Self.candidateDirectories(root: root, around: date) {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: candidate,
                includingPropertiesForKeys: nil
            )) ?? []
            if let match = contents.first(where: {
                $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.contains(sessionID)
            }) {
                return match
            }
        }
        return nil
    }

    /// The creation instant embedded in a UUIDv7 session id, when there is one.
    static func derivedTranscriptDate(sessionID: String) -> Date? {
        let compact = sessionID.replacingOccurrences(of: "-", with: "")
        guard compact.count >= 12, let milliseconds = UInt64(compact.prefix(12), radix: 16) else { return nil }
        let seconds = Double(milliseconds) / 1000
        guard seconds > 1_600_000_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func candidateDirectories(root: URL, around date: Date) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let offsets = [0, -86_400, 86_400]
        return offsets.compactMap { offset in
            guard let day = calendar.date(byAdding: .second, value: offset, to: date) else { return nil }
            return root
                .appendingPathComponent(String(format: "%04d", calendar.component(.year, from: day)), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", calendar.component(.month, from: day)), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", calendar.component(.day, from: day)), isDirectory: true)
        }
    }

    /// Bounded fallback scan, used when the derived path does not exist.
    private static func searchTranscript(sessionID: String, root: URL) -> URL? {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            if fileURL.lastPathComponent.contains(sessionID) { return fileURL }
        }
        return nil
    }

    // MARK: - Transcript inspection

    /// Reads the first JSONL record of a transcript, up to `limit` bytes.
    ///
    /// `FileHandle.read` errors are no longer swallowed silently: a failure is logged so a
    /// truncated or permission-denied transcript is visible instead of degrading to "no cwd".
    static func firstRecord(in fileURL: URL, limit: Int = 1_048_576) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            AppLog.warning("cannot open transcript", category: .session)
            return nil
        }
        defer { try? handle.close() }

        var buffer = Data()
        while buffer.count < limit {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: 65_536), !read.isEmpty else { break }
                chunk = read
            } catch {
                AppLog.warning("transcript read failed: \(error.localizedDescription)", category: .session)
                return nil
            }
            if let newline = chunk.firstIndex(of: 0x0A) {
                buffer.append(chunk.prefix(upTo: newline))
                break
            }
            buffer.append(chunk)
        }
        guard !buffer.isEmpty else { return nil }
        if buffer.count >= limit {
            AppLog.warning("transcript metadata exceeded the \(limit) byte read limit", category: .session)
        }
        return (try? JSONSerialization.jsonObject(with: buffer)) as? [String: Any]
    }

    /// Original working directory of a session.
    ///
    /// Preferred source is the `threads` table, which Codex keeps current. Parsing the rollout's
    /// first record remains as the fallback for older installs and for sandbox fixtures that have
    /// no database at all.
    func workingDirectory(for sessionID: String) -> URL? {
        if let recorded = Self.validatedDirectory(directory.record(for: sessionID)?.cwd)
            ?? Self.validatedDirectory(CodexDatabase.workingDirectory(sessionID: sessionID,
                                                                      codexHome: config.codexHome)) {
            return recorded
        }
        guard let transcript = transcriptURL(for: sessionID),
              let record = Self.firstRecord(in: transcript),
              let payload = record["payload"] as? [String: Any],
              let path = payload["cwd"] as? String else { return nil }
        return Self.validatedDirectory(path)
    }

    /// Turns a path into a directory URL, but only while it still exists on disk.
    private static func validatedDirectory(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// True when `directory` sits inside a Git repository.
    ///
    /// The previous version only checked for `directory/.git`, which misclassified two common
    /// layouts: running from a subdirectory of a repository, and a linked worktree or submodule
    /// where `.git` is a *file*. Both caused the app to add `--skip-git-repo-check` unnecessarily,
    /// silently weakening the CLI's trusted-directory check.
    static func isInsideGitRepository(_ directory: URL) -> Bool {
        var url = directory.standardizedFileURL
        let manager = FileManager.default
        var depth = 0
        while depth < 32 {
            let marker = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                return true
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
            depth += 1
        }
        return false
    }

    /// Whether a `task_started` event newer than `after` has been followed by its `task_complete`.
    static func taskState(in fileURL: URL, after: Date) -> SessionTaskState {
        guard let contents = boundedContents(of: fileURL) else { return .unknown }
        var activeTurnID: String?
        for line in contents.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let timestamp = object["timestamp"] as? String,
                  let eventDate = Formatters.parseTimestamp(timestamp),
                  eventDate >= after,
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            if type == "task_started" {
                activeTurnID = payload["turn_id"] as? String
            } else if type == "task_complete" {
                let turnID = payload["turn_id"] as? String
                // A completion without a matching start is not evidence that our attempt
                // finished; accepting it made unrelated historical events mark a run successful.
                if let activeTurnID, activeTurnID == turnID {
                    return .completed
                }
            }
        }
        return activeTurnID == nil ? .unknown : .running
    }

    /// Recent user requests from the transcript, newest first, trimmed and de-duplicated.
    ///
    /// Used by the "rich context" continuation mode. Only the instruction text is kept and it is
    /// truncated hard, so a prompt can never leak a large chunk of conversation into a process
    /// argument or a log line.
    static func recentRequests(in fileURL: URL, limit: Int, characterBudget: Int) -> [String] {
        guard limit > 0, characterBudget > 0, let contents = boundedContents(of: fileURL) else { return [] }
        var results: [String] = []
        for line in contents.split(separator: "\n").reversed() {
            guard results.count < limit else { break }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "response_item",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  payload["role"] as? String == "user" else { continue }
            guard let content = payload["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { item -> String? in
                guard let kind = item["type"] as? String, kind == "input_text",
                      let value = item["text"] as? String else { return nil }
                return value
            }.joined(separator: " ")
            let trimmed = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 8 else { continue }
            let clipped = String(trimmed.prefix(characterBudget))
            if !results.contains(clipped) { results.append(clipped) }
        }
        return results
    }

    /// Returns the newest cumulative `token_count` event in a local transcript.
    static func tokenUsage(in fileURL: URL, after: Date? = nil) -> TokenUsage? {
        guard let contents = boundedContents(of: fileURL) else { return nil }
        for line in contents.split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let timestamp = object["timestamp"] as? String,
                  let eventDate = Formatters.parseTimestamp(timestamp),
                  after.map({ eventDate >= $0 }) ?? true else { continue }
            let payload = (object["payload"] as? [String: Any]) ?? [:]
            guard let info = (object["info"] as? [String: Any]) ?? (payload["info"] as? [String: Any]),
                  let totals = info["total_token_usage"] as? [String: Any],
                  let input = integer(totals["input_tokens"]),
                  let output = integer(totals["output_tokens"]),
                  input >= 0, output >= 0 else { continue }
            return TokenUsage(
                inputTokens: input,
                cachedInputTokens: integer(totals["cached_input_tokens"]) ?? 0,
                outputTokens: output,
                reasoningOutputTokens: integer(totals["reasoning_output_tokens"]) ?? 0,
                totalTokens: integer(totals["total_tokens"]),
                measuredAt: eventDate
            )
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let number = value as? Int64 { return number }
        if let number = value as? Int { return Int64(number) }
        if let number = value as? Double, number.isFinite, number >= 0, number <= Double(Int64.max) {
            return Int64(number.rounded())
        }
        return nil
    }

    /// Reads only the tail of a transcript so a multi-gigabyte rollout cannot block reconciliation
    /// or allocate an unbounded string on the main actor. The first partial line is discarded.
    private static func boundedContents(of fileURL: URL, maxBytes: Int = 8 * 1024 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        let size = ((try? handle.seekToEnd()) ?? 0)
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            guard !data.isEmpty else { return nil }
            var text = String(decoding: data, as: UTF8.self)
            if offset > 0, let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            return text
        } catch {
            AppLog.warning("bounded transcript read failed: \(error.localizedDescription)", category: .session)
            return nil
        }
    }
}
