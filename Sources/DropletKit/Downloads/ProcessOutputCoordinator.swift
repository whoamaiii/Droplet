import Foundation

/// Orders output delivery before termination, even when Foundation reports the
/// process exit before its last pipe read. One coordinator per process attempt.
final class ProcessOutputCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ProcessLineBuffer()
    private var eof = false
    private var exited = false
    private var deliveredCompletion = false
    private var framingError: Error?
    private let onLines: @Sendable ([String]) -> Void
    private let onCompletion: @Sendable (Error?) -> Void

    init(onLines: @escaping @Sendable ([String]) -> Void,
         onCompletion: @escaping @Sendable (Error?) -> Void) {
        self.onLines = onLines
        self.onCompletion = onCompletion
    }

    func read(_ handle: FileHandle) {
        lock.lock(); defer { lock.unlock() }
        guard !eof else { return }
        let data = handle.availableData
        var lines: [String] = []
        if data.isEmpty {
            handle.readabilityHandler = nil
            lines = buffer.finish()
            eof = true
        } else {
            do { lines = try buffer.append(data) }
            catch { framingError = error }
        }
        // Submit while holding the lock: another callback cannot enqueue exit
        // ahead of the final lines. Delivery itself never runs under the lock.
        if !lines.isEmpty {
            let delivered = lines
            DispatchQueue.main.async { [onLines] in onLines(delivered) }
        }
        completeIfReady()
    }

    func processExited() {
        lock.lock(); defer { lock.unlock() }
        exited = true
        completeIfReady()
    }

    private func completeIfReady() {
        guard eof, exited, !deliveredCompletion else { return }
        deliveredCompletion = true
        let error = framingError
        DispatchQueue.main.async { [onCompletion] in onCompletion(error) }
    }
}
