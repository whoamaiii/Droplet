import Cocoa

struct ProcessIdentity: Equatable, Sendable {
    let pid: pid_t
    let seconds: Int
    let microseconds: Int
}

enum ProcessInspector {
    static func identity(of pid: pid_t) -> ProcessIdentity? {
        guard let time = startTime(of: pid) else { return nil }
        return ProcessIdentity(pid: pid, seconds: time.0, microseconds: time.1)
    }


    /// Every descendant of `root` (children, grandchildren, …).
    /// Read straight from the kernel, so it is exact — no command-line string
    /// matching that could hit an unrelated process that merely has the same
    /// program name.
    static func descendantPIDs(of root: pid_t) -> [pid_t] {
        descendantPIDs(of: root, in: processTable())
    }

    static func descendantPIDs(of root: pid_t, in entries: [(pid: pid_t, ppid: pid_t)]) -> [pid_t] {
        var childrenOf: [pid_t: [pid_t]] = [:]
        for entry in entries {
            childrenOf[entry.ppid, default: []].append(entry.pid)
        }

        var found: [pid_t] = []
        var queue = childrenOf[root] ?? []
        var seen: Set<pid_t> = [root]
        while let pid = queue.popLast() {
            guard pid > 1, seen.insert(pid).inserted else { continue }
            found.append(pid)
            queue.append(contentsOf: childrenOf[pid] ?? [])
        }
        return found
    }

    /// Sort key that puts the oldest process first, PID breaking exact ties.
    /// A process whose start time can't be read sorts last, so it yields.
    /// NSRunningApplication.launchDate is nil for a process started outside
    /// LaunchServices (launchd's `Program`, a direct exec), which is exactly
    /// when the instance guard needs a reliable answer — hence the kernel.
    static func rank(of pid: pid_t) -> (Int, Int, Int32) {
        guard let started = startTime(of: pid) else { return (.max, .max, pid) }
        return (started.0, started.1, pid)
    }

    static func isZombie(_ pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat == SZOMB
    }

    /// Wall-clock start time (seconds, microseconds) of `pid`.
    private static func startTime(of pid: pid_t) -> (Int, Int)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return (Int(started.tv_sec), Int(started.tv_usec))
    }

    /// (pid, ppid) for every process on the system.
    private static func processTable() -> [(pid: pid_t, ppid: pid_t)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // the table can grow between sizing and reading — ask for some slack
        let stride = MemoryLayout<kinfo_proc>.stride
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = entries.count * stride
        let ok = entries.withUnsafeMutableBufferPointer { buffer -> Bool in
            sysctl(&mib, 4, buffer.baseAddress, &size, nil, 0) == 0
        }
        guard ok else { return [] }

        return entries.prefix(size / stride).map {
            (pid: $0.kp_proc.p_pid, ppid: $0.kp_eproc.e_ppid)
        }
    }
}
