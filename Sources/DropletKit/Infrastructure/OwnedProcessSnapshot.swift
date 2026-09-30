import Foundation

/// Revalidate the kernel start time before every signal, including delayed
/// cleanup after children have reparented. Failure to identify means no signal.
struct OwnedProcessSnapshot {
    let identities: [ProcessIdentity]
    let identify: (pid_t) -> ProcessIdentity?
    let signal: (pid_t, Int32) -> Int32

    init(pids: [pid_t], identify: @escaping (pid_t) -> ProcessIdentity?, signal: @escaping (pid_t, Int32) -> Int32) {
        self.identities = Array(Set(pids)).filter { $0 > 1 }.compactMap(identify)
        self.identify = identify
        self.signal = signal
    }

    func send(_ number: Int32) {
        for identity in identities where identify(identity.pid) == identity {
            _ = signal(identity.pid, number)
        }
    }

    var hasLiveMember: Bool {
        identities.contains { identify($0.pid) == $0 }
    }
}
