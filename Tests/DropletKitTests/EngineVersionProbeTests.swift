import Foundation
@testable import DropletKit

struct EngineVersionProbeTests {
    @MainActor
    func testRealProcessRemainsResponsiveAndTimesOut() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("version-helper")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        var environment = DownloadEnvironment.live
        environment.downloaderURL = helper
        let child = Process()
        environment.makeProcess = { child }
        environment.clock.scheduleOnMain = { _, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        let probe = EngineVersionProbe(environment: environment)
        var finished = false
        let started = Date()
        probe.start { version in expectNil(version); finished = true }
        expectFalse(finished)
        await drainMainQueue()
        expectFalse(finished, "Main queue must run while subprocess is sleeping")
        while !finished && Date().timeIntervalSince(started) < 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        expectTrue(finished, "Real hanging process must time out")
        while child.isRunning && Date().timeIntervalSince(started) < 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        expectFalse(child.isRunning, "Timeout must stop the OS process, not just deliver a callback")
        expectTrue(Date().timeIntervalSince(started) < 3)
        probe.cancel()
    }

    @MainActor
    func testVersionWaitsForOutputAndExit() async {
        let h = DownloadHarness()
        let probe = EngineVersionProbe(environment: h.environment)
        var values: [String?] = []
        probe.start { values.append($0) }
        expectEqual(values.count, 0, "Starting the probe must return immediately")
        h.processes[0].enqueueOutput("2026.08.19")
        await drainMainQueue()
        expectEqual(values.count, 0)
        h.processes[0].finish(status: 0)
        await drainMainQueue()
        expectEqual(values.count, 1)
        expectEqual(values[0], "2026.08.19")
        h.clock.runMain()
        expectEqual(values.count, 1, "Cancelled deadline cannot deliver twice")
    }

    @MainActor
    func testTimeoutStopsOwnedProcessAndIgnoresLateOutput() async {
        let h = DownloadHarness()
        h.children = [21001]
        h.alive.formUnion([21001, 99999])
        let probe = EngineVersionProbe(environment: h.environment)
        var calls = 0
        probe.start { value in calls += 1; expectNil(value) }
        expectEqual(h.clock.mainActions.first?.0, 5)
        h.clock.runMain()
        expectEqual(calls, 1)
        expectEqual(h.processes[0].terminateCount, 1)
        expectFalse(h.alive.contains(h.processes[0].fakePID))
        expectFalse(h.alive.contains(21001))
        expectTrue(h.alive.contains(99999))
        h.processes[0].finish(status: 0)
        await drainMainQueue()
        expectEqual(calls, 1)
    }

    @MainActor
    func testInvalidOutputAndCancellation() async {
        for text in ["", "2026.08.19\nERROR: bad", String(repeating: "x", count: 400)] {
            let h = DownloadHarness()
            let probe = EngineVersionProbe(environment: h.environment)
            var calls = 0
            probe.start { value in calls += 1; expectNil(value) }
            if !text.isEmpty { h.processes[0].enqueueOutput(text) }
            h.processes[0].finish(status: 0)
            await drainMainQueue()
            expectEqual(calls, 1)
        }
        let h = DownloadHarness()
        let probe = EngineVersionProbe(environment: h.environment)
        var calls = 0
        probe.start { _ in calls += 1 }
        probe.cancel()
        h.processes[0].finish(status: 0)
        h.clock.runMain()
        await drainMainQueue()
        expectEqual(calls, 0)
        expectEqual(h.processes[0].terminateCount, 1)
    }
}
