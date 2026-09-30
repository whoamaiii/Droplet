import Foundation
@testable import DropletKit

struct DownloadTimeoutTests {
    @MainActor
    func testRealHangingDownloadStopsWithoutFreezingApp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let helper = folder.appendingPathComponent("hanging-engine")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let child = Process()
        var logical = Date()
        var environment = DownloadEnvironment.live
        environment.downloaderURL = helper
        environment.downloadsFolder = folder
        environment.readClipboardURL = { URL(string: "https://example.invalid/fixture") }
        environment.makeProcess = { child }
        environment.playSound = { _ in }
        environment.clock.now = { logical }
        environment.clock.scheduleOnMain = { _, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                logical.addTimeInterval(130)
                work.perform()
            }
        }
        let manager = DownloadManager(environment: environment)
        let started = Date()
        manager.startDownload()
        await drainMainQueue()
        expectEqual(manager.phase, .downloading, "The main queue stays responsive during a hanging process")
        while manager.phase == .downloading && Date().timeIntervalSince(started) < 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if case .failed = manager.phase { expectTrue(true) }
        else { recordFailure("Actual engine hang must become a timeout") }
        while child.isRunning && Date().timeIntervalSince(started) < 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        expectFalse(child.isRunning)
        manager.shutdownForQuit()
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".droplet-") }.count, 0)
    }

    @MainActor
    func testFetchingTimeoutAndStaleTimer() async {
        let h = DownloadHarness()
        let original = h.clipboard
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        let old = h.processes[0]
        h.clock.date.addTimeInterval(121)
        h.clock.runMain()
        if case .failed(let message) = manager.phase { expectTrue(message.contains("stopped making progress")) }
        else { recordFailure("A hanging fetch must fail") }
        expectTrue(manager.canRetry)
        expectEqual(old.terminateCount, 1)
        h.clock.runCleanup()
        expectFalse(h.alive.contains(old.fakePID))
        manager.retryFromFailure()
        expectEqual(h.processes[1].arguments?.last, original.absoluteString)
        old.finish(status: 0)
        await drainMainQueue()
        expectEqual(manager.phase, .downloading)
        manager.cancel()
        h.clock.date.addTimeInterval(1000)
        h.clock.runMain()
        expectEqual(manager.phase, .idle, "Cancelled watchdog must not fail a stopped job")
        h.clock.runCleanup()
    }

    @MainActor
    func testUnknownTotalProgressKeepsTransferAliveButRepeatedRecordDoesNot() async {
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        let process = h.processes[0]
        func progress(_ bytes: Int) -> String {
            process.eventLine(["event":"download", "status":"downloading", "downloaded":bytes, "title":"fixture"]) + "\n"
        }
        process.enqueueOutput(progress(1))
        await drainMainQueue()
        for bytes in 2...5 {
            h.clock.date.addTimeInterval(200)
            process.enqueueOutput(progress(bytes))
            await drainMainQueue()
            h.clock.runMain()
            expectEqual(manager.phase, .downloading)
        }
        expectFalse(manager.progressKnown)
        h.clock.date.addTimeInterval(301)
        process.enqueueOutput(progress(5))
        await drainMainQueue()
        h.clock.runMain()
        if case .failed = manager.phase { expectTrue(true) }
        else { recordFailure("Repeated output cannot keep a stuck transfer alive") }
        h.clock.runCleanup()
    }

    @MainActor
    func testProcessingAndTotalLimits() async {
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        let process = h.processes[0]
        process.enqueueOutput(process.eventLine(["event":"postprocess", "processor":"Merger"]) + "\n")
        await drainMainQueue()
        h.clock.date.addTimeInterval(600)
        h.clock.runMain()
        expectEqual(manager.phase, .downloading, "A quiet merge gets a longer processing allowance")
        h.clock.date.addTimeInterval(1800)
        h.clock.runMain()
        if case .failed = manager.phase { expectTrue(true) }
        else { recordFailure("Processing must still be bounded") }
        h.clock.runCleanup()
        manager.retryFromFailure()
        let next = h.processes[1]
        h.clock.date.addTimeInterval(6 * 60 * 60)
        next.enqueueOutput(next.eventLine(["event":"download", "status":"downloading", "downloaded":1]) + "\n")
        await drainMainQueue()
        h.clock.runMain()
        if case .failed(let message) = manager.phase { expectTrue(message.contains("six-hour")) }
        else { recordFailure("Even active output cannot evade the total lifetime bound") }
        h.clock.runCleanup()
    }
}
