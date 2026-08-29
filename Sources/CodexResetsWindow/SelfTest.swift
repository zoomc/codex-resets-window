import Foundation

/// A pocket-sized test harness.
///
/// The Command Line Tools toolchain that this project builds with ships neither XCTest nor
/// swift-testing, so `swift test` cannot run here at all. Rather than add a dependency, the tests
/// live inside the product and are invoked with `--selftest`. They are plain Swift, they run in
/// milliseconds, and they exercise the same types the app does.
struct TestRunner {
    struct Failure {
        let test: String
        let message: String
    }

    private(set) var failures: [Failure] = []
    private(set) var checks = 0
    private(set) var executed: [String] = []

    var isVerbose: Bool

    init(verbose: Bool = false) { self.isVerbose = verbose }

    // MARK: - Assertions

    mutating func expect(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) {
        checks += 1
        if !condition {
            failures.append(Failure(test: currentTest ?? file, message: "\(message) (\(file):\(line))"))
        }
    }

    mutating func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: String = #fileID, line: Int = #line) {
        checks += 1
        if lhs != rhs {
            let detail = message.isEmpty ? "" : "\(message) — "
            failures.append(Failure(test: currentTest ?? file, message: "\(detail)expected <\(rhs)>, got <\(lhs)> (\(file):\(line))"))
        }
    }

    mutating func expectNil<T>(_ value: T?, _ message: String, file: String = #fileID, line: Int = #line) {
        checks += 1
        if value != nil {
            failures.append(Failure(test: currentTest ?? file, message: "\(message) — expected nil (\(file):\(line))"))
        }
    }

    mutating func expectNotNil<T>(_ value: T?, _ message: String, file: String = #fileID, line: Int = #line) {
        checks += 1
        if value == nil {
            failures.append(Failure(test: currentTest ?? file, message: "\(message) — expected non-nil (\(file):\(line))"))
        }
    }

    mutating func expectAlmost(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-6, _ message: String = "", file: String = #fileID, line: Int = #line) {
        checks += 1
        if abs(lhs - rhs) > tolerance {
            let detail = message.isEmpty ? "" : "\(message) — "
            failures.append(Failure(test: currentTest ?? file, message: "\(detail)expected <\(rhs)> ±\(tolerance), got <\(lhs)> (\(file):\(line))"))
        }
    }

    mutating func note(_ message: String) {
        if isVerbose { print("      · \(message)") }
    }

    private var currentTest: String?
    mutating func begin(_ test: String) {
        currentTest = test
        executed.append(test)
        if isVerbose { print("    \(test)") }
    }

    // MARK: - Reporting

    var summary: String {
        if failures.isEmpty {
            return "✓ \(executed.count) test cases, \(checks) assertions — all passed"
        }
        var lines = ["✗ \(failures.count) failure(s) across \(executed.count) test cases, \(checks) assertions:"]
        for failure in failures { lines.append("   · [\(failure.test)] \(failure.message)") }
        return lines.joined(separator: "\n")
    }
}

/// Yields enough times for `@MainActor` work enqueued with `Task` to make progress.
func settle(_ iterations: Int = 40) async {
    for _ in 0..<iterations { await Task.yield() }
    if iterations > 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
    await Task.yield()
}

/// Creates a throwaway directory that is removed when the returned closure runs.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("crw-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}
