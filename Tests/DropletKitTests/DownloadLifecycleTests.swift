import Foundation
@testable import DropletKit

final class DownloadLifecycleTests{
    @MainActor
    func testQuitWhileMergingClearsOnlyOwnedWork() async {
        let h = DownloadHarness()
        h.children = [21001]
        h.alive.formUnion([21001, 99999])
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        let process = h.processes[0]
        process.enqueueOutput(process.eventLine(["event":"postprocess", "processor":"Merger"]) + "\n")
        await drainMainQueue()
        expectEqual(manager.stage, .merging)
        manager.shutdownForQuit()
        expectEqual(manager.phase, .idle)
        expectNil(manager.result)
        expectFalse(h.alive.contains(process.fakePID))
        expectFalse(h.alive.contains(21001))
        expectTrue(h.alive.contains(99999))
        process.finish(status: 0)
        await drainMainQueue()
        expectEqual(manager.phase, .idle)
        expectNil(manager.result)
    }

    @MainActor
    func testRepeatedStartKeepsExactlyOneJob() {
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        manager.startDownload()
        expectEqual(h.processes.count, 1)
        expectEqual(manager.phase, .downloading)
        manager.cancel()
    }

    @MainActor
    func testOldExitCannotOverwriteReplacementJob() async {
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        let old = h.processes[0]
        manager.cancel()
        manager.startDownload()
        old.finish(status: 0)
        await drainMainQueue()
        expectEqual(manager.phase, .downloading)
        expectTrue(h.processes[1].isRunning)
        manager.cancel()
        expectEqual(h.processes[1].terminateCount, 1, "Old completion must not clear the current task reference")
    }

    @MainActor
    func testQueuedOldOutputCannotOverwriteReplacementProgress() async {
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        h.processes[0].enqueueOutput(h.processes[0].eventLine(["event": "download", "status": "downloading", "downloaded": 87, "total": 100, "title": "old"]) + "\n")
        manager.cancel()
        manager.startDownload()
        await drainMainQueue()
        expectEqual(manager.progress, 0)
        expectEqual(manager.title, "")
        expectEqual(manager.phase, .downloading)
        manager.cancel()
    }

    @MainActor
    func testRetryKeepsOriginalURLWhenClipboardChanges() async {
        let h = DownloadHarness()
        h.clipboard = URL(string: "https://www.youtube.com/watch?v=original")!
        let original = h.clipboard
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        h.clipboard = URL(string: "https://example.invalid/replacement")!
        manager.beginSession()
        h.processes[0].enqueueOutput("ERROR: connection timed out\n")
        h.processes[0].finish(status: 1)
        await drainMainQueue()
        expectEqual(h.processes.count, 2)
        expectEqual(h.processes[1].arguments?.last, original.absoluteString)
        let args = h.processes[1].arguments!
        // yt-dlp's own per-site headers are used; no frozen browser identity.
        expectFalse(args.contains("--user-agent"))
        expectFalse(args.contains("--referer"))
        manager.cancel()
    }

