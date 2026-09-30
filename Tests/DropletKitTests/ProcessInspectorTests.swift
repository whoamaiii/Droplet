import Foundation
@testable import DropletKit

final class ProcessInspectorTests {
    func testDescendantsExcludeBystandersAndRootEvenWithCycles() {
        let table: [(pid: Int32, ppid: Int32)] = [
            (100, 1), (101, 100), (102, 101), (103, 100),
            (999, 1), (1000, 999), (100, 102), (1, 100), (101, 100),
        ]
        let descendants = ProcessInspector.descendantPIDs(of: 100, in: table)
        expectEqual(Set(descendants), [101, 102, 103])
        expectEqual(descendants.count, 3, "Duplicate process rows must not cause duplicate signals")
    }

    func testActualKernelRankForThisProcessExists() {
        let rank = ProcessInspector.rank(of: getpid())
        expectTrue(rank.0 > 0 && rank.0 != Int.max)
        expectEqual(rank.2, getpid())
        let absent = ProcessInspector.rank(of: Int32.max)
        expectEqual(absent.0, Int.max)
        expectTrue(rank < absent)
    }

    @MainActor
    func testRealFoundationProcessRoutesFailureWithoutNetworkOrCookies() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Droplet-process-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temp) }
        let helper = temp.appendingPathComponent("fixture")
        try Data("#!/bin/sh\nprintf 'ERROR: local fixture failure\\n'\nsleep 0.1\nexit 1\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        var environment = DownloadEnvironment.live
        environment.downloaderURL = helper
        environment.downloadsFolder = temp
        environment.readClipboardURL = { URL(string: "https://fixture.invalid/no-network") }
        environment.playSound = { _ in }
        let manager = DownloadManager(environment: environment)
        manager.startDownload()
        defer { manager.cancel() }
        // Wait only for this real process test, with a strict five-second bound.
        let deadline = Date().addingTimeInterval(5)
        while manager.phase == .downloading && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .failed = manager.phase else { return recordFailure("Fixture failure was not delivered: \(manager.phase)") }
        expectTrue(true)
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path), ["fixture"])
    }
}
