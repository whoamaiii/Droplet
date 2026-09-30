import Foundation
@testable import DropletKit

struct SingleInstanceLockTests {
    @MainActor
    func testContenderCannotRecoverOwnersTrialJournal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrialFileStore(directory: directory.appendingPathComponent("Trial"))
        let path = directory.appendingPathComponent("instance.lock")
        var owner: SingleInstanceLock? = SingleInstanceLock()
        expectEqual(owner!.acquire(at: path), .acquired)
        let trial = try PersistentTrialAccounting(store: store)
        try trial.reserve(jobID: UUID())
        let before = try store.read(key: "trial-v1")
        let contender = SingleInstanceLock()
        let resource = OwnershipBoundResource<Int>()
        var calls = 0
        resource.initialize(ownership: contender.acquire(at: path)) { calls += 1; return 3 }
        expectEqual(calls, 0, "A dormant contender must not initialize persistent state")
        expectEqual(try store.read(key: "trial-v1"), before, "Active publication journal must remain untouched")
        expectTrue(resource.value == nil)
        owner = nil
        resource.initialize(ownership: contender.acquire(at: path)) { calls += 1; return 2 }
        expectEqual(resource.value, 2, "Successor initializes fresh state after ownership")
        resource.initialize(ownership: .acquired) { calls += 1; return 1 }
        expectEqual(calls, 1, "The owner initializes state once")
    }

    @MainActor
    func testTwoRealProcessesHaveOneOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = directory.appendingPathComponent("race.lock")
        func contender() -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--instance-lock-probe", lock.path]
            return process
        }
        let first = contender(), second = contender()
        defer {
            if first.isRunning { first.terminate() }
            if second.isRunning { second.terminate() }
        }
        try first.run()
        try second.run()
        let limit = Date().addingTimeInterval(3)
        while (first.isRunning || second.isRunning) && Date() < limit {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard !first.isRunning, !second.isRunning else { return recordFailure("Lock probes must finish") }
        expectEqual(Set([first.terminationStatus, second.terminationStatus]), Set([0, 73]), "Exactly one real process may own the lock")
        let successor = SingleInstanceLock()
        expectEqual(successor.acquire(at: lock), .acquired, "OS process exit releases ownership for a successor")
    }

    func testExclusiveOwnershipAndRelease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("instance.lock")
        var owner: SingleInstanceLock? = SingleInstanceLock()
        let contender = SingleInstanceLock()
        expectEqual(owner!.acquire(at: path), .acquired)
        expectEqual(owner!.acquire(at: path), .acquired)
        expectEqual(contender.acquire(at: path), .occupied)
        owner = nil
        expectTrue(FileManager.default.fileExists(atPath: path.path), "Releasing must not unlink the stable lock inode")
        expectEqual(contender.acquire(at: path), .acquired)
    }

    func testSymlinkAndHardlinkAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        try Data("preserve".utf8).write(to: target)
        let symlink = directory.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        if case .failed = SingleInstanceLock().acquire(at: symlink) { expectTrue(true) }
        else { recordFailure("Lock must not follow symlinks") }
        let hardlink = directory.appendingPathComponent("hardlink")
        try FileManager.default.linkItem(at: target, to: hardlink)
        if case .failed = SingleInstanceLock().acquire(at: hardlink) { expectTrue(true) }
        else { recordFailure("Lock must not accept a multiply linked file") }
        expectEqual(try String(contentsOf: target), "preserve")
    }
}
