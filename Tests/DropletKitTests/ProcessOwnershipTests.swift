import Foundation
@testable import DropletKit

struct ProcessOwnershipTests {
    @MainActor
    func testRealChildrenStopAndUnrelatedProcessSurvives() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let helper = folder.appendingPathComponent("owned-engine")
        try Data("#!/bin/sh\ntrap '' TERM\n/opt/homebrew/bin/ffmpeg -v error -re -f lavfi -i color=c=blue:s=16x16:r=1 -t 30 -f null - &\nwait\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        unrelated.arguments = ["-v", "error", "-re", "-f", "lavfi", "-i", "color=c=red:s=16x16:r=1", "-t", "30", "-f", "null", "-"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() } }
        let engine = Process()
        var environment = DownloadEnvironment.live
        environment.downloaderURL = helper
        environment.downloadsFolder = folder
        environment.readClipboardURL = { URL(string: "https://example.invalid/fixture") }
        environment.makeProcess = { engine }
        environment.playSound = { _ in }
        let manager = DownloadManager(environment: environment)
        manager.startDownload()
        var children: [Int32] = []
        let deadline = Date().addingTimeInterval(2)
        while children.isEmpty && Date() < deadline {
            children = ProcessInspector.descendantPIDs(of: engine.processIdentifier)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        expectFalse(children.isEmpty, "Actual helper must have a child to test")
        let identities = children.compactMap { ProcessInspector.identity(of: $0) }
        manager.cancel()
        manager.cancel()
        manager.shutdownForQuit() // Before delayed cleanup can run.
        let stoppedBy = Date().addingTimeInterval(2)
        while engine.isRunning && Date() < stoppedBy { try await Task.sleep(nanoseconds: 10_000_000) }
        expectFalse(engine.isRunning)
        // Reaped children disappear; zombies have exited and cannot execute.
        for identity in identities {
            var exited = false
            while !exited && Date() < stoppedBy {
                let current = ProcessInspector.identity(of: identity.pid)
                exited = current != identity || ProcessInspector.isZombie(identity.pid)
                if !exited { try await Task.sleep(nanoseconds: 10_000_000) }
            }
            expectTrue(exited, "An owned real child must no longer execute")
        }
        expectTrue(unrelated.isRunning, "Unrelated real work must survive Droplet cancellation and quit")
    }

    @MainActor
    func testDelayedCleanupSkipsReusedRootAndChildIDs() {
        let h = DownloadHarness()
        h.children = [21001, 21002]
        h.alive.formUnion(h.children)
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        let root = h.processes[0].fakePID
        manager.cancel()
        // The original root/child exit; the kernel reuses their numeric IDs.
        h.identityGenerations[root] = 2
        h.identityGenerations[21001] = 2
        h.clock.runCleanup()
        expectTrue(h.alive.contains(root), "A replacement root PID must survive")
        expectTrue(h.alive.contains(21001), "A replacement child PID must survive")
        expectFalse(h.alive.contains(21002), "The original child must still be stopped")
        let killed = Set(h.signals.filter { $0.1 == SIGKILL }.map { $0.0 })
        expectEqual(killed, [21002])
        manager.shutdownForQuit()
    }

    @MainActor
    func testUpdaterCleanupSkipsReusedIDsAndQuitDoesNotRepeat() {
        let h = DownloadHarness()
        h.children = [21001]
        h.alive.insert(21001)
        let updater = EngineUpdater(environment: h.environment)
        updater.updateDownloader()
        h.clock.runMain()
        let root = h.processes[0].fakePID
        h.identityGenerations[root] = 2
        h.identityGenerations[21001] = 2
        updater.shutdown()
        h.clock.runCleanup()
        expectTrue(h.alive.contains(root))
        expectTrue(h.alive.contains(21001))
        expectFalse(h.signals.contains { $0.1 == SIGKILL })
    }

    func testUnknownIdentityIsNeverSignalledAndKernelIdentityMatches() {
        var signalled: [Int32] = []
        let snapshot = OwnedProcessSnapshot(pids: [12345], identify: { _ in nil }, signal: { pid, _ in signalled.append(pid); return 0 })
        snapshot.send(SIGKILL)
        expectTrue(signalled.isEmpty)
        expectFalse(snapshot.hasLiveMember)
        let actual = ProcessInspector.identity(of: getpid())
        expectEqual(actual?.pid, getpid())
        expectEqual(actual, ProcessInspector.identity(of: getpid()))
    }
}