    @MainActor
    func testCancelDetachesPipeAndSignalsOnlyOwnedSnapshot() {
        let h = DownloadHarness()
        h.children = [21_001, 21_002]
        h.alive.formUnion([21_001, 21_002, 99_999])
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        let process = h.processes[0]
        manager.cancel()
        expectNil((process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler)
        expectEqual(process.terminateCount, 1)
        expectEqual(h.clock.cleanupActions.first?.0, 1)
        h.clock.runCleanup()
        let killed = Set(h.signals.filter { $0.1 == SIGKILL }.map { $0.0 })
        expectEqual(killed, [process.fakePID, 21_001, 21_002])
        expectTrue(h.alive.contains(99_999), "A bystander's process must survive")
    }

    @MainActor
    func testOpeningPopoverDoesNotResetActiveDownload() {
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        manager.progress = 0.42
        manager.title = "Active video"
        manager.beginSession()
        expectEqual(manager.phase, .downloading)
        expectEqual(manager.progress, 0.42)
        expectEqual(manager.title, "Active video")
        expectEqual(manager.session, 1)
        manager.cancel()
    }

    @MainActor
    func testLaunchFailureIsVisibleAndAllowsASecondAttempt() {
        let h = DownloadHarness()
        h.launchError = CocoaError(.fileNoSuchFile)
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        guard case .failed = manager.phase else { return recordFailure("Launch error must not report success") }
        h.launchError = nil
        manager.startDownload()
        expectEqual(manager.phase, .downloading)
        expectEqual(h.processes.count, 2)
        manager.cancel()
    }

    @MainActor
    func testShutdownUsesVirtualClockAndKillsOnlyItsOwnProcessTree() {
        let h = DownloadHarness()
        h.children = [21_001]
        h.alive.formUnion([21_001, 99_999])
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        manager.shutdownForQuit()
        expectEqual(manager.phase, .idle)
        expectAtLeast(h.clock.date.timeIntervalSince1970, 1000.5)
        expectTrue(h.alive.contains(99_999))
        expectFalse(h.alive.contains(h.processes[0].fakePID))
        expectFalse(h.alive.contains(21_001))
    }

    @MainActor
    func testUpdaterBoundaryIsObservableAndDoesNotStartTwice() async {
        let h = DownloadHarness()
        let updater = EngineUpdater(environment: h.environment)
        let manager = DownloadManager(environment: h.environment, updater: updater)
        manager.updateDownloader()
        manager.updateDownloader()
        expectEqual(h.processes.count, 1)
        expectEqual(manager.updateNote, "Updating yt-dlp…")
        h.processes[0].finish(status: 1)
        await drainMainQueue()
        expectEqual(manager.updateNote, "Engine update failed. Check your connection and try again later.")
        expectEqual(h.engineStaging.discarded.count, 1, "A failed update discards its staged copy")
        h.clock.runMain()
        expectEqual(manager.updateNote, "")
    }
    @MainActor
    func testSplitProgressAndFinalErrorBeforeExit() async {
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        let process = h.processes[0]
        let event = process.eventLine(["event": "download", "status": "downloading", "downloaded": 42, "total": 100])
        process.enqueueOutput(String(event.prefix(6)))
        await drainMainQueue()
        expectEqual(manager.progress, 0)
        process.enqueueOutput(String(event.dropFirst(6)) + "\r\nERROR: siste ø")
        await drainMainQueue()
        expectEqual(manager.progress, 0.42)
        // Fake sends process-exit first, then EOF. Final error has no newline.
        process.finish(status: 1)
        await drainMainQueue()
        expectEqual(manager.phase, .failed("siste ø"))
    }

    @MainActor
    func testEOFAwaitsExitAndOldFinalLineIsIgnored() async {
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        let old = h.processes[0]
        old.enqueueOutput("ERROR: obsolete")
        let pipe = old.standardOutput as! Pipe
        let reader = pipe.fileHandleForReading
        let handler = reader.readabilityHandler
        reader.readabilityHandler = nil
        try? pipe.fileHandleForWriting.close()
        handler?(reader)
        await drainMainQueue()
        expectEqual(manager.phase, .downloading, "EOF must wait for exit")
        manager.cancel()
        manager.startDownload()
        old.finish(status: 1)
        await drainMainQueue()
        expectEqual(manager.phase, .downloading)
        expectEqual(manager.progress, 0)
        expectEqual(h.processes.count, 2)
        manager.cancel()
    }

    @MainActor
    func testQuitFlushesAllPreviouslyCancelledJobs() throws {
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment)
        h.children = [21_001]
        h.alive.insert(21_001)
        manager.startDownload()
        manager.cancel()
        h.children = [21_002]
        h.alive.insert(21_002)
        manager.startDownload()
        manager.cancel()
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: h.folder.path).count, 2)
        manager.shutdownForQuit()
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: h.folder.path).count, 0)
        let killed = Set(h.signals.filter { $0.1 == SIGKILL }.map { $0.0 })
        expectTrue(killed.contains(21_001))
        expectTrue(killed.contains(21_002))
        let count = h.signals.count
        h.clock.runCleanup()
        expectEqual(h.signals.count, count, "Delayed timers must not repeat quit cleanup")
    }

}
