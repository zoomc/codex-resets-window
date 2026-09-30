import Foundation

/// Resolves the `PATH` a resumed Codex CLI actually needs.
///
/// A menu-bar app is started by launchd, which hands it a minimal `PATH`
/// (`/usr/bin:/bin:/usr/sbin:/sbin`). The Codex CLI is very often an npm-installed script whose
/// shebang is `#!/usr/bin/env node`, and `node` normally lives in a version-manager directory
/// (fnm, nvm, volta, asdf). Launching that CLI with launchd's `PATH` dies instantly with exit code
/// 127 — `env: node: No such file or directory` — even though the binary itself is present. The
/// stub CLI in the sandbox tests is a `#!/usr/bin/env bash` script, which is exactly why the tests
/// passed while the real npm CLI failed every time.
///
/// Discovery and execution must also agree: the old code looked for `codex` on the app's minimal
/// `PATH` and then launched the child with that same minimal `PATH`. One resolved value is used
/// for both here, so the two can never diverge again.
enum ToolchainPaths {
    /// Directories every macOS install can rely on. Also the last-resort fallback.
    static let systemDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// Package-manager and user-install locations, in priority order.
    static let wellKnownDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "~/.local/bin",
        "~/.bun/bin",
        "~/.deno/bin",
        "~/.volta/bin"
    ]

    /// Version-manager `node` directories. npm-installed CLIs are `#!/usr/bin/env node` scripts, so
    /// without one of these on the child's `PATH` they cannot start at all.
    static let nodeDirectoryGlobs = [
        "~/.local/share/fnm/node-versions/*/installation/bin",
        "~/.fnm/node-versions/*/installation/bin",
        "~/.nvm/versions/node/*/bin",
        "~/.asdf/installs/nodejs/*/bin",
        "~/.volta/tools/image/node/*/bin"
    ]

    private static let resolved: String = build()

    /// The `PATH` handed to a resumed session.
    static var value: String { resolved }

    static func entries() -> [String] { resolved.split(separator: ":").map(String.init) }

    private static func build() -> String {
        var seen = Set<String>()
        var result: [String] = []

        func append(_ candidate: String) {
            let expanded = (candidate as NSString).expandingTildeInPath
            guard seen.insert(expanded).inserted else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return }
            result.append(expanded)
        }

        // The inherited PATH goes first so a user who launched the app from a shell keeps that
        // toolchain; our guesses only fill in what launchd withheld.
        for entry in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            append(String(entry))
        }
        for directory in wellKnownDirectories { append(directory) }
        for pattern in nodeDirectoryGlobs { expandGlob(pattern).forEach(append) }
        systemDirectories.forEach(append)

        return result.isEmpty ? systemDirectories.joined(separator: ":") : result.joined(separator: ":")
    }

    /// Minimal glob: only a `~` prefix and a single interior `*` are needed here.
    ///
    /// The directory prefix is split on its final slash, so `…/node-versions/*/bin` lists the
    /// children of `node-versions`. Two details are load-bearing:
    /// - The trailing slash before the `*` must be detected on the **raw** pattern text.
    ///   `expandingTildeInPath` strips it, which would make `lastPathComponent` return
    ///   `node-versions` and filter out every real child.
    /// - An empty `leafPrefix` means "every child", not "nothing".
    private static func expandGlob(_ pattern: String) -> [String] {
        let parts = pattern.split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return [pattern] }
        let rawPrefix = String(parts[0])
        let suffix = String(parts[1])
        let endsWithSlash = rawPrefix.hasSuffix("/")
        let prefix = (rawPrefix as NSString).expandingTildeInPath
        let base = endsWithSlash ? prefix : (prefix as NSString).deletingLastPathComponent
        let leafPrefix = endsWithSlash ? "" : (prefix as NSString).lastPathComponent
        guard !base.isEmpty else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        // Sorted so the resolved PATH is deterministic and testable.
        return contents
            .filter { $0.hasPrefix(leafPrefix) }
            .sorted()
            .map { base + "/" + $0 + suffix }
    }

    /// Absolute path of `name` on the resolved `PATH`, or nil.
    static func locate(_ name: String) -> String? {
        for directory in entries() {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Whether a `node` runtime resolves on the resolved `PATH`.
    ///
    /// Lets the scheduler distinguish "Codex is not installed" from "Codex is installed but is a
    /// script whose interpreter the child cannot find" — both surface as exit code 127.
    static func hasNodeRuntime() -> Bool { locate("node") != nil }
}
