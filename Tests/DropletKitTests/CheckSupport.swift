import Foundation

/// Minimal command-line assertion runner, not an XCTest replacement in the app.
/// No network/package dependency or full Xcode installation is required.
enum Checks {
    static let lock = NSLock()
    private static var failures = 0
    private static var assertions = 0

    static var counts: (failures: Int, assertions: Int) {
        lock.lock(); defer { lock.unlock() }
        return (failures, assertions)
    }

    static func check(_ condition: Bool, _ message: String, file: StaticString, line: UInt) {
        lock.lock(); defer { lock.unlock() }
        assertions += 1
        if !condition {
            failures += 1
            print("FAIL \(file):\(line): \(message)")
        }
    }
}

func recordFailure(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    Checks.check(false, message, file: file, line: line)
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "Values differ", file: StaticString = #filePath, line: UInt = #line) {
    Checks.check(a == b, "\(message): \(a) vs \(b)", file: file, line: line)
}

func expectTrue(_ value: Bool, _ message: String = "Expected true", file: StaticString = #filePath, line: UInt = #line) {
    Checks.check(value, message, file: file, line: line)
}

func expectFalse(_ value: Bool, _ message: String = "Expected false", file: StaticString = #filePath, line: UInt = #line) {
    Checks.check(!value, message, file: file, line: line)
}

func expectNil<T>(_ value: T?, _ message: String = "Expected nil", file: StaticString = #filePath, line: UInt = #line) {
    Checks.check(value == nil, message, file: file, line: line)
}

func expectAtLeast<T: Comparable>(_ value: T, _ minimum: T, file: StaticString = #filePath, line: UInt = #line) {
    Checks.check(value >= minimum, "Expected \(value) >= \(minimum)", file: file, line: line)
}

func expectThrows<T>(_ action: @autoclosure () throws -> T, _ message: String = "Expected error", file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try action(); Checks.check(false, message, file: file, line: line) }
    catch { Checks.check(true, "", file: file, line: line) }
}
