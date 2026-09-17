import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Reassembles byte chunks before decoding, preserving split UTF-8 and final lines.
struct LineFramer {
    private var bytes: [UInt8] = []
    private var droppingLongLine = false
    let limit: Int = 65_536

    mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 10 || byte == 13 {
                if !bytes.isEmpty { lines.append(String(decoding: bytes, as: UTF8.self)) }
                bytes.removeAll(keepingCapacity: true)
                droppingLongLine = false
            } else if !droppingLongLine {
                if bytes.count < limit { bytes.append(byte) }
                else {
                    // Bound memory even when a broken executable never emits a newline.
                    bytes.removeAll(keepingCapacity: true)
                    droppingLongLine = true
                }
            }
        }
        return lines
    }

    mutating func finish() -> [String] {
        defer { bytes.removeAll(); droppingLongLine = false }
        return bytes.isEmpty ? [] : [String(decoding: bytes, as: UTF8.self)]
    }
}

struct CommandResult {
    let status: Int32
    let cancelled: Bool
    let lastError: String
    let tail: [String]
}

/// Owns one process group. All spawning, draining, signalling and reaping happen
/// off-main. Output and completion are dispatched FIFO to the same callback queue.
/// No Foundation Process/SIGCHLD reaper is allowed to reap these children.
final class ManagedCommand: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private static let spawnLock = NSLock()

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var cancellationRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func start(executable: URL, arguments: [String], environment: [String: String],
               timeout: TimeInterval? = nil, callbackQueue: DispatchQueue = .main,
               onLines: @escaping ([String]) -> Void,
               onCompletion: @escaping (CommandResult) -> Void) {
        lock.lock()
        precondition(!started, "A ManagedCommand can only be started once")
        started = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            let result = execute(executable: executable, arguments: arguments,
                                 environment: environment, timeout: timeout) { lines in
                callbackQueue.async { onLines(lines) }
            }
            callbackQueue.async { onCompletion(result) }
        }
    }

    private func execute(executable: URL, arguments: [String], environment: [String: String],
                         timeout: TimeInterval?, emit: ([String]) -> Void) -> CommandResult {
        if cancellationRequested {
            return CommandResult(status: 130, cancelled: true, lastError: "", tail: [])
        }
        let argvStrings = [executable.path] + arguments
        let envStrings = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        guard !(argvStrings + envStrings).contains(where: { $0.utf8.contains(0) }) else {
            return CommandResult(status: 126, cancelled: false,
                                 lastError: "ERROR: Invalid NUL byte in command", tail: [])
        }
        var argv = argvStrings.map { strdup($0) } + [nil]
        var envp = envStrings.map { strdup($0) } + [nil]
        defer { for p in argv { free(p) }; for p in envp { free(p) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else {
            return CommandResult(status: 126, cancelled: false, lastError: "ERROR: Out of memory", tail: [])
        }
        var pid: pid_t = -1
        var fd: Int32 = -1
        Self.spawnLock.lock()
        let spawnError = droplet_spawn(executable.path, &argv, &envp, &pid, &fd)
        Self.spawnLock.unlock()
        guard spawnError == 0 else {
            return CommandResult(status: 127, cancelled: cancellationRequested,
                                 lastError: "ERROR: Couldn't launch \(executable.lastPathComponent): \(String(cString: strerror(spawnError)))",
                                 tail: [])
        }
        defer { close(fd) }
        var framer = LineFramer()
        var tail: [String] = []
        var lastError = ""
        func consume(_ lines: [String]) {
            guard !lines.isEmpty else { return }
            for line in lines {
                if line.hasPrefix("ERROR:") { lastError = line }
                tail.append(String(line.prefix(2_048)))
            }
            if tail.count > 20 { tail.removeFirst(tail.count - 20) }
            emit(lines)
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        var stopAt: TimeInterval?
        var exitedAt: TimeInterval?
        var sentKill = false
        var eof = false
        var childExited: Int32 = 0
        var status: Int32 = 1
        var ownsChild = true
        var timedOut = false
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            // Observe FIRST, without reaping. Even an exited leader reserves its
            // PID until after the final group signal, eliminating PID-reuse races.
            if childExited == 0 {
                let error = droplet_observe(pid, &childExited, &status)
                if error == ECHILD {
                    ownsChild = false // A foreign reaper would invalidate ownership.
                    lastError = "ERROR: Lost child-process ownership; refusing to signal a reused PID."
                    status = 1
                    break
                } else if error != 0 && error != EINTR {
                    lastError = "ERROR: Couldn't observe process: \(String(cString: strerror(error)))"
                    if stopAt == nil { stopAt = now; _ = droplet_signal_group(pid, SIGTERM) }
                }
                if childExited != 0 { exitedAt = now }
            }
            timedOut = timedOut || timeout.map { now - startedAt >= $0 } == true
            if stopAt == nil && (cancellationRequested || timedOut || childExited != 0) {
                stopAt = now
                _ = droplet_signal_group(pid, SIGTERM)
            }
            if let stopAt, !sentKill, now - stopAt >= 1 {
                _ = droplet_signal_group(pid, SIGKILL)
                sentKill = true
            }
            if !eof {
                // Bounded batch: a noisy child cannot starve cancellation checks.
                for _ in 0..<16 {
                    let count = read(fd, &buffer, buffer.count)
                    if count > 0 { consume(framer.append(Data(buffer.prefix(count)))) }
                    else if count == 0 { eof = true; break }
                    else if errno == EINTR { continue }
                    else if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    else {
                        lastError = "ERROR: Couldn't read process output."
                        eof = true
                        if stopAt == nil { stopAt = now; _ = droplet_signal_group(pid, SIGTERM) }
                        break
                    }
                }
            }
            if childExited != 0 && eof { break }
            // A child deliberately escaping its group may retain a pipe; never
            // hang shutdown forever waiting on that inherited descriptor.
            if let exitedAt, sentKill, now - exitedAt > 2 { break }
            var pollFD = pollfd(fd: eof ? -1 : fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&pollFD, 1, 40)
        }
        if ownsChild {
            // Also removes descendants that closed stdout/stderr. The zombie
            // leader remains reserved until AFTER this last group signal.
            _ = droplet_signal_group(pid, SIGKILL)
            _ = droplet_reap(pid)
        }
        consume(framer.finish()) // Final ERROR without newline precedes completion.
        if timedOut { lastError = "ERROR: Command timed out."; status = 124 }
        return CommandResult(status: status, cancelled: cancellationRequested,
                             lastError: lastError, tail: tail)
    }
}
