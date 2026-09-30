import Foundation

/// A delayed cleanup can also be flushed during quit. Concurrent calls wait for
/// the first caller to finish instead of running effects twice or skipping them.
final class OnceCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func run() {
        lock.lock(); defer { lock.unlock() }
        guard let action else { return }
        self.action = nil
        action()
    }
}
